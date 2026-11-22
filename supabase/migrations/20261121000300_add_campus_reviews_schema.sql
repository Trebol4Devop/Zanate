-- =============================================================================
-- Zanate / PEMTREE · Migración: Esquema de Reseñas y Calificaciones del Mapa
-- Archivo: supabase/migrations/20261121000300_add_campus_reviews_schema.sql
-- Propósito:
--   1. Tabla idempotente public.campus_reviews (Zero-PII estricto).
--   2. RLS y políticas para anon (lectura) y authenticated (CRUD de lo propio).
--   3. Índices optimizados para consulta y agregación.
--   4. Vista precomputada public.campus_rating_aggregates con Escala Oficial de 5 Clases de Sanitarios USAC.
--   5. RPC public.get_target_reviews_with_authors (SECURITY DEFINER, Zero-PII).
--   6. Grants explícitos para anon, authenticated y service_role.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. TABLA: public.campus_reviews
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.campus_reviews (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    target_id text NOT NULL,
    target_type text NOT NULL DEFAULT 'building',
    target_category text NOT NULL DEFAULT 'general',
    rating integer NOT NULL CHECK (rating >= 1 AND rating <= 5),
    bathroom_tier text,
    comment text,
    tags jsonb NOT NULL DEFAULT '{}'::jsonb,
    author_alias text NOT NULL DEFAULT 'Estudiante USAC',
    author_hash text,
    moderation_status integer NOT NULL DEFAULT 1,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT uq_campus_reviews_user_target UNIQUE (user_id, target_id)
);

-- Comentarios explicativos y garantía Zero-PII
COMMENT ON TABLE public.campus_reviews IS 'Reseñas de edificios, POIs y sanitarios del campus. Cumple Zero-PII sin almacenar CUI, DPI, carné ni full_name.';
COMMENT ON COLUMN public.campus_reviews.author_alias IS 'Seudónimo del estudiante mostrado en la reseña.';
COMMENT ON COLUMN public.campus_reviews.author_hash IS 'Hash criptográfico (SHA-256 con salt del sistema) derivado del user_id.';
COMMENT ON COLUMN public.campus_reviews.moderation_status IS '0: pendiente, 1: aprobado/visible, 2: ocultado/cuarentena.';

-- -----------------------------------------------------------------------------
-- 2. ÍNDICES DE RENDIMIENTO
-- -----------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_campus_reviews_target_id
    ON public.campus_reviews (target_id);

CREATE INDEX IF NOT EXISTS idx_campus_reviews_user_id
    ON public.campus_reviews (user_id);

CREATE INDEX IF NOT EXISTS idx_campus_reviews_target_moderation
    ON public.campus_reviews (target_id, moderation_status);

CREATE INDEX IF NOT EXISTS idx_campus_reviews_created_at
    ON public.campus_reviews (created_at DESC);

-- -----------------------------------------------------------------------------
-- 3. TRIGGER: AUTOMATIZACIÓN DE AUTHOR_HASH, TIMESTAMPS Y SANITIZACIÓN
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.handle_campus_review_defaults()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_uid uuid := COALESCE(auth.uid(), NEW.user_id);
BEGIN
    IF v_uid IS NOT NULL THEN
        NEW.user_id := v_uid;
        NEW.author_hash := public.generate_author_hash(v_uid);
    END IF;

    IF NEW.author_alias IS NULL OR trim(NEW.author_alias) = '' THEN
        NEW.author_alias := 'Estudiante USAC';
    ELSE
        NEW.author_alias := trim(NEW.author_alias);
    END IF;

    IF NEW.comment IS NOT NULL THEN
        NEW.comment := trim(NEW.comment);
    END IF;

    NEW.tags := COALESCE(NEW.tags, '{}'::jsonb);
    NEW.updated_at := now();

    -- Moderation status default check
    IF NEW.moderation_status IS NULL THEN
        NEW.moderation_status := 1;
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_campus_review_defaults ON public.campus_reviews;
CREATE TRIGGER trg_campus_review_defaults
    BEFORE INSERT OR UPDATE ON public.campus_reviews
    FOR EACH ROW
    EXECUTE FUNCTION public.handle_campus_review_defaults();

-- -----------------------------------------------------------------------------
-- 4. SEGURIDAD: ROW LEVEL SECURITY (RLS)
-- -----------------------------------------------------------------------------
ALTER TABLE public.campus_reviews ENABLE ROW LEVEL SECURITY;

-- Limpieza idempotente de políticas previas
DROP POLICY IF EXISTS "campus_reviews_select_anon" ON public.campus_reviews;
DROP POLICY IF EXISTS "campus_reviews_select_auth" ON public.campus_reviews;
DROP POLICY IF EXISTS "campus_reviews_insert_auth" ON public.campus_reviews;
DROP POLICY IF EXISTS "campus_reviews_update_auth" ON public.campus_reviews;
DROP POLICY IF EXISTS "campus_reviews_delete_auth" ON public.campus_reviews;

-- Anon: Solo lectura de reseñas aprobadas
CREATE POLICY "campus_reviews_select_anon"
    ON public.campus_reviews
    FOR SELECT
    TO anon
    USING (moderation_status = 1);

-- Authenticated: Lectura de aprobadas, propias o si es moderador/admin
CREATE POLICY "campus_reviews_select_auth"
    ON public.campus_reviews
    FOR SELECT
    TO authenticated
    USING (
        moderation_status = 1
        OR auth.uid() = user_id
        OR public.is_pemtree_admin(auth.uid())
        OR public.is_pemtree_moderator(auth.uid())
    );

-- Authenticated: Inserción de reseñas propias
CREATE POLICY "campus_reviews_insert_auth"
    ON public.campus_reviews
    FOR INSERT
    TO authenticated
    WITH CHECK (auth.uid() = user_id);

-- Authenticated: Actualización de reseñas propias
CREATE POLICY "campus_reviews_update_auth"
    ON public.campus_reviews
    FOR UPDATE
    TO authenticated
    USING (auth.uid() = user_id)
    WITH CHECK (auth.uid() = user_id);

-- Authenticated: Eliminación de reseñas propias o moderador/admin
CREATE POLICY "campus_reviews_delete_auth"
    ON public.campus_reviews
    FOR DELETE
    TO authenticated
    USING (
        auth.uid() = user_id
        OR public.is_pemtree_admin(auth.uid())
        OR public.is_pemtree_moderator(auth.uid())
    );

-- -----------------------------------------------------------------------------
-- 5. VISTA: public.campus_rating_aggregates
-- -----------------------------------------------------------------------------
-- Precalcula promedios, total de reseñas, desglose de etiquetas higiénicas
-- y resuelve la Escala Oficial de 5 Clases de Sanitarios USAC:
--   >= 4.60 : templo_dioses
--   >= 4.00 : disfrutable
--   >= 3.00 : cacada_limpia
--   >= 2.00 : cacada_tolerable
--   <  2.00 : cacada
CREATE OR REPLACE VIEW public.campus_rating_aggregates AS
SELECT
    cr.target_id,
    COUNT(*)::bigint AS total_reviews,
    ROUND(AVG(cr.rating)::numeric, 2) AS average_rating,
    CASE
        WHEN AVG(cr.rating) >= 4.60 THEN 'templo_dioses'
        WHEN AVG(cr.rating) >= 4.00 THEN 'disfrutable'
        WHEN AVG(cr.rating) >= 3.00 THEN 'cacada_limpia'
        WHEN AVG(cr.rating) >= 2.00 THEN 'cacada_tolerable'
        ELSE 'cacada'
    END AS bathroom_class,
    COALESCE(
        (
            SELECT jsonb_object_agg(sub.tag_key, sub.tag_count)
            FROM (
                SELECT t.key AS tag_key, COUNT(*) AS tag_count
                FROM public.campus_reviews cr2,
                     LATERAL jsonb_each(cr2.tags) t
                WHERE cr2.target_id = cr.target_id
                  AND cr2.moderation_status = 1
                  AND (t.value = 'true'::jsonb OR t.value = '"true"'::jsonb)
                GROUP BY t.key
            ) sub
        ),
        '{}'::jsonb
    ) AS tags_summary
FROM public.campus_reviews cr
WHERE cr.moderation_status = 1
GROUP BY cr.target_id;

COMMENT ON VIEW public.campus_rating_aggregates IS 'Vista agregada de calificaciones del campus y etiquetas higiénicas/servicios.';

-- -----------------------------------------------------------------------------
-- 6. RPC: public.get_target_reviews_with_authors
-- -----------------------------------------------------------------------------
-- Devuelve las opiniones asociadas a un targetId con seudónimo y perfil verificado,
-- cumpliendo estrictamente con Zero-PII (sin exponer UUID interno ni datos identificables).
CREATE OR REPLACE FUNCTION public.get_target_reviews_with_authors(
    p_target_id text,
    p_limit integer DEFAULT 20,
    p_offset integer DEFAULT 0
)
RETURNS TABLE (
    id uuid,
    target_id text,
    target_type text,
    target_category text,
    rating integer,
    bathroom_tier text,
    comment text,
    tags jsonb,
    author_alias text,
    author_hash text,
    author_carrera text,
    author_is_verified boolean,
    created_at timestamptz,
    updated_at timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT
        cr.id,
        cr.target_id,
        cr.target_type,
        cr.target_category,
        cr.rating,
        cr.bathroom_tier,
        cr.comment,
        cr.tags,
        COALESCE(cr.author_alias, 'Estudiante USAC') AS author_alias,
        COALESCE(cr.author_hash, public.generate_author_hash(cr.user_id)) AS author_hash,
        p.carrera AS author_carrera,
        COALESCE(p.is_verified, false) AS author_is_verified,
        cr.created_at,
        cr.updated_at
    FROM public.campus_reviews cr
    LEFT JOIN public.profiles p ON p.id = cr.user_id
    WHERE cr.target_id = p_target_id
      AND (
          cr.moderation_status = 1
          OR (auth.uid() IS NOT NULL AND cr.user_id = auth.uid())
          OR (auth.uid() IS NOT NULL AND (public.is_pemtree_admin(auth.uid()) OR public.is_pemtree_moderator(auth.uid())))
      )
    ORDER BY cr.created_at DESC
    LIMIT LEAST(GREATEST(COALESCE(p_limit, 20), 1), 100)
    OFFSET GREATEST(COALESCE(p_offset, 0), 0);
$$;

COMMENT ON FUNCTION public.get_target_reviews_with_authors(text, integer, integer) IS
    'Consulta de reseñas paginadas de un lugar del campus protegiendo la identidad del alumno (Zero-PII).';

-- -----------------------------------------------------------------------------
-- 7. PERMISOS Y CONCESIÓN DE PRIVILEGIOS (GRANTS)
-- -----------------------------------------------------------------------------
-- Revocaciones defensivas
REVOKE ALL ON TABLE public.campus_reviews FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_target_reviews_with_authors(text, integer, integer) FROM PUBLIC;

-- Tabla public.campus_reviews
GRANT SELECT ON TABLE public.campus_reviews TO anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.campus_reviews TO authenticated;
GRANT ALL ON TABLE public.campus_reviews TO service_role;

-- Vista public.campus_rating_aggregates
GRANT SELECT ON TABLE public.campus_rating_aggregates TO anon, authenticated, service_role;

-- RPC public.get_target_reviews_with_authors
GRANT EXECUTE ON FUNCTION public.get_target_reviews_with_authors(text, integer, integer) TO anon, authenticated, service_role;
