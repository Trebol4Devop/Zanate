-- =============================================================================
-- Sincronización integral App/Worker <-> Supabase y endurecimiento de seguridad
-- Archivo: supabase/migrations/20261124174258_sync_and_security_hardening.sql
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Tabla dedicada public.campus_comments para el Mapa del Campus + Realtime
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.campus_comments (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    target_id text NOT NULL,
    parent_id uuid REFERENCES public.campus_comments(id) ON DELETE CASCADE,
    user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    author_alias text NOT NULL DEFAULT 'Estudiante USAC',
    content text NOT NULL CHECK (char_length(trim(content)) > 0 AND char_length(content) <= 2000),
    moderation_status smallint NOT NULL DEFAULT 1,
    likes_count integer NOT NULL DEFAULT 0 CHECK (likes_count >= 0),
    deleted_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_campus_comments_target_created
    ON public.campus_comments (target_id, created_at DESC)
    WHERE deleted_at IS NULL;

ALTER TABLE public.campus_comments ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Campus comments public read" ON public.campus_comments;
CREATE POLICY "Campus comments public read"
    ON public.campus_comments
    FOR SELECT
    TO anon, authenticated
    USING (
        (deleted_at IS NULL AND moderation_status = 1)
        OR (SELECT auth.uid()) = user_id
        OR public.is_pemtree_moderator((SELECT auth.uid()))
        OR public.is_pemtree_admin((SELECT auth.uid()))
    );

DROP POLICY IF EXISTS "Campus comments authenticated insert" ON public.campus_comments;
CREATE POLICY "Campus comments authenticated insert"
    ON public.campus_comments
    FOR INSERT
    TO authenticated
    WITH CHECK ((SELECT auth.uid()) = user_id);

DROP POLICY IF EXISTS "Campus comments owner or staff update" ON public.campus_comments;
CREATE POLICY "Campus comments owner or staff update"
    ON public.campus_comments
    FOR UPDATE
    TO authenticated
    USING (
        (SELECT auth.uid()) = user_id
        OR public.is_pemtree_moderator((SELECT auth.uid()))
        OR public.is_pemtree_admin((SELECT auth.uid()))
    )
    WITH CHECK (
        (SELECT auth.uid()) = user_id
        OR public.is_pemtree_moderator((SELECT auth.uid()))
        OR public.is_pemtree_admin((SELECT auth.uid()))
    );

DROP POLICY IF EXISTS "Campus comments deny delete" ON public.campus_comments;
CREATE POLICY "Campus comments deny delete"
    ON public.campus_comments
    FOR DELETE
    TO anon, authenticated
    USING (false);

REVOKE ALL ON TABLE public.campus_comments FROM PUBLIC, anon, authenticated;
GRANT SELECT (
    id, target_id, parent_id, author_alias, content,
    moderation_status, likes_count, deleted_at, created_at, updated_at
) ON TABLE public.campus_comments TO anon, authenticated;
GRANT INSERT (
    target_id, parent_id, user_id, author_alias, content, moderation_status
) ON TABLE public.campus_comments TO authenticated;
GRANT UPDATE (
    content, deleted_at, updated_at
) ON TABLE public.campus_comments TO authenticated;

CREATE OR REPLACE FUNCTION public.get_target_comments_with_authors(
    p_target_id text,
    p_limit integer DEFAULT 50,
    p_offset integer DEFAULT 0
)
RETURNS TABLE (
    id uuid,
    target_id text,
    parent_id uuid,
    content text,
    author_alias text,
    likes_count integer,
    created_at timestamptz,
    is_my_comment boolean
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT
        c.id,
        c.target_id,
        c.parent_id,
        c.content,
        COALESCE(
            NULLIF(trim(c.author_alias), ''),
            NULLIF(trim(p.alias), ''),
            'Estudiante USAC'
        )::text AS author_alias,
        c.likes_count,
        c.created_at,
        ((SELECT auth.uid()) = c.user_id) AS is_my_comment
    FROM public.campus_comments c
    LEFT JOIN public.profiles p ON p.id = c.user_id
    WHERE c.target_id = p_target_id
      AND c.deleted_at IS NULL
      AND (c.moderation_status = 1 OR (SELECT auth.uid()) = c.user_id)
    ORDER BY c.created_at ASC
    LIMIT p_limit
    OFFSET p_offset;
$$;

REVOKE ALL ON FUNCTION public.get_target_comments_with_authors(text, integer, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_target_comments_with_authors(text, integer, integer) TO anon, authenticated;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime') THEN
        IF NOT EXISTS (
            SELECT 1
            FROM pg_publication_tables
            WHERE pubname = 'supabase_realtime'
              AND schemaname = 'public'
              AND tablename = 'campus_comments'
        ) THEN
            ALTER PUBLICATION supabase_realtime ADD TABLE public.campus_comments;
        END IF;
    END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 2. Políticas RLS para public.campus_review_reactions
-- -----------------------------------------------------------------------------
ALTER TABLE public.campus_review_reactions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Campus review reactions public read" ON public.campus_review_reactions;
CREATE POLICY "Campus review reactions public read"
    ON public.campus_review_reactions
    FOR SELECT
    TO anon, authenticated
    USING (true);

DROP POLICY IF EXISTS "Campus review reactions auth insert" ON public.campus_review_reactions;
CREATE POLICY "Campus review reactions auth insert"
    ON public.campus_review_reactions
    FOR INSERT
    TO authenticated
    WITH CHECK ((SELECT auth.uid()) = user_id);

DROP POLICY IF EXISTS "Campus review reactions auth delete" ON public.campus_review_reactions;
CREATE POLICY "Campus review reactions auth delete"
    ON public.campus_review_reactions
    FOR DELETE
    TO authenticated
    USING ((SELECT auth.uid()) = user_id);

-- -----------------------------------------------------------------------------
-- 3. Corregir get_target_reviews_with_authors para usar alias real del perfil
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_target_reviews_with_authors(
    p_target_id text,
    p_limit integer DEFAULT 20,
    p_offset integer DEFAULT 0
)
RETURNS TABLE(
    id uuid,
    target_id text,
    target_type text,
    target_category text,
    rating smallint,
    bathroom_tier text,
    comment text,
    tags jsonb,
    likes_count integer,
    created_at timestamp with time zone,
    author_alias text,
    author_carrera text,
    author_is_verified boolean,
    is_my_review boolean
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
    SELECT
        r.id,
        r.target_id,
        r.target_type,
        r.target_category,
        r.rating,
        r.bathroom_tier,
        r.comment,
        r.tags,
        r.likes_count,
        r.created_at,
        COALESCE(NULLIF(trim(p.alias), ''), 'Estudiante USAC')::text AS author_alias,
        p.carrera AS author_carrera,
        COALESCE(p.is_verified, false) AS author_is_verified,
        ((SELECT auth.uid()) = r.user_id) AS is_my_review
    FROM public.campus_reviews r
    LEFT JOIN public.profiles p ON p.id = r.user_id
    WHERE r.target_id = p_target_id
      AND (r.moderation_status = 1 OR (SELECT auth.uid()) = r.user_id)
    ORDER BY ((SELECT auth.uid()) = r.user_id) DESC, r.likes_count DESC, r.created_at DESC
    LIMIT p_limit
    OFFSET p_offset;
$function$;

REVOKE ALL ON FUNCTION public.get_target_reviews_with_authors(text, integer, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_target_reviews_with_authors(text, integer, integer) TO anon, authenticated;

-- -----------------------------------------------------------------------------
-- 4. Mover extensión unaccent fuera de public y fijar search_path en 6 funciones
-- -----------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS extensions;

DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM pg_extension e
        JOIN pg_namespace n ON n.oid = e.extnamespace
        WHERE e.extname = 'unaccent'
          AND n.nspname = 'public'
    ) THEN
        ALTER EXTENSION unaccent SET SCHEMA extensions;
    END IF;
END $$;

ALTER FUNCTION public.fn_resolve_bathroom_tier(numeric)
    SET search_path = public, pg_temp;

ALTER FUNCTION public.fn_normalize_profanity_text(text)
    SET search_path = public, extensions, pg_temp;

ALTER FUNCTION public.fn_filter_comment_profanity()
    SET search_path = public, extensions, pg_temp;

ALTER FUNCTION public.test_profanity_filter(text)
    SET search_path = public, extensions, pg_temp;

ALTER FUNCTION public.admin_issue_forum_strike(uuid, text, text, uuid, uuid)
    SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION public.admin_hard_delete_comment(p_comment_id uuid, p_justificacion text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
    v_user_id uuid := auth.uid();
    v_has_replies boolean := false;
    v_comment_row record;
BEGIN
    IF NOT public.is_pemtree_admin(v_user_id) THEN
        RAISE EXCEPTION 'Permiso denegado: Únicamente los Administradores Globales pueden ejecutar la eliminación definitiva de comentarios.';
    END IF;

    IF p_justificacion IS NULL OR trim(p_justificacion) = '' THEN
        RAISE EXCEPTION 'La justificación es obligatoria para registrar la pista de auditoría del borrado.';
    END IF;

    SELECT * INTO v_comment_row FROM public.comments WHERE id = p_comment_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El comentario especificado no existe o ya fue eliminado.';
    END IF;

    SELECT EXISTS (SELECT 1 FROM public.comments WHERE parent_id = p_comment_id) INTO v_has_replies;

    INSERT INTO public.moderation_audit_log (
        moderator_id,
        entity_table,
        entity_id,
        justification,
        is_automated,
        moderation_label
    ) VALUES (
        v_user_id,
        'comments',
        p_comment_id,
        trim(p_justificacion) || ' [Borrado definitivo ejecutado por Administrador Global]',
        false,
        'deleted_hard'
    );

    IF v_has_replies THEN
        UPDATE public.comments
        SET content = '[Comentario eliminado permanentemente por el Administrador]',
            gif_url = NULL,
            is_deleted = true,
            deleted_at = now(),
            deleted_by = v_user_id,
            moderation_status = 2,
            moderation_reason = trim(p_justificacion),
            is_flagged = false
        WHERE id = p_comment_id;

        RETURN jsonb_build_object(
            'success', true,
            'mode', 'tombstone_preserved',
            'message', 'El comentario tiene respuestas asociadas. Se purgó el contenido y se preservó el árbol jerárquico.'
        );
    ELSE
        -- El trigger sync_post_comments_counter actualiza public.posts.comments_count automáticamente
        DELETE FROM public.comments WHERE id = p_comment_id;

        RETURN jsonb_build_object(
            'success', true,
            'mode', 'hard_deleted',
            'message', 'Comentario eliminado de forma definitiva de la base de datos.'
        );
    END IF;
END;
$function$;

-- -----------------------------------------------------------------------------
-- 5. Revocar EXECUTE indebido a anon en funciones SECURITY DEFINER
-- -----------------------------------------------------------------------------
-- 5a. Funciones de administración, staff o usuarios autenticados
REVOKE ALL ON FUNCTION public.admin_hard_delete_comment(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_hard_delete_comment(uuid, text) TO authenticated;

REVOKE ALL ON FUNCTION public.admin_issue_forum_strike(uuid, text, text, uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_issue_forum_strike(uuid, text, text, uuid, uuid) TO authenticated;

REVOKE ALL ON FUNCTION public.staff_set_campus_review_status(uuid, integer, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.staff_set_campus_review_status(uuid, integer, text) TO authenticated;

REVOKE ALL ON FUNCTION public.get_admin_dashboard_stats() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_admin_dashboard_stats() TO authenticated;

REVOKE ALL ON FUNCTION public.get_user_activity_admin(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_user_activity_admin(uuid) TO authenticated;

REVOKE ALL ON FUNCTION public.get_verification_stats() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_verification_stats() TO authenticated;

REVOKE ALL ON FUNCTION public.test_profanity_filter(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.test_profanity_filter(text) TO authenticated;

REVOKE ALL ON FUNCTION public.get_marketplace_metrics(integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_marketplace_metrics(integer) TO authenticated;

REVOKE ALL ON FUNCTION public.get_my_marketplace_status() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_my_marketplace_status() TO authenticated;

REVOKE ALL ON FUNCTION public.get_my_marketplace_items(text, integer, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_my_marketplace_items(text, integer, integer) TO authenticated;

REVOKE ALL ON FUNCTION public.get_my_bookmarked_items(integer, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_my_bookmarked_items(integer, integer) TO authenticated;

REVOKE ALL ON FUNCTION public.toggle_marketplace_bookmark(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.toggle_marketplace_bookmark(uuid) TO authenticated;

REVOKE ALL ON FUNCTION public.is_verified_seller(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.is_verified_seller(uuid) TO authenticated;

-- 5b. Funciones internas/mantenimiento (solo postgres/service_role/pg_cron)
REVOKE ALL ON FUNCTION public.pause_expired_marketplace_items() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.reconcile_seller_plan_limits(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.get_effective_seller_plan(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.get_item_seller_context(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.is_risk_report_reason(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.marketplace_contains_prohibited_terms(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.moderation_priority_for(text, uuid, text, boolean) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.count_total_profiles() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.generate_author_hash(uuid, text) FROM PUBLIC, anon, authenticated;

-- 5c. Revocar EXECUTE de PUBLIC, anon, authenticated en todas las funciones trigger SECURITY DEFINER
DO $$
DECLARE
    v_fn record;
BEGIN
    FOR v_fn IN
        SELECT p.oid::regprocedure AS sig
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.prosecdef = true
          AND p.prorettype = 'trigger'::regtype
    LOOP
        EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated;', v_fn.sig);
    END LOOP;
END $$;

-- -----------------------------------------------------------------------------
-- 6. Añadir WITH CHECK en políticas UPDATE y restringir notificaciones a authenticated
-- -----------------------------------------------------------------------------
DROP POLICY IF EXISTS "Actualizar propios comentarios o moderador" ON public.comments;
CREATE POLICY "Actualizar propios comentarios o moderador"
    ON public.comments
    FOR UPDATE
    TO authenticated
    USING (
        (
            (SELECT auth.uid()) IS NOT NULL
            AND (
                (SELECT auth.uid()) = user_id
                OR EXISTS (
                    SELECT 1
                    FROM public.comment_authors
                    WHERE comment_authors.comment_id = comments.id
                      AND comment_authors.user_id = (SELECT auth.uid())
                )
            )
        )
        OR public.is_pemtree_moderator((SELECT auth.uid()))
    )
    WITH CHECK (
        (
            (SELECT auth.uid()) IS NOT NULL
            AND (
                (SELECT auth.uid()) = user_id
                OR EXISTS (
                    SELECT 1
                    FROM public.comment_authors
                    WHERE comment_authors.comment_id = comments.id
                      AND comment_authors.user_id = (SELECT auth.uid())
                )
            )
        )
        OR public.is_pemtree_moderator((SELECT auth.uid()))
    );

DROP POLICY IF EXISTS "Actualizar propias publicaciones o moderador" ON public.posts;
CREATE POLICY "Actualizar propias publicaciones o moderador"
    ON public.posts
    FOR UPDATE
    TO authenticated
    USING (
        (
            (SELECT auth.uid()) IS NOT NULL
            AND (
                (SELECT auth.uid()) = user_id
                OR EXISTS (
                    SELECT 1
                    FROM public.post_authors
                    WHERE post_authors.post_id = posts.id
                      AND post_authors.user_id = (SELECT auth.uid())
                )
            )
        )
        OR public.is_pemtree_moderator((SELECT auth.uid()))
    )
    WITH CHECK (
        (
            (SELECT auth.uid()) IS NOT NULL
            AND (
                (SELECT auth.uid()) = user_id
                OR EXISTS (
                    SELECT 1
                    FROM public.post_authors
                    WHERE post_authors.post_id = posts.id
                      AND post_authors.user_id = (SELECT auth.uid())
                )
            )
        )
        OR public.is_pemtree_moderator((SELECT auth.uid()))
    );

DROP POLICY IF EXISTS "Editar grupos dueño, admin o moderador" ON public.student_groups;
CREATE POLICY "Editar grupos dueño, admin o moderador"
    ON public.student_groups
    FOR UPDATE
    TO authenticated
    USING (
        (SELECT auth.uid()) = user_id
        OR ((SELECT auth.uid()) IS NOT NULL AND public.is_pemtree_admin((SELECT auth.uid())))
        OR ((SELECT auth.uid()) IS NOT NULL AND public.is_pemtree_moderator((SELECT auth.uid())))
    )
    WITH CHECK (
        (SELECT auth.uid()) = user_id
        OR ((SELECT auth.uid()) IS NOT NULL AND public.is_pemtree_admin((SELECT auth.uid())))
        OR ((SELECT auth.uid()) IS NOT NULL AND public.is_pemtree_moderator((SELECT auth.uid())))
    );

DROP POLICY IF EXISTS "Users can update their own marketplace items o moderador" ON public.marketplace_items;
CREATE POLICY "Users can update their own marketplace items o moderador"
    ON public.marketplace_items
    FOR UPDATE
    TO authenticated
    USING (
        ((SELECT auth.uid()) IS NOT NULL AND (SELECT auth.uid()) = user_id)
        OR public.is_pemtree_moderator((SELECT auth.uid()))
    )
    WITH CHECK (
        ((SELECT auth.uid()) IS NOT NULL AND (SELECT auth.uid()) = user_id)
        OR public.is_pemtree_moderator((SELECT auth.uid()))
    );

DROP POLICY IF EXISTS "Moderators can update entity reports" ON public.entity_reports;
CREATE POLICY "Moderators can update entity reports"
    ON public.entity_reports
    FOR UPDATE
    TO authenticated
    USING (
        public.is_pemtree_admin((SELECT auth.uid()))
        OR public.is_pemtree_moderator((SELECT auth.uid()))
    )
    WITH CHECK (
        public.is_pemtree_admin((SELECT auth.uid()))
        OR public.is_pemtree_moderator((SELECT auth.uid()))
    );

-- Notificaciones: cambiar TO public -> TO authenticated y añadir WITH CHECK en UPDATE
DROP POLICY IF EXISTS "Ver mis preferencias de notificación" ON public.notification_preferences;
CREATE POLICY "Ver mis preferencias de notificación"
    ON public.notification_preferences
    FOR SELECT
    TO authenticated
    USING ((SELECT auth.uid()) = user_id);

DROP POLICY IF EXISTS "Crear mis preferencias de notificación" ON public.notification_preferences;
CREATE POLICY "Crear mis preferencias de notificación"
    ON public.notification_preferences
    FOR INSERT
    TO authenticated
    WITH CHECK ((SELECT auth.uid()) = user_id);

DROP POLICY IF EXISTS "Actualizar mis preferencias de notificación" ON public.notification_preferences;
CREATE POLICY "Actualizar mis preferencias de notificación"
    ON public.notification_preferences
    FOR UPDATE
    TO authenticated
    USING ((SELECT auth.uid()) = user_id)
    WITH CHECK ((SELECT auth.uid()) = user_id);

DROP POLICY IF EXISTS "Ver mis suscripciones de notificación" ON public.notification_subscriptions;
CREATE POLICY "Ver mis suscripciones de notificación"
    ON public.notification_subscriptions
    FOR SELECT
    TO authenticated
    USING ((SELECT auth.uid()) = user_id);

DROP POLICY IF EXISTS "Crear mis suscripciones de notificación" ON public.notification_subscriptions;
CREATE POLICY "Crear mis suscripciones de notificación"
    ON public.notification_subscriptions
    FOR INSERT
    TO authenticated
    WITH CHECK ((SELECT auth.uid()) = user_id);

DROP POLICY IF EXISTS "Actualizar mis suscripciones de notificación" ON public.notification_subscriptions;
CREATE POLICY "Actualizar mis suscripciones de notificación"
    ON public.notification_subscriptions
    FOR UPDATE
    TO authenticated
    USING ((SELECT auth.uid()) = user_id)
    WITH CHECK ((SELECT auth.uid()) = user_id);

DROP POLICY IF EXISTS "Borrar mis suscripciones de notificación" ON public.notification_subscriptions;
CREATE POLICY "Borrar mis suscripciones de notificación"
    ON public.notification_subscriptions
    FOR DELETE
    TO authenticated
    USING ((SELECT auth.uid()) = user_id);

DROP POLICY IF EXISTS "Ver mis notificaciones" ON public.user_notifications;
CREATE POLICY "Ver mis notificaciones"
    ON public.user_notifications
    FOR SELECT
    TO authenticated
    USING ((SELECT auth.uid()) = user_id);

DROP POLICY IF EXISTS "Actualizar mis notificaciones (leídas)" ON public.user_notifications;
CREATE POLICY "Actualizar mis notificaciones (leídas)"
    ON public.user_notifications
    FOR UPDATE
    TO authenticated
    USING ((SELECT auth.uid()) = user_id)
    WITH CHECK ((SELECT auth.uid()) = user_id);

DROP POLICY IF EXISTS "Borrar mis notificaciones" ON public.user_notifications;
CREATE POLICY "Borrar mis notificaciones"
    ON public.user_notifications
    FOR DELETE
    TO authenticated
    USING ((SELECT auth.uid()) = user_id);
