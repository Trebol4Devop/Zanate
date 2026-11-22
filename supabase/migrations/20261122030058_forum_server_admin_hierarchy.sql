-- =============================================================================
-- Zanate · Administración de espacios con jerarquía
-- Fecha: 2026-11-22
-- =============================================================================

create or replace function public.admin_upsert_forum_server(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_id text;
  v_nombre text;
  v_icon text;
  v_color text;
  v_result jsonb;
begin
  if v_uid is null then
    raise exception 'No autenticado' using errcode = '42501';
  end if;
  if not public.is_pemtree_admin(v_uid) then
    raise exception 'Permiso denegado: solo administradores pueden gestionar espacios del foro'
      using errcode = '42501';
  end if;

  v_id := lower(btrim(coalesce(p_payload ->> 'id', '')));
  if v_id !~ '^[a-z0-9][a-z0-9_-]{1,59}$' then
    raise exception 'Identificador de espacio inválido (2-60 caracteres: minúsculas, números, guion y guion bajo)'
      using errcode = '22023';
  end if;

  v_nombre := nullif(btrim(p_payload ->> 'nombre'), '');
  if v_nombre is null then
    raise exception 'El nombre del espacio es obligatorio' using errcode = '22023';
  end if;

  v_icon := coalesce(nullif(btrim(p_payload ->> 'icon'), ''), 'tag');
  v_color := coalesce(nullif(btrim(p_payload ->> 'color_hex'), ''), '#004B87');
  if v_color !~ '^#[0-9A-Fa-f]{6}$' then
    raise exception 'color_hex debe tener formato #RRGGBB' using errcode = '22023';
  end if;

  insert into public.forum_servers as s (
    id, nombre, short_code, descripcion, icon, color_hex, facultad_id, facultad_nombre,
    carrera_id, is_groups, show_in_rail, is_active, sort_order, logo_asset,
    parent_id, server_kind, scope_key, updated_at
  ) values (
    v_id, v_nombre,
    coalesce(nullif(btrim(p_payload ->> 'short_code'), ''), upper(left(v_nombre, 5))),
    nullif(btrim(p_payload ->> 'descripcion'), ''),
    v_icon, v_color,
    coalesce(nullif(btrim(p_payload ->> 'facultad_id'), ''), 'todas'),
    nullif(btrim(p_payload ->> 'facultad_nombre'), ''),
    coalesce(nullif(btrim(p_payload ->> 'carrera_id'), ''), v_id),
    coalesce((p_payload ->> 'is_groups')::boolean, false),
    coalesce((p_payload ->> 'show_in_rail')::boolean, false),
    coalesce((p_payload ->> 'is_active')::boolean, true),
    coalesce((p_payload ->> 'sort_order')::integer, 0),
    nullif(btrim(p_payload ->> 'logo_asset'), ''),
    nullif(btrim(p_payload ->> 'parent_id'), ''),
    coalesce(nullif(btrim(p_payload ->> 'server_kind'), ''), 'career'),
    coalesce(nullif(btrim(p_payload ->> 'scope_key'), ''), v_id),
    now()
  )
  on conflict (id) do update set
    nombre = excluded.nombre,
    short_code = excluded.short_code,
    descripcion = excluded.descripcion,
    icon = excluded.icon,
    color_hex = excluded.color_hex,
    facultad_id = excluded.facultad_id,
    facultad_nombre = excluded.facultad_nombre,
    carrera_id = excluded.carrera_id,
    is_groups = excluded.is_groups,
    show_in_rail = case when s.is_system then true else excluded.show_in_rail end,
    is_active = case when s.is_system then true else excluded.is_active end,
    sort_order = excluded.sort_order,
    logo_asset = excluded.logo_asset,
    parent_id = excluded.parent_id,
    server_kind = excluded.server_kind,
    scope_key = excluded.scope_key,
    updated_at = now();

  select to_jsonb(s) into v_result from public.forum_servers s where s.id = v_id;

  insert into public.moderation_audit_log (
    moderator_id, entity_table, entity_id, justification, is_automated, moderation_label
  ) values (
    v_uid, 'forum_servers', gen_random_uuid(),
    format('Espacio de foro "%s" (%s) guardado', v_nombre, v_id),
    false, 'forum_server'
  );

  return jsonb_build_object('server', v_result, 'id', v_id);
end;
$$;

revoke execute on function public.admin_upsert_forum_server(jsonb) from public, anon;
grant execute on function public.admin_upsert_forum_server(jsonb) to authenticated, service_role;
