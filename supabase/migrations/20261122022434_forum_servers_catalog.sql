-- =============================================================================
-- Zanate · Catálogo único de espacios/servidores del foro
-- Fecha: 2026-11-22
-- =============================================================================
-- Hasta ahora el rail y el selector de carrera se armaban con listas
-- hardcodeadas en Flutter (defaultServers, groupsSubservers, USACConstants).
-- Esta migración crea public.forum_servers como única fuente de verdad y la
-- siembra con TODO lo que la app muestra hoy:
--
--   1) Servidores curados del rail (Todas las Facultades, Área Común, carreras,
--      Grupos de Estudio).
--   2) Subservidores de Grupos de Estudio (por facultad).
--   3) Espacios "Todas las Carreras de <Facultad>".
--   4) El resto de carreras del catálogo académico (facultades/carreras).
--
-- El panel PEMTREE-admin administra este catálogo con
-- admin_upsert_forum_server / admin_delete_forum_server.
-- =============================================================================

create table if not exists public.forum_servers (
    id              text primary key,
    nombre          text not null,
    short_code      text not null default '',
    descripcion     text,
    icon            text not null default 'tag',
    color_hex       text not null default '#004B87',
    facultad_id     text not null default 'todas',
    facultad_nombre text,
    carrera_id      text not null default 'todas',
    is_groups       boolean not null default false,
    show_in_rail    boolean not null default false,
    is_active       boolean not null default true,
    is_system       boolean not null default false,
    sort_order      integer not null default 0,
    logo_asset      text,
    created_at      timestamptz not null default now(),
    updated_at      timestamptz not null default now(),
    constraint forum_servers_id_format check (id ~ '^[a-z0-9][a-z0-9_-]{1,59}$'),
    constraint forum_servers_color_format check (color_hex ~ '^#[0-9A-Fa-f]{6}$')
);

comment on table public.forum_servers is
  'Catálogo de espacios del foro (rail, grupos y selector de carrera). Fuente única para la app y PEMTREE-admin.';

create index if not exists idx_forum_servers_rail
  on public.forum_servers (sort_order, id)
  where show_in_rail and is_active;

create index if not exists idx_forum_servers_groups
  on public.forum_servers (sort_order, id)
  where is_groups;

-- ---------------------------------------------------------------------------
-- 1) Servidores curados del rail
-- ---------------------------------------------------------------------------
insert into public.forum_servers
  (id, nombre, short_code, descripcion, icon, color_hex, facultad_id, facultad_nombre,
   carrera_id, is_groups, show_in_rail, is_active, is_system, sort_order)
values
  ('todas', 'Todas las Facultades', 'USAC',
   'Espacio general para todas las facultades, escuelas y sedes.',
   'school', '#004B87', 'todas', 'Todas las Facultades', 'todas', false, true, true, true, 10),
  ('grupos_estudio', 'Grupos de Estudio', 'GRUPOS',
   'Directorio oficial de grupos de WhatsApp y estudio USAC organizados por facultad y curso.',
   'chat', '#25D366', 'todas', 'Todas las Facultades', 'todas', true, true, true, true, 20),
  ('area_comun', 'Área Común', 'BAS',
   'Ciencias básicas, matemáticas, físicas y químicas de primeros semestres.',
   'auto_stories', '#0284C7', '08', 'Facultad de Ingeniería', 'area_comun', false, true, true, false, 30),
  ('sistemas', 'Ingeniería en Sistemas', 'SIST',
   'Escuela de Ciencias y Sistemas. Programación, proyectos y tecnología.',
   'terminal', '#0284C7', '08', 'Facultad de Ingeniería', 'sistemas', false, true, true, false, 40),
  ('civil', 'Ingeniería Civil', 'CIV',
   'Estructuras, topografía, materiales y diseño vial.',
   'construction', '#D97706', '08', 'Facultad de Ingeniería', 'civil', false, true, true, false, 50),
  ('industrial', 'Ingeniería Industrial', 'IND',
   'Producción, logística, procesos y operaciones.',
   'precision_manufacturing', '#EA580C', '08', 'Facultad de Ingeniería', 'industrial', false, true, true, false, 60),
  ('medicina', 'Ciencias Médicas', 'MED',
   'Anatomía, fisiología, materias clínicas e internado.',
   'medical_services', '#DC2626', '05', 'Facultad de Ciencias Médicas (CUM)', '05-00-01', false, true, true, false, 70),
  ('derecho', 'Ciencias Jurídicas y Sociales', 'DER',
   'Leyes, doctrina, ramas del derecho y clínicas jurídicas.',
   'gavel', '#7C3AED', '04', 'Facultad de Ciencias Jurídicas y Sociales', '04-00-01', false, true, true, false, 80),
  ('arquitectura', 'Facultad de Arquitectura', 'ARQ',
   'Arquitectura, diseño, talleres y proyectos.',
   'architecture', '#059669', '02', 'Facultad de Arquitectura', '02-00-01', false, true, true, false, 90),
  ('economicas', 'Ciencias Económicas', 'ECON',
   'Auditoría, administración, contabilidad y finanzas.',
   'trending_up', '#0D9488', '03', 'Facultad de Ciencias Económicas', '03-00-01', false, true, true, false, 100),
  ('agronomia', 'Facultad de Agronomía', 'AGRO',
   'Recursos naturales, producción agrícola y gestión ambiental.',
   'eco', '#16A34A', '01', 'Facultad de Agronomía', '01-00-02', false, true, true, false, 110)
on conflict (id) do update set
  nombre          = coalesce(nullif(btrim(forum_servers.nombre), ''), excluded.nombre),
  descripcion     = coalesce(nullif(btrim(forum_servers.descripcion), ''), excluded.descripcion),
  icon            = coalesce(forum_servers.icon, excluded.icon),
  color_hex       = coalesce(forum_servers.color_hex, excluded.color_hex),
  facultad_nombre = coalesce(forum_servers.facultad_nombre, excluded.facultad_nombre),
  show_in_rail    = forum_servers.show_in_rail or excluded.show_in_rail,
  is_system       = forum_servers.is_system or excluded.is_system,
  updated_at      = now();

-- ---------------------------------------------------------------------------
-- 2) Subservidores de Grupos de Estudio
-- ---------------------------------------------------------------------------
insert into public.forum_servers
  (id, nombre, short_code, descripcion, icon, color_hex, facultad_id, facultad_nombre,
   carrera_id, is_groups, show_in_rail, is_active, is_system, sort_order)
values
  ('groups_todas', 'Todas las Facultades', 'TODAS',
   'Grupos de estudio y WhatsApp de todas las facultades de la USAC.',
   'school', '#004B87', 'todas', 'Todas las Facultades', 'todas', true, false, true, false, 210),
  ('groups_humanidades', 'Facultad de Humanidades', 'HUM',
   'Grupos de estudio para profesorados, pedagogía y licenciaturas de Humanidades.',
   'psychology', '#D97706', '07', 'Facultad de Humanidades (Central & Extensiones)', 'todas', true, false, true, false, 220),
  ('groups_medicina', 'Médico y Cirujano', 'MED',
   'Grupos de WhatsApp de materias clínicas, ciencias básicas y años de Medicina.',
   'medical_services', '#DC2626', '05', 'Facultad de Ciencias Médicas (CUM)', '05-00-01', true, false, true, false, 230),
  ('groups_veterinaria', 'Medicina Veterinaria y Zootecnia', 'VET',
   'Grupos de WhatsApp para Medicina Veterinaria y Zootecnia.',
   'pets', '#9333EA', '10', 'Facultad de Medicina Veterinaria y Zootecnia', 'todas', true, false, true, false, 240),
  ('groups_odontologia', 'Facultad de Odontología', 'ODON',
   'Grupos de WhatsApp para cursos y clínicas dentales de Odontología.',
   'healing', '#4F46E5', '09', 'Facultad de Odontología', 'todas', true, false, true, false, 250),
  ('groups_ingenieria', 'Facultad de Ingeniería', 'ING',
   'Grupos de WhatsApp de cursos de Área Común y carreras de Ingeniería.',
   'engineering', '#0284C7', '08', 'Facultad de Ingeniería', 'todas', true, false, true, false, 260),
  ('groups_quimica_farmacia', 'Ciencias Químicas y Farmacéuticas', 'FARM',
   'Grupos de WhatsApp de Química, Farmacia, Biología, Nutrición y Química Biológica.',
   'biotech', '#E11D48', '06', 'Facultad de Ciencias Químicas y Farmacia', 'todas', true, false, true, false, 270),
  ('groups_ciencias_medicas', 'Facultad de Ciencias Médicas', 'CMED',
   'Grupos de WhatsApp de la Facultad de Ciencias Médicas, enfermería y fisioterapia.',
   'health_and_safety', '#DC2626', '05', 'Facultad de Ciencias Médicas (CUM)', 'todas', true, false, true, false, 280),
  ('groups_derecho', 'Ciencias Jurídicas y Sociales', 'DER',
   'Grupos de WhatsApp de Ciencias Jurídicas y Sociales.',
   'gavel', '#7C3AED', '04', 'Facultad de Ciencias Jurídicas y Sociales', 'todas', true, false, true, false, 290),
  ('groups_economicas', 'Facultad de Ciencias Económicas', 'ECON',
   'Grupos de WhatsApp de Contaduría Pública y Auditoría, Administración y Economía.',
   'trending_up', '#0D9488', '03', 'Facultad de Ciencias Económicas', 'todas', true, false, true, false, 300),
  ('groups_arquitectura', 'Facultad de Arquitectura', 'ARQ',
   'Grupos de WhatsApp de Licenciatura en Arquitectura y Diseño Gráfico.',
   'architecture', '#059669', '02', 'Facultad de Arquitectura', 'todas', true, false, true, false, 310),
  ('groups_agronomia', 'Facultad de Agronomía', 'AGRO',
   'Grupos de WhatsApp de Sistemas de Producción Agrícola y Recursos Naturales.',
   'eco', '#16A34A', '01', 'Facultad de Agronomía', 'todas', true, false, true, false, 320)
on conflict (id) do update set
  nombre          = coalesce(nullif(btrim(forum_servers.nombre), ''), excluded.nombre),
  descripcion     = coalesce(nullif(btrim(forum_servers.descripcion), ''), excluded.descripcion),
  icon            = coalesce(forum_servers.icon, excluded.icon),
  color_hex       = coalesce(forum_servers.color_hex, excluded.color_hex),
  facultad_nombre = coalesce(forum_servers.facultad_nombre, excluded.facultad_nombre),
  updated_at      = now();

-- ---------------------------------------------------------------------------
-- 3) Espacios "Todas las Carreras de <Facultad>"
-- ---------------------------------------------------------------------------
insert into public.forum_servers
  (id, nombre, short_code, descripcion, icon, color_hex, facultad_id, facultad_nombre,
   carrera_id, is_groups, show_in_rail, is_active, is_system, sort_order)
select
  'fac_' || f.id || '_todas',
  'Todas las Carreras de ' || regexp_replace(regexp_replace(f.nombre, '^Facultad de ', ''), ' \(.*\)$', ''),
  upper(left(regexp_replace(regexp_replace(f.nombre, '^Facultad de ', ''), '[^A-Za-zÁÉÍÓÚÑ]', '', 'g'), 4)),
  'Espacio transversal para todas las carreras de ' || regexp_replace(regexp_replace(f.nombre, '^Facultad de ', ''), ' \(.*\)$', '') || '.',
  'school',
  case f.id
    when '01' then '#16A34A' when '02' then '#059669' when '03' then '#0D9488'
    when '04' then '#7C3AED' when '05' then '#DC2626' when '06' then '#E11D48'
    when '07' then '#D97706' when '08' then '#0284C7' when '09' then '#4F46E5'
    when '10' then '#9333EA' else '#004B87' end,
  f.id, f.nombre, 'todas', false, false, true, false, 400
from public.facultades f
where f.id <> 'todas'
on conflict (id) do update set
  facultad_nombre = coalesce(forum_servers.facultad_nombre, excluded.facultad_nombre),
  updated_at = now();

-- ---------------------------------------------------------------------------
-- 4) Resto del catálogo de carreras (selector de espacios)
-- ---------------------------------------------------------------------------
insert into public.forum_servers
  (id, nombre, short_code, descripcion, icon, color_hex, facultad_id, facultad_nombre,
   carrera_id, is_groups, show_in_rail, is_active, is_system, sort_order)
select
  c.id,
  c.nombre,
  upper(left(regexp_replace(c.nombre, '[^A-Za-zÁÉÍÓÚÑ]', '', 'g'), 4)),
  'Espacio de discusión para ' || c.nombre || '.',
  'tag',
  case c.facultad_id
    when '01' then '#16A34A' when '02' then '#059669' when '03' then '#0D9488'
    when '04' then '#7C3AED' when '05' then '#DC2626' when '06' then '#E11D48'
    when '07' then '#D97706' when '08' then '#0284C7' when '09' then '#4F46E5'
    when '10' then '#9333EA' else '#004B87' end,
  c.facultad_id,
  f.nombre,
  c.id,
  false, false, true, false,
  500 + row_number() over (order by c.facultad_id, c.codigo)
from public.carreras c
join public.facultades f on f.id = c.facultad_id
where c.id not in ('todas', 'area_comun')
  and not exists (select 1 from public.forum_servers s where s.id = c.id)
on conflict (id) do nothing;

-- ---------------------------------------------------------------------------
-- 5) RLS y permisos
-- ---------------------------------------------------------------------------
alter table public.forum_servers enable row level security;

drop policy if exists "Lectura de servidores (anon)" on public.forum_servers;
drop policy if exists "Lectura de servidores (auth)" on public.forum_servers;

create policy "Lectura de servidores (anon)"
  on public.forum_servers for select to anon
  using (is_active = true);

create policy "Lectura de servidores (auth)"
  on public.forum_servers for select to authenticated
  using (
    is_active = true
    or public.is_pemtree_admin((select auth.uid()))
    or public.is_pemtree_moderator((select auth.uid()))
  );

revoke insert, update, delete on public.forum_servers from anon, authenticated;
grant select on public.forum_servers to anon, authenticated;
grant all on public.forum_servers to service_role;

-- ---------------------------------------------------------------------------
-- 6) Vista de administración
-- ---------------------------------------------------------------------------
drop view if exists public.v_forum_servers_admin;

create view public.v_forum_servers_admin
with (security_invoker = true)
as
with counts as (
  select
    p.carrera,
    count(*)::bigint as posts_count,
    count(*) filter (where p.moderation_status = 0)::bigint as pending_posts,
    count(*) filter (where p.moderation_status = 2)::bigint as hidden_posts
  from public.posts p
  group by p.carrera
)
select
  s.id,
  s.nombre,
  s.short_code,
  s.descripcion,
  s.icon,
  s.color_hex,
  s.facultad_id,
  s.facultad_nombre,
  s.carrera_id,
  s.is_groups,
  s.show_in_rail,
  s.is_active,
  s.is_system,
  s.sort_order,
  s.logo_asset,
  s.created_at,
  s.updated_at,
  coalesce(ct.posts_count, 0)::bigint as posts_count,
  coalesce(ct.pending_posts, 0)::bigint as pending_posts,
  coalesce(ct.hidden_posts, 0)::bigint as hidden_posts
from public.forum_servers s
left join counts ct on ct.carrera = s.carrera_id;

grant select on public.v_forum_servers_admin to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 7) RPC: crear/editar espacio
-- ---------------------------------------------------------------------------
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
    carrera_id, is_groups, show_in_rail, is_active, sort_order, logo_asset, updated_at
  ) values (
    v_id,
    v_nombre,
    coalesce(nullif(btrim(p_payload ->> 'short_code'), ''), upper(left(v_nombre, 5))),
    nullif(btrim(p_payload ->> 'descripcion'), ''),
    v_icon,
    v_color,
    coalesce(nullif(btrim(p_payload ->> 'facultad_id'), ''), 'todas'),
    nullif(btrim(p_payload ->> 'facultad_nombre'), ''),
    coalesce(nullif(btrim(p_payload ->> 'carrera_id'), ''), v_id),
    coalesce((p_payload ->> 'is_groups')::boolean, false),
    coalesce((p_payload ->> 'show_in_rail')::boolean, false),
    coalesce((p_payload ->> 'is_active')::boolean, true),
    coalesce((p_payload ->> 'sort_order')::integer, 0),
    nullif(btrim(p_payload ->> 'logo_asset'), ''),
    now()
  )
  on conflict (id) do update set
    nombre          = excluded.nombre,
    short_code      = excluded.short_code,
    descripcion     = excluded.descripcion,
    icon            = excluded.icon,
    color_hex       = excluded.color_hex,
    facultad_id     = excluded.facultad_id,
    facultad_nombre = excluded.facultad_nombre,
    carrera_id      = excluded.carrera_id,
    is_groups       = excluded.is_groups,
    show_in_rail    = case when s.is_system then true else excluded.show_in_rail end,
    is_active       = case when s.is_system then true else excluded.is_active end,
    sort_order      = excluded.sort_order,
    logo_asset      = excluded.logo_asset,
    updated_at      = now();

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

-- ---------------------------------------------------------------------------
-- 8) RPC: eliminar o desactivar espacio
-- ---------------------------------------------------------------------------
create or replace function public.admin_delete_forum_server(p_id text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_id text := lower(btrim(coalesce(p_id, '')));
  v_server public.forum_servers%ROWTYPE;
  v_posts bigint := 0;
begin
  if v_uid is null then
    raise exception 'No autenticado' using errcode = '42501';
  end if;
  if not public.is_pemtree_admin(v_uid) then
    raise exception 'Permiso denegado: solo administradores pueden gestionar espacios del foro'
      using errcode = '42501';
  end if;

  select * into v_server from public.forum_servers where id = v_id;
  if not found then
    raise exception 'El espacio "%" no existe', v_id using errcode = 'P0002';
  end if;
  if v_server.is_system then
    raise exception 'El espacio "%" es de sistema y no se puede eliminar', v_server.nombre
      using errcode = '22023';
  end if;

  select count(*) into v_posts from public.posts where carrera = v_server.carrera_id;

  if v_posts > 0 then
    update public.forum_servers set is_active = false, updated_at = now() where id = v_id;
    insert into public.moderation_audit_log (moderator_id, entity_table, entity_id, justification, is_automated, moderation_label)
    values (v_uid, 'forum_servers', gen_random_uuid(),
      format('Espacio "%s" desactivado: conserva %s publicaciones', v_server.nombre, v_posts),
      false, 'forum_server');
    return jsonb_build_object('deleted', false, 'deactivated', true, 'posts', v_posts, 'id', v_id);
  end if;

  delete from public.forum_servers where id = v_id;
  insert into public.moderation_audit_log (moderator_id, entity_table, entity_id, justification, is_automated, moderation_label)
  values (v_uid, 'forum_servers', gen_random_uuid(),
    format('Espacio "%s" eliminado (sin publicaciones)', v_server.nombre),
    false, 'forum_server');
  return jsonb_build_object('deleted', true, 'deactivated', false, 'posts', 0, 'id', v_id);
end;
$$;

revoke execute on function public.admin_delete_forum_server(text) from public, anon;
grant execute on function public.admin_delete_forum_server(text) to authenticated, service_role;
