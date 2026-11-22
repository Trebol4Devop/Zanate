-- =============================================================================
-- Zanate · Reorganización jerárquica del foro
-- Fecha: 2026-11-22
-- =============================================================================
-- Estructura objetivo:
--   Rail: General + una Facultad por servidor + Grupos de Estudio.
--   Subservidores de cada facultad: sus carreras (y Área Común en Ingeniería).
--   Canales: por carrera (plantilla + específicos).
--   General: subservidores por temática (Objetos Perdidos, Desmadre USAC,
--   Congresos de Ingeniería, Becas, Empleos, Deportes, etc.).
--   Moderación: una política por servidor/subservidor (scope_key).
-- =============================================================================

-- 1) Jerarquía y metadatos
alter table public.forum_servers
  add column if not exists parent_id text references public.forum_servers(id) on delete cascade,
  add column if not exists server_kind text,
  add column if not exists scope_key text;

create index if not exists idx_forum_servers_parent
  on public.forum_servers (parent_id, sort_order, id);

-- 2) General (servidor principal de temáticas)
insert into public.forum_servers
  (id, nombre, short_code, descripcion, icon, color_hex, facultad_id, facultad_nombre,
   carrera_id, is_groups, show_in_rail, is_active, is_system, sort_order, parent_id,
   server_kind, scope_key)
values
  ('general', 'General', 'GEN',
   'Espacio abierto de temas transversales: objetos perdidos, desmadre, congresos, becas y más.',
   'campaign_outlined', '#004B87', 'todas', 'Todas las Facultades', 'general',
   false, true, true, true, 5, null, 'general', 'general')
on conflict (id) do update set
  parent_id = null, server_kind = 'general', scope_key = 'general',
  show_in_rail = true, is_active = true, is_system = true, updated_at = now();

-- 3) Un servidor principal por facultad
insert into public.forum_servers
  (id, nombre, short_code, descripcion, icon, color_hex, facultad_id, facultad_nombre,
   carrera_id, is_groups, show_in_rail, is_active, is_system, sort_order, parent_id,
   server_kind, scope_key)
select
  'fac_' || f.id,
  f.nombre,
  upper(left(regexp_replace(regexp_replace(f.nombre, '^Facultad de ', ''), '[^A-Za-zÁÉÍÓÚÑ]', '', 'g'), 4)),
  'Espacio principal de la ' || f.nombre || '. Sus carreras son subservidores con canales propios.',
  'school',
  case f.id
    when '01' then '#16A34A' when '02' then '#059669' when '03' then '#0D9488'
    when '04' then '#7C3AED' when '05' then '#DC2626' when '06' then '#E11D48'
    when '07' then '#D97706' when '08' then '#0284C7' when '09' then '#4F46E5'
    when '10' then '#9333EA' else '#004B87' end,
  f.id, f.nombre, 'todas', false, true, true, false,
  100 + (f.codigo)::integer, null, 'faculty', 'fac_' || f.id
from public.facultades f
where f.id <> 'todas'
on conflict (id) do update set
  parent_id = null, server_kind = 'faculty', scope_key = 'fac_' || excluded.facultad_id,
  show_in_rail = true, is_active = true, updated_at = now();

-- 4) Reubicar carreras y pseudo-carreras como subservidores
update public.forum_servers s
   set parent_id = 'fac_' || s.facultad_id,
       server_kind = 'career',
       scope_key = s.id,
       show_in_rail = false,
       sort_order = 600 + coalesce(nullif(regexp_replace(s.carrera_id, '\D', '', 'g'), '')::integer, 0),
       updated_at = now()
 where s.id not in ('todas', 'general', 'grupos_estudio')
   and s.id not like 'groups_%'
   and s.id not like 'fac\_%'
   and s.facultad_id <> 'todas';

update public.forum_servers
   set parent_id = 'fac_' || facultad_id,
       server_kind = 'career',
       scope_key = id,
       show_in_rail = false,
       is_active = true,
       sort_order = 580,
       updated_at = now()
 where id like 'fac_0%_todas';

-- Área Común pasa a ser subservidor de Ingeniería
update public.forum_servers
   set parent_id = 'fac_08', server_kind = 'career', scope_key = id,
       show_in_rail = false, is_active = true, sort_order = 570, updated_at = now()
 where id = 'area_comun';

-- El antiguo servidor "Todas las Facultades" queda como legado fuera del rail
update public.forum_servers
   set show_in_rail = false, is_active = false, server_kind = 'legacy',
       updated_at = now()
 where id = 'todas';

-- Evitar carreras duplicadas: desactivar alias curados cuando ya existe la carrera real
update public.forum_servers s
   set is_active = false, show_in_rail = false, updated_at = now()
 where s.id in ('medicina', 'derecho', 'arquitectura', 'economicas', 'agronomia')
   and exists (
       select 1 from public.forum_servers c
        where c.id = s.carrera_id and c.id <> s.id and c.server_kind = 'career'
   );

-- Grupos de Estudio sigue siendo servidor principal
update public.forum_servers
   set server_kind = 'groups', scope_key = 'grupos_estudio',
       show_in_rail = true, parent_id = null, sort_order = 90, updated_at = now()
 where id = 'grupos_estudio';

-- 5) Subservidores temáticos de General
insert into public.forum_servers
  (id, nombre, short_code, descripcion, icon, color_hex, facultad_id, facultad_nombre,
   carrera_id, is_groups, show_in_rail, is_active, is_system, sort_order, parent_id,
   server_kind, scope_key)
values
  ('objetos_perdidos', 'Objetos Perdidos', 'PERD', 'Reporta objetos perdidos y encontrados en el campus.', 'search', '#0EA5E9', 'todas', 'General', 'objetos_perdidos', false, false, true, false, 10, 'general', 'topic', 'objetos_perdidos'),
  ('desmadre', 'Desmadre USAC', 'DESM', 'Humor pesado, memes y desahogo con reglas flexibles.', 'mood_bad_outlined', '#F59E0B', 'todas', 'General', 'desmadre', false, false, true, false, 20, 'general', 'topic', 'desmadre'),
  ('congresos_ingenieria', 'Congresos de Ingeniería', 'CONG', 'Congresos, charlas, hackathons y actividades de ingeniería.', 'engineering', '#0284C7', '08', 'Facultad de Ingeniería', 'congresos_ingenieria', false, false, true, false, 30, 'general', 'topic', 'congresos_ingenieria'),
  ('becas', 'Becas y Financiamiento', 'BECA', 'Convocatorias de becas, apoyo económico y resultados.', 'campaign_outlined', '#16A34A', 'todas', 'General', 'becas', false, false, true, false, 40, 'general', 'topic', 'becas'),
  ('empleos_practicas', 'Empleos y Prácticas', 'EMP', 'Ofertas laborales, prácticas profesionales y pasantías.', 'work_outline', '#7C3AED', 'todas', 'General', 'empleos_practicas', false, false, true, false, 50, 'general', 'topic', 'empleos_practicas'),
  ('deportes', 'Deportes', 'DEP', 'Fútbol, torneos, entrenamientos y actividades deportivas.', 'sports_soccer', '#DC2626', 'todas', 'General', 'deportes', false, false, true, false, 60, 'general', 'topic', 'deportes'),
  ('arte_cultura', 'Arte y Cultura', 'ARTE', 'Música, teatro, exposiciones y eventos culturales.', 'palette', '#059669', 'todas', 'General', 'arte_cultura', false, false, true, false, 70, 'general', 'topic', 'arte_cultura'),
  ('eventos', 'Eventos y Actividades', 'EVT', 'Agenda de eventos, semanas académicas y actividades.', 'event', '#D97706', 'todas', 'General', 'eventos', false, false, true, false, 80, 'general', 'topic', 'eventos'),
  ('tramites', 'Trámites y Servicios', 'TRAM', 'Guías y dudas sobre trámites universitarios.', 'description', '#4F46E5', 'todas', 'General', 'tramites', false, false, true, false, 90, 'general', 'topic', 'tramites'),
  ('compras_ventas', 'Compras y Ventas', 'CVA', 'Compra, venta e intercambio entre estudiantes.', 'shopping_bag', '#0D9488', 'todas', 'General', 'compras_ventas', false, false, true, false, 100, 'general', 'topic', 'compras_ventas')
on conflict (id) do update set
  parent_id = 'general', server_kind = 'topic', scope_key = excluded.scope_key,
  show_in_rail = false, is_active = true, updated_at = now();

-- 6) Canales para servidores de facultad (anuncios y eventos)
insert into public.forum_server_channels
  (server_id, id, nombre, slug, descripcion, icon, sort_order, is_active, is_system)
select s.id, v.id, v.nombre, v.slug, v.descripcion, v.icon, v.orden, true, false
from public.forum_servers s
cross join (values
  ('anuncios', 'Anuncios de la Facultad', 'anuncios', 'Avisos oficiales y fechas importantes.', 'campaign_outlined', 10),
  ('eventos', 'Eventos y Actividades', 'eventos', 'Semanas académicas, charlas y actividades.', 'event', 20)
) as v(id, nombre, slug, descripcion, icon, orden)
where s.server_kind = 'faculty'
on conflict (server_id, id) do nothing;

-- 7) Canales específicos por carrera
insert into public.forum_server_channels
  (server_id, id, nombre, slug, descripcion, icon, sort_order, is_active, is_system)
select s.id, v.id, v.nombre, v.slug, v.descripcion, v.icon, v.orden, true, false
from public.forum_servers s
join (values
  ('sistemas', 'programacion', 'Programación', 'programacion', 'Código, algoritmos y proyectos de software.', 'terminal', 100),
  ('sistemas', 'bases-datos', 'Bases de Datos', 'bases-datos', 'SQL, modelado y proyectos de bases de datos.', 'storage', 110),
  ('sistemas', 'redes', 'Redes y Sistemas Operativos', 'redes', 'Redes, servidores y sistemas operativos.', 'lan', 120),
  ('sistemas', 'pasantias', 'Pasantías y Empleos TI', 'pasantias', 'Oportunidades de práctica y trabajo en tecnología.', 'work_outline', 130),
  ('civil', 'estructuras', 'Estructuras', 'estructuras', 'Análisis estructural y diseño sismorresistente.', 'architecture', 100),
  ('civil', 'topografia', 'Topografía', 'topografia', 'Levantamientos, planos y mediciones.', 'map', 110),
  ('civil', 'materiales', 'Materiales de Construcción', 'materiales', 'Ensayos, concreto y materiales.', 'construction', 120),
  ('industrial', 'produccion', 'Producción y Operaciones', 'produccion', 'Procesos, manufactura y operaciones.', 'precision_manufacturing', 100),
  ('industrial', 'logistica', 'Logística y Cadena de Suministro', 'logistica', 'Inventarios, distribución y logística.', 'local_shipping', 110),
  ('industrial', 'calidad', 'Calidad y Mejora Continua', 'calidad', 'Six Sigma, calidad y productividad.', 'verified', 120),
  ('medicina', 'ciencias-basicas', 'Ciencias Básicas', 'ciencias-basicas', 'Anatomía, fisiología y bioquímica.', 'science', 100),
  ('medicina', 'clinicas', 'Clínicas', 'clinicas', 'Rotaciones y práctica clínica.', 'medical_services', 110),
  ('medicina', 'internado', 'Internado', 'internado', 'Información y apoyo para el internado.', 'local_hospital', 120),
  ('derecho', 'doctrina', 'Doctrina y Legislación', 'doctrina', 'Leyes, códigos y doctrina jurídica.', 'gavel', 100),
  ('derecho', 'casos', 'Casos y Jurisprudencia', 'casos', 'Análisis de casos y jurisprudencia.', 'menu_book', 110),
  ('derecho', 'clinica-juridica', 'Clínica Jurídica', 'clinica-juridica', 'Práctica y servicios legales.', 'balance', 120),
  ('arquitectura', 'talleres', 'Talleres de Diseño', 'talleres', 'Talleres, entregas y críticas.', 'architecture', 100),
  ('arquitectura', 'maquetas', 'Maquetas y Representación', 'maquetas', 'Maquetas, planos y render.', 'view_in_ar', 110),
  ('agronomia', 'cultivos', 'Cultivos', 'cultivos', 'Producción agrícola y manejo de cultivos.', 'agriculture', 100),
  ('agronomia', 'suelos', 'Suelos y Recursos Naturales', 'suelos', 'Suelos, riego y recursos naturales.', 'eco', 110),
  ('quimica', 'laboratorios', 'Laboratorios', 'laboratorios', 'Prácticas de laboratorio y reactivos.', 'biotech', 100),
  ('quimica', 'farmacia', 'Farmacia', 'farmacia', 'Farmacología y farmacia.', 'medication', 110),
  ('quimica', 'nutricion', 'Nutrición', 'nutricion', 'Nutrición y dietética.', 'restaurant', 120),
  ('economicas', 'auditoria', 'Auditoría y Contabilidad', 'auditoria', 'Contabilidad, auditoría y finanzas.', 'account_balance', 100),
  ('economicas', 'economia', 'Economía', 'economia', 'Teoría económica y análisis.', 'trending_up', 110),
  ('humanidades', 'pedagogia', 'Pedagogía', 'pedagogia', 'Profesorados, didáctica y educación.', 'school_outlined', 100),
  ('humanidades', 'arte', 'Arte y Letras', 'arte', 'Arte, filosofía y letras.', 'palette', 110),
  ('odontologia', 'clinicas', 'Clínicas Odontológicas', 'clinicas', 'Práctica clínica y pacientes.', 'healing', 100),
  ('odontologia', 'materiales', 'Materiales Dentales', 'materiales', 'Materiales e insumos dentales.', 'science', 110),
  ('veterinaria', 'clinica-menor', 'Clínica de Pequeños Animales', 'clinica-menor', 'Consulta y cirugía de pequeños animales.', 'pets', 100),
  ('veterinaria', 'produccion-animal', 'Producción Animal', 'produccion-animal', 'Zootecnia y producción animal.', 'agriculture', 110)
) as v(career, id, nombre, slug, descripcion, icon, orden)
  on v.career = s.id
where s.server_kind = 'career' and s.is_active
on conflict (server_id, id) do nothing;

-- 8) Canales temáticos de General
insert into public.forum_server_channels
  (server_id, id, nombre, slug, descripcion, icon, sort_order, is_active, is_system)
select v.server_id, v.id, v.nombre, v.slug, v.descripcion, v.icon, v.orden, true, false
from (values
  ('objetos_perdidos', 'perdi', 'Perdí algo', 'perdi', 'Publica lo que perdiste.', 'search', 10),
  ('objetos_perdidos', 'encontre', 'Encontré algo', 'encontre', 'Reporta objetos encontrados.', 'search', 20),
  ('objetos_perdidos', 'entregados', 'Objetos entregados', 'entregados', 'Casos resueltos y objetos devueltos.', 'check_circle', 30),
  ('desmadre', 'memes', 'Memes', 'memes', 'Memes y humor de la comunidad.', 'mood_bad_outlined', 10),
  ('desmadre', 'chistes', 'Chistes y anécdotas', 'chistes', 'Humor pesado y anécdotas.', 'sentiment_satisfied_outlined', 20),
  ('desmadre', 'confesiones', 'Confesiones', 'confesiones', 'Confesiones anónimas del campus.', 'visibility_off', 30),
  ('congresos_ingenieria', 'convocatorias', 'Convocatorias', 'convocatorias', 'Congresos, hackathons y convocatorias.', 'campaign_outlined', 10),
  ('congresos_ingenieria', 'ponentes', 'Ponentes y Charlas', 'ponentes', 'Charlas, ponentes y agendas.', 'record_voice_over_outlined', 20),
  ('congresos_ingenieria', 'fotos', 'Fotos y Evidencias', 'fotos', 'Fotos y material de los congresos.', 'photo_library', 30),
  ('becas', 'convocatorias', 'Convocatorias', 'convocatorias', 'Becas abiertas y requisitos.', 'campaign_outlined', 10),
  ('becas', 'dudas', 'Dudas', 'dudas', 'Preguntas sobre postulaciones.', 'help_outline', 20),
  ('empleos_practicas', 'ofertas', 'Ofertas', 'ofertas', 'Ofertas laborales y pasantías.', 'work_outline', 10),
  ('empleos_practicas', 'curriculum', 'Currículum y Entrevistas', 'curriculum', 'Consejos de CV y entrevistas.', 'description', 20),
  ('deportes', 'futbol', 'Fútbol', 'futbol', 'Partidos y torneos de fútbol.', 'sports_soccer', 10),
  ('deportes', 'torneos', 'Torneos', 'torneos', 'Torneos interfacultades.', 'emoji_events', 20),
  ('arte_cultura', 'musica', 'Música', 'musica', 'Música y conciertos.', 'music_note', 10),
  ('arte_cultura', 'teatro', 'Teatro y Exposiciones', 'teatro', 'Teatro, danza y exposiciones.', 'theater_comedy', 20),
  ('eventos', 'hoy', 'Hoy', 'hoy', 'Eventos de hoy.', 'event', 10),
  ('eventos', 'semana', 'Esta semana', 'semana', 'Agenda semanal.', 'date_range', 20),
  ('tramites', 'guias', 'Guías', 'guias', 'Guías paso a paso.', 'menu_book', 10),
  ('tramites', 'dudas', 'Dudas', 'dudas', 'Preguntas sobre trámites.', 'help_outline', 20),
  ('compras_ventas', 'ofertas', 'Ofertas', 'ofertas', 'Artículos en venta.', 'shopping_bag', 10),
  ('compras_ventas', 'busco', 'Busco', 'busco', 'Busco comprar o intercambiar.', 'search', 20)
) as v(server_id, id, nombre, slug, descripcion, icon, orden)
on conflict (server_id, id) do nothing;

-- 9) Política de moderación por cada servidor/subservidor activo
insert into public.moderation_policies (
  entity_table, scope_key, allow_colloquial_profanity, allow_external_links,
  require_verified_user, laya_thresholds, escalation_margin, report_score_to_hide
)
select
  'posts', s.scope_key, p.allow_colloquial_profanity, p.allow_external_links,
  p.require_verified_user, p.laya_thresholds, p.escalation_margin, p.report_score_to_hide
from public.forum_servers s
join public.moderation_policies p
  on p.entity_table = 'posts' and p.scope_key = 'default'
where s.is_active and s.scope_key is not null and s.scope_key <> 'default'
on conflict (entity_table, scope_key) do nothing;

-- 10) El post conoce su servidor (para moderación por subservidor)
alter table public.posts add column if not exists forum_server_id text;

create index if not exists idx_posts_forum_server
  on public.posts (forum_server_id, category);

do $do$
declare
  v_def text;
begin
  v_def := pg_get_functiondef('public.check_content_moderation()'::regprocedure);
  if position('forum_server_id' in v_def) = 0 then
    v_def := replace(
      v_def,
      'v_scope := coalesce(nullif(trim(new_row->>''carrera''), ''''), ''default'');',
      'v_scope := coalesce(nullif(trim(new_row->>''forum_server_id''), ''''), nullif(trim(new_row->>''carrera''), ''''), ''default'');'
    );
    execute v_def;
  end if;
end
$do$;

-- 11) Vista y RPC de administración con jerarquía
drop view if exists public.v_forum_servers_admin;

create view public.v_forum_servers_admin
with (security_invoker = true)
as
with counts as (
  select
    coalesce(p.forum_server_id, p.carrera) as scope,
    count(*)::bigint as posts_count,
    count(*) filter (where p.moderation_status = 0)::bigint as pending_posts,
    count(*) filter (where p.moderation_status = 2)::bigint as hidden_posts
  from public.posts p
  group by coalesce(p.forum_server_id, p.carrera)
)
select
  s.id, s.nombre, s.short_code, s.descripcion, s.icon, s.color_hex,
  s.facultad_id, s.facultad_nombre, s.carrera_id, s.is_groups, s.show_in_rail,
  s.is_active, s.is_system, s.sort_order, s.logo_asset, s.created_at, s.updated_at,
  s.parent_id, s.server_kind, s.scope_key,
  coalesce(ct.posts_count, 0)::bigint as posts_count,
  coalesce(ct.pending_posts, 0)::bigint as pending_posts,
  coalesce(ct.hidden_posts, 0)::bigint as hidden_posts
from public.forum_servers s
left join counts ct on ct.scope = s.scope_key;

grant select on public.v_forum_servers_admin to authenticated, service_role;
