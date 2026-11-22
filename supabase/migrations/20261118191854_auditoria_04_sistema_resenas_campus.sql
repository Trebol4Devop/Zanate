-- ============================================================================
-- PEMTREE: Migración 04 - Sistema de Reseñas y Calificaciones del Campus USAC
-- Incluye clasificación especializada de 5 niveles para Sanitarios
-- ============================================================================

-- 1. Tabla de Reseñas de Campus
CREATE TABLE IF NOT EXISTS public.campus_reviews (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    target_id TEXT NOT NULL,
    target_type TEXT NOT NULL CHECK (target_type IN ('building', 'poi')),
    target_category TEXT DEFAULT 'general',
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    rating SMALLINT NOT NULL CHECK (rating >= 1 AND rating <= 5),
    bathroom_tier TEXT CHECK (bathroom_tier IN ('cacada', 'cacada_tolerable', 'cacada_limpia', 'disfrutable', 'templo_dioses') OR bathroom_tier IS NULL),
    comment TEXT,
    tags JSONB DEFAULT '{}'::jsonb,
    moderation_status SMALLINT DEFAULT 1 NOT NULL CHECK (moderation_status IN (0, 1, 2, 3)),
    moderation_reason TEXT,
    likes_count INTEGER DEFAULT 0 NOT NULL,
    created_at TIMESTAMPTZ DEFAULT timezone('utc'::text, now()) NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT timezone('utc'::text, now()) NOT NULL,
    CONSTRAINT uq_user_target_review UNIQUE (user_id, target_id)
);

CREATE INDEX IF NOT EXISTS idx_campus_reviews_target ON public.campus_reviews (target_id, moderation_status);
CREATE INDEX IF NOT EXISTS idx_campus_reviews_user ON public.campus_reviews (user_id);
CREATE INDEX IF NOT EXISTS idx_campus_reviews_category ON public.campus_reviews (target_category);

-- 2. Tabla de Agregados para Consultas Inmediatas
CREATE TABLE IF NOT EXISTS public.campus_rating_aggregates (
    target_id TEXT PRIMARY KEY,
    target_type TEXT NOT NULL CHECK (target_type IN ('building', 'poi')),
    target_category TEXT DEFAULT 'general',
    average_rating NUMERIC(3, 2) DEFAULT 0.00 NOT NULL,
    total_reviews INTEGER DEFAULT 0 NOT NULL,
    bathroom_class TEXT CHECK (bathroom_class IN ('cacada', 'cacada_tolerable', 'cacada_limpia', 'disfrutable', 'templo_dioses') OR bathroom_class IS NULL),
    bathroom_class_label TEXT,
    star_1_count INTEGER DEFAULT 0 NOT NULL,
    star_2_count INTEGER DEFAULT 0 NOT NULL,
    star_3_count INTEGER DEFAULT 0 NOT NULL,
    star_4_count INTEGER DEFAULT 0 NOT NULL,
    star_5_count INTEGER DEFAULT 0 NOT NULL,
    tags_summary JSONB DEFAULT '{}'::jsonb,
    updated_at TIMESTAMPTZ DEFAULT timezone('utc'::text, now()) NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_aggregates_category ON public.campus_rating_aggregates (target_category);
CREATE INDEX IF NOT EXISTS idx_aggregates_rating ON public.campus_rating_aggregates (average_rating DESC);

-- 3. Tabla de Reacciones (Útil / Me gusta a Reseña)
CREATE TABLE IF NOT EXISTS public.campus_review_reactions (
    review_id UUID NOT NULL REFERENCES public.campus_reviews(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ DEFAULT timezone('utc'::text, now()) NOT NULL,
    PRIMARY KEY (review_id, user_id)
);

-- 4. Función de Clasificación de Baños
CREATE OR REPLACE FUNCTION public.fn_resolve_bathroom_tier(p_avg NUMERIC)
RETURNS TABLE (tier_code TEXT, tier_label TEXT) 
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF p_avg >= 4.60 THEN
        RETURN QUERY SELECT 'templo_dioses'::TEXT, 'Templo de los dioses'::TEXT;
    ELSIF p_avg >= 4.00 THEN
        RETURN QUERY SELECT 'disfrutable'::TEXT, 'Disfrutable'::TEXT;
    ELSIF p_avg >= 3.00 THEN
        RETURN QUERY SELECT 'cacada_limpia'::TEXT, 'Cacada limpia'::TEXT;
    ELSIF p_avg >= 2.00 THEN
        RETURN QUERY SELECT 'cacada_tolerable'::TEXT, 'Cacada tolerable'::TEXT;
    ELSIF p_avg > 0 THEN
        RETURN QUERY SELECT 'cacada'::TEXT, 'Cacada'::TEXT;
    ELSE
        RETURN QUERY SELECT NULL::TEXT, NULL::TEXT;
    END IF;
END;
$$;

-- 5. Trigger de Recálculo Automático
CREATE OR REPLACE FUNCTION public.fn_recalculate_campus_rating_aggregate()
RETURNS TRIGGER 
LANGUAGE plpgsql 
SECURITY DEFINER 
SET search_path = public AS $$
DECLARE
    v_target_id TEXT;
    v_target_type TEXT;
    v_category TEXT;
    v_avg NUMERIC(3, 2);
    v_total INTEGER;
    v_s1 INTEGER; v_s2 INTEGER; v_s3 INTEGER; v_s4 INTEGER; v_s5 INTEGER;
    v_b_code TEXT; v_b_label TEXT;
BEGIN
    IF TG_OP = 'DELETE' THEN
        v_target_id := OLD.target_id;
        v_target_type := OLD.target_type;
        v_category := OLD.target_category;
    ELSE
        v_target_id := NEW.target_id;
        v_target_type := NEW.target_type;
        v_category := NEW.target_category;
    END IF;

    SELECT 
        COALESCE(ROUND(AVG(rating)::numeric, 2), 0.00),
        COUNT(*),
        COUNT(*) FILTER (WHERE rating = 1),
        COUNT(*) FILTER (WHERE rating = 2),
        COUNT(*) FILTER (WHERE rating = 3),
        COUNT(*) FILTER (WHERE rating = 4),
        COUNT(*) FILTER (WHERE rating = 5)
    INTO 
        v_avg, v_total, v_s1, v_s2, v_s3, v_s4, v_s5
    FROM public.campus_reviews
    WHERE target_id = v_target_id AND moderation_status = 1;

    IF v_category = 'sanitarios' AND v_total > 0 THEN
        SELECT tier_code, tier_label INTO v_b_code, v_b_label
        FROM public.fn_resolve_bathroom_tier(v_avg);
    ELSE
        v_b_code := NULL;
        v_b_label := NULL;
    END IF;

    INSERT INTO public.campus_rating_aggregates (
        target_id, target_type, target_category,
        average_rating, total_reviews,
        bathroom_class, bathroom_class_label,
        star_1_count, star_2_count, star_3_count, star_4_count, star_5_count,
        updated_at
    )
    VALUES (
        v_target_id, v_target_type, v_category,
        v_avg, v_total,
        v_b_code, v_b_label,
        v_s1, v_s2, v_s3, v_s4, v_s5,
        timezone('utc'::text, now())
    )
    ON CONFLICT (target_id) DO UPDATE SET
        average_rating = EXCLUDED.average_rating,
        total_reviews = EXCLUDED.total_reviews,
        bathroom_class = EXCLUDED.bathroom_class,
        bathroom_class_label = EXCLUDED.bathroom_class_label,
        star_1_count = EXCLUDED.star_1_count,
        star_2_count = EXCLUDED.star_2_count,
        star_3_count = EXCLUDED.star_3_count,
        star_4_count = EXCLUDED.star_4_count,
        star_5_count = EXCLUDED.star_5_count,
        updated_at = EXCLUDED.updated_at;

    RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_recalculate_campus_rating ON public.campus_reviews;
CREATE TRIGGER trg_recalculate_campus_rating
AFTER INSERT OR UPDATE OR DELETE ON public.campus_reviews
FOR EACH ROW
EXECUTE FUNCTION public.fn_recalculate_campus_rating_aggregate();

-- 6. RPC Segura para Consultar Reseñas con Pseudónimos
CREATE OR REPLACE FUNCTION public.get_target_reviews_with_authors(
    p_target_id TEXT,
    p_limit INTEGER DEFAULT 20,
    p_offset INTEGER DEFAULT 0
)
RETURNS TABLE (
    id UUID,
    target_id TEXT,
    target_type TEXT,
    target_category TEXT,
    rating SMALLINT,
    bathroom_tier TEXT,
    comment TEXT,
    tags JSONB,
    likes_count INTEGER,
    created_at TIMESTAMPTZ,
    author_alias TEXT,
    author_carrera TEXT,
    author_is_verified BOOLEAN,
    is_my_review BOOLEAN
) 
LANGUAGE sql 
STABLE 
SECURITY DEFINER 
SET search_path = public AS $$
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
        'Estudiante USAC'::text AS author_alias,
        p.carrera AS author_carrera,
        COALESCE(p.is_verified, false) AS author_is_verified,
        (auth.uid() = r.user_id) AS is_my_review
    FROM public.campus_reviews r
    LEFT JOIN public.profiles p ON p.id = r.user_id
    WHERE r.target_id = p_target_id
      AND (r.moderation_status = 1 OR auth.uid() = r.user_id)
    ORDER BY (auth.uid() = r.user_id) DESC, r.likes_count DESC, r.created_at DESC
    LIMIT p_limit
    OFFSET p_offset;
$$;

-- 7. Políticas RLS
ALTER TABLE public.campus_reviews ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.campus_rating_aggregates ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.campus_review_reactions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Public read aggregates" ON public.campus_rating_aggregates;
CREATE POLICY "Public read aggregates"
ON public.campus_rating_aggregates FOR SELECT
TO authenticated, anon
USING (true);

DROP POLICY IF EXISTS "Read approved reviews" ON public.campus_reviews;
CREATE POLICY "Read approved reviews"
ON public.campus_reviews FOR SELECT
TO authenticated, anon
USING (
    moderation_status = 1 
    OR auth.uid() = user_id 
    OR public.is_pemtree_moderator(auth.uid()) 
    OR public.is_pemtree_admin(auth.uid())
);

DROP POLICY IF EXISTS "Insert own review" ON public.campus_reviews;
CREATE POLICY "Insert own review"
ON public.campus_reviews FOR INSERT
TO authenticated
WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "Update own review or staff" ON public.campus_reviews;
CREATE POLICY "Update own review or staff"
ON public.campus_reviews FOR UPDATE
TO authenticated
USING (
    auth.uid() = user_id 
    OR public.is_pemtree_moderator(auth.uid()) 
    OR public.is_pemtree_admin(auth.uid())
)
WITH CHECK (
    auth.uid() = user_id 
    OR public.is_pemtree_moderator(auth.uid()) 
    OR public.is_pemtree_admin(auth.uid())
);

DROP POLICY IF EXISTS "Delete own review or admin" ON public.campus_reviews;
CREATE POLICY "Delete own review or admin"
ON public.campus_reviews FOR DELETE
TO authenticated
USING (
    auth.uid() = user_id 
    OR public.is_pemtree_admin(auth.uid())
);

GRANT SELECT ON public.campus_rating_aggregates TO authenticated, anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.campus_reviews TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_target_reviews_with_authors(TEXT, INTEGER, INTEGER) TO authenticated, anon;
