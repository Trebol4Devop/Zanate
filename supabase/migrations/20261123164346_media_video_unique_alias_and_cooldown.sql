-- =============================================================================
-- Fase 3: Video en Foro, Alias Único Libre por Cuenta y Cooldown de 30 Segundos
-- Archivo: supabase/migrations/20261123164346_media_video_unique_alias_and_cooldown.sql
-- Nota: Generado localmente para revisión previa antes de aplicarse en Supabase.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Soporte de video exclusivo para publicaciones del foro (public.posts)
-- -----------------------------------------------------------------------------
ALTER TABLE public.posts
    ADD COLUMN IF NOT EXISTS video_url text;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'public.posts'::regclass
          AND conname = 'posts_video_url_https_check'
    ) THEN
        ALTER TABLE public.posts
            ADD CONSTRAINT posts_video_url_https_check
            CHECK (
                video_url IS NULL
                OR btrim(video_url) = ''
                OR video_url ~ '^https://'
            );
    END IF;
END $$;

GRANT SELECT (video_url) ON TABLE public.posts TO anon, authenticated;
GRANT INSERT (video_url), UPDATE (video_url) ON TABLE public.posts TO authenticated;

-- Actualizar vistas públicas existentes agregando video_url al final del SELECT
-- Orden obligatorio en PEMTREE: primero safe_posts_feed, luego v_public_posts (que lee de safe_posts_feed)
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
                p.video_url
            FROM public.posts p
            WHERE p.deleted_at IS NULL
              AND p.moderation_status IS DISTINCT FROM 2
              AND (p.expires_at IS NULL OR p.expires_at > now());
        $view$;
    END IF;

    IF to_regclass('public.v_public_posts') IS NOT NULL THEN
        IF to_regclass('public.safe_posts_feed') IS NOT NULL THEN
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
                    video_url
                FROM public.safe_posts_feed;
            $view$;
        ELSE
            EXECUTE $view$
                CREATE OR REPLACE VIEW public.v_public_posts
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
                    p.carrera,
                    p.image_url,
                    p.gif_url,
                    p.is_pinned,
                    p.quoted_post_id,
                    p.created_at,
                    p.moderation_status,
                    (
                        SELECT count(*)::integer AS count
                        FROM public.comments c
                        WHERE c.post_id = p.id
                          AND c.moderation_status IS DISTINCT FROM 2
                    ) AS comment_count,
                    CASE
                        WHEN auth.uid() IS NOT NULL THEN
                            p.author_hash = encode(
                                extensions.digest(
                                    (auth.uid()::text || ':USAC_COMMUNITY_ANON_SECRET_SALT_2026_KEY'),
                                    'sha256'
                                ),
                                'hex'
                            )
                        ELSE false
                    END AS is_my_post,
                    p.video_url
                FROM public.posts p
                WHERE p.moderation_status IS DISTINCT FROM 2;
            $view$;
        END IF;
    END IF;
END $$;


-- -----------------------------------------------------------------------------
-- 2. Alias único y libre por cuenta (public.profiles.alias + claim_unique_alias)
-- -----------------------------------------------------------------------------
ALTER TABLE public.profiles
    ADD COLUMN IF NOT EXISTS alias text;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'public.profiles'::regclass
          AND conname = 'profiles_alias_length_check'
    ) THEN
        ALTER TABLE public.profiles
            ADD CONSTRAINT profiles_alias_length_check
            CHECK (
                alias IS NULL
                OR char_length(btrim(alias)) BETWEEN 2 AND 32
            );
    END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS idx_profiles_alias_unique
    ON public.profiles (lower(btrim(alias)))
    WHERE alias IS NOT NULL AND btrim(alias) <> '';

CREATE OR REPLACE FUNCTION public.claim_unique_alias(p_alias text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $fn$
DECLARE
    v_uid uuid := auth.uid();
    v_claims_raw text := NULLIF(current_setting('request.jwt.claims', true), '');
    v_is_anon text := NULL;
    v_norm text;
BEGIN
    IF v_uid IS NULL THEN
        RETURN jsonb_build_object(
            'ok', false,
            'code', 'unauthenticated',
            'message', 'Debes iniciar sesión para guardar un alias.'
        );
    END IF;

    IF v_claims_raw IS NOT NULL THEN
        v_is_anon := v_claims_raw::jsonb ->> 'is_anonymous';
    END IF;

    IF v_is_anon = 'true' THEN
        RETURN jsonb_build_object(
            'ok', false,
            'code', 'anonymous_not_allowed',
            'message', 'Debes iniciar sesión con una cuenta registrada.'
        );
    END IF;

    v_norm := btrim(
        regexp_replace(
            regexp_replace(coalesce(p_alias, ''), E'[\\r\\n\\t]+', ' ', 'g'),
            '\s+',
            ' ',
            'g'
        )
    );

    IF char_length(v_norm) < 2 OR char_length(v_norm) > 32 THEN
        RETURN jsonb_build_object(
            'ok', false,
            'code', 'invalid_alias',
            'message', 'El alias debe tener entre 2 y 32 caracteres.'
        );
    END IF;

    BEGIN
        INSERT INTO public.profiles (id, alias)
        VALUES (v_uid, v_norm)
        ON CONFLICT (id) DO UPDATE
            SET alias = EXCLUDED.alias,
                updated_at = now();
    EXCEPTION
        WHEN unique_violation THEN
            RETURN jsonb_build_object(
                'ok', false,
                'code', 'alias_taken',
                'message', 'Ese alias ya está en uso por otra cuenta. Elige uno diferente.'
            );
    END;

    RETURN jsonb_build_object(
        'ok', true,
        'alias', v_norm
    );
END;
$fn$;

REVOKE ALL ON FUNCTION public.claim_unique_alias(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.claim_unique_alias(text) TO authenticated, service_role;

-- Si existe el validador legado de catálogo cerrado, actualizarlo a longitud libre (2..32)
DO $$
BEGIN
    IF to_regprocedure('public.check_author_alias_validity()') IS NOT NULL THEN
        EXECUTE $compat$
            CREATE OR REPLACE FUNCTION public.check_author_alias_validity()
            RETURNS trigger
            LANGUAGE plpgsql
            SECURITY DEFINER
            SET search_path = ''
            AS $inner$
            DECLARE
                v_norm text;
            BEGIN
                IF NEW.author_alias IS NULL THEN
                    RAISE EXCEPTION 'El alias debe tener entre 2 y 32 caracteres.'
                        USING ERRCODE = '23514';
                END IF;

                v_norm := btrim(
                    regexp_replace(
                        regexp_replace(NEW.author_alias, E'[\\r\\n\\t]+', ' ', 'g'),
                        '\s+',
                        ' ',
                        'g'
                    )
                );

                IF char_length(v_norm) < 2 OR char_length(v_norm) > 32 THEN
                    RAISE EXCEPTION 'El alias debe tener entre 2 y 32 caracteres.'
                        USING ERRCODE = '23514';
                END IF;

                NEW.author_alias := v_norm;
                RETURN NEW;
            END;
            $inner$;
        $compat$;
        REVOKE ALL ON FUNCTION public.check_author_alias_validity() FROM PUBLIC, anon, authenticated;
        GRANT EXECUTE ON FUNCTION public.check_author_alias_validity() TO service_role;
    END IF;
END $$;


-- -----------------------------------------------------------------------------
-- 3. Protección anti-sobrecarga: Cooldown de 30 segundos entre publicaciones
-- -----------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_posts_user_created_at
    ON public.posts (user_id, created_at DESC)
    WHERE user_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_student_groups_user_created_at
    ON public.student_groups (user_id, created_at DESC)
    WHERE user_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_marketplace_items_user_created_at
    ON public.marketplace_items (user_id, created_at DESC)
    WHERE user_id IS NOT NULL;

CREATE OR REPLACE FUNCTION public.enforce_publish_cooldown_30s()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $fn$
DECLARE
    v_claims_raw text := NULLIF(current_setting('request.jwt.claims', true), '');
    v_jwt_role text := NULL;
    v_uid uuid := coalesce(NEW.user_id, auth.uid());
    v_last_created timestamptz;
    v_wait_seconds integer;
BEGIN
    IF v_claims_raw IS NOT NULL THEN
        v_jwt_role := v_claims_raw::jsonb ->> 'role';
    END IF;

    -- Permitir inserciones internas de mantenimiento / service_role
    IF v_jwt_role = 'service_role'
       OR (auth.uid() IS NULL AND current_user IN ('postgres', 'service_role', 'supabase_admin')) THEN
        RETURN NEW;
    END IF;

    IF v_uid IS NULL THEN
        RETURN NEW;
    END IF;

    IF TG_TABLE_NAME = 'posts' THEN
        SELECT max(created_at)
          INTO v_last_created
        FROM public.posts
        WHERE user_id = v_uid
          AND created_at > now() - interval '30 seconds';
    ELSIF TG_TABLE_NAME = 'student_groups' THEN
        SELECT max(created_at)
          INTO v_last_created
        FROM public.student_groups
        WHERE user_id = v_uid
          AND created_at > now() - interval '30 seconds';
    ELSIF TG_TABLE_NAME = 'marketplace_items' THEN
        SELECT max(created_at)
          INTO v_last_created
        FROM public.marketplace_items
        WHERE user_id = v_uid
          AND created_at > now() - interval '30 seconds';
    END IF;

    IF v_last_created IS NOT NULL THEN
        v_wait_seconds := greatest(
            1,
            ceil(extract(epoch FROM ((v_last_created + interval '30 seconds') - now())))::integer
        );
        RAISE EXCEPTION 'Espera % segundos antes de publicar nuevamente.', v_wait_seconds
            USING ERRCODE = '23514', HINT = 'rate_limited';
    END IF;

    RETURN NEW;
END;
$fn$;

REVOKE ALL ON FUNCTION public.enforce_publish_cooldown_30s() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.enforce_publish_cooldown_30s() TO service_role;

DROP TRIGGER IF EXISTS trg_cooldown_30s_posts ON public.posts;
CREATE TRIGGER trg_cooldown_30s_posts
    BEFORE INSERT ON public.posts
    FOR EACH ROW
    EXECUTE FUNCTION public.enforce_publish_cooldown_30s();

DROP TRIGGER IF EXISTS trg_cooldown_30s_student_groups ON public.student_groups;
CREATE TRIGGER trg_cooldown_30s_student_groups
    BEFORE INSERT ON public.student_groups
    FOR EACH ROW
    EXECUTE FUNCTION public.enforce_publish_cooldown_30s();

DROP TRIGGER IF EXISTS trg_cooldown_30s_marketplace_items ON public.marketplace_items;
CREATE TRIGGER trg_cooldown_30s_marketplace_items
    BEFORE INSERT ON public.marketplace_items
    FOR EACH ROW
    EXECUTE FUNCTION public.enforce_publish_cooldown_30s();
