-- =============================================================================
-- Zanate · Migración: Retiro completo de requerimientos AAL2 / TOTP
-- Archivo: supabase/migrations/20261121000100_drop_aal2_requirements.sql
-- =============================================================================
-- MFA/TOTP/AAL2 queda completamente fuera de la arquitectura.
-- Se retira la función require_aal2_for_authenticated_write y sus triggers asociados,
-- se eliminan las políticas restrictivas de AAL2 y se redefinen las políticas y RPCs
-- para requerir únicamente sesión autenticada no anónima (auth.uid() is not null y
-- no anónimo), conservando intactas las verificaciones de vendedor y Marketplace.
-- =============================================================================

-- 1. Eliminar triggers trg_require_aal2_writes de todas las tablas públicas
do $$
declare
  v_table record;
begin
  for v_table in
    select n.nspname, c.relname
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relkind in ('r', 'p')
  loop
    execute format(
      'drop trigger if exists trg_require_aal2_writes on %I.%I',
      v_table.nspname, v_table.relname
    );
  end loop;
end;
$$;

-- 2. Eliminar políticas restrictivas require_aal2_* de todas las tablas públicas
do $$
declare
  v_table record;
  v_name text;
begin
  for v_table in
    select n.nspname, c.relname
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relkind in ('r', 'p')
  loop
    foreach v_name in array array['require_aal2_insert', 'require_aal2_update', 'require_aal2_delete']
    loop
      execute format(
        'drop policy if exists %I on %I.%I',
        v_name, v_table.nspname, v_table.relname
      );
    end loop;
  end loop;
end;
$$;

-- 3. Eliminar la función require_aal2_for_authenticated_write
drop function if exists public.require_aal2_for_authenticated_write();

-- 4. Asegurar que las políticas restrictivas contra sesiones anónimas sigan vigentes
-- Exige auth.uid() no nulo y sesión no anónima para escrituras autenticadas.
do $$
declare
  v_table record;
  v_command text;
  v_policy text;
  v_check text := '(auth.uid() is not null and coalesce(auth.jwt() ->> ''is_anonymous'', ''false'') <> ''true'')';
begin
  for v_table in
    select n.nspname, c.relname
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relkind in ('r', 'p')
      and c.relrowsecurity
  loop
    foreach v_command in array array['insert', 'update', 'delete']
    loop
      v_policy := 'deny_anonymous_auth_' || v_command;
      execute format('drop policy if exists %I on %I.%I', v_policy, v_table.nspname, v_table.relname);

      if v_command = 'insert' then
        execute format(
          'create policy %I on %I.%I as restrictive for insert to authenticated with check (%s)',
          v_policy, v_table.nspname, v_table.relname, v_check
        );
      elsif v_command = 'update' then
        execute format(
          'create policy %I on %I.%I as restrictive for update to authenticated using (%s) with check (%s)',
          v_policy, v_table.nspname, v_table.relname, v_check, v_check
        );
      else
        execute format(
          'create policy %I on %I.%I as restrictive for delete to authenticated using (%s)',
          v_policy, v_table.nspname, v_table.relname, v_check
        );
      end if;
    end loop;
  end loop;
end;
$$;

-- 5. Actualizar funciones RPC de moderación y reportes sin comprobación de AAL2

create or replace function public.moderate_marketplace_item (
  target_item_id uuid,
  new_status integer,
  p_label text default null,
  p_confidence double precision default null,
  p_reason text default null
) returns boolean
language plpgsql security definer
set search_path to 'public'
as $$
declare
  v_user_id uuid := auth.uid();
  v_user_role text;
begin
  if v_user_id is null
     or coalesce(auth.jwt() ->> 'is_anonymous', 'false') = 'true' then
    return false;
  end if;

  select role into v_user_role
  from public.user_roles
  where user_id = v_user_id;
  if coalesce(v_user_role, '') not in ('admin', 'moderator') then
    return false;
  end if;

  update public.marketplace_items
  set moderation_status = new_status,
      moderation_label = coalesce(p_label, moderation_label),
      moderation_confidence = coalesce(p_confidence, moderation_confidence),
      moderation_reason = coalesce(nullif(trim(p_reason), ''), moderation_reason),
      moderated_at = now(),
      moderated_by = v_user_id
  where id = target_item_id;
  if not found then return false; end if;

  insert into public.moderation_audit_log (
    moderator_id, entity_table, entity_id, justification,
    is_automated, moderation_label, confidence
  ) values (
    v_user_id, 'marketplace_items', target_item_id,
    coalesce(nullif(trim(p_reason), ''), 'Moderación manual de publicación de marketplace'),
    false, p_label, p_confidence
  );
  return true;
end;
$$;

create or replace function public.report_forum_comment(
  p_comment_id uuid,
  p_reason text,
  p_details text default null
) returns boolean
language plpgsql security definer
set search_path to 'public'
as $$
begin
  if auth.uid() is null
     or coalesce(auth.jwt() ->> 'is_anonymous', 'false') = 'true' then
    raise exception 'Debes iniciar sesión con una cuenta para reportar.'
      using errcode = '42501';
  end if;
  insert into public.entity_reports (reporter_id, entity_type, entity_id, reason, details)
  values (auth.uid(), 'comment', p_comment_id, p_reason, p_details)
  on conflict (reporter_id, entity_type, entity_id) do nothing;
  return true;
end;
$$;

create or replace function public.report_forum_post(
  p_post_id uuid,
  p_reason text,
  p_details text default null
) returns boolean
language plpgsql security definer
set search_path to 'public'
as $$
begin
  if auth.uid() is null
     or coalesce(auth.jwt() ->> 'is_anonymous', 'false') = 'true' then
    raise exception 'Debes iniciar sesión con una cuenta para reportar.'
      using errcode = '42501';
  end if;
  insert into public.entity_reports (reporter_id, entity_type, entity_id, reason, details)
  values (auth.uid(), 'post', p_post_id, p_reason, p_details)
  on conflict (reporter_id, entity_type, entity_id) do nothing;
  return true;
end;
$$;

create or replace function public.report_marketplace_item(
  target_item_id uuid,
  report_reason text,
  target_seller_id uuid default null,
  target_seller_alias text default null
) returns boolean
language plpgsql security definer
set search_path to 'public'
as $$
declare
  v_count int;
begin
  if auth.uid() is null
     or coalesce(auth.jwt() ->> 'is_anonymous', 'false') = 'true' then
    return false;
  end if;

  insert into public.entity_reports (
    reporter_id, entity_type, entity_id, entity_owner_id, reason, metadata
  ) values (
    auth.uid(), 'marketplace_item', target_item_id,
    case when target_seller_id is not null and public.user_exists(target_seller_id)
      then target_seller_id else null end,
    report_reason,
    jsonb_strip_nulls(jsonb_build_object('seller_alias', target_seller_alias))
  )
  on conflict (reporter_id, entity_type, entity_id) do nothing;

  select reported_count into v_count
  from public.marketplace_items
  where id = target_item_id;
  if v_count >= 3 then
    update public.marketplace_items
    set moderation_status = 2
    where id = target_item_id;
  end if;
  return true;
exception when others then
  if sqlstate = '42501' then raise; end if;
  return false;
end;
$$;

grant execute on function public.moderate_marketplace_item(uuid, integer, text, double precision, text) to authenticated, service_role;
grant execute on function public.report_forum_comment(uuid, text, text) to anon, authenticated, service_role;
grant execute on function public.report_forum_post(uuid, text, text) to anon, authenticated, service_role;
grant execute on function public.report_marketplace_item(uuid, text, uuid, text) to anon, authenticated, service_role;
