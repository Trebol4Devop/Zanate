-- =============================================================================
-- Contador de compartidos (shares_count) para grupos estudiantiles
-- Archivo: supabase/migrations/20261123204000_student_groups_shares_count.sql
-- =============================================================================

-- 1. Agregar columna shares_count a public.student_groups si no existe
ALTER TABLE public.student_groups
    ADD COLUMN IF NOT EXISTS shares_count integer NOT NULL DEFAULT 0;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'public.student_groups'::regclass
          AND conname = 'student_groups_shares_count_non_negative'
    ) THEN
        ALTER TABLE public.student_groups
            ADD CONSTRAINT student_groups_shares_count_non_negative
            CHECK (shares_count >= 0);
    END IF;
END $$;

REVOKE UPDATE (shares_count) ON TABLE public.student_groups FROM anon, authenticated;
GRANT SELECT (shares_count) ON TABLE public.student_groups TO anon, authenticated;

-- 2. Actualizar la vista pública safe_student_groups incluyendo shares_count al final
CREATE OR REPLACE VIEW public.safe_student_groups
WITH (security_invoker = true) AS
SELECT
    id,
    title,
    carrera,
    curso,
    section,
    link,
    description,
    author_alias,
    upvotes,
    reported_count,
    created_at,
    image_url,
    moderation_status,
    moderation_label,
    moderation_confidence,
    moderation_reason,
    moderated_at,
    moderated_by,
    platform,
    updated_at,
    deleted_at,
    is_legal_hold,
    public.is_my_group(id) AS is_mine,
    shares_count
FROM public.student_groups
WHERE deleted_at IS NULL
  AND (moderation_status IS DISTINCT FROM 2 OR public.is_my_group(id));

-- 3. RPC atómico para incrementar shares_count al compartir un enlace de grupo
CREATE OR REPLACE FUNCTION public.increment_student_group_share(p_group_id uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_new_count integer;
BEGIN
    UPDATE public.student_groups
    SET shares_count = shares_count + 1
    WHERE id = p_group_id
      AND deleted_at IS NULL
      AND moderation_status IS DISTINCT FROM 2
    RETURNING shares_count INTO v_new_count;

    RETURN COALESCE(v_new_count, 0);
END;
$$;

REVOKE ALL ON FUNCTION public.increment_student_group_share(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.increment_student_group_share(uuid) TO anon, authenticated;
