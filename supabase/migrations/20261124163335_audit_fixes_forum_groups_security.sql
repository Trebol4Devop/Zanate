-- =============================================================================
-- Correcciones de auditoría:
-- 1. Restringir student_groups.platform a ('whatsapp', 'telegram', 'discord')
-- 2. RPCs get_student_groups_avatars y get_comments_avatars
-- 3. Persistencia de shares_count en posts (increment_post_share) y vistas
-- 4. Revocar SELECT completo y restaurar GRANT SELECT por columna (sin user_id)
-- 5. Actualizar public.is_valid_anonymous_alias a alias libre de 2-32 caracteres
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Plataformas de student_groups: solo whatsapp, telegram, discord
-- -----------------------------------------------------------------------------
UPDATE public.student_groups
SET platform = CASE
    WHEN lower(coalesce(link, '')) LIKE '%t.me%'
      OR lower(coalesce(link, '')) LIKE '%telegram.me%' THEN 'telegram'
    WHEN lower(coalesce(link, '')) LIKE '%discord.gg%'
      OR lower(coalesce(link, '')) LIKE '%discord.com%' THEN 'discord'
    ELSE 'whatsapp'
END
WHERE platform IS NULL
   OR platform NOT IN ('whatsapp', 'telegram', 'discord');

ALTER TABLE public.student_groups
    DROP CONSTRAINT IF EXISTS student_groups_platform_check;

ALTER TABLE public.student_groups
    ADD CONSTRAINT student_groups_platform_check
    CHECK (platform = ANY (ARRAY['whatsapp'::text, 'telegram'::text, 'discord'::text]));

-- -----------------------------------------------------------------------------
-- 2. RPCs seguros de avatares para grupos y comentarios (sin exponer user_id)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_student_groups_avatars(p_group_ids uuid[])
RETURNS TABLE (
    group_id uuid,
    avatar_color_index smallint,
    avatar_icon_index smallint
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT
        sg.id AS group_id,
        pr.avatar_color_index,
        pr.avatar_icon_index
    FROM public.student_groups sg
    JOIN public.profiles pr
      ON pr.id = sg.user_id
    WHERE sg.id = ANY(p_group_ids)
      AND sg.deleted_at IS NULL
      AND pr.avatar_color_index IS NOT NULL
      AND pr.avatar_icon_index IS NOT NULL;
$$;

REVOKE ALL ON FUNCTION public.get_student_groups_avatars(uuid[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_student_groups_avatars(uuid[]) TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.get_comments_avatars(p_comment_ids uuid[])
RETURNS TABLE (
    comment_id uuid,
    avatar_color_index smallint,
    avatar_icon_index smallint
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT
        c.id AS comment_id,
        pr.avatar_color_index,
        pr.avatar_icon_index
    FROM public.comments c
    JOIN public.profiles pr
      ON pr.id = c.user_id
    WHERE c.id = ANY(p_comment_ids)
      AND c.deleted_at IS NULL
      AND pr.avatar_color_index IS NOT NULL
      AND pr.avatar_icon_index IS NOT NULL;
$$;

REVOKE ALL ON FUNCTION public.get_comments_avatars(uuid[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_comments_avatars(uuid[]) TO anon, authenticated;

-- -----------------------------------------------------------------------------
-- 3. Persistencia de shares_count en public.posts y actualización de vistas
-- -----------------------------------------------------------------------------
ALTER TABLE public.posts
    ADD COLUMN IF NOT EXISTS shares_count integer NOT NULL DEFAULT 0;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'public.posts'::regclass
          AND conname = 'posts_shares_count_non_negative'
    ) THEN
        ALTER TABLE public.posts
            ADD CONSTRAINT posts_shares_count_non_negative
            CHECK (shares_count >= 0);
    END IF;
END $$;

REVOKE UPDATE (shares_count) ON TABLE public.posts FROM anon, authenticated;

CREATE OR REPLACE FUNCTION public.increment_post_share(p_post_id uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_new_count integer;
BEGIN
    UPDATE public.posts
    SET shares_count = shares_count + 1
    WHERE id = p_post_id
      AND deleted_at IS NULL
      AND moderation_status IS DISTINCT FROM 2
    RETURNING shares_count INTO v_new_count;

    RETURN COALESCE(v_new_count, 0);
END;
$$;

REVOKE ALL ON FUNCTION public.increment_post_share(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.increment_post_share(uuid) TO anon, authenticated;

-- Actualizar vistas agregando shares_count y forum_server_id al final del SELECT
DO $$
BEGIN
    IF to_regclass('public.safe_posts_feed') IS NOT NULL THEN
        EXECUTE $view$
            CREATE OR REPLACE VIEW public.safe_posts_feed
            WITH (security_invoker = true) AS
            SELECT
                p.id,
                p.title,
                p.category,
                p.content,
                p.author_alias,
                p.author_hash,
                p.likes,
                p.reposts_count,
                p.comments_count,
                p.comments_count AS comment_count,
                p.hot_score,
                p.carrera,
                p.image_url,
                p.gif_url,
                p.is_pinned,
                p.quoted_post_id,
                p.created_at,
                p.updated_at,
                p.moderation_status,
                p.moderation_label,
                p.moderation_confidence,
                p.moderation_reason,
                p.moderated_at,
                p.moderated_by,
                p.expires_at,
                p.deleted_at,
                p.is_legal_hold,
                public.is_my_post(p.id) AS is_mine,
                p.video_url,
                p.shares_count,
                p.forum_server_id
            FROM public.posts p
            WHERE p.deleted_at IS NULL
              AND p.moderation_status IS DISTINCT FROM 2
              AND (p.expires_at IS NULL OR p.expires_at > now());
        $view$;

        GRANT SELECT ON public.safe_posts_feed TO anon, authenticated;
    END IF;

    IF to_regclass('public.v_public_posts') IS NOT NULL
       AND to_regclass('public.safe_posts_feed') IS NOT NULL THEN
        EXECUTE $view$
            CREATE OR REPLACE VIEW public.v_public_posts
            WITH (security_invoker = true) AS
            SELECT
                id,
                title,
                category,
                content,
                author_alias,
                author_hash,
                likes,
                reposts_count,
                carrera,
                image_url,
                gif_url,
                is_pinned,
                quoted_post_id,
                created_at,
                moderation_status,
                comments_count AS comment_count,
                is_mine AS is_my_post,
                video_url,
                shares_count,
                forum_server_id
            FROM public.safe_posts_feed;
        $view$;

        GRANT SELECT ON public.v_public_posts TO anon, authenticated;
    END IF;
END $$;

-- -----------------------------------------------------------------------------
-- 4. Corregir regresión de GRANT SELECT a nivel de tabla (proteger user_id)
-- -----------------------------------------------------------------------------
REVOKE SELECT ON TABLE public.posts FROM anon, authenticated;
GRANT SELECT (
    id, title, category, content, author_alias, likes, created_at, carrera,
    image_url, moderation_status, moderation_label, moderation_confidence,
    moderation_reason, moderated_at, moderated_by, quoted_post_id, gif_url,
    is_pinned, reposts_count, author_hash, updated_at, deleted_at,
    is_legal_hold, comments_count, hot_score, expires_at, shares_count,
    forum_server_id, video_url
) ON TABLE public.posts TO anon, authenticated;

REVOKE SELECT ON TABLE public.comments FROM anon, authenticated;
GRANT SELECT (
    id, post_id, author_alias, content, created_at, parent_id,
    moderation_status, moderation_label, moderation_confidence,
    moderation_reason, moderated_at, moderated_by, gif_url, author_hash,
    updated_at, is_op, likes_count, deleted_at, is_legal_hold, is_flagged,
    flag_reason, toxicity_score, profanity_matches, is_deleted, deleted_by,
    auto_moderated
) ON TABLE public.comments TO anon, authenticated;

REVOKE SELECT ON TABLE public.student_groups FROM anon, authenticated;
GRANT SELECT (
    id, title, carrera, curso, section, link, description, author_alias,
    upvotes, reported_count, created_at, image_url, moderation_status,
    moderation_label, moderation_confidence, moderation_reason, moderated_at,
    moderated_by, platform, updated_at, deleted_at, is_legal_hold, shares_count
) ON TABLE public.student_groups TO anon, authenticated;

REVOKE SELECT ON TABLE public.marketplace_items FROM anon, authenticated;
GRANT SELECT (
    id, title, description, price, is_free, category, facultad, sede,
    building_code, location_detail, contact_whatsapp, contact_telegram,
    image_urls, video_url, is_sponsored, sponsor_badge_text, author_alias,
    upvotes, moderation_status, created_at, contact_instagram,
    contact_messenger, social_links, reported_count, status, moderation_label,
    moderation_confidence, moderation_reason, moderated_at, moderated_by,
    updated_at, deleted_at, is_legal_hold, shares_count, expires_at
) ON TABLE public.marketplace_items TO anon, authenticated;

-- -----------------------------------------------------------------------------
-- 5. Actualizar public.is_valid_anonymous_alias para alias libre (2-32 chars)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.is_valid_anonymous_alias(p_alias text)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $fn$
DECLARE
    v_norm text;
BEGIN
    IF p_alias IS NULL THEN
        RETURN false;
    END IF;

    v_norm := trim(regexp_replace(p_alias, '\s+', ' ', 'g'));
    IF char_length(v_norm) < 2 OR char_length(v_norm) > 32 THEN
        RETURN false;
    END IF;

    -- No debe contener @ ni secuencias de dominio/correo web
    IF v_norm ~ '@' OR v_norm ~* '\.[a-z]{2,}' THEN
        RETURN false;
    END IF;

    -- No debe contener 5 o más dígitos consecutivos (carné, CUI, teléfono)
    IF v_norm ~ '\d{5,}' THEN
        RETURN false;
    END IF;

    -- No debe contener títulos académicos seguidos de nombre propio
    IF v_norm ~* '(^|\s)(ing|lic|dr|dra|arq|msc|mtra|prof|doctor|doctora|licenciado|licenciada|ingeniero|ingeniera)\.?\s+[A-ZÁÉÍÓÚÑ]' THEN
        RETURN false;
    END IF;

    RETURN true;
END;
$fn$;

REVOKE ALL ON FUNCTION public.is_valid_anonymous_alias(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.is_valid_anonymous_alias(text) TO anon, authenticated, service_role;
