-- ============================================================================
-- PEMTREE · Motor de moderación dinámica, circuit breaker y retención legal
-- Archivo: supabase/migrations/20261118160000_moderacion_dinamica.sql
-- Fecha: 2026-11-18
--
-- Contenido:
--   1) seccion_reviews en el circuito de moderación (columnas, índice, RLS, grants).
--   2) Constraints actualizados en moderation_jobs y entity_reports.
--   3) Tabla public.moderation_policies (políticas/umbrales dinámicos, RLS, semillas, RPC de upsert).
--   4) Refactor de check_content_moderation() con protección legal Guatemala (PII: teléfono/DPI)
--      y groserías condicionales por ámbito.
--   5) Prioridad dinámica al encolar (public.moderation_priority_for y triggers actualizados).
--   6) Circuit breaker ponderado de reportes (handle_entity_report_auto_quarantine corregido).
--   7) Vista de reportes agrupados (v_grouped_entity_reports) y RPC admin_resolve_entity_reports.
--   8) Retención legal (trigger enforce_legal_hold_on_delete, filtros en purgas,
--      ocultar/restaurar/eliminar extendidos a seccion_reviews, RPC admin_toggle_legal_hold).
--   9) Worker batch (apply_moderation_batch con seccion_reviews, status 3 e is_legal_hold).
--  10) RPCs de salud y administración de cola para el panel (stats, reintentos, errores).
--
-- Idempotente: seguro para re-ejecución. Sin BEGIN/COMMIT explícitos.
-- ============================================================================

-- ============================================================================
-- 1) seccion_reviews EN EL CIRCUITO DE MODERACIÓN
-- ============================================================================

-- Columnas de moderación en public.seccion_reviews
alter table public.seccion_reviews
  add column if not exists moderation_status integer not null default 0,
  add column if not exists moderation_label text,
  add column if not exists moderation_confidence double precision,
  add column if not exists moderation_reason text,
  add column if not exists moderated_at timestamptz,
  add column if not exists moderated_by uuid references auth.users(id) on delete set null,
  add column if not exists reported_count integer not null default 0;

-- Constraint de estado (0: pendiente, 1: aprobado, 2: rechazado/oculto, 3: zona gris / error)
do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.seccion_reviews'::regclass
       and conname = 'seccion_reviews_moderation_status_check'
  ) then
    alter table public.seccion_reviews
      add constraint seccion_reviews_moderation_status_check
      check (moderation_status between 0 and 3);
  end if;
end;
$$;

-- Índice parcial para consultas de feed y lectura pública
create index if not exists idx_seccion_reviews_moderation_status
  on public.seccion_reviews (moderation_status)
  where moderation_status is distinct from 2;

-- Grants para PostgREST
grant select on table public.seccion_reviews to anon, authenticated;
grant insert, update on table public.seccion_reviews to authenticated;
grant all on table public.seccion_reviews to service_role;

-- RLS: reemplaza la policy pública permisiva por políticas alineadas al estándar PEMTREE
alter table public.seccion_reviews enable row level security;

drop policy if exists "Lectura pública de reseñas de secciones" on public.seccion_reviews;
drop policy if exists "Lectura pública de reseñas (anon)" on public.seccion_reviews;
drop policy if exists "Lectura de reseñas (auth: dueño/admin/moderador ven estado 2)" on public.seccion_reviews;

create policy "Lectura pública de reseñas (anon)"
  on public.seccion_reviews for select to anon
  using (moderation_status is distinct from 2);

create policy "Lectura de reseñas (auth: dueño/admin/moderador ven estado 2)"
  on public.seccion_reviews for select to authenticated
  using (
    moderation_status is distinct from 2
    or user_id = (select auth.uid())
    or public.is_pemtree_admin((select auth.uid()))
    or public.is_pemtree_moderator((select auth.uid()))
  );


-- ============================================================================
-- 2) CONSTRAINTS DE TABLAS Y REPORTES
-- ============================================================================

-- moderation_jobs: incluye 'seccion_reviews'
alter table public.moderation_jobs
  drop constraint if exists moderation_jobs_entity_table_check;

alter table public.moderation_jobs
  add constraint moderation_jobs_entity_table_check
  check (entity_table in (
    'posts',
    'comments',
    'student_groups',
    'marketplace_items',
    'verification_requests',
    'merchant_verification_requests',
    'seccion_reviews'
  ));

-- entity_reports: incluye 'seccion_review'
alter table public.entity_reports
  drop constraint if exists entity_reports_entity_type_check;

alter table public.entity_reports
  add constraint entity_reports_entity_type_check
  check (entity_type in (
    'post',
    'comment',
    'group',
    'marketplace_item',
    'user',
    'seccion_review'
  ));


-- ============================================================================
-- 3) public.moderation_policies (POLÍTICAS Y UMBRALES DINÁMICOS)
-- ============================================================================

create table if not exists public.moderation_policies (
  entity_table text not null,
  scope_key text not null default 'default',
  allow_colloquial_profanity boolean not null default false,
  allow_external_links boolean not null default true,
  require_verified_user boolean not null default false,
  laya_thresholds jsonb not null default '{"targeted_harassment":0.50,"doxxing_or_crime":0.45,"profanity":0.55,"explicit":0.50}'::jsonb,
  escalation_margin double precision not null default 0.12,
  report_score_to_hide numeric not null default 3.0,
  updated_at timestamptz not null default now(),
  constraint moderation_policies_pkey primary key (entity_table, scope_key),
  constraint moderation_policies_entity_table_check check (
    entity_table in ('posts', 'comments', 'student_groups', 'marketplace_items', 'seccion_reviews')
  )
);

comment on table public.moderation_policies is
  'Configuración dinámica de moderación, umbrales de IA y tolerancias por entidad y categoría/ámbito.';

-- RLS en moderation_policies
alter table public.moderation_policies enable row level security;

drop policy if exists "Lectura pública de políticas de moderación (anon)" on public.moderation_policies;
drop policy if exists "Lectura pública de políticas de moderación (auth)" on public.moderation_policies;
drop policy if exists "Escritura de políticas solo admin (insert)" on public.moderation_policies;
drop policy if exists "Escritura de políticas solo admin (update)" on public.moderation_policies;
drop policy if exists "Escritura de políticas solo admin (delete)" on public.moderation_policies;

create policy "Lectura pública de políticas de moderación (anon)"
  on public.moderation_policies for select to anon
  using (true);

create policy "Lectura pública de políticas de moderación (auth)"
  on public.moderation_policies for select to authenticated
  using (true);

create policy "Escritura de políticas solo admin (insert)"
  on public.moderation_policies for insert to authenticated
  with check (public.is_pemtree_admin((select auth.uid())));

create policy "Escritura de políticas solo admin (update)"
  on public.moderation_policies for update to authenticated
  using (public.is_pemtree_admin((select auth.uid())))
  with check (public.is_pemtree_admin((select auth.uid())));

create policy "Escritura de políticas solo admin (delete)"
  on public.moderation_policies for delete to authenticated
  using (public.is_pemtree_admin((select auth.uid())));

-- Permisos
grant select on table public.moderation_policies to anon, authenticated;
grant all on table public.moderation_policies to authenticated;
grant all on table public.moderation_policies to service_role;

-- Trigger updated_at reutilizando el trigger estándar del sistema
do $$
begin
  if exists (
    select 1 from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = '_triggers' and p.proname = 'set_updated_at'
  ) then
    drop trigger if exists trg_set_updated_at on public.moderation_policies;
    create trigger trg_set_updated_at
      before update on public.moderation_policies
      for each row execute function _triggers.set_updated_at();
  end if;
end;
$$;

-- Semillas requeridas
insert into public.moderation_policies (
  entity_table, scope_key, allow_colloquial_profanity, allow_external_links,
  require_verified_user, laya_thresholds, escalation_margin, report_score_to_hide
) values
  ('posts', 'default', false, true, false, '{"targeted_harassment":0.50,"doxxing_or_crime":0.45,"profanity":0.55,"explicit":0.50}'::jsonb, 0.12, 3.0),
  ('posts', 'desahogo', true, true, false, '{"targeted_harassment":0.55,"doxxing_or_crime":0.45,"explicit":0.55}'::jsonb, 0.12, 3.0),
  ('comments', 'default', false, true, false, '{"targeted_harassment":0.50,"doxxing_or_crime":0.45,"profanity":0.55,"explicit":0.50}'::jsonb, 0.12, 3.0),
  ('marketplace_items', 'default', false, true, false, '{"targeted_harassment":0.50,"doxxing_or_crime":0.45,"profanity":0.55,"explicit":0.50}'::jsonb, 0.12, 3.0),
  ('student_groups', 'default', false, true, false, '{"targeted_harassment":0.50,"doxxing_or_crime":0.45,"profanity":0.55,"explicit":0.50}'::jsonb, 0.12, 3.0),
  ('seccion_reviews', 'default', true, true, false, '{"defamation_or_personal_attack":0.48,"doxxing_or_crime":0.45}'::jsonb, 0.12, 3.0)
on conflict (entity_table, scope_key) do nothing;

-- RPC de upsert de política para el panel de administración
create or replace function public.admin_upsert_moderation_policy(p_payload jsonb)
returns public.moderation_policies
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_table text;
  v_scope text;
  v_res public.moderation_policies;
begin
  if v_uid is null then
    raise exception 'No autenticado' using errcode = '42501';
  end if;
  if not public.is_pemtree_admin(v_uid) then
    raise exception 'Permiso denegado: solo administradores pueden modificar políticas de moderación'
      using errcode = '42501';
  end if;

  v_table := trim(p_payload->>'entity_table');
  v_scope := coalesce(nullif(trim(p_payload->>'scope_key'), ''), 'default');

  if v_table is null or v_table not in ('posts', 'comments', 'student_groups', 'marketplace_items', 'seccion_reviews') then
    raise exception 'entity_table inválido: %', coalesce(v_table, '(null)') using errcode = '22023';
  end if;

  insert into public.moderation_policies as mp (
    entity_table,
    scope_key,
    allow_colloquial_profanity,
    allow_external_links,
    require_verified_user,
    laya_thresholds,
    escalation_margin,
    report_score_to_hide,
    updated_at
  ) values (
    v_table,
    v_scope,
    coalesce((p_payload->>'allow_colloquial_profanity')::boolean, false),
    coalesce((p_payload->>'allow_external_links')::boolean, true),
    coalesce((p_payload->>'require_verified_user')::boolean, false),
    coalesce(p_payload->'laya_thresholds', '{"targeted_harassment":0.50,"doxxing_or_crime":0.45,"profanity":0.55,"explicit":0.50}'::jsonb),
    coalesce((p_payload->>'escalation_margin')::double precision, 0.12),
    coalesce((p_payload->>'report_score_to_hide')::numeric, 3.0),
    now()
  )
  on conflict (entity_table, scope_key) do update set
    allow_colloquial_profanity = case when p_payload ? 'allow_colloquial_profanity'
      then (p_payload->>'allow_colloquial_profanity')::boolean else mp.allow_colloquial_profanity end,
    allow_external_links = case when p_payload ? 'allow_external_links'
      then (p_payload->>'allow_external_links')::boolean else mp.allow_external_links end,
    require_verified_user = case when p_payload ? 'require_verified_user'
      then (p_payload->>'require_verified_user')::boolean else mp.require_verified_user end,
    laya_thresholds = case when p_payload ? 'laya_thresholds'
      then p_payload->'laya_thresholds' else mp.laya_thresholds end,
    escalation_margin = case when p_payload ? 'escalation_margin'
      then (p_payload->>'escalation_margin')::double precision else mp.escalation_margin end,
    report_score_to_hide = case when p_payload ? 'report_score_to_hide'
      then (p_payload->>'report_score_to_hide')::numeric else mp.report_score_to_hide end,
    updated_at = now()
  returning * into v_res;

  insert into public.moderation_audit_log (
    moderator_id,
    entity_table,
    entity_id,
    justification,
    is_automated,
    moderation_label
  ) values (
    v_uid,
    'moderation_policies',
    gen_random_uuid(),
    p_payload::text,
    false,
    'policy_update'
  );

  return v_res;
end;
$$;

revoke execute on function public.admin_upsert_moderation_policy(jsonb) from public, anon;
grant execute on function public.admin_upsert_moderation_policy(jsonb) to authenticated, service_role;


-- ============================================================================
-- 4) REFACTOR DE check_content_moderation (CAPA 1: FILTRO DURO EN BD)
-- ============================================================================

create or replace function public.check_content_moderation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_table text := TG_TABLE_NAME;
  new_row jsonb := to_jsonb(NEW);
  v_scope text := 'default';
  v_policy public.moderation_policies%ROWTYPE;
  v_allow_profanity boolean := false;
  v_allow_ext_links boolean := true;
  v_require_verified boolean := false;
  v_author_id uuid;
  v_pii_text text := '';
  clean_text text := '';
  compact_text text := '';
  key text;
  val text;
  word text;

  -- Slurs severos que NUNCA se permiten, aun con allow_colloquial_profanity = true
  severe_slurs text[] := array[
    'nigger', 'niggers', 'nigga', 'niggas',
    'maricon', 'maricones', 'marica', 'maricas',
    'faggot', 'fags',
    'pedofilo', 'pedofila', 'pedofilos', 'pedofilas', 'pedofilia', 'pedophile', 'pedophiles',
    'violador', 'violadores', 'violacion'
  ];

  -- Lista completa de groserías e insultos (cuando allow_colloquial_profanity = false)
  forbidden_words text[] := array[
    -- Guatemaltequismos / Centroamérica
    'cerote', 'cerota', 'cerotes', 'cerotas', 'mula', 'mulas', 'mulada', 'muladas',
    'pisado', 'pisada', 'pisados', 'pisadas', 'shumo', 'shuma', 'marote', 'taliche',
    'huevon', 'huevona', 'huevones', 'culero', 'culera', 'culeros', 'culo', 'culito',
    'pija', 'pijas', 'pijazo', 'verga', 'vergas', 'vergazo', 'verguiza', 'cagada',
    'cagadas', 'cagon', 'cagona', 'mierda', 'mierdas', 'mierdero', 'caca', 'cacas',
    'malparido', 'malparida', 'hijueputa', 'hijueputas', 'hijo de puta', 'hp', 'hdp',
    'ptm', 'alv', 'vtl',
    -- General Español
    'pendejo', 'pendeja', 'pendejos', 'pendejas', 'idiota', 'idiotas', 'estupido',
    'estupida', 'estupidos', 'estupidas', 'imbecil', 'imbeciles', 'puta', 'putas',
    'puto', 'putos', 'putazo', 'putazos', 'putero', 'cabron', 'cabrona', 'cabrones',
    'chingar', 'chinga', 'chingada', 'chingadazo', 'pinche', 'pinches', 'gonorrea',
    'mamahuevos', 'mamada', 'mamadas', 'tarado', 'tarada', 'tarados', 'zorete',
    'zorra', 'zorras', 'perra', 'perras', 'asqueroso', 'asquerosa', 'puerco', 'puerca',
    'mongol', 'mongoles', 'mongolito', 'mongolita', 'bastardo', 'bastarda',
    'joder', 'jodido', 'jodida', 'subnormal', 'subnormales', 'lacra', 'lacras',
    'baboso', 'babosa', 'babosos', 'mamon', 'mamona',
    -- Inglés
    'fuck', 'fucker', 'fuckers', 'fucking', 'motherfucker', 'motherfuckers', 'fucktard',
    'shit', 'shits', 'shitty', 'bullshit', 'dipshit', 'shithead', 'bitch', 'bitches',
    'asshole', 'assholes', 'dumbass', 'jackass', 'bastard', 'bastards', 'scumbag',
    'dick', 'dickhead', 'cock', 'cocksucker', 'pussy', 'pussies', 'cunt', 'cunts',
    'twat', 'wanker', 'prick', 'whore', 'slut', 'sluts', 'douchebag', 'skank',
    'retard', 'retarded',
    -- Incluye los slurs severos
    'nigger', 'niggers', 'nigga', 'niggas', 'maricon', 'maricones', 'marica', 'maricas',
    'faggot', 'fags', 'pedofilo', 'pedofila', 'pedofilos', 'pedofilas', 'pedofilia',
    'pedophile', 'pedophiles', 'violador', 'violadores', 'violacion'
  ];

  -- Lista de enlaces a adultos, apuestas, acortadores de spam y archivos maliciosos
  forbidden_links text[] := array[
    -- Adultos / Pornografía
    'porn', 'xxx', 'xvideos', 'pornhub', 'onlyfans', 'xhamster', 'redtube',
    'brazzers', 'chaturbate', 'xnxx', 'eporner', 'youporn', 'spankbang', 'hentai',
    'sex', 'nude', 'pack de', 'packs de', 'camgirls',
    -- Apuestas / Casinos
    'casino', 'bet365', '1xbet', 'poker', 'slots', 'apuestas', 'rushbet',
    'codere', 'sportingbet', 'roulette', 'jackpot',
    -- Acortadores peligrosos y redes de spam
    'bit.ly', 'tinyurl.com', 't.co/', 'is.gd', 'cutt.ly', 'shorte.st', 'adf.ly',
    'shrinkme', 'ow.ly', 'buff.ly', 'bl.ink',
    -- Archivos y dominios sospechosos
    '.exe', '.apk', '.bat', '.scr', '.vbs', '.msi', '.xyz', '.top', '.ru', '.tk', '.biz',
    'trojan', 'keygen', 'phishing'
  ];
begin
  -- 0) En UPDATE, si no cambió el contenido, no re-escanear el texto.
  --    Esto permite aplicar cambios de moderación, métricas o is_legal_hold sobre
  --    filas que ya contienen PII (precisamente la evidencia que se debe preservar)
  --    sin que el filtro duro bloquee la operación del panel o del worker.
  if TG_OP = 'UPDATE' then
    if v_table = 'posts' then
      if (new_row ->> 'title') is not distinct from (to_jsonb(OLD) ->> 'title')
         and (new_row ->> 'content') is not distinct from (to_jsonb(OLD) ->> 'content')
         and (new_row ->> 'image_url') is not distinct from (to_jsonb(OLD) ->> 'image_url')
         and (new_row ->> 'gif_url') is not distinct from (to_jsonb(OLD) ->> 'gif_url') then
        return NEW;
      end if;
    elsif v_table = 'comments' then
      if (new_row ->> 'content') is not distinct from (to_jsonb(OLD) ->> 'content')
         and (new_row ->> 'gif_url') is not distinct from (to_jsonb(OLD) ->> 'gif_url') then
        return NEW;
      end if;
    elsif v_table = 'student_groups' then
      if (new_row ->> 'title') is not distinct from (to_jsonb(OLD) ->> 'title')
         and (new_row ->> 'description') is not distinct from (to_jsonb(OLD) ->> 'description')
         and (new_row ->> 'link') is not distinct from (to_jsonb(OLD) ->> 'link')
         and (new_row ->> 'image_url') is not distinct from (to_jsonb(OLD) ->> 'image_url') then
        return NEW;
      end if;
    elsif v_table = 'marketplace_items' then
      if (new_row ->> 'title') is not distinct from (to_jsonb(OLD) ->> 'title')
         and (new_row ->> 'description') is not distinct from (to_jsonb(OLD) ->> 'description')
         and (new_row -> 'image_urls') is not distinct from (to_jsonb(OLD) -> 'image_urls')
         and (new_row ->> 'video_url') is not distinct from (to_jsonb(OLD) ->> 'video_url') then
        return NEW;
      end if;
    elsif v_table = 'seccion_reviews' then
      if (new_row ->> 'comentario') is not distinct from (to_jsonb(OLD) ->> 'comentario')
         and (new_row ->> 'catedratico_nombre') is not distinct from (to_jsonb(OLD) ->> 'catedratico_nombre')
         and (new_row ->> 'curso_codigo') is not distinct from (to_jsonb(OLD) ->> 'curso_codigo') then
        return NEW;
      end if;
    elsif v_table = 'entity_reports' then
      if (new_row ->> 'reason') is not distinct from (to_jsonb(OLD) ->> 'reason')
         and (new_row ->> 'details') is not distinct from (to_jsonb(OLD) ->> 'details')
         and (new_row -> 'metadata') is not distinct from (to_jsonb(OLD) -> 'metadata') then
        return NEW;
      end if;
    else
      return NEW;
    end if;
  end if;

  -- 1) Determinar scope_key de forma segura con to_jsonb
  if v_table in ('posts', 'marketplace_items') and (new_row ? 'category') then
    v_scope := coalesce(nullif(trim(new_row->>'category'), ''), 'default');
  else
    v_scope := 'default';
  end if;

  -- 2) Cargar política con fallback a 'default' y a valores seguros en código
  select * into v_policy
    from public.moderation_policies
   where entity_table = v_table and scope_key = v_scope;

  if not found and v_scope <> 'default' then
    select * into v_policy
      from public.moderation_policies
     where entity_table = v_table and scope_key = 'default';
  end if;

  v_allow_profanity := coalesce(v_policy.allow_colloquial_profanity, false);
  v_allow_ext_links := coalesce(v_policy.allow_external_links, true);
  v_require_verified := coalesce(v_policy.require_verified_user, false);

  -- 3) Protección legal Guatemala (SIEMPRE ACTIVA, sin importar la política)
  --    SOLO en posts, comments y seccion_reviews sobre campos de contenido
  if v_table in ('posts', 'comments', 'seccion_reviews') then
    if v_table = 'posts' then
      v_pii_text := coalesce(new_row->>'title', '') || ' ' || coalesce(new_row->>'content', '');
    elsif v_table = 'comments' then
      v_pii_text := coalesce(new_row->>'content', '');
    elsif v_table = 'seccion_reviews' then
      v_pii_text := coalesce(new_row->>'comentario', '');
    end if;

    -- Teléfono GT: 8 dígitos empezando por 3, 4, 5, 6 o 7
    if v_pii_text ~ '\m[34567][0-9]{3}[-[:space:]]?[0-9]{4}\M' then
      raise exception 'Protección legal (Guatemala): no se permite divulgar números de teléfono personales.'
        using errcode = 'P0001';
    end if;

    -- DPI: 13 dígitos exactos
    if v_pii_text ~ '\m[0-9]{13}\M' then
      raise exception 'Protección legal (Guatemala): no se permite divulgar números de DPI / CUI personales.'
        using errcode = 'P0001';
    end if;
  end if;

  -- 4) Validación require_verified_user
  if v_require_verified and v_table <> 'entity_reports' then
    v_author_id := nullif(new_row->>'user_id', '')::uuid;
    if v_author_id is null or not exists (
      select 1 from public.profiles
       where id = v_author_id and is_verified = true
    ) then
      raise exception 'Esta sección requiere que el usuario esté verificado para publicar.'
        using errcode = 'P0001';
    end if;
  end if;

  -- 5) Extracción de texto dinámico excluyendo campos técnicos y de contacto
  for key, val in select k, v from jsonb_each_text(new_row) as e(k, v)
  loop
    if key = 'id'
       or key like '%\_id'
       or key = 'image_url'
       or key = 'image_urls'
       or key = 'video_url'
       or key like 'moderation\_%'
       or key = 'moderated_by'
       or key like '%\_at'
       or (v_table = 'marketplace_items' and key like 'contact\_%')
    then
      continue;
    end if;
    clean_text := clean_text || ' ' || coalesce(val, '');
  end loop;

  clean_text := lower(clean_text);
  -- Anti-evasión: leetspeak y remoción de acentos
  clean_text := translate(clean_text, '013457@$!v', 'oieastasiu');
  clean_text := translate(clean_text, 'áéíóúüñÁÉÍÓÚÜÑ', 'aeiouunAEIOUUN');
  compact_text := regexp_replace(clean_text, '[\s\-\_\.\*\+\?\!|/()\[\]{}:,;~#%&^=]', '', 'g');

  -- Flooding: repeticiones consecutivas excesivas (>12)
  if compact_text ~* '(.)\1{12,}' then
    raise exception 'El contenido contiene caracteres repetidos de forma excesiva (flooding).'
      using errcode = 'P0001';
  end if;

  -- Enlaces externos si la política los prohíbe
  if not v_allow_ext_links and v_table <> 'entity_reports' then
    if clean_text ~* '(https?://|www\.[a-z0-9\-]+\.[a-z]{2,}|[a-z0-9\-]+\.(com|org|net|edu|gob|gt|io|app|dev|me|co)\M)' then
      raise exception 'No se permiten enlaces externos en esta sección.'
        using errcode = 'P0001';
    end if;
  end if;

  -- Enlaces prohibidos (adultos, apuestas, malware, acortadores)
  foreach word in array forbidden_links
  loop
    if left(word, 1) = '.' then
      if clean_text ~* ('\' || word || '(\/|\?|\y|$)') then
        raise exception 'El contenido incluye enlaces o extensiones de archivo prohibidas ("%").', word
          using errcode = 'P0001';
      end if;
    else
      if clean_text ~* ('\y' || word || '\y')
         or clean_text ~* ('\.' || word || '\.')
         or clean_text ~* ('\/' || word || '(\/|\?|\y|$)')
      then
        raise exception 'El contenido incluye enlaces no autorizados ("%").', word
          using errcode = 'P0001';
      end if;
    end if;
  end loop;

  -- 6) Groserías / Slurs (en entity_reports no se aplican groserías)
  if v_table <> 'entity_reports' then
    if v_allow_profanity then
      -- Solo bloquea slurs severos
      foreach word in array severe_slurs
      loop
        if clean_text ~* ('\y' || word || '\y') then
          raise exception 'El contenido contiene lenguaje de odio o violencia prohibido ("%").', word
            using errcode = 'P0001';
        end if;
      end loop;
    else
      -- Bloquea lista completa de groserías
      foreach word in array forbidden_words
      loop
        if clean_text ~* ('\y' || word || '\y') then
          raise exception 'El contenido contiene lenguaje inapropiado u ofensivo ("%").', word
            using errcode = 'P0001';
        end if;
      end loop;
    end if;
  end if;

  return NEW;
end;
$function$;

grant execute on function public.check_content_moderation() to anon, authenticated, service_role;

-- Vincular trigger en todas las tablas de contenido y reportes
drop trigger if exists trg_moderate_posts on public.posts;
create trigger trg_moderate_posts
  before insert or update on public.posts
  for each row execute function public.check_content_moderation();

drop trigger if exists trg_moderate_comments on public.comments;
create trigger trg_moderate_comments
  before insert or update on public.comments
  for each row execute function public.check_content_moderation();

drop trigger if exists trg_moderate_student_groups on public.student_groups;
create trigger trg_moderate_student_groups
  before insert or update on public.student_groups
  for each row execute function public.check_content_moderation();

drop trigger if exists trg_moderate_whatsapp_groups on public.student_groups;

drop trigger if exists trg_moderate_marketplace_items on public.marketplace_items;
create trigger trg_moderate_marketplace_items
  before insert or update on public.marketplace_items
  for each row execute function public.check_content_moderation();

drop trigger if exists trg_moderate_seccion_reviews on public.seccion_reviews;
create trigger trg_moderate_seccion_reviews
  before insert or update on public.seccion_reviews
  for each row execute function public.check_content_moderation();

drop trigger if exists trg_moderate_entity_reports on public.entity_reports;
create trigger trg_moderate_entity_reports
  before insert or update on public.entity_reports
  for each row execute function public.check_content_moderation();


-- ============================================================================
-- 5) PRIORIDAD DINÁMICA Y ENCOLADO ASÍNCRONO
-- ============================================================================

-- Cálculo de prioridad dinámica al encolar
-- 10 = urgencia/riesgo alto (sale primero en cola)
-- 100 = estándar
-- 200 = baja prioridad / autor de confianza alta
create or replace function public.moderation_priority_for(
  p_entity_table text,
  p_user_id uuid,
  p_text text,
  p_has_image boolean
) returns integer
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_is_verified boolean := false;
  v_reputation numeric := null;
  v_has_url boolean := false;
begin
  if p_user_id is not null then
    select coalesce(p.is_verified, false), p.reputation_score
      into v_is_verified, v_reputation
      from public.profiles p
     where p.id = p_user_id;
  end if;

  if p_text is not null and p_text ~* '(https?://|www\.[a-z0-9\-]+\.[a-z]{2,}|[a-z0-9\-]+\.(com|org|net|edu|gob|gt|io|app|dev|me|co)\M)' then
    v_has_url := true;
  end if;

  -- 10 si reputation_score < 3.5 (incluye perfil inexistente/null) o si contiene URL o imagen
  if coalesce(v_reputation, 0) < 3.5 or v_has_url or coalesce(p_has_image, false) then
    return 10;
  end if;

  -- 200 si el autor está verificado y cuenta con alta reputación (>= 4.5)
  if v_is_verified and v_reputation >= 4.5 then
    return 200;
  end if;

  -- 100 en el resto
  return 100;
end;
$$;

grant execute on function public.moderation_priority_for(text, uuid, text, boolean) to anon, authenticated, service_role;

-- Encolar en moderation_jobs (idempotente)
create or replace function public.enqueue_moderation(
  p_table text,
  p_id uuid,
  p_hash text,
  p_priority int default 100,
  p_has_image boolean default false
) returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.moderation_jobs as j
    (entity_table, entity_id, content_hash, priority, has_image)
  values (p_table, p_id, p_hash, p_priority, p_has_image)
  on conflict (entity_table, entity_id, content_hash) do update
     set status     = 'pending',
         attempts   = 0,
         last_error = null,
         priority   = least(j.priority, excluded.priority),
         run_after  = now(),
         updated_at = now()
   where j.status in ('done', 'failed');
end;
$$;

-- Triggers de encolado dinámico por tabla de contenido
create or replace function public.trg_enqueue_posts() returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_new text;
  v_old text;
  v_has_image boolean;
  v_priority integer;
begin
  v_has_image := (new.image_url is not null or new.gif_url is not null);
  v_new := md5(coalesce(new.title, '') || coalesce(new.content, '') || coalesce(new.image_url, '') || coalesce(new.gif_url, ''));

  if tg_op = 'UPDATE' then
    v_old := md5(coalesce(old.title, '') || coalesce(old.content, '') || coalesce(old.image_url, '') || coalesce(old.gif_url, ''));
    if v_new = v_old then return new; end if;
  end if;

  v_priority := public.moderation_priority_for(
    'posts', new.user_id,
    coalesce(new.title, '') || ' ' || coalesce(new.content, ''),
    v_has_image
  );

  perform public.enqueue_moderation('posts', new.id, v_new, v_priority, v_has_image);
  return new;
end;
$$;

drop trigger if exists posts_enqueue on public.posts;
create trigger posts_enqueue
  after insert or update of title, content, image_url, gif_url on public.posts
  for each row execute function public.trg_enqueue_posts();

create or replace function public.trg_enqueue_comments() returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_new text;
  v_old text;
  v_has_image boolean;
  v_priority integer;
begin
  v_has_image := (new.gif_url is not null);
  v_new := md5(coalesce(new.content, '') || coalesce(new.gif_url, ''));

  if tg_op = 'UPDATE' then
    v_old := md5(coalesce(old.content, '') || coalesce(old.gif_url, ''));
    if v_new = v_old then return new; end if;
  end if;

  v_priority := public.moderation_priority_for('comments', new.user_id, coalesce(new.content, ''), v_has_image);
  perform public.enqueue_moderation('comments', new.id, v_new, v_priority, v_has_image);
  return new;
end;
$$;

drop trigger if exists comments_enqueue on public.comments;
create trigger comments_enqueue
  after insert or update of content, gif_url on public.comments
  for each row execute function public.trg_enqueue_comments();

create or replace function public.trg_enqueue_student_groups() returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_new text;
  v_old text;
  v_has_image boolean;
  v_priority integer;
begin
  v_has_image := (new.image_url is not null);
  v_new := md5(coalesce(new.title, '') || coalesce(new.description, '') || coalesce(new.link, '') || coalesce(new.image_url, ''));

  if tg_op = 'UPDATE' then
    v_old := md5(coalesce(old.title, '') || coalesce(old.description, '') || coalesce(old.link, '') || coalesce(old.image_url, ''));
    if v_new = v_old then return new; end if;
  end if;

  v_priority := public.moderation_priority_for(
    'student_groups', new.user_id,
    coalesce(new.title, '') || ' ' || coalesce(new.description, '') || ' ' || coalesce(new.link, ''),
    v_has_image
  );

  perform public.enqueue_moderation('student_groups', new.id, v_new, v_priority, v_has_image);
  return new;
end;
$$;

drop trigger if exists student_groups_enqueue on public.student_groups;
create trigger student_groups_enqueue
  after insert or update of title, description, link, image_url on public.student_groups
  for each row execute function public.trg_enqueue_student_groups();

create or replace function public.trg_enqueue_marketplace() returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_first_img text;
  v_first_img_old text;
  v_new text;
  v_old text;
  v_has_image boolean;
  v_priority integer;
begin
  v_first_img := case
    when new.image_urls is null or array_length(new.image_urls, 1) is null then null
    else new.image_urls[1]
  end;
  v_has_image := (v_first_img is not null);
  v_new := md5(coalesce(new.title, '') || coalesce(new.description, '') || coalesce(v_first_img, '') || coalesce(new.video_url, ''));

  if tg_op = 'UPDATE' then
    v_first_img_old := case
      when old.image_urls is null or array_length(old.image_urls, 1) is null then null
      else old.image_urls[1]
    end;
    v_old := md5(coalesce(old.title, '') || coalesce(old.description, '') || coalesce(v_first_img_old, '') || coalesce(old.video_url, ''));
    if v_new = v_old then return new; end if;
  end if;

  v_priority := public.moderation_priority_for(
    'marketplace_items', new.user_id,
    coalesce(new.title, '') || ' ' || coalesce(new.description, ''),
    v_has_image
  );

  perform public.enqueue_moderation('marketplace_items', new.id, v_new, v_priority, v_has_image);
  return new;
end;
$$;

drop trigger if exists marketplace_enqueue on public.marketplace_items;
create trigger marketplace_enqueue
  after insert or update of title, description, image_urls, video_url on public.marketplace_items
  for each row execute function public.trg_enqueue_marketplace();

create or replace function public.trg_enqueue_seccion_reviews() returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_new text;
  v_old text;
  v_priority integer;
begin
  v_new := md5(coalesce(new.comentario, '') || coalesce(new.catedratico_nombre, '') || coalesce(new.curso_codigo, '') || coalesce(new.seccion, ''));

  if tg_op = 'UPDATE' then
    v_old := md5(coalesce(old.comentario, '') || coalesce(old.catedratico_nombre, '') || coalesce(old.curso_codigo, '') || coalesce(old.seccion, ''));
    if v_new = v_old then return new; end if;
  end if;

  v_priority := public.moderation_priority_for(
    'seccion_reviews', new.user_id,
    coalesce(new.comentario, '') || ' ' || coalesce(new.catedratico_nombre, ''),
    false
  );

  perform public.enqueue_moderation('seccion_reviews', new.id, v_new, v_priority, false);
  return new;
end;
$$;

drop trigger if exists seccion_reviews_enqueue on public.seccion_reviews;
create trigger seccion_reviews_enqueue
  after insert or update of comentario, catedratico_nombre, curso_codigo, seccion on public.seccion_reviews
  for each row execute function public.trg_enqueue_seccion_reviews();

-- Reencolar desde reporte si no hay job pendiente (soporta seccion_review)
create or replace function public.enqueue_from_report() returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_table text;
begin
  v_table := case new.entity_type
    when 'post' then 'posts'
    when 'comment' then 'comments'
    when 'group' then 'student_groups'
    when 'student_group' then 'student_groups'
    when 'marketplace_item' then 'marketplace_items'
    when 'seccion_review' then 'seccion_reviews'
    else null end;

  if v_table is null then return new; end if;

  if not exists (
    select 1 from public.moderation_jobs j
     where j.entity_table = v_table
       and j.entity_id = new.entity_id
       and j.status in ('pending', 'processing')
  ) then
    insert into public.moderation_jobs (entity_table, entity_id, content_hash, priority)
    values (v_table, new.entity_id, 'report:' || new.id::text, 10)
    on conflict (entity_table, entity_id, content_hash) do nothing;
  end if;

  return new;
end;
$$;

drop trigger if exists entity_reports_enqueue on public.entity_reports;
create trigger entity_reports_enqueue
  after insert on public.entity_reports
  for each row execute function public.enqueue_from_report();


-- ============================================================================
-- 6) CIRCUIT BREAKER PONDERADO DE REPORTES
-- ============================================================================

create or replace function public.is_risk_report_reason(p_reason text)
returns boolean
language plpgsql
immutable
security definer
set search_path = ''
as $$
declare
  v_norm text;
begin
  if p_reason is null then
    return false;
  end if;

  v_norm := lower(translate(trim(regexp_replace(p_reason, '\s+', ' ', 'g')), 'áéíóúÁÉÍÓÚ', 'aeiouaeiou'));
  return (
    v_norm ~ '(acoso|difamacion|informacion personal|doxxing|pii|venta ilegal|servicios prohibidos|suplantacion|impersonation|amenaza|threat|fraude|fraud|extorsion|acceso ilicito|access_abuse)'
  );
end;
$$;

grant execute on function public.is_risk_report_reason(text) to anon, authenticated, service_role;

-- Reemplazo de auto-cuarentena con lógica ponderada y corrección de estado
create or replace function public.handle_entity_report_auto_quarantine()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_table text;
  v_scope text := 'default';
  v_weighted_score numeric := 0;
  v_threshold numeric := 3.0;
  v_has_risk boolean := false;
  v_has_legal_risk boolean := false;
  v_reason_norm text;
  v_target_status integer;
  v_set_legal_hold boolean := false;
  v_entity_updated boolean := false;
begin
  -- 1) Mapear entity_type singular a tabla
  v_table := case NEW.entity_type
    when 'post' then 'posts'
    when 'comment' then 'comments'
    when 'group' then 'student_groups'
    when 'student_group' then 'student_groups'
    when 'marketplace_item' then 'marketplace_items'
    when 'seccion_review' then 'seccion_reviews'
    else null
  end;

  if v_table is null then
    return NEW;
  end if;

  -- 2) Calcular weighted_score de reportes pendientes (moderation_status = 0)
  --    1.5 si el reportero está verificado, 0.5 si no
  select coalesce(sum(case when p.is_verified = true then 1.5 else 0.5 end), 0)
    into v_weighted_score
    from public.entity_reports er
    left join public.profiles p on p.id = er.reporter_id
   where er.entity_type = NEW.entity_type
     and er.entity_id = NEW.entity_id
     and er.moderation_status = 0;

  -- 3) Leer report_score_to_hide de la política de la entidad
  if v_table = 'posts' then
    select coalesce(nullif(trim(category), ''), 'default') into v_scope from public.posts where id = NEW.entity_id;
  elsif v_table = 'marketplace_items' then
    select coalesce(nullif(trim(category), ''), 'default') into v_scope from public.marketplace_items where id = NEW.entity_id;
  end if;

  select report_score_to_hide into v_threshold
    from public.moderation_policies
   where entity_table = v_table and scope_key = coalesce(v_scope, 'default');

  if v_threshold is null then
    select report_score_to_hide into v_threshold
      from public.moderation_policies
     where entity_table = v_table and scope_key = 'default';
  end if;

  v_threshold := coalesce(v_threshold, 3.0);

  -- 4) Evaluación de riesgo.
  --    Riesgo legal (doxxing, datos personales, ilícitos) => ocultar + retención.
  --    Otros motivos de riesgo (acoso, amenazas, difamación) => zona gris (3) para
  --    revisión humana sin activar retención automática.
  v_reason_norm := lower(translate(coalesce(NEW.reason, ''), 'áéíóúÁÉÍÓÚ', 'aeiouaeiou'));
  v_has_risk := public.is_risk_report_reason(NEW.reason);
  v_has_legal_risk := (
    v_reason_norm ~ '(doxxing|ilegal|informacion personal|\mpii\M|extorsion|suplantacion|venta ilicita|acceso ilicito|fraude|estafa)'
  );

  -- 5) Si se supera el umbral ponderado o es motivo de riesgo
  if v_weighted_score >= v_threshold or v_has_risk then
    if v_has_legal_risk then
      v_target_status := 2; -- Oculto inmediatamente
      v_set_legal_hold := true;
    else
      v_target_status := 3; -- Zona gris / requiere revisión
      v_set_legal_hold := false;
    end if;

    -- Actualizar entidad
    if v_table = 'posts' then
      update public.posts set
        moderation_status = v_target_status,
        is_legal_hold = case when v_set_legal_hold then true else is_legal_hold end,
        moderation_reason = 'Escalado automático por reportes de la comunidad',
        updated_at = now()
       where id = NEW.entity_id;
      v_entity_updated := found;

    elsif v_table = 'comments' then
      update public.comments set
        moderation_status = v_target_status,
        is_legal_hold = case when v_set_legal_hold then true else is_legal_hold end,
        moderation_reason = 'Escalado automático por reportes de la comunidad',
        updated_at = now()
       where id = NEW.entity_id;
      v_entity_updated := found;

    elsif v_table = 'student_groups' then
      update public.student_groups set
        moderation_status = v_target_status,
        is_legal_hold = case when v_set_legal_hold then true else is_legal_hold end,
        moderation_reason = 'Escalado automático por reportes de la comunidad',
        updated_at = now()
       where id = NEW.entity_id;
      v_entity_updated := found;

    elsif v_table = 'marketplace_items' then
      update public.marketplace_items set
        moderation_status = v_target_status,
        is_legal_hold = case when v_set_legal_hold then true else is_legal_hold end,
        moderation_reason = 'Escalado automático por reportes de la comunidad',
        updated_at = now()
       where id = NEW.entity_id;
      v_entity_updated := found;

    elsif v_table = 'seccion_reviews' then
      update public.seccion_reviews set
        moderation_status = v_target_status,
        is_legal_hold = case when v_set_legal_hold then true else is_legal_hold end,
        moderation_reason = 'Escalado automático por reportes de la comunidad',
        updated_at = now()
       where id = NEW.entity_id;
      v_entity_updated := found;
    end if;

    if not v_entity_updated then
      return NEW;
    end if;

    -- Escalar prioridad a 5 en jobs existentes pendientes o procesando
    update public.moderation_jobs
       set priority = 5,
           updated_at = now()
     where entity_table = v_table
       and entity_id = NEW.entity_id
       and status in ('pending', 'processing');

    -- Asegurar trabajo encolado con prioridad 5
    perform public.enqueue_moderation(v_table, NEW.entity_id, 'report:' || NEW.id::text, 5, false);

    -- Auditoría idempotente
    if not exists (
      select 1 from public.moderation_audit_log
       where entity_table = v_table
         and entity_id = NEW.entity_id
         and moderation_label = 'COMMUNITY_AUTO_QUARANTINE'
    ) then
      insert into public.moderation_audit_log (
        moderator_id, entity_table, entity_id, justification,
        is_automated, moderation_label, confidence, created_at
      ) values (
        null, v_table, NEW.entity_id,
        'Escalado automático por reportes de la comunidad (score=' || v_weighted_score || ')',
        true, 'COMMUNITY_AUTO_QUARANTINE', 1.0, now()
      );
    end if;
  end if;

  return NEW;
end;
$$;

revoke all on function public.handle_entity_report_auto_quarantine() from public;
grant execute on function public.handle_entity_report_auto_quarantine() to anon, authenticated, service_role;

drop trigger if exists trg_entity_reports_auto_quarantine on public.entity_reports;
create trigger trg_entity_reports_auto_quarantine
  after insert on public.entity_reports
  for each row execute function public.handle_entity_report_auto_quarantine();


-- ============================================================================
-- 7) VISTA Y RPC DEL PANEL HUMANO DE REPORTES
-- ============================================================================

-- Vista agrupada de reportes por entidad
create or replace view public.v_grouped_entity_reports
with (security_invoker = true)
as
with report_summary as (
  select
    er.entity_type,
    er.entity_id,
    count(*)::bigint as total_reports,
    count(*) filter (where er.moderation_status = 0)::bigint as pending_reports,
    coalesce(sum(case when p.is_verified = true then 1.5 else 0.5 end) filter (where er.moderation_status = 0), 0)::numeric as weighted_score,
    max(er.created_at) as latest_report_at,
    (array_agg(coalesce(er.reported_user_id, er.entity_owner_id) order by er.created_at desc) filter (where coalesce(er.reported_user_id, er.entity_owner_id) is not null))[1] as reported_user_id
  from public.entity_reports er
  left join public.profiles p on p.id = er.reporter_id
  group by er.entity_type, er.entity_id
),
reason_counts as (
  select
    entity_type,
    entity_id,
    coalesce(nullif(trim(reason), ''), 'sin_motivo') as r_reason,
    count(*) as r_cnt
  from public.entity_reports
  group by entity_type, entity_id, coalesce(nullif(trim(reason), ''), 'sin_motivo')
),
reason_summary as (
  select
    entity_type,
    entity_id,
    jsonb_object_agg(r_reason, r_cnt) as reasons_summary
  from reason_counts
  group by entity_type, entity_id
)
select
  rs.entity_type,
  rs.entity_id,
  rs.total_reports,
  rs.pending_reports,
  rs.weighted_score,
  coalesce(rea.reasons_summary, '{}'::jsonb) as reasons_summary,
  rs.latest_report_at,
  coalesce(
    rs.reported_user_id,
    case rs.entity_type
      when 'post' then po.user_id
      when 'comment' then co.user_id
      when 'group' then sg.user_id
      when 'student_group' then sg.user_id
      when 'marketplace_item' then mi.user_id
      when 'seccion_review' then sr.user_id
      when 'user' then rs.entity_id
      else null
    end
  ) as reported_user_id,
  case rs.entity_type
    when 'post' then
      jsonb_build_object(
        'title', po.title,
        'content', po.content,
        'author_alias', po.author_alias,
        'user_id', po.user_id,
        'moderation_status', po.moderation_status,
        'is_legal_hold', po.is_legal_hold,
        'category', po.category,
        'image_url', po.image_url
      )
    when 'comment' then
      jsonb_build_object(
        'title', null,
        'content', co.content,
        'author_alias', co.author_alias,
        'user_id', co.user_id,
        'moderation_status', co.moderation_status,
        'is_legal_hold', co.is_legal_hold,
        'category', null,
        'image_url', null
      )
    when 'group' then
      jsonb_build_object(
        'title', sg.title,
        'content', sg.description,
        'author_alias', sg.author_alias,
        'user_id', sg.user_id,
        'moderation_status', sg.moderation_status,
        'is_legal_hold', sg.is_legal_hold,
        'category', sg.curso,
        'image_url', sg.image_url
      )
    when 'student_group' then
      jsonb_build_object(
        'title', sg.title,
        'content', sg.description,
        'author_alias', sg.author_alias,
        'user_id', sg.user_id,
        'moderation_status', sg.moderation_status,
        'is_legal_hold', sg.is_legal_hold,
        'category', sg.curso,
        'image_url', sg.image_url
      )
    when 'marketplace_item' then
      jsonb_build_object(
        'title', mi.title,
        'content', mi.description,
        'author_alias', mi.author_alias,
        'user_id', mi.user_id,
        'moderation_status', mi.moderation_status,
        'is_legal_hold', mi.is_legal_hold,
        'category', mi.category,
        'image_url', case when array_length(mi.image_urls, 1) >= 1 then mi.image_urls[1] else null end
      )
    when 'seccion_review' then
      jsonb_build_object(
        'title', sr.catedratico_nombre,
        'content', sr.comentario,
        'author_alias', null,
        'user_id', sr.user_id,
        'moderation_status', sr.moderation_status,
        'is_legal_hold', sr.is_legal_hold,
        'category', sr.curso_codigo,
        'image_url', null
      )
    when 'user' then
      jsonb_build_object(
        'title', null,
        'content', null,
        'author_alias', null,
        'user_id', rs.entity_id,
        'moderation_status', null,
        'is_legal_hold', null,
        'category', null,
        'image_url', null
      )
    else
      jsonb_build_object(
        'title', null,
        'content', null,
        'author_alias', null,
        'user_id', null,
        'moderation_status', null,
        'is_legal_hold', null,
        'category', null,
        'image_url', null
      )
  end as entity_snapshot
from report_summary rs
left join reason_summary rea
  on rea.entity_type = rs.entity_type
 and rea.entity_id = rs.entity_id
left join public.posts po
  on rs.entity_type = 'post'
 and po.id = rs.entity_id
left join public.comments co
  on rs.entity_type = 'comment'
 and co.id = rs.entity_id
left join public.student_groups sg
  on rs.entity_type in ('group', 'student_group')
 and sg.id = rs.entity_id
left join public.marketplace_items mi
  on rs.entity_type = 'marketplace_item'
 and mi.id = rs.entity_id
left join public.seccion_reviews sr
  on rs.entity_type = 'seccion_review'
 and sr.id = rs.entity_id;

grant select on public.v_grouped_entity_reports to authenticated, service_role;

-- Cancelar jobs del panel
create or replace function public._cancelar_jobs_panel(p_tabla text, p_id uuid)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_n integer;
begin
  update public.moderation_jobs
     set status     = 'done',
         locked_by  = null,
         updated_at = now(),
         last_error = coalesce(last_error, 'Cancelado por decisión manual del panel')
   where entity_table = p_tabla
     and entity_id = p_id
     and status in ('pending', 'processing');
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

revoke execute on function public._cancelar_jobs_panel(text, uuid) from public, anon, authenticated;

-- RPC para resolución humana de reportes
create or replace function public.admin_resolve_entity_reports(
  p_entity_type text,
  p_entity_id uuid,
  p_resolution_status int,
  p_hide_content boolean,
  p_reputation_delta numeric default 0,
  p_set_legal_hold boolean default false,
  p_justification text default null
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_reports_resolved integer := 0;
  v_table text;
  v_author_id uuid := null;
  v_current_hold boolean := false;
  v_final_hold boolean := false;
  v_label text;
  v_reason text;
begin
  if v_uid is null then
    raise exception 'No autenticado' using errcode = '42501';
  end if;
  if not (public.is_pemtree_admin(v_uid) or public.is_pemtree_moderator(v_uid)) then
    raise exception 'Permiso denegado: solo administradores o moderadores pueden resolver reportes'
      using errcode = '42501';
  end if;

  v_table := case p_entity_type
    when 'post' then 'posts'
    when 'comment' then 'comments'
    when 'group' then 'student_groups'
    when 'student_group' then 'student_groups'
    when 'marketplace_item' then 'marketplace_items'
    when 'seccion_review' then 'seccion_reviews'
    when 'user' then 'user'
    else null
  end;

  if v_table is null then
    raise exception 'entity_type no válido: %', p_entity_type using errcode = '22023';
  end if;

  v_reason := coalesce(nullif(trim(p_justification), ''), 'Resolución de reportes desde el panel');
  v_label := case p_resolution_status
    when 1 then 'appropriate'
    when 2 then 'inappropriate'
    else 'resolved'
  end;

  -- 1) Resolver reportes pendientes
  update public.entity_reports
     set moderation_status = p_resolution_status,
         moderated_by = v_uid,
         moderated_at = now(),
         moderation_reason = v_reason,
         moderation_label = v_label,
         updated_at = now()
   where entity_type = p_entity_type
     and entity_id = p_entity_id
     and moderation_status = 0;
  get diagnostics v_reports_resolved = row_count;

  -- 2) Localizar autor y estado de retención legal actual
  if v_table = 'posts' then
    select user_id, coalesce(is_legal_hold, false) into v_author_id, v_current_hold
      from public.posts where id = p_entity_id;
  elsif v_table = 'comments' then
    select user_id, coalesce(is_legal_hold, false) into v_author_id, v_current_hold
      from public.comments where id = p_entity_id;
  elsif v_table = 'student_groups' then
    select user_id, coalesce(is_legal_hold, false) into v_author_id, v_current_hold
      from public.student_groups where id = p_entity_id;
  elsif v_table = 'marketplace_items' then
    select user_id, coalesce(is_legal_hold, false) into v_author_id, v_current_hold
      from public.marketplace_items where id = p_entity_id;
  elsif v_table = 'seccion_reviews' then
    select user_id, coalesce(is_legal_hold, false) into v_author_id, v_current_hold
      from public.seccion_reviews where id = p_entity_id;
  elsif v_table = 'user' then
    v_author_id := p_entity_id;
  end if;

  -- La retención legal solo se puede ACTIVAR desde la resolución de reportes.
  -- Desactivarla requiere la acción explícita admin_toggle_legal_hold, para que
  -- un "confirmar y ocultar" no libere evidencia por accidente.
  v_final_hold := coalesce(v_current_hold, false) or coalesce(p_set_legal_hold, false);

  -- 3) Si p_hide_content = true y no es un usuario directo: ocultar contenido
  if coalesce(p_hide_content, false) and v_table <> 'user' then
    if v_table = 'posts' then
      update public.posts set
        moderation_status = 2,
        moderation_label = 'inappropriate',
        moderation_reason = v_reason,
        moderated_by = v_uid,
        moderated_at = now(),
        is_legal_hold = v_final_hold,
        updated_at = now()
       where id = p_entity_id;
    elsif v_table = 'comments' then
      update public.comments set
        moderation_status = 2,
        moderation_label = 'inappropriate',
        moderation_reason = v_reason,
        moderated_by = v_uid,
        moderated_at = now(),
        is_legal_hold = v_final_hold,
        updated_at = now()
       where id = p_entity_id;
    elsif v_table = 'student_groups' then
      update public.student_groups set
        moderation_status = 2,
        moderation_label = 'inappropriate',
        moderation_reason = v_reason,
        moderated_by = v_uid,
        moderated_at = now(),
        is_legal_hold = v_final_hold,
        updated_at = now()
       where id = p_entity_id;
    elsif v_table = 'marketplace_items' then
      update public.marketplace_items set
        moderation_status = 2,
        moderation_label = 'inappropriate',
        moderation_reason = v_reason,
        moderated_by = v_uid,
        moderated_at = now(),
        is_legal_hold = v_final_hold,
        updated_at = now()
       where id = p_entity_id;
    elsif v_table = 'seccion_reviews' then
      update public.seccion_reviews set
        moderation_status = 2,
        moderation_label = 'inappropriate',
        moderation_reason = v_reason,
        moderated_by = v_uid,
        moderated_at = now(),
        is_legal_hold = v_final_hold,
        updated_at = now()
       where id = p_entity_id;
    end if;

    perform public._cancelar_jobs_panel(v_table, p_entity_id);
  end if;

  -- 4) Impacto en reputación de autor
  if coalesce(p_reputation_delta, 0) <> 0 and v_author_id is not null then
    update public.profiles
       set reputation_score = greatest(0::numeric, least(5.0::numeric, coalesce(reputation_score, 3.0::numeric) + p_reputation_delta)),
           updated_at = now()
     where id = v_author_id;
  end if;

  -- 5) Registrar auditoría
  insert into public.moderation_audit_log (
    moderator_id,
    entity_table,
    entity_id,
    justification,
    is_automated,
    moderation_label
  ) values (
    v_uid,
    case when v_table = 'user' then 'profiles' else v_table end,
    p_entity_id,
    v_reason,
    false,
    case when coalesce(p_hide_content, false) then 'inappropriate' else v_label end
  );

  return jsonb_build_object(
    'reports_resolved', v_reports_resolved,
    'content_hidden', coalesce(p_hide_content, false),
    'legal_hold', v_final_hold,
    'reputation_delta', coalesce(p_reputation_delta, 0)
  );
end;
$$;

revoke execute on function public.admin_resolve_entity_reports(text, uuid, integer, boolean, numeric, boolean, text) from public, anon;
grant execute on function public.admin_resolve_entity_reports(text, uuid, integer, boolean, numeric, boolean, text) to authenticated, service_role;


-- ============================================================================
-- 8) RETENCIÓN LEGAL Y GESTIÓN DE ACCIONES MANUALES
-- ============================================================================

-- Trigger BEFORE DELETE para salvaguardar contenido en retención legal
create or replace function public.enforce_legal_hold_on_delete()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if coalesce(old.is_legal_hold, false) then
    raise exception 'No se puede eliminar contenido bajo retención legal (is_legal_hold = true)'
      using errcode = '42501';
  end if;
  return old;
end;
$$;

grant execute on function public.enforce_legal_hold_on_delete() to anon, authenticated, service_role;

drop trigger if exists trg_legal_hold_delete_posts on public.posts;
create trigger trg_legal_hold_delete_posts
  before delete on public.posts
  for each row execute function public.enforce_legal_hold_on_delete();

drop trigger if exists trg_legal_hold_delete_comments on public.comments;
create trigger trg_legal_hold_delete_comments
  before delete on public.comments
  for each row execute function public.enforce_legal_hold_on_delete();

drop trigger if exists trg_legal_hold_delete_student_groups on public.student_groups;
create trigger trg_legal_hold_delete_student_groups
  before delete on public.student_groups
  for each row execute function public.enforce_legal_hold_on_delete();

drop trigger if exists trg_legal_hold_delete_marketplace_items on public.marketplace_items;
create trigger trg_legal_hold_delete_marketplace_items
  before delete on public.marketplace_items
  for each row execute function public.enforce_legal_hold_on_delete();

drop trigger if exists trg_legal_hold_delete_seccion_reviews on public.seccion_reviews;
create trigger trg_legal_hold_delete_seccion_reviews
  before delete on public.seccion_reviews
  for each row execute function public.enforce_legal_hold_on_delete();

-- RPC para alternar retención legal manualmente desde el panel
create or replace function public.admin_toggle_legal_hold(
  p_table text,
  p_id uuid,
  p_value boolean
) returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_updated boolean := false;
  v_justification text;
begin
  if v_uid is null then
    raise exception 'No autenticado' using errcode = '42501';
  end if;
  if not (public.is_pemtree_admin(v_uid) or public.is_pemtree_moderator(v_uid)) then
    raise exception 'Permiso denegado: solo administradores o moderadores pueden alternar retención legal'
      using errcode = '42501';
  end if;

  if p_table not in ('posts', 'comments', 'student_groups', 'marketplace_items', 'seccion_reviews') then
    raise exception 'Tabla (%) no válida para retención legal.', p_table using errcode = '22023';
  end if;

  if p_table = 'posts' then
    update public.posts set is_legal_hold = p_value, updated_at = now() where id = p_id;
    v_updated := found;
  elsif p_table = 'comments' then
    update public.comments set is_legal_hold = p_value, updated_at = now() where id = p_id;
    v_updated := found;
  elsif p_table = 'student_groups' then
    update public.student_groups set is_legal_hold = p_value, updated_at = now() where id = p_id;
    v_updated := found;
  elsif p_table = 'marketplace_items' then
    update public.marketplace_items set is_legal_hold = p_value, updated_at = now() where id = p_id;
    v_updated := found;
  elsif p_table = 'seccion_reviews' then
    update public.seccion_reviews set is_legal_hold = p_value, updated_at = now() where id = p_id;
    v_updated := found;
  end if;

  if not v_updated then
    raise exception 'El registro ya no existe en la base de datos.' using errcode = 'P0002';
  end if;

  v_justification := case when p_value then 'Retención legal activada' else 'Retención legal desactivada' end;

  insert into public.moderation_audit_log (
    moderator_id,
    entity_table,
    entity_id,
    justification,
    is_automated,
    moderation_label
  ) values (
    v_uid,
    p_table,
    p_id,
    v_justification,
    false,
    'legal_hold'
  );

  return true;
end;
$$;

revoke execute on function public.admin_toggle_legal_hold(text, uuid, boolean) from public, anon;
grant execute on function public.admin_toggle_legal_hold(text, uuid, boolean) to authenticated, service_role;

-- Ocultar contenido con soporte para seccion_reviews
create or replace function public.ocultar_contenido_moderado(
  p_tabla text,
  p_item_id uuid,
  p_justificacion text default null
) returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_owner_id uuid;
  v_is_admin boolean := public.is_pemtree_admin(v_user_id);
  v_is_mod boolean := public.is_pemtree_moderator(v_user_id);
  v_justificacion text;
begin
  if v_user_id is null then
    raise exception 'No estás autenticado en el sistema.' using errcode = '42501';
  end if;

  if p_tabla = 'whatsapp_groups' then
    select user_id into v_owner_id from public.whatsapp_groups where id = p_item_id;
  elsif p_tabla = 'posts' then
    select user_id into v_owner_id from public.posts where id = p_item_id;
  elsif p_tabla = 'comments' then
    select user_id into v_owner_id from public.comments where id = p_item_id;
  elsif p_tabla = 'student_groups' then
    select user_id into v_owner_id from public.student_groups where id = p_item_id;
  elsif p_tabla = 'marketplace_items' then
    select user_id into v_owner_id from public.marketplace_items where id = p_item_id;
  elsif p_tabla = 'seccion_reviews' then
    select user_id into v_owner_id from public.seccion_reviews where id = p_item_id;
  else
    raise exception 'Tabla (%) no válida para moderación.', p_tabla using errcode = '22023';
  end if;

  if not found then
    raise exception 'El registro ya no existe o fue eliminado previamente en la base de datos.' using errcode = 'P0002';
  end if;

  if v_owner_id <> v_user_id and not v_is_admin and not v_is_mod then
    raise exception 'Permiso denegado: No tienes autorización para ocultar este contenido.' using errcode = '42501';
  end if;

  if v_owner_id <> v_user_id and not v_is_admin then
    if p_justificacion is null or trim(p_justificacion) = '' then
      raise exception 'Justificación obligatoria: Como moderador, debes ingresar la razón por la cual ocultas este contenido.' using errcode = 'P0001';
    end if;
    v_justificacion := trim(p_justificacion);
  else
    v_justificacion := coalesce(nullif(trim(p_justificacion), ''), 'Ocultado por el autor o administrador');
  end if;

  insert into public.moderation_audit_log (
    moderator_id, entity_table, entity_id, justification, is_automated, moderation_label
  ) values (
    v_user_id, p_tabla, p_item_id, v_justificacion, false, 'inappropriate'
  );

  if p_tabla = 'whatsapp_groups' then
    update public.whatsapp_groups
       set moderation_status = 2, moderation_label = 'inappropriate', moderation_reason = v_justificacion,
           moderated_by = v_user_id, moderated_at = now()
     where id = p_item_id;
  elsif p_tabla = 'posts' then
    update public.posts
       set moderation_status = 2, moderation_label = 'inappropriate', moderation_reason = v_justificacion,
           moderated_by = v_user_id, moderated_at = now()
     where id = p_item_id;
  elsif p_tabla = 'comments' then
    update public.comments
       set moderation_status = 2, moderation_label = 'inappropriate', moderation_reason = v_justificacion,
           moderated_by = v_user_id, moderated_at = now()
     where id = p_item_id;
  elsif p_tabla = 'student_groups' then
    update public.student_groups
       set moderation_status = 2, moderation_label = 'inappropriate', moderation_reason = v_justificacion,
           moderated_by = v_user_id, moderated_at = now()
     where id = p_item_id;
  elsif p_tabla = 'marketplace_items' then
    update public.marketplace_items
       set moderation_status = 2, moderation_label = 'inappropriate', moderation_reason = v_justificacion,
           moderated_by = v_user_id, moderated_at = now()
     where id = p_item_id;
  elsif p_tabla = 'seccion_reviews' then
    update public.seccion_reviews
       set moderation_status = 2, moderation_label = 'inappropriate', moderation_reason = v_justificacion,
           moderated_by = v_user_id, moderated_at = now()
     where id = p_item_id;
  end if;

  perform public._cancelar_jobs_panel(p_tabla, p_item_id);

  return true;
end;
$$;

revoke execute on function public.ocultar_contenido_moderado(text, uuid, text) from public, anon;
grant execute on function public.ocultar_contenido_moderado(text, uuid, text) to authenticated, service_role;

-- Restaurar contenido con soporte para seccion_reviews
create or replace function public.restaurar_contenido_moderado(
  p_tabla text,
  p_item_id uuid
) returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_is_admin boolean := public.is_pemtree_admin(v_user_id);
  v_is_mod boolean := public.is_pemtree_moderator(v_user_id);
begin
  if v_user_id is null then
    raise exception 'No estás autenticado en el sistema.' using errcode = '42501';
  end if;

  if p_tabla = 'whatsapp_groups' then
    perform 1 from public.whatsapp_groups where id = p_item_id;
  elsif p_tabla = 'posts' then
    perform 1 from public.posts where id = p_item_id;
  elsif p_tabla = 'comments' then
    perform 1 from public.comments where id = p_item_id;
  elsif p_tabla = 'student_groups' then
    perform 1 from public.student_groups where id = p_item_id;
  elsif p_tabla = 'marketplace_items' then
    perform 1 from public.marketplace_items where id = p_item_id;
  elsif p_tabla = 'seccion_reviews' then
    perform 1 from public.seccion_reviews where id = p_item_id;
  else
    raise exception 'Tabla (%) no válida para moderación.', p_tabla using errcode = '22023';
  end if;

  if not found then
    raise exception 'El registro ya no existe o fue eliminado previamente en la base de datos.' using errcode = 'P0002';
  end if;

  if not v_is_admin and not v_is_mod then
    raise exception 'Permiso denegado: Solo un administrador o moderador puede restaurar contenido oculto.' using errcode = '42501';
  end if;

  insert into public.moderation_audit_log (
    moderator_id, entity_table, entity_id, justification, is_automated, moderation_label
  ) values (
    v_user_id, p_tabla, p_item_id, 'Contenido restaurado/aprobado', false, 'appropriate'
  );

  if p_tabla = 'whatsapp_groups' then
    update public.whatsapp_groups
       set moderation_status = 1, moderation_label = 'appropriate', moderation_reason = null,
           moderated_by = null, moderated_at = null
     where id = p_item_id;
  elsif p_tabla = 'posts' then
    update public.posts
       set moderation_status = 1, moderation_label = 'appropriate', moderation_reason = null,
           moderated_by = null, moderated_at = null
     where id = p_item_id;
  elsif p_tabla = 'comments' then
    update public.comments
       set moderation_status = 1, moderation_label = 'appropriate', moderation_reason = null,
           moderated_by = null, moderated_at = null
     where id = p_item_id;
  elsif p_tabla = 'student_groups' then
    update public.student_groups
       set moderation_status = 1, moderation_label = 'appropriate', moderation_reason = null,
           moderated_by = null, moderated_at = null
     where id = p_item_id;
  elsif p_tabla = 'marketplace_items' then
    update public.marketplace_items
       set moderation_status = 1, moderation_label = 'appropriate', moderation_reason = null,
           moderated_by = null, moderated_at = null
     where id = p_item_id;
  elsif p_tabla = 'seccion_reviews' then
    update public.seccion_reviews
       set moderation_status = 1, moderation_label = 'appropriate', moderation_reason = null,
           moderated_by = null, moderated_at = null
     where id = p_item_id;
  end if;

  perform public._cancelar_jobs_panel(p_tabla, p_item_id);

  return true;
end;
$$;

revoke execute on function public.restaurar_contenido_moderado(text, uuid) from public, anon;
grant execute on function public.restaurar_contenido_moderado(text, uuid) to authenticated, service_role;

-- Eliminar contenido con soporte para seccion_reviews y guardia explícita de legal hold
create or replace function public.eliminar_contenido_moderado(
  p_tabla text,
  p_item_id uuid,
  p_justificacion text default null
) returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_owner_id uuid;
  v_is_legal_hold boolean := false;
begin
  if v_user_id is null then
    raise exception 'No estás autenticado en el sistema.' using errcode = '42501';
  end if;

  if p_tabla = 'whatsapp_groups' then
    select user_id, false into v_owner_id, v_is_legal_hold from public.whatsapp_groups where id = p_item_id;
  elsif p_tabla = 'posts' then
    select user_id, coalesce(is_legal_hold, false) into v_owner_id, v_is_legal_hold from public.posts where id = p_item_id;
  elsif p_tabla = 'comments' then
    select user_id, coalesce(is_legal_hold, false) into v_owner_id, v_is_legal_hold from public.comments where id = p_item_id;
  elsif p_tabla = 'student_groups' then
    select user_id, coalesce(is_legal_hold, false) into v_owner_id, v_is_legal_hold from public.student_groups where id = p_item_id;
  elsif p_tabla = 'marketplace_items' then
    select user_id, coalesce(is_legal_hold, false) into v_owner_id, v_is_legal_hold from public.marketplace_items where id = p_item_id;
  elsif p_tabla = 'seccion_reviews' then
    select user_id, coalesce(is_legal_hold, false) into v_owner_id, v_is_legal_hold from public.seccion_reviews where id = p_item_id;
  else
    raise exception 'Tabla (%) no válida para moderación.', p_tabla using errcode = '22023';
  end if;

  if not found then
    raise exception 'El registro ya no existe o fue eliminado previamente en la base de datos.' using errcode = 'P0002';
  end if;

  if not public.is_pemtree_admin(v_user_id) then
    raise exception 'Permiso denegado: Solo el administrador de PEMTREE puede eliminar contenido de forma definitiva.' using errcode = '42501';
  end if;

  -- Guardia de retención legal
  if v_is_legal_hold then
    raise exception 'No se puede eliminar contenido bajo retención legal (is_legal_hold = true)' using errcode = '42501';
  end if;

  insert into public.moderation_audit_log (
    moderator_id, entity_table, entity_id, justification, is_automated, moderation_label
  ) values (
    v_user_id, p_tabla, p_item_id,
    coalesce(nullif(trim(p_justificacion), ''), 'Eliminación definitiva por administrador'),
    false, 'deleted'
  );

  if p_tabla = 'whatsapp_groups' then
    delete from public.whatsapp_groups where id = p_item_id;
  elsif p_tabla = 'posts' then
    delete from public.posts where id = p_item_id;
  elsif p_tabla = 'comments' then
    delete from public.comments where id = p_item_id;
  elsif p_tabla = 'student_groups' then
    delete from public.student_groups where id = p_item_id;
  elsif p_tabla = 'marketplace_items' then
    delete from public.marketplace_items where id = p_item_id;
  elsif p_tabla = 'seccion_reviews' then
    delete from public.seccion_reviews where id = p_item_id;
  end if;

  perform public._cancelar_jobs_panel(p_tabla, p_item_id);

  return true;
end;
$$;

revoke execute on function public.eliminar_contenido_moderado(text, uuid, text) from public, anon;
grant execute on function public.eliminar_contenido_moderado(text, uuid, text) to authenticated, service_role;

-- Actualización de funciones de purga para respetar is_legal_hold
create or replace function public.delete_inappropriate_posts()
returns text
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_user_id uuid := auth.uid();
  v_deleted integer;
begin
  if not public.is_pemtree_admin(v_user_id) then
    raise exception 'Permiso denegado: solo los administradores pueden ejecutar esta limpieza.' using errcode = '42501';
  end if;

  delete from public.posts
   where moderation_status = 2
     and coalesce(is_legal_hold, false) = false;
  get diagnostics v_deleted = row_count;

  return 'Se eliminaron ' || v_deleted || ' publicaciones no apropiadas.';
end;
$function$;

create or replace function public.delete_old_posts(months_old integer default 3)
returns text
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_user_id uuid := auth.uid();
  v_deleted integer;
begin
  if not public.is_pemtree_admin(v_user_id) then
    raise exception 'Permiso denegado: solo los administradores pueden ejecutar esta limpieza.' using errcode = '42501';
  end if;

  delete from public.posts
   where created_at < now() - (months_old || ' months')::interval
     and coalesce(is_legal_hold, false) = false;
  get diagnostics v_deleted = row_count;

  return 'Se eliminaron ' || v_deleted || ' publicaciones con más de ' || months_old || ' meses de antigüedad.';
end;
$function$;

create or replace function public.purge_inappropriate_content()
returns text
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_user_id uuid := auth.uid();
  v_posts integer := 0;
  v_comments integer := 0;
  v_groups integer := 0;
  v_ureports integer := 0;
  v_greports integer := 0;
begin
  if not public.is_pemtree_admin(v_user_id) then
    raise exception 'Permiso denegado: solo los administradores pueden ejecutar esta limpieza.' using errcode = '42501';
  end if;

  delete from public.posts where moderation_status = 2 and coalesce(is_legal_hold, false) = false;
  get diagnostics v_posts = row_count;

  delete from public.comments where moderation_status = 2 and coalesce(is_legal_hold, false) = false;
  get diagnostics v_comments = row_count;

  delete from public.whatsapp_groups where moderation_status = 2;
  get diagnostics v_groups = row_count;

  delete from public.user_reports where moderation_status = 2;
  get diagnostics v_ureports = row_count;

  delete from public.whatsapp_group_reports where moderation_status = 2;
  get diagnostics v_greports = row_count;

  insert into public.moderation_audit_log (
    moderator_id, entity_table, entity_id, justification, is_automated, moderation_label
  ) values (
    v_user_id, 'cleanup', '00000000-0000-0000-0000-000000000000',
    'Limpieza administrador: todo el contenido inapropiado/bloqueado', false, 'cleanup'
  );

  return 'Limpieza completada — posts=' || v_posts || ', comentarios=' || v_comments ||
         ', grupos=' || v_groups || ', reportes de usuario=' || v_ureports || ', reportes de grupo=' || v_greports;
end;
$function$;

create or replace function public.purge_old_content(p_months integer default 3)
returns text
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_user_id uuid := auth.uid();
  v_deleted integer;
  v_cutoff timestamptz := now() - make_interval(months => p_months);
begin
  if not public.is_pemtree_admin(v_user_id) then
    raise exception 'Permiso denegado: solo los administradores pueden ejecutar esta limpieza.' using errcode = '42501';
  end if;

  delete from public.posts where created_at < v_cutoff and coalesce(is_legal_hold, false) = false;
  get diagnostics v_deleted = row_count;

  insert into public.moderation_audit_log (
    moderator_id, entity_table, entity_id, justification, is_automated, moderation_label
  ) values (
    v_user_id, 'cleanup', '00000000-0000-0000-0000-000000000000',
    'Limpieza administrador: posts con más de ' || p_months || ' meses de antigüedad', false, 'cleanup'
  );

  return 'Se eliminaron ' || v_deleted || ' publicaciones con más de ' || p_months || ' meses de antigüedad.';
end;
$function$;

create or replace function public.limpieza_semestral_pemtree()
returns void
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_hoy_md text := to_char(current_date, 'MM-DD');
  v_es_fecha_grupos boolean := v_hoy_md in ('01-01', '05-15', '07-01', '11-15');
begin
  delete from public.posts
   where created_at < now() - interval '3 months'
     and coalesce(is_legal_hold, false) = false;

  delete from public.user_reports
   where created_at < now() - interval '3 months';

  delete from public.comments
   where created_at < now() - interval '3 months'
     and coalesce(is_legal_hold, false) = false;

  delete from public.user_notifications
   where created_at < now() - interval '3 months';

  if v_es_fecha_grupos then
    delete from public.whatsapp_groups;
  end if;
end;
$function$;

grant execute on function public.delete_inappropriate_posts() to service_role;
grant execute on function public.delete_old_posts(integer) to service_role;
grant execute on function public.purge_inappropriate_content() to service_role;
grant execute on function public.purge_old_content(integer) to service_role;
grant execute on function public.limpieza_semestral_pemtree() to service_role;


-- ============================================================================
-- 9) WORKER / PROCESAMIENTO EN LOTE (apply_moderation_batch)
-- ============================================================================

create or replace function public.apply_moderation_batch(p_items jsonb)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_item jsonb;
  v_table text;
  v_id uuid;
  v_key uuid;
  v_label text;
  v_status integer;
  v_confidence double precision;
  v_reason text;
  v_job_id uuid;
  v_locked timestamptz;
  v_legal_hold boolean;
  v_updated integer := 0;
begin
  for v_item in select * from jsonb_array_elements(p_items)
  loop
    v_table      := v_item->>'table';
    v_id         := (v_item->>'id')::uuid;
    v_key        := nullif(v_item->>'key', '')::uuid;
    v_job_id     := nullif(v_item->>'job_id', '')::uuid;

    -- Acepta status numérico explícito (incluyendo 3: zona gris / error)
    v_status     := coalesce(
                      nullif(v_item->>'status', '')::integer,
                      case v_item->>'label'
                        when 'appropriate' then 1
                        when 'inappropriate' then 2
                        else 3
                      end
                    );
    v_label      := coalesce(
                      nullif(v_item->>'label', ''),
                      case v_status
                        when 1 then 'appropriate'
                        when 2 then 'inappropriate'
                        else 'error'
                      end
                    );
    v_confidence := coalesce((v_item->>'confidence')::double precision, 0.0);
    v_reason     := coalesce(v_item->>'reason', '');
    v_legal_hold := case when (v_item ? 'is_legal_hold') then (v_item->>'is_legal_hold')::boolean else null end;

    -- Momento en que el worker reclamó el job para respetar decisiones humanas posteriores
    v_locked := null;
    if v_job_id is not null then
      select j.locked_at into v_locked from public.moderation_jobs j where j.id = v_job_id;
    end if;

    if v_table = 'posts' then
      update public.posts set
        moderation_status = v_status,
        moderation_label = v_label,
        moderation_confidence = v_confidence,
        moderation_reason = v_reason,
        is_legal_hold = case when coalesce(v_legal_hold, false) then true else is_legal_hold end,
        moderated_at = now(),
        moderated_by = null
       where id = v_id
         and not exists (
           select 1 from public.moderation_audit_log a
            where a.entity_table = 'posts' and a.entity_id = v_id
              and a.is_automated = false and a.created_at > v_locked
         );

    elsif v_table = 'comments' then
      update public.comments set
        moderation_status = v_status,
        moderation_label = v_label,
        moderation_confidence = v_confidence,
        moderation_reason = v_reason,
        is_legal_hold = case when coalesce(v_legal_hold, false) then true else is_legal_hold end,
        moderated_at = now(),
        moderated_by = null
       where id = v_id
         and not exists (
           select 1 from public.moderation_audit_log a
            where a.entity_table = 'comments' and a.entity_id = v_id
              and a.is_automated = false and a.created_at > v_locked
         );

    elsif v_table = 'student_groups' then
      update public.student_groups set
        moderation_status = v_status,
        moderation_label = v_label,
        moderation_confidence = v_confidence,
        moderation_reason = v_reason,
        is_legal_hold = case when coalesce(v_legal_hold, false) then true else is_legal_hold end,
        moderated_at = now(),
        moderated_by = null
       where id = v_id
         and not exists (
           select 1 from public.moderation_audit_log a
            where a.entity_table = 'student_groups' and a.entity_id = v_id
              and a.is_automated = false and a.created_at > v_locked
         );

    elsif v_table = 'marketplace_items' then
      update public.marketplace_items set
        moderation_status = v_status,
        moderation_label = v_label,
        moderation_confidence = v_confidence,
        moderation_reason = v_reason,
        is_legal_hold = case when coalesce(v_legal_hold, false) then true else is_legal_hold end,
        moderated_at = now(),
        moderated_by = null
       where id = v_id
         and not exists (
           select 1 from public.moderation_audit_log a
            where a.entity_table = 'marketplace_items' and a.entity_id = v_id
              and a.is_automated = false and a.created_at > v_locked
         );

    elsif v_table = 'seccion_reviews' then
      update public.seccion_reviews set
        moderation_status = v_status,
        moderation_label = v_label,
        moderation_confidence = v_confidence,
        moderation_reason = v_reason,
        is_legal_hold = case when coalesce(v_legal_hold, false) then true else is_legal_hold end,
        moderated_at = now(),
        moderated_by = null
       where id = v_id
         and not exists (
           select 1 from public.moderation_audit_log a
            where a.entity_table = 'seccion_reviews' and a.entity_id = v_id
              and a.is_automated = false and a.created_at > v_locked
         );

    -- Tablas legacy
    elsif v_table = 'whatsapp_groups' then
      update public.whatsapp_groups set
        moderation_status = v_status,
        moderation_label = v_label,
        moderation_confidence = v_confidence,
        moderation_reason = v_reason,
        moderated_at = now(),
        moderated_by = null
       where id = v_id;

    elsif v_table = 'user_reports' then
      update public.user_reports set
        moderation_status = v_status,
        moderation_label = v_label,
        moderation_confidence = v_confidence,
        moderation_reason = v_reason,
        moderated_at = now(),
        moderated_by = null
       where id = v_id;

    elsif v_table = 'whatsapp_group_reports' then
      update public.whatsapp_group_reports set
        moderation_status = v_status,
        moderation_label = v_label,
        moderation_confidence = v_confidence,
        moderation_reason = v_reason,
        moderated_at = now(),
        moderated_by = null
       where group_id = v_id and user_id = v_key;

    else
      if v_job_id is not null then
        perform public.fail_moderation_job(v_job_id, 'Tabla desconocida: ' || coalesce(v_table, '(null)'));
      end if;
      continue;
    end if;

    if found then
      insert into public.moderation_audit_log (
        moderator_id, entity_table, entity_id, justification,
        is_automated, moderation_label, confidence
      ) values (
        null, v_table, v_id, v_reason, true, v_label, v_confidence
      );
      v_updated := v_updated + 1;
    end if;

    if v_job_id is not null then
      perform public.complete_moderation_job(v_job_id);
    end if;
  end loop;

  return v_updated;
end;
$$;

revoke execute on function public.apply_moderation_batch(jsonb) from public, anon, authenticated;
grant execute on function public.apply_moderation_batch(jsonb) to service_role;


-- ============================================================================
-- 10) RPCS DE SALUD DE COLA Y MANTENIMIENTO DEL PANEL
-- ============================================================================

-- Reclamar trabajo (worker)
create or replace function public.claim_moderation_job(p_worker text)
returns table(job_id uuid, entity_table text, entity_id uuid, attempts int, has_image boolean)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  update public.moderation_jobs as mj
     set status     = case when mj.attempts >= mj.max_attempts then 'failed' else 'pending' end,
         last_error = coalesce(mj.last_error, 'Worker sin respuesta (job colgado)'),
         locked_by  = null,
         locked_at  = null,
         updated_at = now()
   where mj.status = 'processing'
     and mj.locked_at < now() - interval '10 minutes';

  select j.id into v_id
    from public.moderation_jobs j
   where j.status = 'pending' and j.run_after <= now()
   order by j.priority, j.created_at
   for update skip locked
   limit 1;

  if v_id is null then return; end if;

  update public.moderation_jobs as mj
     set status     = 'processing',
         locked_by  = p_worker,
         locked_at  = now(),
         attempts   = mj.attempts + 1,
         updated_at = now()
   where mj.id = v_id;

  return query
    select m.id, m.entity_table, m.entity_id, m.attempts, m.has_image
      from public.moderation_jobs m where m.id = v_id;
end;
$$;

revoke execute on function public.claim_moderation_job(text) from public, anon, authenticated;
grant execute on function public.claim_moderation_job(text) to service_role;

-- Completar trabajo (worker)
create or replace function public.complete_moderation_job(p_job_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.moderation_jobs
     set status     = 'done',
         updated_at = now(),
         locked_by  = null,
         locked_at  = null
   where id = p_job_id;
end;
$$;

revoke execute on function public.complete_moderation_job(uuid) from public, anon, authenticated;
grant execute on function public.complete_moderation_job(uuid) to service_role;

-- Fallar trabajo con backoff exponencial (worker)
create or replace function public.fail_moderation_job(p_job_id uuid, p_error text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_attempts int;
  v_max int;
begin
  select attempts, max_attempts into v_attempts, v_max
    from public.moderation_jobs where id = p_job_id;

  if v_attempts is null then return; end if;

  if v_attempts >= v_max then
    update public.moderation_jobs
       set status     = 'failed',
           last_error = p_error,
           updated_at = now(),
           locked_by  = null,
           locked_at  = null
     where id = p_job_id;
  else
    update public.moderation_jobs
       set status     = 'pending',
           run_after  = now() + (interval '1 minute' * power(2, v_attempts)),
           last_error = p_error,
           updated_at = now(),
           locked_by  = null,
           locked_at  = null
     where id = p_job_id;
  end if;
end;
$$;

revoke execute on function public.fail_moderation_job(uuid, text) from public, anon, authenticated;
grant execute on function public.fail_moderation_job(uuid, text) to service_role;

-- Marcar pendientes como error si el servicio externo no responde (incluye seccion_reviews)
create or replace function public.marcar_pendientes_error(p_horas integer default 1)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_limite timestamptz := now() - make_interval(hours => p_horas);
  v_total integer := 0;
  v_cont integer;
begin
  -- posts
  with marcados as (
    update public.posts
       set moderation_status = 3, moderation_label = 'error', moderation_confidence = 0,
           moderation_reason = 'Servicio de moderación no disponible',
           moderated_at = now(), moderated_by = null
     where moderation_status = 0 and created_at < v_limite
    returning id
  )
  insert into public.moderation_audit_log
    (moderator_id, entity_table, entity_id, justification, is_automated, moderation_label, confidence)
  select null, 'posts', id, 'Servicio de moderación no disponible', true, 'error', 0 from marcados;
  get diagnostics v_cont = row_count;
  v_total := v_total + v_cont;

  -- comments
  with marcados as (
    update public.comments
       set moderation_status = 3, moderation_label = 'error', moderation_confidence = 0,
           moderation_reason = 'Servicio de moderación no disponible',
           moderated_at = now(), moderated_by = null
     where moderation_status = 0 and created_at < v_limite
    returning id
  )
  insert into public.moderation_audit_log
    (moderator_id, entity_table, entity_id, justification, is_automated, moderation_label, confidence)
  select null, 'comments', id, 'Servicio de moderación no disponible', true, 'error', 0 from marcados;
  get diagnostics v_cont = row_count;
  v_total := v_total + v_cont;

  -- student_groups
  with marcados as (
    update public.student_groups
       set moderation_status = 3, moderation_label = 'error', moderation_confidence = 0,
           moderation_reason = 'Servicio de moderación no disponible',
           moderated_at = now(), moderated_by = null
     where moderation_status = 0 and created_at < v_limite
    returning id
  )
  insert into public.moderation_audit_log
    (moderator_id, entity_table, entity_id, justification, is_automated, moderation_label, confidence)
  select null, 'student_groups', id, 'Servicio de moderación no disponible', true, 'error', 0 from marcados;
  get diagnostics v_cont = row_count;
  v_total := v_total + v_cont;

  -- marketplace_items
  with marcados as (
    update public.marketplace_items
       set moderation_status = 3, moderation_label = 'error', moderation_confidence = 0,
           moderation_reason = 'Servicio de moderación no disponible',
           moderated_at = now(), moderated_by = null
     where moderation_status = 0 and created_at < v_limite
    returning id
  )
  insert into public.moderation_audit_log
    (moderator_id, entity_table, entity_id, justification, is_automated, moderation_label, confidence)
  select null, 'marketplace_items', id, 'Servicio de moderación no disponible', true, 'error', 0 from marcados;
  get diagnostics v_cont = row_count;
  v_total := v_total + v_cont;

  -- seccion_reviews
  with marcados as (
    update public.seccion_reviews
       set moderation_status = 3, moderation_label = 'error', moderation_confidence = 0,
           moderation_reason = 'Servicio de moderación no disponible',
           moderated_at = now(), moderated_by = null
     where moderation_status = 0 and created_at < v_limite
    returning id
  )
  insert into public.moderation_audit_log
    (moderator_id, entity_table, entity_id, justification, is_automated, moderation_label, confidence)
  select null, 'seccion_reviews', id, 'Servicio de moderación no disponible', true, 'error', 0 from marcados;
  get diagnostics v_cont = row_count;
  v_total := v_total + v_cont;

  return v_total;
end;
$$;

revoke execute on function public.marcar_pendientes_error(integer) from public, anon, authenticated;
grant execute on function public.marcar_pendientes_error(integer) to service_role;

-- Cola de revisión humana del panel (incluye seccion_reviews)
create or replace function public.panel_cola_revision(p_umbral double precision default 0.75)
returns table (
  tabla text,
  item_id uuid,
  titulo text,
  moderation_status integer,
  moderation_label text,
  moderation_confidence double precision,
  moderation_reason text,
  created_at timestamptz,
  motivo_cola text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not (public.is_pemtree_admin(auth.uid()) or public.is_pemtree_moderator(auth.uid())) then
    raise exception 'Permiso denegado: solo administradores o moderadores pueden ver la cola de revisión.';
  end if;

  return query
  select q.tabla, q.item_id, q.titulo, q.moderation_status, q.moderation_label,
         q.moderation_confidence, q.moderation_reason, q.created_at, q.motivo_cola
  from (
    select 'posts'::text as tabla, p.id as item_id, p.title as titulo,
           p.moderation_status, p.moderation_label, p.moderation_confidence,
           p.moderation_reason, p.created_at, 'error'::text as motivo_cola, 0 as orden
      from public.posts p
     where p.moderation_status = 3
    union all
    select 'comments', c.id, left(c.content, 80),
           c.moderation_status, c.moderation_label, c.moderation_confidence,
           c.moderation_reason, c.created_at, 'error', 0
      from public.comments c
     where c.moderation_status = 3
    union all
    select 'student_groups', g.id, g.title,
           g.moderation_status, g.moderation_label, g.moderation_confidence,
           g.moderation_reason, g.created_at, 'error', 0
      from public.student_groups g
     where g.moderation_status = 3
    union all
    select 'marketplace_items', m.id, m.title,
           m.moderation_status, m.moderation_label, m.moderation_confidence,
           m.moderation_reason, m.created_at, 'error', 0
      from public.marketplace_items m
     where m.moderation_status = 3
    union all
    select 'seccion_reviews', r.id, coalesce(r.catedratico_nombre, 'Reseña') || ': ' || left(coalesce(r.comentario, ''), 60),
           r.moderation_status, r.moderation_label, r.moderation_confidence,
           r.moderation_reason, r.created_at, 'error', 0
      from public.seccion_reviews r
     where r.moderation_status = 3
    union all
    select 'posts', p.id, p.title,
           p.moderation_status, p.moderation_label, p.moderation_confidence,
           p.moderation_reason, p.created_at, 'baja_confianza', 1
      from public.posts p
     where p.moderation_status = 2 and coalesce(p.moderation_confidence, 0) < p_umbral
    union all
    select 'comments', c.id, left(c.content, 80),
           c.moderation_status, c.moderation_label, c.moderation_confidence,
           c.moderation_reason, c.created_at, 'baja_confianza', 1
      from public.comments c
     where c.moderation_status = 2 and coalesce(c.moderation_confidence, 0) < p_umbral
    union all
    select 'student_groups', g.id, g.title,
           g.moderation_status, g.moderation_label, g.moderation_confidence,
           g.moderation_reason, g.created_at, 'baja_confianza', 1
      from public.student_groups g
     where g.moderation_status = 2 and coalesce(g.moderation_confidence, 0) < p_umbral
    union all
    select 'marketplace_items', m.id, m.title,
           m.moderation_status, m.moderation_label, m.moderation_confidence,
           m.moderation_reason, m.created_at, 'baja_confianza', 1
      from public.marketplace_items m
     where m.moderation_status = 2 and coalesce(m.moderation_confidence, 0) < p_umbral
    union all
    select 'seccion_reviews', r.id, coalesce(r.catedratico_nombre, 'Reseña') || ': ' || left(coalesce(r.comentario, ''), 60),
           r.moderation_status, r.moderation_label, r.moderation_confidence,
           r.moderation_reason, r.created_at, 'baja_confianza', 1
      from public.seccion_reviews r
     where r.moderation_status = 2 and coalesce(r.moderation_confidence, 0) < p_umbral
  ) q
  order by q.orden, q.created_at desc;
end;
$$;

revoke execute on function public.panel_cola_revision(double precision) from public, anon;
grant execute on function public.panel_cola_revision(double precision) to authenticated, service_role;

-- Aprobar manualmente (incluye seccion_reviews)
create or replace function public.panel_aprobar(
  p_tabla text,
  p_id uuid,
  p_reason text default 'Aprobado por moderador'
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_reason text := coalesce(nullif(trim(p_reason), ''), 'Aprobado por moderador');
begin
  if v_uid is null then
    raise exception 'No estás autenticado en el sistema.';
  end if;
  if not (public.is_pemtree_admin(v_uid) or public.is_pemtree_moderator(v_uid)) then
    raise exception 'Permiso denegado: solo administradores o moderadores pueden aprobar contenido manualmente.';
  end if;

  if p_tabla = 'posts' then
    update public.posts
       set moderation_status = 1, moderation_label = 'appropriate',
           moderation_reason = v_reason, moderated_by = v_uid, moderated_at = now()
     where id = p_id;
  elsif p_tabla = 'comments' then
    update public.comments
       set moderation_status = 1, moderation_label = 'appropriate',
           moderation_reason = v_reason, moderated_by = v_uid, moderated_at = now()
     where id = p_id;
  elsif p_tabla = 'student_groups' then
    update public.student_groups
       set moderation_status = 1, moderation_label = 'appropriate',
           moderation_reason = v_reason, moderated_by = v_uid, moderated_at = now()
     where id = p_id;
  elsif p_tabla = 'marketplace_items' then
    update public.marketplace_items
       set moderation_status = 1, moderation_label = 'appropriate',
           moderation_reason = v_reason, moderated_by = v_uid, moderated_at = now()
     where id = p_id;
  elsif p_tabla = 'seccion_reviews' then
    update public.seccion_reviews
       set moderation_status = 1, moderation_label = 'appropriate',
           moderation_reason = v_reason, moderated_by = v_uid, moderated_at = now()
     where id = p_id;
  else
    raise exception 'Tabla (%) no válida para moderación manual.', p_tabla;
  end if;

  if not found then
    raise exception 'El registro ya no existe en la base de datos.';
  end if;

  perform public._cancelar_jobs_panel(p_tabla, p_id);

  insert into public.moderation_audit_log
      (moderator_id, entity_table, entity_id, justification, is_automated, moderation_label)
  values (v_uid, p_tabla, p_id, v_reason, false, 'appropriate');

  return true;
end;
$$;

revoke execute on function public.panel_aprobar(text, uuid, text) from public, anon;
grant execute on function public.panel_aprobar(text, uuid, text) to authenticated, service_role;

-- Rechazar manualmente (incluye seccion_reviews)
create or replace function public.panel_rechazar(
  p_tabla text,
  p_id uuid,
  p_reason text
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_reason text := nullif(trim(p_reason), '');
begin
  if v_uid is null then
    raise exception 'No estás autenticado en el sistema.';
  end if;
  if not (public.is_pemtree_admin(v_uid) or public.is_pemtree_moderator(v_uid)) then
    raise exception 'Permiso denegado: solo administradores o moderadores pueden rechazar contenido manualmente.';
  end if;
  if v_reason is null then
    raise exception 'Justificación obligatoria: debes indicar la razón del rechazo.';
  end if;

  if p_tabla = 'posts' then
    update public.posts
       set moderation_status = 2, moderation_label = 'inappropriate',
           moderation_reason = v_reason, moderated_by = v_uid, moderated_at = now()
     where id = p_id;
  elsif p_tabla = 'comments' then
    update public.comments
       set moderation_status = 2, moderation_label = 'inappropriate',
           moderation_reason = v_reason, moderated_by = v_uid, moderated_at = now()
     where id = p_id;
  elsif p_tabla = 'student_groups' then
    update public.student_groups
       set moderation_status = 2, moderation_label = 'inappropriate',
           moderation_reason = v_reason, moderated_by = v_uid, moderated_at = now()
     where id = p_id;
  elsif p_tabla = 'marketplace_items' then
    update public.marketplace_items
       set moderation_status = 2, moderation_label = 'inappropriate',
           moderation_reason = v_reason, moderated_by = v_uid, moderated_at = now()
     where id = p_id;
  elsif p_tabla = 'seccion_reviews' then
    update public.seccion_reviews
       set moderation_status = 2, moderation_label = 'inappropriate',
           moderation_reason = v_reason, moderated_by = v_uid, moderated_at = now()
     where id = p_id;
  else
    raise exception 'Tabla (%) no válida para moderación manual.', p_tabla;
  end if;

  if not found then
    raise exception 'El registro ya no existe en la base de datos.';
  end if;

  perform public._cancelar_jobs_panel(p_tabla, p_id);

  insert into public.moderation_audit_log
      (moderator_id, entity_table, entity_id, justification, is_automated, moderation_label)
  values (v_uid, p_tabla, p_id, v_reason, false, 'inappropriate');

  return true;
end;
$$;

revoke execute on function public.panel_rechazar(text, uuid, text) from public, anon;
grant execute on function public.panel_rechazar(text, uuid, text) to authenticated, service_role;

-- Re-moderar manualmente desde el panel (incluye seccion_reviews)
create or replace function public.panel_remoderar(p_tabla text, p_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_has_image boolean := false;
  v_job_id uuid;
begin
  if v_uid is null then
    raise exception 'No estás autenticado en el sistema.';
  end if;
  if not (public.is_pemtree_admin(v_uid) or public.is_pemtree_moderator(v_uid)) then
    raise exception 'Permiso denegado: solo administradores o moderadores pueden re-moderar contenido.';
  end if;

  if p_tabla = 'posts' then
    select (p.image_url is not null or p.gif_url is not null)
      into v_has_image
      from public.posts p where p.id = p_id;
  elsif p_tabla = 'comments' then
    select (c.gif_url is not null)
      into v_has_image
      from public.comments c where c.id = p_id;
  elsif p_tabla = 'student_groups' then
    select (g.image_url is not null)
      into v_has_image
      from public.student_groups g where g.id = p_id;
  elsif p_tabla = 'marketplace_items' then
    select (coalesce(array_length(m.image_urls, 1), 0) >= 1)
      into v_has_image
      from public.marketplace_items m where m.id = p_id;
  elsif p_tabla = 'seccion_reviews' then
    perform 1 from public.seccion_reviews where id = p_id;
    v_has_image := false;
  else
    raise exception 'Tabla (%) no válida para re-moderación.', p_tabla;
  end if;

  if not found then
    raise exception 'El registro ya no existe en la base de datos.';
  end if;

  perform public._cancelar_jobs_panel(p_tabla, p_id);

  insert into public.moderation_jobs(entity_table, entity_id, content_hash, priority, has_image)
  values (p_tabla, p_id, 'manual:' || gen_random_uuid()::text, 5, coalesce(v_has_image, false))
  returning id into v_job_id;

  insert into public.moderation_audit_log
      (moderator_id, entity_table, entity_id, justification, is_automated, moderation_label)
  values (v_uid, p_tabla, p_id, 'Re-moderación manual solicitada desde el panel', false, null);

  return v_job_id;
end;
$$;

revoke execute on function public.panel_remoderar(text, uuid) from public, anon;
grant execute on function public.panel_remoderar(text, uuid) to authenticated, service_role;

-- Estadísticas de la cola de moderación para el panel
create or replace function public.admin_moderation_queue_stats()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_stats jsonb;
begin
  if v_uid is null then
    raise exception 'No autenticado' using errcode = '42501';
  end if;
  if not (public.is_pemtree_admin(v_uid) or public.is_pemtree_moderator(v_uid)) then
    raise exception 'Permiso denegado: solo administradores o moderadores pueden ver estadísticas de la cola'
      using errcode = '42501';
  end if;

  select jsonb_build_object(
    'pending', coalesce(count(*) filter (where status = 'pending'), 0),
    'processing', coalesce(count(*) filter (where status = 'processing'), 0),
    'failed', coalesce(count(*) filter (where status = 'failed'), 0),
    'done', coalesce(count(*) filter (where status = 'done'), 0),
    'oldest_pending_at', min(created_at) filter (where status = 'pending'),
    'last_done_at', max(updated_at) filter (where status = 'done'),
    'last_failed_at', max(updated_at) filter (where status = 'failed')
  ) into v_stats
  from public.moderation_jobs;

  return v_stats;
end;
$$;

revoke execute on function public.admin_moderation_queue_stats() from public, anon;
grant execute on function public.admin_moderation_queue_stats() to authenticated, service_role;

-- Reintentar masivamente trabajos fallidos
create or replace function public.admin_retry_failed_moderation_jobs()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_retried integer := 0;
begin
  if v_uid is null then
    raise exception 'No autenticado' using errcode = '42501';
  end if;
  if not public.is_pemtree_admin(v_uid) then
    raise exception 'Permiso denegado: solo administradores pueden reintentar trabajos fallidos'
      using errcode = '42501';
  end if;

  update public.moderation_jobs
     set status     = 'pending',
         attempts   = 0,
         run_after  = now(),
         last_error = null,
         updated_at = now()
   where status = 'failed';
  get diagnostics v_retried = row_count;

  if v_retried > 0 then
    insert into public.moderation_audit_log (
      moderator_id,
      entity_table,
      entity_id,
      justification,
      is_automated,
      moderation_label
    ) values (
      v_uid,
      'moderation_jobs',
      gen_random_uuid(),
      'Reintento administrativo masivo de ' || v_retried || ' trabajos fallidos',
      false,
      'queue_retry'
    );
  end if;

  return v_retried;
end;
$$;

revoke execute on function public.admin_retry_failed_moderation_jobs() from public, anon;
grant execute on function public.admin_retry_failed_moderation_jobs() to authenticated, service_role;

-- Consulta de errores recientes de trabajos en cola
create or replace function public.admin_moderation_job_errors(p_limit integer default 20)
returns table (
  id uuid,
  entity_table text,
  entity_id uuid,
  attempts integer,
  last_error text,
  updated_at timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'No autenticado' using errcode = '42501';
  end if;
  if not (public.is_pemtree_admin(v_uid) or public.is_pemtree_moderator(v_uid)) then
    raise exception 'Permiso denegado: solo administradores o moderadores pueden ver errores de moderación'
      using errcode = '42501';
  end if;

  return query
  select j.id, j.entity_table, j.entity_id, j.attempts, j.last_error, j.updated_at
    from public.moderation_jobs j
   where j.status = 'failed'
   order by j.updated_at desc
   limit coalesce(p_limit, 20);
end;
$$;

revoke execute on function public.admin_moderation_job_errors(integer) from public, anon;
grant execute on function public.admin_moderation_job_errors(integer) to authenticated, service_role;
