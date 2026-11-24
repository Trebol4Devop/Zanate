-- =============================================================================
-- Sincronización total del Foro con Supabase (sin estado local)
-- Archivo: supabase/migrations/20261124175236_forum_full_db_sync.sql
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Tabla public.user_forum_servers para persistir servidores del usuario en DB
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.user_forum_servers (
    user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    server_id text NOT NULL REFERENCES public.forum_servers(id) ON DELETE CASCADE,
    sort_order integer NOT NULL DEFAULT 0,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, server_id)
);

CREATE INDEX IF NOT EXISTS idx_user_forum_servers_user_order
    ON public.user_forum_servers (user_id, sort_order, created_at);

ALTER TABLE public.user_forum_servers ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "User forum servers select own" ON public.user_forum_servers;
CREATE POLICY "User forum servers select own"
    ON public.user_forum_servers
    FOR SELECT
    TO authenticated
    USING ((SELECT auth.uid()) = user_id);

DROP POLICY IF EXISTS "User forum servers insert own" ON public.user_forum_servers;
CREATE POLICY "User forum servers insert own"
    ON public.user_forum_servers
    FOR INSERT
    TO authenticated
    WITH CHECK ((SELECT auth.uid()) = user_id);

DROP POLICY IF EXISTS "User forum servers update own" ON public.user_forum_servers;
CREATE POLICY "User forum servers update own"
    ON public.user_forum_servers
    FOR UPDATE
    TO authenticated
    USING ((SELECT auth.uid()) = user_id)
    WITH CHECK ((SELECT auth.uid()) = user_id);

DROP POLICY IF EXISTS "User forum servers delete own" ON public.user_forum_servers;
CREATE POLICY "User forum servers delete own"
    ON public.user_forum_servers
    FOR DELETE
    TO authenticated
    USING ((SELECT auth.uid()) = user_id);

REVOKE ALL ON TABLE public.user_forum_servers FROM PUBLIC, anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.user_forum_servers TO authenticated;

-- -----------------------------------------------------------------------------
-- 2. Sanear catálogo public.forum_servers
-- -----------------------------------------------------------------------------
UPDATE public.forum_servers
SET server_kind = 'groups'
WHERE is_groups = true
  AND server_kind IS NULL;

UPDATE public.forum_servers
SET is_active = false,
    server_kind = 'legacy',
    show_in_rail = false
WHERE id = 'fac_10_todas';

UPDATE public.forum_servers
SET show_in_rail = false
WHERE id = 'desmadre'
  AND parent_id = 'general';

-- -----------------------------------------------------------------------------
-- 3. Sanear posts existentes y reconciliar comments_count
-- -----------------------------------------------------------------------------
UPDATE public.posts
SET forum_server_id = 'general'
WHERE forum_server_id = 'todas'
   OR (forum_server_id IS NULL AND carrera = 'todas');

UPDATE public.posts p
SET forum_server_id = fs.id
FROM public.forum_servers fs
WHERE p.forum_server_id IS NULL
  AND fs.is_active = true
  AND fs.is_groups = false
  AND (fs.id = p.carrera OR fs.carrera_id = p.carrera);

UPDATE public.posts p
SET comments_count = sub.cnt
FROM (
    SELECT
        p2.id AS post_id,
        count(c.id)::integer AS cnt
    FROM public.posts p2
    LEFT JOIN public.comments c
      ON c.post_id = p2.id
     AND c.deleted_at IS NULL
     AND c.moderation_status IS DISTINCT FROM 2
    GROUP BY p2.id
) sub
WHERE p.id = sub.post_id
  AND p.comments_count IS DISTINCT FROM sub.cnt;

-- -----------------------------------------------------------------------------
-- 4. Actualizar get_posts_avatars y get_comments_avatars para retornar también
--    el alias vivo desde public.profiles
-- -----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.get_posts_avatars(uuid[]);
CREATE FUNCTION public.get_posts_avatars(p_post_ids uuid[])
RETURNS TABLE (
    post_id uuid,
    avatar_color_index smallint,
    avatar_icon_index smallint,
    author_alias text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT
        pa.post_id,
        pr.avatar_color_index,
        pr.avatar_icon_index,
        NULLIF(trim(pr.alias), '')::text AS author_alias
    FROM public.post_authors pa
    JOIN public.profiles pr
      ON pr.id = pa.user_id
    WHERE pa.post_id = ANY(p_post_ids)
      AND (
        (pr.avatar_color_index IS NOT NULL AND pr.avatar_icon_index IS NOT NULL)
        OR NULLIF(trim(pr.alias), '') IS NOT NULL
      );
$$;

REVOKE ALL ON FUNCTION public.get_posts_avatars(uuid[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_posts_avatars(uuid[]) TO anon, authenticated;

DROP FUNCTION IF EXISTS public.get_comments_avatars(uuid[]);
CREATE FUNCTION public.get_comments_avatars(p_comment_ids uuid[])
RETURNS TABLE (
    comment_id uuid,
    avatar_color_index smallint,
    avatar_icon_index smallint,
    author_alias text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
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
      AND (
        (pr.avatar_color_index IS NOT NULL AND pr.avatar_icon_index IS NOT NULL)
        OR NULLIF(trim(pr.alias), '') IS NOT NULL
      );
$$;

REVOKE ALL ON FUNCTION public.get_comments_avatars(uuid[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_comments_avatars(uuid[]) TO anon, authenticated;
