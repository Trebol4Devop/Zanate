-- =============================================================================
-- Migración: 20261127171305_audit_security_hardening.sql
-- Propósito: Endurecimiento de seguridad, corrección de RLS para anon,
--            desbloqueo de reporte agrupado para staff y limpieza de deuda SQL.
-- Compatibilidad: 100% retrocompatible con Zanate (Flutter) y Zanate Admin.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1) Triggers de protección de moderación en campus_reviews y campus_comments
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.guard_campus_review_moderation_fields()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
    v_uid  uuid := auth.uid();
    v_role text := current_setting('role', true);
    v_jwt  jsonb := NULLIF(current_setting('request.jwt.claims', true), '')::jsonb;
BEGIN
    IF pg_trigger_depth() > 1
       OR v_uid IS NULL
       OR v_role IN ('postgres', 'service_role', 'supabase_admin')
       OR (v_jwt IS NOT NULL AND (v_jwt ->> 'role') = 'service_role')
       OR public.is_pemtree_admin(v_uid)
       OR public.is_pemtree_moderator(v_uid) THEN
        RETURN NEW;
    END IF;

    IF TG_OP = 'INSERT' THEN
        NEW.user_id := v_uid;
        NEW.moderation_status := 1;
        NEW.moderation_reason := NULL;
        NEW.likes_count := 0;
        RETURN NEW;
    END IF;

    IF NEW.id IS DISTINCT FROM OLD.id
       OR NEW.user_id IS DISTINCT FROM OLD.user_id
       OR NEW.created_at IS DISTINCT FROM OLD.created_at
       OR NEW.likes_count IS DISTINCT FROM OLD.likes_count
       OR NEW.moderation_status IS DISTINCT FROM OLD.moderation_status
       OR NEW.moderation_reason IS DISTINCT FROM OLD.moderation_reason THEN
        RAISE EXCEPTION 'Permiso denegado: no puedes modificar campos de autoría, métricas o moderación de la reseña.'
            USING ERRCODE = '42501';
    END IF;

    RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_guard_campus_reviews_moderation ON public.campus_reviews;
CREATE TRIGGER trg_guard_campus_reviews_moderation
    BEFORE INSERT OR UPDATE ON public.campus_reviews
    FOR EACH ROW EXECUTE FUNCTION public.guard_campus_review_moderation_fields();

CREATE OR REPLACE FUNCTION public.guard_campus_comment_moderation_fields()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
    v_uid  uuid := auth.uid();
    v_role text := current_setting('role', true);
    v_jwt  jsonb := NULLIF(current_setting('request.jwt.claims', true), '')::jsonb;
BEGIN
    IF pg_trigger_depth() > 1
       OR v_uid IS NULL
       OR v_role IN ('postgres', 'service_role', 'supabase_admin')
       OR (v_jwt IS NOT NULL AND (v_jwt ->> 'role') = 'service_role')
       OR public.is_pemtree_admin(v_uid)
       OR public.is_pemtree_moderator(v_uid) THEN
        RETURN NEW;
    END IF;

    IF TG_OP = 'INSERT' THEN
        NEW.user_id := v_uid;
        NEW.moderation_status := 1;
        NEW.likes_count := 0;
        NEW.deleted_at := NULL;
        RETURN NEW;
    END IF;

    IF NEW.id IS DISTINCT FROM OLD.id
       OR NEW.user_id IS DISTINCT FROM OLD.user_id
       OR NEW.target_id IS DISTINCT FROM OLD.target_id
       OR NEW.parent_id IS DISTINCT FROM OLD.parent_id
       OR NEW.created_at IS DISTINCT FROM OLD.created_at
       OR NEW.likes_count IS DISTINCT FROM OLD.likes_count
       OR NEW.moderation_status IS DISTINCT FROM OLD.moderation_status THEN
        RAISE EXCEPTION 'Permiso denegado: no puedes modificar campos de autoría, métricas o moderación del comentario.'
            USING ERRCODE = '42501';
    END IF;

    RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_guard_campus_comments_moderation ON public.campus_comments;
CREATE TRIGGER trg_guard_campus_comments_moderation
    BEFORE INSERT OR UPDATE ON public.campus_comments
    FOR EACH ROW EXECUTE FUNCTION public.guard_campus_comment_moderation_fields();

-- -----------------------------------------------------------------------------
-- 2) Políticas RLS separadas para anon vs authenticated + (SELECT auth.uid())
-- -----------------------------------------------------------------------------

-- 2.1 marketplace_plans
DROP POLICY IF EXISTS "Lectura pública de planes activos" ON public.marketplace_plans;
DROP POLICY IF EXISTS "Administración de planes por staff" ON public.marketplace_plans;
DROP POLICY IF EXISTS "Lectura pública de planes activos (anon)" ON public.marketplace_plans;
DROP POLICY IF EXISTS "Lectura pública de planes activos (auth)" ON public.marketplace_plans;
DROP POLICY IF EXISTS "Admins insert marketplace_plans" ON public.marketplace_plans;
DROP POLICY IF EXISTS "Admins update marketplace_plans" ON public.marketplace_plans;
DROP POLICY IF EXISTS "Admins delete marketplace_plans" ON public.marketplace_plans;

CREATE POLICY "Lectura pública de planes activos (anon)"
    ON public.marketplace_plans
    FOR SELECT
    TO anon
    USING (is_active = true);

CREATE POLICY "Lectura pública de planes activos (auth)"
    ON public.marketplace_plans
    FOR SELECT
    TO authenticated
    USING (
        (is_active = true)
        OR public.is_pemtree_admin((SELECT auth.uid()))
        OR public.is_pemtree_moderator((SELECT auth.uid()))
    );

CREATE POLICY "Admins insert marketplace_plans"
    ON public.marketplace_plans
    FOR INSERT
    TO authenticated
    WITH CHECK (public.is_pemtree_admin((SELECT auth.uid())));

CREATE POLICY "Admins update marketplace_plans"
    ON public.marketplace_plans
    FOR UPDATE
    TO authenticated
    USING (public.is_pemtree_admin((SELECT auth.uid())))
    WITH CHECK (public.is_pemtree_admin((SELECT auth.uid())));

CREATE POLICY "Admins delete marketplace_plans"
    ON public.marketplace_plans
    FOR DELETE
    TO authenticated
    USING (public.is_pemtree_admin((SELECT auth.uid())));

-- 2.2 campus_reviews
DROP POLICY IF EXISTS "Read approved reviews" ON public.campus_reviews;
DROP POLICY IF EXISTS "Read approved reviews (anon)" ON public.campus_reviews;
DROP POLICY IF EXISTS "Read approved reviews (auth)" ON public.campus_reviews;
DROP POLICY IF EXISTS "Insert own review" ON public.campus_reviews;
DROP POLICY IF EXISTS "Update own review or admin" ON public.campus_reviews;
DROP POLICY IF EXISTS "Delete own review or admin" ON public.campus_reviews;

CREATE POLICY "Read approved reviews (anon)"
    ON public.campus_reviews
    FOR SELECT
    TO anon
    USING (moderation_status = 1);

CREATE POLICY "Read approved reviews (auth)"
    ON public.campus_reviews
    FOR SELECT
    TO authenticated
    USING (
        (moderation_status = 1)
        OR ((SELECT auth.uid()) = user_id)
        OR public.is_pemtree_moderator((SELECT auth.uid()))
        OR public.is_pemtree_admin((SELECT auth.uid()))
    );

CREATE POLICY "Insert own review"
    ON public.campus_reviews
    FOR INSERT
    TO authenticated
    WITH CHECK ((SELECT auth.uid()) = user_id);

CREATE POLICY "Update own review or admin"
    ON public.campus_reviews
    FOR UPDATE
    TO authenticated
    USING (((SELECT auth.uid()) = user_id) OR public.is_pemtree_admin((SELECT auth.uid())))
    WITH CHECK (((SELECT auth.uid()) = user_id) OR public.is_pemtree_admin((SELECT auth.uid())));

CREATE POLICY "Delete own review or admin"
    ON public.campus_reviews
    FOR DELETE
    TO authenticated
    USING (((SELECT auth.uid()) = user_id) OR public.is_pemtree_admin((SELECT auth.uid())));

-- 2.3 campus_comments
DROP POLICY IF EXISTS "Campus comments public read" ON public.campus_comments;
DROP POLICY IF EXISTS "Campus comments public read (anon)" ON public.campus_comments;
DROP POLICY IF EXISTS "Campus comments public read (auth)" ON public.campus_comments;

CREATE POLICY "Campus comments public read (anon)"
    ON public.campus_comments
    FOR SELECT
    TO anon
    USING ((deleted_at IS NULL) AND (moderation_status = 1));

CREATE POLICY "Campus comments public read (auth)"
    ON public.campus_comments
    FOR SELECT
    TO authenticated
    USING (
        ((deleted_at IS NULL) AND (moderation_status = 1))
        OR ((SELECT auth.uid()) = user_id)
        OR public.is_pemtree_moderator((SELECT auth.uid()))
        OR public.is_pemtree_admin((SELECT auth.uid()))
    );

-- -----------------------------------------------------------------------------
-- 3) Endurecer post_polls y post_poll_options usando is_my_post()
-- -----------------------------------------------------------------------------
DROP POLICY IF EXISTS "Crear encuestas autenticados" ON public.post_polls;
CREATE POLICY "Crear encuestas autenticados"
    ON public.post_polls
    FOR INSERT
    TO authenticated
    WITH CHECK (
        public.is_my_post(post_id)
        OR public.is_pemtree_admin((SELECT auth.uid()))
    );

DROP POLICY IF EXISTS "Crear opciones autenticados" ON public.post_poll_options;
CREATE POLICY "Crear opciones autenticados"
    ON public.post_poll_options
    FOR INSERT
    TO authenticated
    WITH CHECK (
        EXISTS (
            SELECT 1
            FROM public.post_polls pl
            WHERE pl.id = poll_id
              AND (
                  public.is_my_post(pl.post_id)
                  OR public.is_pemtree_admin((SELECT auth.uid()))
              )
        )
    );

-- -----------------------------------------------------------------------------
-- 4) Reportes agrupados: RPC segura para staff + vista v_grouped_entity_reports sin 42501
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_list_grouped_entity_reports(
    p_entity_type text DEFAULT NULL,
    p_status text DEFAULT NULL
)
RETURNS TABLE(
    entity_type text,
    entity_id uuid,
    total_reports bigint,
    pending_reports bigint,
    weighted_score numeric,
    reasons_summary jsonb,
    latest_report_at timestamptz,
    reported_user_id uuid,
    entity_snapshot jsonb
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
    v_uid    uuid := auth.uid();
    v_type   text := NULLIF(btrim(COALESCE(p_entity_type, '')), '');
    v_status text := NULLIF(lower(btrim(COALESCE(p_status, ''))), '');
BEGIN
    IF v_uid IS NULL OR NOT (public.is_pemtree_admin(v_uid) OR public.is_pemtree_moderator(v_uid)) THEN
        RAISE EXCEPTION 'Permiso denegado: se requiere rol de moderador o administrador'
            USING ERRCODE = '42501';
    END IF;

    IF v_type = 'all' THEN v_type := NULL; END IF;
    IF v_status = 'all' THEN v_status := NULL; END IF;

    RETURN QUERY
    WITH report_summary AS (
        SELECT
            er.entity_type,
            er.entity_id,
            count(*)::bigint AS total_reports,
            count(*) FILTER (WHERE er.moderation_status = 0)::bigint AS pending_reports,
            COALESCE(
                sum(CASE WHEN p.is_verified = true THEN 1.5 ELSE 0.5 END)
                FILTER (WHERE er.moderation_status = 0),
                0::numeric
            ) AS weighted_score,
            max(er.created_at) AS latest_report_at,
            (array_agg(COALESCE(er.reported_user_id, er.entity_owner_id) ORDER BY er.created_at DESC)
                FILTER (WHERE COALESCE(er.reported_user_id, er.entity_owner_id) IS NOT NULL))[1] AS reported_user_id
        FROM public.entity_reports er
        LEFT JOIN public.profiles p ON p.id = er.reporter_id
        WHERE (v_type IS NULL OR er.entity_type = v_type)
        GROUP BY er.entity_type, er.entity_id
    ),
    reason_counts AS (
        SELECT
            er.entity_type,
            er.entity_id,
            COALESCE(NULLIF(btrim(er.reason), ''), 'sin_motivo') AS r_reason,
            count(*) AS r_cnt
        FROM public.entity_reports er
        WHERE (v_type IS NULL OR er.entity_type = v_type)
        GROUP BY er.entity_type, er.entity_id, COALESCE(NULLIF(btrim(er.reason), ''), 'sin_motivo')
    ),
    reason_summary AS (
        SELECT
            rc.entity_type,
            rc.entity_id,
            jsonb_object_agg(rc.r_reason, rc.r_cnt) AS reasons_summary
        FROM reason_counts rc
        GROUP BY rc.entity_type, rc.entity_id
    )
    SELECT
        rs.entity_type,
        rs.entity_id,
        rs.total_reports,
        rs.pending_reports,
        rs.weighted_score,
        COALESCE(rea.reasons_summary, '{}'::jsonb) AS reasons_summary,
        rs.latest_report_at,
        COALESCE(
            rs.reported_user_id,
            CASE rs.entity_type
                WHEN 'post' THEN po.user_id
                WHEN 'comment' THEN co.user_id
                WHEN 'group' THEN sg.user_id
                WHEN 'student_group' THEN sg.user_id
                WHEN 'marketplace_item' THEN mi.user_id
                WHEN 'seccion_review' THEN sr.user_id
                WHEN 'user' THEN rs.entity_id
                ELSE NULL::uuid
            END
        ) AS reported_user_id,
        CASE rs.entity_type
            WHEN 'post' THEN jsonb_build_object(
                'title', po.title, 'content', po.content, 'author_alias', po.author_alias,
                'user_id', po.user_id, 'moderation_status', po.moderation_status,
                'is_legal_hold', po.is_legal_hold, 'category', po.category, 'image_url', po.image_url
            )
            WHEN 'comment' THEN jsonb_build_object(
                'title', NULL::text, 'content', co.content, 'author_alias', co.author_alias,
                'user_id', co.user_id, 'moderation_status', co.moderation_status,
                'is_legal_hold', co.is_legal_hold, 'category', NULL::text, 'image_url', NULL::text
            )
            WHEN 'group' THEN jsonb_build_object(
                'title', sg.title, 'content', sg.description, 'author_alias', sg.author_alias,
                'user_id', sg.user_id, 'moderation_status', sg.moderation_status,
                'is_legal_hold', sg.is_legal_hold, 'category', sg.curso, 'image_url', sg.image_url
            )
            WHEN 'student_group' THEN jsonb_build_object(
                'title', sg.title, 'content', sg.description, 'author_alias', sg.author_alias,
                'user_id', sg.user_id, 'moderation_status', sg.moderation_status,
                'is_legal_hold', sg.is_legal_hold, 'category', sg.curso, 'image_url', sg.image_url
            )
            WHEN 'marketplace_item' THEN jsonb_build_object(
                'title', mi.title, 'content', mi.description, 'author_alias', mi.author_alias,
                'user_id', mi.user_id, 'moderation_status', mi.moderation_status,
                'is_legal_hold', mi.is_legal_hold, 'category', mi.category,
                'image_url', CASE WHEN array_length(mi.image_urls, 1) >= 1 THEN mi.image_urls[1] ELSE NULL::text END
            )
            WHEN 'seccion_review' THEN jsonb_build_object(
                'title', sr.catedratico_nombre, 'content', sr.comentario, 'author_alias', NULL::text,
                'user_id', sr.user_id, 'moderation_status', sr.moderation_status,
                'is_legal_hold', sr.is_legal_hold, 'category', sr.curso_codigo, 'image_url', NULL::text
            )
            WHEN 'user' THEN jsonb_build_object(
                'title', NULL::text, 'content', NULL::text, 'author_alias', NULL::text,
                'user_id', rs.entity_id, 'moderation_status', NULL::integer,
                'is_legal_hold', NULL::boolean, 'category', NULL::text, 'image_url', NULL::text
            )
            ELSE jsonb_build_object(
                'title', NULL::text, 'content', NULL::text, 'author_alias', NULL::text,
                'user_id', NULL::uuid, 'moderation_status', NULL::integer,
                'is_legal_hold', NULL::boolean, 'category', NULL::text, 'image_url', NULL::text
            )
        END AS entity_snapshot
    FROM report_summary rs
    LEFT JOIN reason_summary rea ON rea.entity_type = rs.entity_type AND rea.entity_id = rs.entity_id
    LEFT JOIN public.posts po ON rs.entity_type = 'post' AND po.id = rs.entity_id
    LEFT JOIN public.comments co ON rs.entity_type = 'comment' AND co.id = rs.entity_id
    LEFT JOIN public.student_groups sg ON rs.entity_type = ANY (ARRAY['group', 'student_group']) AND sg.id = rs.entity_id
    LEFT JOIN public.marketplace_items mi ON rs.entity_type = 'marketplace_item' AND mi.id = rs.entity_id
    LEFT JOIN public.seccion_reviews sr ON rs.entity_type = 'seccion_review' AND sr.id = rs.entity_id
    WHERE (
        v_status IS NULL
        OR (v_status IN ('0', 'pending') AND rs.pending_reports > 0)
        OR (v_status IN ('resolved', '1', '2') AND rs.pending_reports = 0)
    )
    ORDER BY rs.pending_reports DESC, rs.latest_report_at DESC;
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_list_grouped_entity_reports(text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_list_grouped_entity_reports(text, text) TO authenticated;

CREATE OR REPLACE VIEW public.v_grouped_entity_reports
WITH (security_invoker = true) AS
WITH report_summary AS (
    SELECT er.entity_type,
        er.entity_id,
        count(*) AS total_reports,
        count(*) FILTER (WHERE er.moderation_status = 0) AS pending_reports,
        COALESCE(sum(
            CASE
                WHEN p.is_verified = true THEN 1.5
                ELSE 0.5
            END) FILTER (WHERE er.moderation_status = 0), 0::numeric) AS weighted_score,
        max(er.created_at) AS latest_report_at,
        (array_agg(COALESCE(er.reported_user_id, er.entity_owner_id) ORDER BY er.created_at DESC)
            FILTER (WHERE COALESCE(er.reported_user_id, er.entity_owner_id) IS NOT NULL))[1] AS reported_user_id
    FROM public.entity_reports er
    LEFT JOIN public.profiles p ON p.id = er.reporter_id
    GROUP BY er.entity_type, er.entity_id
), reason_counts AS (
    SELECT entity_reports.entity_type,
        entity_reports.entity_id,
        COALESCE(NULLIF(TRIM(BOTH FROM entity_reports.reason), ''::text), 'sin_motivo'::text) AS r_reason,
        count(*) AS r_cnt
    FROM public.entity_reports
    GROUP BY entity_reports.entity_type, entity_reports.entity_id, (COALESCE(NULLIF(TRIM(BOTH FROM entity_reports.reason), ''::text), 'sin_motivo'::text))
), reason_summary AS (
    SELECT reason_counts.entity_type,
        reason_counts.entity_id,
        jsonb_object_agg(reason_counts.r_reason, reason_counts.r_cnt) AS reasons_summary
    FROM reason_counts
    GROUP BY reason_counts.entity_type, reason_counts.entity_id
)
SELECT rs.entity_type,
    rs.entity_id,
    rs.total_reports,
    rs.pending_reports,
    rs.weighted_score,
    COALESCE(rea.reasons_summary, '{}'::jsonb) AS reasons_summary,
    rs.latest_report_at,
    COALESCE(rs.reported_user_id,
        CASE rs.entity_type
            WHEN 'seccion_review'::text THEN sr.user_id
            WHEN 'user'::text THEN rs.entity_id
            ELSE NULL::uuid
        END) AS reported_user_id,
    CASE rs.entity_type
        WHEN 'post'::text THEN jsonb_build_object('title', po.title, 'content', po.content, 'author_alias', po.author_alias, 'user_id', rs.reported_user_id, 'moderation_status', po.moderation_status, 'is_legal_hold', po.is_legal_hold, 'category', po.category, 'image_url', po.image_url)
        WHEN 'comment'::text THEN jsonb_build_object('title', NULL::unknown, 'content', co.content, 'author_alias', co.author_alias, 'user_id', rs.reported_user_id, 'moderation_status', co.moderation_status, 'is_legal_hold', co.is_legal_hold, 'category', NULL::unknown, 'image_url', NULL::unknown)
        WHEN 'group'::text THEN jsonb_build_object('title', sg.title, 'content', sg.description, 'author_alias', sg.author_alias, 'user_id', rs.reported_user_id, 'moderation_status', sg.moderation_status, 'is_legal_hold', sg.is_legal_hold, 'category', sg.curso, 'image_url', sg.image_url)
        WHEN 'student_group'::text THEN jsonb_build_object('title', sg.title, 'content', sg.description, 'author_alias', sg.author_alias, 'user_id', rs.reported_user_id, 'moderation_status', sg.moderation_status, 'is_legal_hold', sg.is_legal_hold, 'category', sg.curso, 'image_url', sg.image_url)
        WHEN 'marketplace_item'::text THEN jsonb_build_object('title', mi.title, 'content', mi.description, 'author_alias', mi.author_alias, 'user_id', rs.reported_user_id, 'moderation_status', mi.moderation_status, 'is_legal_hold', mi.is_legal_hold, 'category', mi.category, 'image_url',
        CASE
            WHEN array_length(mi.image_urls, 1) >= 1 THEN mi.image_urls[1]
            ELSE NULL::text
        END)
        WHEN 'seccion_review'::text THEN jsonb_build_object('title', sr.catedratico_nombre, 'content', sr.comentario, 'author_alias', NULL::unknown, 'user_id', COALESCE(rs.reported_user_id, sr.user_id), 'moderation_status', sr.moderation_status, 'is_legal_hold', sr.is_legal_hold, 'category', sr.curso_codigo, 'image_url', NULL::unknown)
        WHEN 'user'::text THEN jsonb_build_object('title', NULL::unknown, 'content', NULL::unknown, 'author_alias', NULL::unknown, 'user_id', rs.entity_id, 'moderation_status', NULL::unknown, 'is_legal_hold', NULL::unknown, 'category', NULL::unknown, 'image_url', NULL::unknown)
        ELSE jsonb_build_object('title', NULL::unknown, 'content', NULL::unknown, 'author_alias', NULL::unknown, 'user_id', NULL::unknown, 'moderation_status', NULL::unknown, 'is_legal_hold', NULL::unknown, 'category', NULL::unknown, 'image_url', NULL::unknown)
    END AS entity_snapshot
FROM report_summary rs
LEFT JOIN reason_summary rea ON rea.entity_type = rs.entity_type AND rea.entity_id = rs.entity_id
LEFT JOIN public.posts po ON rs.entity_type = 'post'::text AND po.id = rs.entity_id
LEFT JOIN public.comments co ON rs.entity_type = 'comment'::text AND co.id = rs.entity_id
LEFT JOIN public.student_groups sg ON (rs.entity_type = ANY (ARRAY['group'::text, 'student_group'::text])) AND sg.id = rs.entity_id
LEFT JOIN public.marketplace_items mi ON rs.entity_type = 'marketplace_item'::text AND mi.id = rs.entity_id
LEFT JOIN public.seccion_reviews sr ON rs.entity_type = 'seccion_review'::text AND sr.id = rs.entity_id;

-- -----------------------------------------------------------------------------
-- 5) Hardening de funciones administrativas y SECURITY DEFINER
-- -----------------------------------------------------------------------------

-- 5.1 Eliminar UUID hardcodeado en is_pemtree_admin asegurando su fila en user_roles
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM auth.users WHERE id = '10884922-e583-409e-b3e8-8a875ddaa5d9') THEN
        INSERT INTO public.user_roles (user_id, role)
        VALUES ('10884922-e583-409e-b3e8-8a875ddaa5d9', 'admin')
        ON CONFLICT (user_id) DO UPDATE SET role = 'admin';
    END IF;
END $$;

CREATE OR REPLACE FUNCTION public.is_pemtree_admin(p_user_id uuid DEFAULT auth.uid())
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
BEGIN
    IF p_user_id IS NULL THEN
        RETURN false;
    END IF;
    RETURN EXISTS (
        SELECT 1
        FROM public.user_roles
        WHERE user_id = p_user_id
          AND role = 'admin'
    );
END;
$function$;

-- 5.2 Comparación NULL-safe en ocultar_contenido_moderado + uso de tabla canónica student_groups
CREATE OR REPLACE FUNCTION public.ocultar_contenido_moderado(
    p_tabla text,
    p_item_id uuid,
    p_justificacion text DEFAULT NULL::text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
    v_user_id       uuid := auth.uid();
    v_owner_id      uuid;
    v_is_admin      boolean := public.is_pemtree_admin(v_user_id);
    v_is_mod        boolean := public.is_pemtree_moderator(v_user_id);
    v_justificacion text;
    v_canonical     text;
BEGIN
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'No estás autenticado en el sistema.' USING ERRCODE = '42501';
    END IF;

    v_canonical := CASE WHEN p_tabla = 'whatsapp_groups' THEN 'student_groups' ELSE p_tabla END;

    IF v_canonical = 'student_groups' THEN
        SELECT user_id INTO v_owner_id FROM public.student_groups WHERE id = p_item_id;
    ELSIF v_canonical = 'posts' THEN
        SELECT user_id INTO v_owner_id FROM public.posts WHERE id = p_item_id;
    ELSIF v_canonical = 'comments' THEN
        SELECT user_id INTO v_owner_id FROM public.comments WHERE id = p_item_id;
    ELSIF v_canonical = 'marketplace_items' THEN
        SELECT user_id INTO v_owner_id FROM public.marketplace_items WHERE id = p_item_id;
    ELSIF v_canonical = 'seccion_reviews' THEN
        SELECT user_id INTO v_owner_id FROM public.seccion_reviews WHERE id = p_item_id;
    ELSE
        RAISE EXCEPTION 'Tabla (%) no válida para moderación.', p_tabla USING ERRCODE = '22023';
    END IF;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El registro ya no existe o fue eliminado previamente en la base de datos.' USING ERRCODE = 'P0002';
    END IF;

    IF v_owner_id IS DISTINCT FROM v_user_id AND NOT v_is_admin AND NOT v_is_mod THEN
        RAISE EXCEPTION 'Permiso denegado: No tienes autorización para ocultar este contenido.' USING ERRCODE = '42501';
    END IF;

    IF v_owner_id IS DISTINCT FROM v_user_id AND NOT v_is_admin THEN
        IF p_justificacion IS NULL OR trim(p_justificacion) = '' THEN
            RAISE EXCEPTION 'Justificación obligatoria: Como moderador, debes ingresar la razón por la cual ocultas este contenido.' USING ERRCODE = 'P0001';
        END IF;
        v_justificacion := trim(p_justificacion);
    ELSE
        v_justificacion := COALESCE(NULLIF(trim(p_justificacion), ''), 'Ocultado por el autor o administrador');
    END IF;

    INSERT INTO public.moderation_audit_log (
        moderator_id, entity_table, entity_id, justification, is_automated, moderation_label
    ) VALUES (
        v_user_id, p_tabla, p_item_id, v_justificacion, false, 'inappropriate'
    );

    IF v_canonical = 'student_groups' THEN
        UPDATE public.student_groups
           SET moderation_status = 2, moderation_label = 'inappropriate', moderation_reason = v_justificacion,
               moderated_by = v_user_id, moderated_at = now()
         WHERE id = p_item_id;
    ELSIF v_canonical = 'posts' THEN
        UPDATE public.posts
           SET moderation_status = 2, moderation_label = 'inappropriate', moderation_reason = v_justificacion,
               moderated_by = v_user_id, moderated_at = now()
         WHERE id = p_item_id;
    ELSIF v_canonical = 'comments' THEN
        UPDATE public.comments
           SET moderation_status = 2, moderation_label = 'inappropriate', moderation_reason = v_justificacion,
               moderated_by = v_user_id, moderated_at = now()
         WHERE id = p_item_id;
    ELSIF v_canonical = 'marketplace_items' THEN
        UPDATE public.marketplace_items
           SET moderation_status = 2, moderation_label = 'inappropriate', moderation_reason = v_justificacion,
               moderated_by = v_user_id, moderated_at = now()
         WHERE id = p_item_id;
    ELSIF v_canonical = 'seccion_reviews' THEN
        UPDATE public.seccion_reviews
           SET moderation_status = 2, moderation_label = 'inappropriate', moderation_reason = v_justificacion,
               moderated_by = v_user_id, moderated_at = now()
         WHERE id = p_item_id;
    END IF;

    PERFORM public._cancelar_jobs_panel(p_tabla, p_item_id);

    RETURN true;
END;
$function$;

-- 5.3 eliminar_contenido_moderado: añade seccion_reviews y usa student_groups
CREATE OR REPLACE FUNCTION public.eliminar_contenido_moderado(
    p_tabla text,
    p_item_id uuid,
    p_justificacion text DEFAULT NULL::text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
    v_user_id   uuid := auth.uid();
    v_owner_id  uuid;
    v_canonical text;
BEGIN
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'No estás autenticado en el sistema.' USING ERRCODE = '42501';
    END IF;

    IF NOT public.is_pemtree_admin(v_user_id) THEN
        RAISE EXCEPTION 'Permiso denegado: Solo el administrador de PEMTREE puede eliminar contenido de forma definitiva.'
            USING ERRCODE = '42501';
    END IF;

    IF p_tabla = 'comments' THEN
        PERFORM public.admin_hard_delete_comment(
            p_item_id,
            COALESCE(NULLIF(trim(p_justificacion), ''), 'Eliminación definitiva por administrador')
        );
        RETURN true;
    END IF;

    v_canonical := CASE WHEN p_tabla = 'whatsapp_groups' THEN 'student_groups' ELSE p_tabla END;

    IF v_canonical = 'student_groups' THEN
        SELECT user_id INTO v_owner_id FROM public.student_groups WHERE id = p_item_id;
    ELSIF v_canonical = 'posts' THEN
        SELECT user_id INTO v_owner_id FROM public.posts WHERE id = p_item_id;
    ELSIF v_canonical = 'marketplace_items' THEN
        SELECT user_id INTO v_owner_id FROM public.marketplace_items WHERE id = p_item_id;
    ELSIF v_canonical = 'seccion_reviews' THEN
        SELECT user_id INTO v_owner_id FROM public.seccion_reviews WHERE id = p_item_id;
    ELSE
        RAISE EXCEPTION 'Tabla (%) no válida para moderación.', p_tabla USING ERRCODE = '22023';
    END IF;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El registro ya no existe o fue eliminado previamente en la base de datos.' USING ERRCODE = 'P0002';
    END IF;

    INSERT INTO public.moderation_audit_log (
        moderator_id, entity_table, entity_id, justification, is_automated, moderation_label
    ) VALUES (
        v_user_id,
        p_tabla,
        p_item_id,
        COALESCE(NULLIF(trim(p_justificacion), ''), 'Eliminación definitiva por administrador'),
        false,
        'deleted'
    );

    IF v_canonical = 'student_groups' THEN
        DELETE FROM public.student_groups WHERE id = p_item_id;
    ELSIF v_canonical = 'posts' THEN
        DELETE FROM public.posts WHERE id = p_item_id;
    ELSIF v_canonical = 'marketplace_items' THEN
        DELETE FROM public.marketplace_items WHERE id = p_item_id;
    ELSIF v_canonical = 'seccion_reviews' THEN
        DELETE FROM public.seccion_reviews WHERE id = p_item_id;
    END IF;

    RETURN true;
END;
$function$;

-- 5.4 Purgas administrativas respetando is_legal_hold en student_groups
CREATE OR REPLACE FUNCTION public.purge_inappropriate_content()
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
    v_user_id  uuid := auth.uid();
    v_posts    integer := 0;
    v_comments integer := 0;
    v_groups   integer := 0;
    v_ureports integer := 0;
    v_greports integer := 0;
BEGIN
    IF NOT public.is_pemtree_admin(v_user_id) THEN
        RAISE EXCEPTION 'Permiso denegado: solo los administradores pueden ejecutar esta limpieza.' USING ERRCODE = '42501';
    END IF;

    DELETE FROM public.posts WHERE moderation_status = 2 AND COALESCE(is_legal_hold, false) = false;
    GET DIAGNOSTICS v_posts = ROW_COUNT;

    DELETE FROM public.comments WHERE moderation_status = 2 AND COALESCE(is_legal_hold, false) = false;
    GET DIAGNOSTICS v_comments = ROW_COUNT;

    DELETE FROM public.student_groups WHERE moderation_status = 2 AND COALESCE(is_legal_hold, false) = false;
    GET DIAGNOSTICS v_groups = ROW_COUNT;

    DELETE FROM public.user_reports WHERE moderation_status = 2;
    GET DIAGNOSTICS v_ureports = ROW_COUNT;

    DELETE FROM public.whatsapp_group_reports WHERE moderation_status = 2;
    GET DIAGNOSTICS v_greports = ROW_COUNT;

    INSERT INTO public.moderation_audit_log (
        moderator_id, entity_table, entity_id, justification, is_automated, moderation_label
    ) VALUES (
        v_user_id, 'cleanup', '00000000-0000-0000-0000-000000000000',
        'Limpieza administrador: todo el contenido inapropiado/bloqueado', false, 'cleanup'
    );

    RETURN 'Limpieza completada — posts=' || v_posts || ', comentarios=' || v_comments ||
           ', grupos=' || v_groups || ', reportes de usuario=' || v_ureports || ', reportes de grupo=' || v_greports;
END;
$function$;

CREATE OR REPLACE FUNCTION public.purge_reported_groups()
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
    v_user_id uuid := auth.uid();
    v_deleted integer;
BEGIN
    IF NOT public.is_pemtree_admin(v_user_id) THEN
        RAISE EXCEPTION 'Permiso denegado: solo los administradores pueden ejecutar esta limpieza.' USING ERRCODE = '42501';
    END IF;

    DELETE FROM public.student_groups
    WHERE (
        reported_count > 0
        OR id IN (SELECT group_id FROM public.whatsapp_group_reports)
    )
      AND COALESCE(is_legal_hold, false) = false;
    GET DIAGNOSTICS v_deleted = ROW_COUNT;

    INSERT INTO public.moderation_audit_log (
        moderator_id, entity_table, entity_id, justification, is_automated, moderation_label
    ) VALUES (
        v_user_id, 'cleanup', '00000000-0000-0000-0000-000000000000',
        'Limpieza administrador: grupos reportados', false, 'cleanup'
    );

    RETURN 'Se eliminaron ' || v_deleted || ' grupos reportados (y sus reportes/votos asociados).';
END;
$function$;

-- 5.5 Revocar EXECUTE a anon en get_posts_with_comment_counts
REVOKE ALL ON FUNCTION public.get_posts_with_comment_counts() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_posts_with_comment_counts() TO authenticated;

-- 5.6 Endurecer user_exists para evitar enumeración de UUIDs por usuarios finales
CREATE OR REPLACE FUNCTION public.user_exists(p_user_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
    v_uid uuid := auth.uid();
BEGIN
    IF pg_trigger_depth() = 0
       AND current_user NOT IN ('postgres', 'service_role', 'supabase_admin')
       AND NOT (v_uid IS NOT NULL AND (public.is_pemtree_admin(v_uid) OR public.is_pemtree_moderator(v_uid))) THEN
        RAISE EXCEPTION 'Permiso denegado' USING ERRCODE = '42501';
    END IF;

    IF p_user_id IS NULL THEN
        RETURN false;
    END IF;

    RETURN EXISTS (SELECT 1 FROM auth.users u WHERE u.id = p_user_id);
END;
$function$;

-- 5.7 Filtrar contenido oculto o eliminado en RPCs de avatares
CREATE OR REPLACE FUNCTION public.get_posts_avatars(p_post_ids uuid[])
RETURNS TABLE(post_id uuid, avatar_color_index smallint, avatar_icon_index smallint, author_alias text)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $function$
    SELECT
        pa.post_id,
        pr.avatar_color_index,
        pr.avatar_icon_index,
        NULLIF(trim(pr.alias), '')::text AS author_alias
    FROM public.post_authors pa
    JOIN public.posts p
      ON p.id = pa.post_id
    JOIN public.profiles pr
      ON pr.id = pa.user_id
    WHERE pa.post_id = ANY(p_post_ids)
      AND p.deleted_at IS NULL
      AND p.moderation_status IS DISTINCT FROM 2
      AND (
        (pr.avatar_color_index IS NOT NULL AND pr.avatar_icon_index IS NOT NULL)
        OR NULLIF(trim(pr.alias), '') IS NOT NULL
      );
$function$;

CREATE OR REPLACE FUNCTION public.get_comments_avatars(p_comment_ids uuid[])
RETURNS TABLE(comment_id uuid, avatar_color_index smallint, avatar_icon_index smallint, author_alias text)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $function$
    SELECT
        c.id AS comment_id,
        pr.avatar_color_index,
        pr.avatar_icon_index,
        NULLIF(trim(pr.alias), '')::text AS author_alias
    FROM public.comments c
    JOIN public.profiles pr
      ON pr.id = c.user_id
    WHERE c.id = ANY(p_comment_ids)
      AND c.deleted_at IS NULL
      AND c.moderation_status IS DISTINCT FROM 2
      AND (
        (pr.avatar_color_index IS NOT NULL AND pr.avatar_icon_index IS NOT NULL)
        OR NULLIF(trim(pr.alias), '') IS NOT NULL
      );
$function$;

CREATE OR REPLACE FUNCTION public.get_student_groups_avatars(p_group_ids uuid[])
RETURNS TABLE(group_id uuid, avatar_color_index smallint, avatar_icon_index smallint)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $function$
    SELECT
        sg.id AS group_id,
        pr.avatar_color_index,
        pr.avatar_icon_index
    FROM public.student_groups sg
    JOIN public.profiles pr
      ON pr.id = sg.user_id
    WHERE sg.id = ANY(p_group_ids)
      AND sg.deleted_at IS NULL
      AND sg.moderation_status IS DISTINCT FROM 2
      AND pr.avatar_color_index IS NOT NULL
      AND pr.avatar_icon_index IS NOT NULL;
$function$;

-- -----------------------------------------------------------------------------
-- 6) Storage, revocación de escritura anon e índices duplicados
-- -----------------------------------------------------------------------------
DROP POLICY IF EXISTS "Subida pública de imágenes para comunidad" ON storage.objects;
DROP POLICY IF EXISTS "Subida autenticada de imágenes para comunidad" ON storage.objects;
CREATE POLICY "Subida autenticada de imágenes para comunidad"
    ON storage.objects
    FOR INSERT
    TO authenticated
    WITH CHECK (
        bucket_id = ANY (ARRAY['images'::text, 'public'::text, 's3'::text, 'media'::text, 'pemtree'::text])
        AND (SELECT auth.uid()) IS NOT NULL
    );

REVOKE INSERT, UPDATE, DELETE ON TABLE
    public.user_roles,
    public.moderation_audit_log,
    public.entity_reports,
    public.profiles,
    public.profanity_dictionary,
    public.user_forum_strikes,
    public.marketplace_plans,
    public.campus_reviews,
    public.campus_review_reactions,
    public.user_notifications,
    public.post_polls,
    public.post_poll_options,
    public.marketplace_bookmarks,
    public.marketplace_item_events
FROM anon;

DROP INDEX IF EXISTS public.idx_posts_created_at;
DROP INDEX IF EXISTS public.idx_post_polls_post;
DROP INDEX IF EXISTS public.idx_post_poll_votes_poll_user;

COMMIT;
