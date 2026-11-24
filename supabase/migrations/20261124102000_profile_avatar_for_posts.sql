-- =============================================================================
-- Avatar persistente por perfil y resolución dinámica en publicaciones del foro
-- Archivo: supabase/migrations/20261124102000_profile_avatar_for_posts.sql
-- =============================================================================

-- 1. Columnas de avatar en public.profiles (NULL hasta que el usuario personalice)
ALTER TABLE public.profiles
    ADD COLUMN IF NOT EXISTS avatar_color_index smallint,
    ADD COLUMN IF NOT EXISTS avatar_icon_index smallint;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'public.profiles'::regclass
          AND conname = 'profiles_avatar_color_index_nonneg_check'
    ) THEN
        ALTER TABLE public.profiles
            ADD CONSTRAINT profiles_avatar_color_index_nonneg_check
            CHECK (avatar_color_index IS NULL OR avatar_color_index >= 0);
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'public.profiles'::regclass
          AND conname = 'profiles_avatar_icon_index_nonneg_check'
    ) THEN
        ALTER TABLE public.profiles
            ADD CONSTRAINT profiles_avatar_icon_index_nonneg_check
            CHECK (avatar_icon_index IS NULL OR avatar_icon_index >= 0);
    END IF;
END $$;

GRANT SELECT (avatar_color_index, avatar_icon_index) ON TABLE public.profiles TO authenticated;
GRANT UPDATE (avatar_color_index, avatar_icon_index) ON TABLE public.profiles TO authenticated;

-- 2. RPC segura para obtener el avatar actual del autor de cada post sin exponer user_id.
--    Al leer desde public.profiles en tiempo real, cualquier cambio de avatar se refleja
--    inmediatamente en todas las publicaciones previas y nuevas de ese usuario.
CREATE OR REPLACE FUNCTION public.get_posts_avatars(p_post_ids uuid[])
RETURNS TABLE (
    post_id uuid,
    avatar_color_index smallint,
    avatar_icon_index smallint
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT
        pa.post_id,
        pr.avatar_color_index,
        pr.avatar_icon_index
    FROM public.post_authors pa
    JOIN public.profiles pr
      ON pr.id = pa.user_id
    WHERE pa.post_id = ANY(p_post_ids)
      AND pr.avatar_color_index IS NOT NULL
      AND pr.avatar_icon_index IS NOT NULL;
$$;

REVOKE ALL ON FUNCTION public.get_posts_avatars(uuid[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_posts_avatars(uuid[]) TO anon, authenticated;
