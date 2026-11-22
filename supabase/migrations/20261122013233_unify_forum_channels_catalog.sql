-- =============================================================================
-- Zanate · Catálogo único de canales del foro (frontend ↔ PEMTREE-admin)
-- Fecha: 2026-11-22
-- =============================================================================
-- Objetivo:
--   1) Enriquecer public.categorias_foro con metadatos de presentación
--      (slug, icon, is_system) para que el frontend renderice canales sin
--      listas hardcodeadas.
--   2) Sembrar/actualizar los canales que ya usa la app para que formen parte
--      del catálogo administrable (crear/editar/eliminar desde PEMTREE-admin).
--   3) Unificar los RPC de administración y la vista de administración.
--
-- Semántica:
--   - `todos` es el agregador "Todas las áreas": editable, pero NO eliminable
--     ni desactivable (is_system = true).
--   - El resto de canales (general, prerrequisitos, catedraticos, apuntes,
--     horarios, desahogo, desmadre y los nuevos) son administrables por
--     completo.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1) Metadatos de presentación
-- ---------------------------------------------------------------------------
alter table public.categorias_foro
  add column if not exists slug text,
  add column if not exists icon text,
  add column if not exists is_system boolean not null default false;

create unique index if not exists uq_categorias_foro_slug
  on public.categorias_foro (lower(slug))
  where slug is not null;

-- ---------------------------------------------------------------------------
-- 2) Sembrado alineado con los canales actuales del frontend
-- ---------------------------------------------------------------------------
insert into public.categorias_foro
  (id, nombre, descripcion, slug, icon, sort_order, is_active, is_system)
values
  ('todos', 'Todas las áreas',
   'Visualiza todas las consultas y aportes de esta carrera en un solo lugar.',
   'todos-los-temas', 'tag', 10, true, true),
  ('general', 'Consultas Generales',
   'Cafetería estudiantil, avisos generales y vida universitaria en la carrera.',
   'charla-general', 'chat_bubble_outline', 20, true, false),
  ('prerrequisitos', 'Prerrequisitos & Pensum',
   'Consultas sobre créditos, asignaciones, prerrequisitos y cierre de pensum.',
   'dudas-y-pensum', 'school_outlined', 30, true, false),
  ('catedraticos', 'Catedráticos & Auxiliares',
   'Experiencias, recomendaciones y estilo de evaluación de docentes y auxiliares.',
   'catedraticos-opiniones', 'record_voice_over_outlined', 40, true, false),
  ('apuntes', 'Apuntes & Exámenes',
   'Material de estudio, resúmenes, parciales pasados, libros y guías de laboratorio.',
   'apuntes-y-recursos', 'folder_shared_outlined', 50, true, false),
  ('horarios', 'Horarios & Secciones',
   'Información de traslapes, cupos, secciones y asignación de laboratorios.',
   'horarios-y-secciones', 'schedule_outlined', 60, true, false),
  ('desahogo', 'Desahogo',
   'Espacio para compartir experiencias y desahogarse de la vida universitaria.',
   'desahogo', 'sentiment_satisfied_outlined', 70, true, false),
  ('desmadre', 'Desmadre USAC',
   'Humor pesado, memes y desahogo. Se permiten groserías y chistes fuertes, pero no acoso dirigido, doxxing, difamación ni contenido explícito.',
   'desmadre', 'mood_bad_outlined', 80, true, false)
on conflict (id) do update set
  -- Conserva el nombre editado por el admin si ya existía; completa metadatos.
  nombre      = coalesce(nullif(btrim(categorias_foro.nombre), ''), excluded.nombre),
  descripcion = coalesce(nullif(btrim(categorias_foro.descripcion), ''), excluded.descripcion),
  slug        = coalesce(categorias_foro.slug, excluded.slug),
  icon        = coalesce(categorias_foro.icon, excluded.icon),
  sort_order  = case when categorias_foro.sort_order = 0
                     then excluded.sort_order
                     else categorias_foro.sort_order end,
  is_system   = categorias_foro.is_system or excluded.is_system,
  updated_at  = now();

-- Reafirmar que el agregador nunca quede inactivo ni eliminable.
update public.categorias_foro
   set is_system = true, is_active = true
 where id = 'todos';

-- ---------------------------------------------------------------------------
-- 3) Vista de administración con metadatos
-- ---------------------------------------------------------------------------
-- Se recrea porque PostgreSQL no permite insertar columnas en medio de una
-- vista existente (solo agregarlas al final), y aquí el orden importa para el
-- panel administrativo.
drop view if exists public.v_forum_category_admin;

create view public.v_forum_category_admin
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
  c.slug,
  c.icon,
  c.is_system,
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
-- 4) RPC: crear/editar canal + política (acepta slug/icon)
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
  v_slug text;
  v_icon text;
  v_is_active boolean;
  v_sort_order integer;
  v_policy jsonb;
  v_category jsonb;
  v_policy_applied boolean := false;
  v_updated boolean := false;
begin
  if v_uid is null then
    raise exception 'No autenticado' using errcode = '42501';
  end if;
  if not public.is_pemtree_admin(v_uid) then
    raise exception 'Permiso denegado: solo administradores pueden gestionar canales del foro'
      using errcode = '42501';
  end if;

  v_nombre := nullif(btrim(p_payload ->> 'nombre'), '');
  if v_nombre is null then
    raise exception 'El nombre del canal es obligatorio' using errcode = '22023';
  end if;
  if char_length(v_nombre) > 60 then
    raise exception 'El nombre del canal no puede superar 60 caracteres' using errcode = '22023';
  end if;

  v_id := lower(btrim(coalesce(p_payload ->> 'id', '')));
  if v_id = '' then
    v_id := lower(translate(v_nombre, 'áéíóúüñÁÉÍÓÚÜÑ', 'aeiouunAEIOUUN'));
    v_id := regexp_replace(v_id, '[^a-z0-9]+', '_', 'g');
    v_id := btrim(v_id, '_');
  end if;

  if v_id !~ '^[a-z0-9][a-z0-9_]{1,39}$' then
    raise exception 'Identificador de canal inválido: usa minúsculas, números y guion bajo (2-40 caracteres)'
      using errcode = '22023';
  end if;
  if v_id = 'default' then
    raise exception 'El identificador "default" está reservado por el sistema' using errcode = '22023';
  end if;

  v_descripcion := nullif(btrim(p_payload ->> 'descripcion'), '');
  v_is_active := coalesce((p_payload ->> 'is_active')::boolean, true);
  v_sort_order := coalesce((p_payload ->> 'sort_order')::integer, 0);

  v_slug := lower(btrim(coalesce(p_payload ->> 'slug', '')));
  if v_slug = '' then
    v_slug := lower(translate(v_nombre, 'áéíóúüñÁÉÍÓÚÜÑ', 'aeiouunAEIOUUN'));
    v_slug := regexp_replace(v_slug, '[^a-z0-9]+', '-', 'g');
    v_slug := btrim(v_slug, '-');
  end if;
  if v_slug !~ '^[a-z0-9][a-z0-9-]{1,59}$' then
    raise exception 'Slug de canal inválido: usa minúsculas, números y guiones (2-60 caracteres)'
      using errcode = '22023';
  end if;

  v_icon := nullif(btrim(p_payload ->> 'icon'), '');
  v_icon := coalesce(v_icon, 'tag');

  insert into public.categorias_foro as c (
    id, nombre, descripcion, slug, icon, is_active, sort_order, updated_at
  ) values (
    v_id, v_nombre, v_descripcion, v_slug, v_icon, v_is_active, v_sort_order, now()
  )
  on conflict (id) do update set
    nombre      = excluded.nombre,
    descripcion = excluded.descripcion,
    slug        = excluded.slug,
    icon        = excluded.icon,
    is_active   = excluded.is_active,
    sort_order  = excluded.sort_order,
    updated_at  = now()
  where c.is_system = false or c.id = 'todos';

  select to_jsonb(c) into v_category
    from public.categorias_foro c where c.id = v_id;
  if v_category is null then
    raise exception 'No se pudo crear ni actualizar el canal "%"', v_id using errcode = 'P0002';
  end if;

  -- Proteger el agregador de una desactivación accidental.
  if v_id = 'todos' and not v_is_active then
    update public.categorias_foro set is_active = true where id = 'todos';
    v_category := v_category || jsonb_build_object('is_active', true);
  end if;

  if (p_payload ? 'policy') and jsonb_typeof(p_payload -> 'policy') = 'object' then
    v_policy := (p_payload -> 'policy') || jsonb_build_object(
      'entity_table', 'posts',
      'scope_key', v_id
    );
    perform public.admin_upsert_moderation_policy(v_policy);
    v_policy_applied := true;
  end if;

  v_updated := true;

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
    'id', v_id,
    'updated', v_updated
  );
end;
$$;

revoke execute on function public.admin_upsert_forum_category(jsonb) from public, anon;
grant execute on function public.admin_upsert_forum_category(jsonb) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 5) RPC: eliminar o desactivar canal (solo `todos` está protegido)
-- ---------------------------------------------------------------------------
create or replace function public.admin_delete_forum_category(p_id text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_id text := lower(btrim(coalesce(p_id, '')));
  v_nombre text;
  v_is_system boolean := false;
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

  select nombre, is_system into v_nombre, v_is_system
    from public.categorias_foro where id = v_id;
  if v_nombre is null then
    raise exception 'El canal "%" no existe', v_id using errcode = 'P0002';
  end if;
  if v_is_system or v_id = 'todos' then
    raise exception 'El canal "Todas las áreas" no se puede eliminar ni desactivar' using errcode = '22023';
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

    return jsonb_build_object('deleted', false, 'deactivated', true, 'posts', v_posts, 'id', v_id);
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

  return jsonb_build_object('deleted', true, 'deactivated', false, 'posts', 0, 'id', v_id);
end;
$$;

revoke execute on function public.admin_delete_forum_category(text) from public, anon;
grant execute on function public.admin_delete_forum_category(text) to authenticated, service_role;
