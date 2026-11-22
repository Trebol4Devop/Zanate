-- ============================================================================
-- PEMTREE · Canales del foro y presets de moderación por canal
-- Fecha: 2026-11-18
--
-- Objetivo:
--   1) Permitir crear/editar/desactivar canales en public.categorias_foro.
--   2) Restringir la escritura a administradores (lectura pública solo activos).
--   3) Crear/actualizar la política de moderación del canal en la misma operación.
--   4) Exponer una vista de administración con conteos y política resumida.
--   5) Sembrar el canal "Desmadre USAC" con moderación permisiva para humor pesado.
--
-- Idempotente. No elimina contenido ni políticas existentes.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1) Metadatos del canal
-- ---------------------------------------------------------------------------
alter table public.categorias_foro
  add column if not exists descripcion text,
  add column if not exists is_active boolean not null default true,
  add column if not exists sort_order integer not null default 0;

create index if not exists idx_categorias_foro_activas
  on public.categorias_foro (sort_order, nombre)
  where is_active = true;

-- ---------------------------------------------------------------------------
-- 2) RLS: lectura pública de activos; escritura solo admin
-- ---------------------------------------------------------------------------
alter table public.categorias_foro enable row level security;

drop policy if exists "Lectura publica de catalogo" on public.categorias_foro;
drop policy if exists "Lectura de canales (anon)" on public.categorias_foro;
drop policy if exists "Lectura de canales (auth)" on public.categorias_foro;
drop policy if exists "Escritura de canales solo admin (insert)" on public.categorias_foro;
drop policy if exists "Escritura de canales solo admin (update)" on public.categorias_foro;
drop policy if exists "Escritura de canales solo admin (delete)" on public.categorias_foro;

create policy "Lectura de canales (anon)"
  on public.categorias_foro for select to anon
  using (is_active = true);

create policy "Lectura de canales (auth)"
  on public.categorias_foro for select to authenticated
  using (
    is_active = true
    or public.is_pemtree_admin((select auth.uid()))
    or public.is_pemtree_moderator((select auth.uid()))
  );

create policy "Escritura de canales solo admin (insert)"
  on public.categorias_foro for insert to authenticated
  with check (public.is_pemtree_admin((select auth.uid())));

create policy "Escritura de canales solo admin (update)"
  on public.categorias_foro for update to authenticated
  using (public.is_pemtree_admin((select auth.uid())))
  with check (public.is_pemtree_admin((select auth.uid())));

create policy "Escritura de canales solo admin (delete)"
  on public.categorias_foro for delete to authenticated
  using (public.is_pemtree_admin((select auth.uid())));

revoke all on table public.categorias_foro from anon;
grant select on table public.categorias_foro to anon, authenticated;
grant insert, update, delete on table public.categorias_foro to authenticated;
grant all on table public.categorias_foro to service_role;

-- ---------------------------------------------------------------------------
-- 3) Vista de administración: canal + conteos + política
-- ---------------------------------------------------------------------------
create or replace view public.v_forum_category_admin
with (security_invoker = true)
as
with counts as (
  select
    p.category,
    count(*)::bigint as posts_count,
    count(*) filter (where p.moderation_status = 0)::bigint as pending_posts,
    count(*) filter (where p.moderation_status = 2)::bigint as hidden_posts
  from public.posts p
  group by p.category
)
select
  c.id,
  c.nombre,
  c.descripcion,
  c.is_active,
  c.sort_order,
  c.created_at,
  c.updated_at,
  coalesce(ct.posts_count, 0)::bigint as posts_count,
  coalesce(ct.pending_posts, 0)::bigint as pending_posts,
  coalesce(ct.hidden_posts, 0)::bigint as hidden_posts,
  (mp.entity_table is not null) as has_policy,
  mp.allow_colloquial_profanity,
  mp.allow_external_links,
  mp.require_verified_user,
  mp.laya_thresholds,
  mp.escalation_margin,
  mp.report_score_to_hide,
  mp.updated_at as policy_updated_at
from public.categorias_foro c
left join counts ct on ct.category = c.id
left join public.moderation_policies mp
  on mp.entity_table = 'posts' and mp.scope_key = c.id;

grant select on public.v_forum_category_admin to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4) RPC: crear/editar canal + política en una sola transacción
-- ---------------------------------------------------------------------------
create or replace function public.admin_upsert_forum_category(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_id text;
  v_nombre text;
  v_descripcion text;
  v_is_active boolean;
  v_sort_order integer;
  v_policy jsonb;
  v_category jsonb;
  v_policy_applied boolean := false;
begin
  if v_uid is null then
    raise exception 'No autenticado' using errcode = '42501';
  end if;
  if not public.is_pemtree_admin(v_uid) then
    raise exception 'Permiso denegado: solo administradores pueden gestionar canales del foro'
      using errcode = '42501';
  end if;

  v_nombre := nullif(trim(p_payload ->> 'nombre'), '');
  if v_nombre is null then
    raise exception 'El nombre del canal es obligatorio' using errcode = '22023';
  end if;
  if char_length(v_nombre) > 60 then
    raise exception 'El nombre del canal no puede superar 60 caracteres' using errcode = '22023';
  end if;

  v_id := lower(trim(coalesce(p_payload ->> 'id', '')));
  if v_id = '' then
    v_id := lower(translate(v_nombre, 'áéíóúüñÁÉÍÓÚÜÑ', 'aeiouunAEIOUUN'));
    v_id := regexp_replace(v_id, '[^a-z0-9]+', '_', 'g');
    v_id := trim(both '_' from v_id);
  end if;

  if v_id !~ '^[a-z0-9][a-z0-9_]{1,39}$' then
    raise exception 'Identificador de canal inválido: usa minúsculas, números y guion bajo (2-40 caracteres)'
      using errcode = '22023';
  end if;
  if v_id in ('todos', 'default') then
    raise exception 'El identificador "%" está reservado por el sistema', v_id using errcode = '22023';
  end if;

  v_descripcion := nullif(trim(p_payload ->> 'descripcion'), '');
  v_is_active := coalesce((p_payload ->> 'is_active')::boolean, true);
  v_sort_order := coalesce((p_payload ->> 'sort_order')::integer, 0);

  insert into public.categorias_foro as c (
    id, nombre, descripcion, is_active, sort_order, updated_at
  ) values (
    v_id, v_nombre, v_descripcion, v_is_active, v_sort_order, now()
  )
  on conflict (id) do update set
    nombre       = excluded.nombre,
    descripcion  = excluded.descripcion,
    is_active    = excluded.is_active,
    sort_order   = excluded.sort_order,
    updated_at   = now();

  select to_jsonb(c) into v_category
    from public.categorias_foro c where c.id = v_id;

  if (p_payload ? 'policy') and jsonb_typeof(p_payload -> 'policy') = 'object' then
    v_policy := (p_payload -> 'policy') || jsonb_build_object(
      'entity_table', 'posts',
      'scope_key', v_id
    );
    perform public.admin_upsert_moderation_policy(v_policy);
    v_policy_applied := true;
  end if;

  insert into public.moderation_audit_log (
    moderator_id, entity_table, entity_id, justification,
    is_automated, moderation_label
  ) values (
    v_uid,
    'categorias_foro',
    gen_random_uuid(),
    format('Canal "%s" (%s) %s; política %s',
      v_nombre,
      v_id,
      case when v_is_active then 'activo' else 'inactivo' end,
      case when v_policy_applied then 'actualizada' else 'sin cambios' end
    ),
    false,
    'forum_category'
  );

  return jsonb_build_object(
    'category', v_category,
    'policy_applied', v_policy_applied,
    'id', v_id
  );
end;
$$;

revoke execute on function public.admin_upsert_forum_category(jsonb) from public, anon;
grant execute on function public.admin_upsert_forum_category(jsonb) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 5) RPC: eliminar o desactivar canal
--    - Si tiene publicaciones, se desactiva (no se borra evidencia).
--    - "general" está protegido.
-- ---------------------------------------------------------------------------
create or replace function public.admin_delete_forum_category(p_id text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_id text := lower(trim(coalesce(p_id, '')));
  v_nombre text;
  v_posts bigint := 0;
begin
  if v_uid is null then
    raise exception 'No autenticado' using errcode = '42501';
  end if;
  if not public.is_pemtree_admin(v_uid) then
    raise exception 'Permiso denegado: solo administradores pueden gestionar canales del foro'
      using errcode = '42501';
  end if;
  if v_id = '' then
    raise exception 'Identificador de canal vacío' using errcode = '22023';
  end if;
  if v_id = 'general' then
    raise exception 'El canal general no se puede eliminar ni desactivar' using errcode = '22023';
  end if;

  select nombre into v_nombre from public.categorias_foro where id = v_id;
  if v_nombre is null then
    raise exception 'El canal "%" no existe', v_id using errcode = 'P0002';
  end if;

  select count(*) into v_posts from public.posts where category = v_id;

  if v_posts > 0 then
    update public.categorias_foro
       set is_active = false, updated_at = now()
     where id = v_id;

    insert into public.moderation_audit_log (
      moderator_id, entity_table, entity_id, justification,
      is_automated, moderation_label
    ) values (
      v_uid, 'categorias_foro', gen_random_uuid(),
      format('Canal "%s" (%s) desactivado: conserva %s publicaciones', v_nombre, v_id, v_posts),
      false, 'forum_category'
    );

    return jsonb_build_object(
      'deleted', false,
      'deactivated', true,
      'posts', v_posts,
      'id', v_id
    );
  end if;

  delete from public.moderation_policies
   where entity_table = 'posts' and scope_key = v_id;
  delete from public.categorias_foro where id = v_id;

  insert into public.moderation_audit_log (
    moderator_id, entity_table, entity_id, justification,
    is_automated, moderation_label
  ) values (
    v_uid, 'categorias_foro', gen_random_uuid(),
    format('Canal "%s" (%s) eliminado (sin publicaciones)', v_nombre, v_id),
    false, 'forum_category'
  );

  return jsonb_build_object(
    'deleted', true,
    'deactivated', false,
    'posts', 0,
    'id', v_id
  );
end;
$$;

revoke execute on function public.admin_delete_forum_category(text) from public, anon;
grant execute on function public.admin_delete_forum_category(text) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 6) Semilla: Desmadre USAC (humor pesado, sin profanity; acoso/doxxing siguen estrictos)
-- ---------------------------------------------------------------------------
insert into public.categorias_foro (id, nombre, descripcion, is_active, sort_order)
values (
  'desmadre',
  'Desmadre USAC',
  'Humor pesado, memes y desahogo. Se permiten groserías y chistes fuertes, pero no acoso dirigido, doxxing, difamación ni contenido explícito.',
  true,
  50
)
on conflict (id) do nothing;

insert into public.moderation_policies (
  entity_table, scope_key, allow_colloquial_profanity, allow_external_links,
  require_verified_user, laya_thresholds, escalation_margin, report_score_to_hide
) values (
  'posts',
  'desmadre',
  true,
  true,
  false,
  '{"targeted_harassment":0.65,"doxxing_or_crime":0.45,"explicit":0.75}'::jsonb,
  0.08,
  4.5
)
on conflict (entity_table, scope_key) do nothing;
