-- =============================================================================
-- Zanate · Moderación con scope de servidor + administración de canales
-- Fecha: 2026-11-22
-- =============================================================================
-- El scope de moderación de posts deja de ser el canal (`category`) y pasa a
-- ser el servidor (`carrera`). Se parchea la función vigente mediante
-- pg_get_functiondef para no duplicar su cuerpo en el repositorio.
-- =============================================================================

do $do$
declare
  v_def text;
begin
  v_def := pg_get_functiondef('public.check_content_moderation()'::regprocedure);

  -- Idempotente: si ya resuelve por carrera, no hacer nada.
  if position('new_row->>''carrera''' in v_def) = 0 then
    v_def := replace(
      v_def,
      'if v_table in (''posts'', ''marketplace_items'') and (new_row ? ''category'') then',
      'if v_table = ''posts'' then' || chr(10) ||
      '    v_scope := coalesce(nullif(trim(new_row->>''carrera''), ''''), ''default'');' || chr(10) ||
      '  elsif v_table in (''posts'', ''marketplace_items'') and (new_row ? ''category'') then'
    );
    execute v_def;
  end if;
end
$do$;

-- Vista de administración de canales por servidor.
drop view if exists public.v_forum_server_channels_admin;

create view public.v_forum_server_channels_admin
with (security_invoker = true)
as
with counts as (
  select
    p.carrera,
    p.category,
    count(*)::bigint as posts_count,
    count(*) filter (where p.moderation_status = 0)::bigint as pending_posts,
    count(*) filter (where p.moderation_status = 2)::bigint as hidden_posts
  from public.posts p
  group by p.carrera, p.category
)
select
  c.server_id,
  c.id,
  c.nombre,
  c.slug,
  c.descripcion,
  c.icon,
  c.sort_order,
  c.is_active,
  c.is_system,
  c.created_at,
  c.updated_at,
  s.nombre as server_nombre,
  s.carrera_id,
  coalesce(ct.posts_count, 0)::bigint as posts_count,
  coalesce(ct.pending_posts, 0)::bigint as pending_posts,
  coalesce(ct.hidden_posts, 0)::bigint as hidden_posts
from public.forum_server_channels c
join public.forum_servers s on s.id = c.server_id
left join counts ct on ct.carrera = s.carrera_id and ct.category = c.id;

grant select on public.v_forum_server_channels_admin to authenticated, service_role;

create or replace function public.admin_upsert_forum_server_channel(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_server_id text;
  v_id text;
  v_nombre text;
  v_slug text;
  v_result jsonb;
begin
  if v_uid is null then
    raise exception 'No autenticado' using errcode = '42501';
  end if;
  if not public.is_pemtree_admin(v_uid) then
    raise exception 'Permiso denegado: solo administradores pueden gestionar canales del foro'
      using errcode = '42501';
  end if;

  v_server_id := lower(btrim(coalesce(p_payload ->> 'server_id', '')));
  if not exists (select 1 from public.forum_servers where id = v_server_id) then
    raise exception 'El servidor "%" no existe', v_server_id using errcode = 'P0002';
  end if;

  v_id := lower(btrim(coalesce(p_payload ->> 'id', '')));
  if v_id !~ '^[a-z0-9][a-z0-9_-]{1,39}$' then
    raise exception 'Identificador de canal inválido (2-40 caracteres: minúsculas, números, guion y guion bajo)'
      using errcode = '22023';
  end if;

  v_nombre := nullif(btrim(p_payload ->> 'nombre'), '');
  if v_nombre is null then
    raise exception 'El nombre del canal es obligatorio' using errcode = '22023';
  end if;

  v_slug := lower(btrim(coalesce(p_payload ->> 'slug', '')));
  if v_slug = '' then
    v_slug := lower(translate(v_nombre, 'áéíóúüñÁÉÍÓÚÜÑ', 'aeiouunAEIOUUN'));
    v_slug := regexp_replace(v_slug, '[^a-z0-9]+', '-', 'g');
    v_slug := btrim(v_slug, '-');
  end if;

  insert into public.forum_server_channels as c (
    server_id, id, nombre, slug, descripcion, icon, sort_order, is_active, updated_at
  ) values (
    v_server_id, v_id, v_nombre, v_slug,
    nullif(btrim(p_payload ->> 'descripcion'), ''),
    coalesce(nullif(btrim(p_payload ->> 'icon'), ''), 'tag'),
    coalesce((p_payload ->> 'sort_order')::integer, 0),
    coalesce((p_payload ->> 'is_active')::boolean, true),
    now()
  )
  on conflict (server_id, id) do update set
    nombre = excluded.nombre,
    slug = excluded.slug,
    descripcion = excluded.descripcion,
    icon = excluded.icon,
    sort_order = excluded.sort_order,
    is_active = case when c.is_system then true else excluded.is_active end,
    updated_at = now();

  select to_jsonb(c) into v_result
    from public.forum_server_channels c
   where c.server_id = v_server_id and c.id = v_id;

  insert into public.moderation_audit_log (
    moderator_id, entity_table, entity_id, justification, is_automated, moderation_label
  ) values (
    v_uid, 'forum_server_channels', gen_random_uuid(),
    format('Canal "%s" (%s) guardado en servidor %s', v_nombre, v_id, v_server_id),
    false, 'forum_server_channel'
  );

  return jsonb_build_object('channel', v_result, 'server_id', v_server_id, 'id', v_id);
end;
$$;

revoke execute on function public.admin_upsert_forum_server_channel(jsonb) from public, anon;
grant execute on function public.admin_upsert_forum_server_channel(jsonb) to authenticated, service_role;

create or replace function public.admin_delete_forum_server_channel(
  p_server_id text,
  p_channel_id text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_channel public.forum_server_channels%ROWTYPE;
  v_carrera text;
  v_posts bigint := 0;
begin
  if v_uid is null then
    raise exception 'No autenticado' using errcode = '42501';
  end if;
  if not public.is_pemtree_admin(v_uid) then
    raise exception 'Permiso denegado: solo administradores pueden gestionar canales del foro'
      using errcode = '42501';
  end if;

  select * into v_channel
    from public.forum_server_channels
   where server_id = lower(btrim(p_server_id)) and id = lower(btrim(p_channel_id));
  if not found then
    raise exception 'El canal no existe en el servidor indicado' using errcode = 'P0002';
  end if;
  if v_channel.is_system then
    raise exception 'El canal "Todas las áreas" es de sistema y no se puede eliminar'
      using errcode = '22023';
  end if;

  select carrera_id into v_carrera from public.forum_servers where id = v_channel.server_id;
  select count(*) into v_posts
    from public.posts
   where carrera = v_carrera and category = v_channel.id;

  if v_posts > 0 then
    update public.forum_server_channels
       set is_active = false, updated_at = now()
     where server_id = v_channel.server_id and id = v_channel.id;
    insert into public.moderation_audit_log (moderator_id, entity_table, entity_id, justification, is_automated, moderation_label)
    values (v_uid, 'forum_server_channels', gen_random_uuid(),
      format('Canal "%s" desactivado en servidor %s: conserva %s publicaciones',
             v_channel.nombre, v_channel.server_id, v_posts),
      false, 'forum_server_channel');
    return jsonb_build_object('deleted', false, 'deactivated', true, 'posts', v_posts,
                              'server_id', v_channel.server_id, 'id', v_channel.id);
  end if;

  delete from public.forum_server_channels
   where server_id = v_channel.server_id and id = v_channel.id;
  insert into public.moderation_audit_log (moderator_id, entity_table, entity_id, justification, is_automated, moderation_label)
  values (v_uid, 'forum_server_channels', gen_random_uuid(),
    format('Canal "%s" eliminado del servidor %s', v_channel.nombre, v_channel.server_id),
    false, 'forum_server_channel');
  return jsonb_build_object('deleted', true, 'deactivated', false, 'posts', 0,
                            'server_id', v_channel.server_id, 'id', v_channel.id);
end;
$$;

revoke execute on function public.admin_delete_forum_server_channel(text, text) from public, anon;
grant execute on function public.admin_delete_forum_server_channel(text, text) to authenticated, service_role;
