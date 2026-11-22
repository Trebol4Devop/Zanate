-- =============================================================================
-- Zanate / PEMTREE · pgTAP Test: Módulo de Reseñas del Mapa y Agregados
-- Archivo: supabase/tests/database/campus_reviews_test.sql
-- Módulo: Calificaciones de Campus, Sanitarios y Agregados (Zero-PII)
-- =============================================================================

BEGIN;

SELECT plan(38);

CREATE EXTENSION IF NOT EXISTS pgtap;

-- Asegurar rol privilegiado inicial y claims limpios
RESET ROLE;
SET ROLE postgres;
SELECT set_config('request.jwt.claims', '', true);
SELECT set_config('request.jwt.claim.sub', '', true);
SELECT set_config('request.jwt.claim.role', '', true);
SELECT set_config('request.jwt.claim.email', '', true);

-- -----------------------------------------------------------------------------
-- Fixtures Globales de Prueba
-- -----------------------------------------------------------------------------
DO $$
DECLARE
    v_u1 uuid := '66000000-0000-0000-0000-000000000001';
    v_u2 uuid := '66000000-0000-0000-0000-000000000002';
    v_u3 uuid := '66000000-0000-0000-0000-000000000003';
    v_mod uuid := '66000000-0000-0000-0000-000000000010';
BEGIN
    PERFORM tests.create_supabase_user(v_u1, 'map_student1@test.com');
    PERFORM tests.create_supabase_user(v_u2, 'map_student2@test.com');
    PERFORM tests.create_supabase_user(v_u3, 'map_student3@test.com');
    PERFORM tests.create_supabase_user(v_mod, 'map_mod@test.com');

    INSERT INTO public.user_roles (user_id, role)
    VALUES (v_mod, 'moderator')
    ON CONFLICT (user_id) DO UPDATE SET role = 'moderator';

    INSERT INTO public.profiles (id, carrera, is_verified)
    VALUES
        (v_u1, 'sistemas', true),
        (v_u2, 'civil', false),
        (v_u3, 'industrial', true),
        (v_mod, 'sistemas', true)
    ON CONFLICT (id) DO UPDATE SET
        carrera = EXCLUDED.carrera,
        is_verified = EXCLUDED.is_verified;
END $$;

-- =============================================================================
-- SECCIÓN 1: Existencia de Objetos del Esquema
-- =============================================================================

SELECT has_table('public', 'campus_reviews', '1. Tabla public.campus_reviews existe');
SELECT has_view('public', 'campus_rating_aggregates', '2. Vista public.campus_rating_aggregates existe');
SELECT has_function('public', 'get_target_reviews_with_authors', ARRAY['text', 'integer', 'integer'], '3. RPC get_target_reviews_with_authors existe');

-- =============================================================================
-- SECCIÓN 2: Garantías de Privacidad Zero-PII en campus_reviews
-- =============================================================================

SELECT hasnt_column('public', 'campus_reviews', 'full_name', '4. campus_reviews no almacena full_name (Zero-PII)');
SELECT hasnt_column('public', 'campus_reviews', 'cui', '5. campus_reviews no almacena cui (Zero-PII)');
SELECT hasnt_column('public', 'campus_reviews', 'dpi', '6. campus_reviews no almacena dpi (Zero-PII)');
SELECT hasnt_column('public', 'campus_reviews', 'carne', '7. campus_reviews no almacena carné (Zero-PII)');

-- =============================================================================
-- SECCIÓN 3: Columnas Obligatorias en campus_reviews
-- =============================================================================

SELECT has_column('public', 'campus_reviews', 'id', '8. campus_reviews tiene id');
SELECT has_column('public', 'campus_reviews', 'user_id', '9. campus_reviews tiene user_id');
SELECT has_column('public', 'campus_reviews', 'target_id', '10. campus_reviews tiene target_id');
SELECT has_column('public', 'campus_reviews', 'target_type', '11. campus_reviews tiene target_type');
SELECT has_column('public', 'campus_reviews', 'target_category', '12. campus_reviews tiene target_category');
SELECT has_column('public', 'campus_reviews', 'rating', '13. campus_reviews tiene rating');
SELECT has_column('public', 'campus_reviews', 'bathroom_tier', '14. campus_reviews tiene bathroom_tier');
SELECT has_column('public', 'campus_reviews', 'comment', '15. campus_reviews tiene comment');
SELECT has_column('public', 'campus_reviews', 'tags', '16. campus_reviews tiene tags');
SELECT has_column('public', 'campus_reviews', 'author_alias', '17. campus_reviews tiene author_alias');
SELECT has_column('public', 'campus_reviews', 'author_hash', '18. campus_reviews tiene author_hash');
SELECT has_column('public', 'campus_reviews', 'moderation_status', '19. campus_reviews tiene moderation_status');
SELECT has_column('public', 'campus_reviews', 'created_at', '20. campus_reviews tiene created_at');
SELECT has_column('public', 'campus_reviews', 'updated_at', '21. campus_reviews tiene updated_at');

-- =============================================================================
-- SECCIÓN 4: Columnas Obligatorias en la Vista campus_rating_aggregates
-- =============================================================================

SELECT has_column('public', 'campus_rating_aggregates', 'target_id', '22. campus_rating_aggregates tiene target_id');
SELECT has_column('public', 'campus_rating_aggregates', 'total_reviews', '23. campus_rating_aggregates tiene total_reviews');
SELECT has_column('public', 'campus_rating_aggregates', 'average_rating', '24. campus_rating_aggregates tiene average_rating');
SELECT has_column('public', 'campus_rating_aggregates', 'bathroom_class', '25. campus_rating_aggregates tiene bathroom_class');
SELECT has_column('public', 'campus_rating_aggregates', 'tags_summary', '26. campus_rating_aggregates tiene tags_summary');

-- =============================================================================
-- SECCIÓN 5: Pruebas Funcionales de Inserción, Triggers y RLS
-- =============================================================================

-- 5.1 Intentar inserción como anon debe fallar por RLS
SELECT tests.authenticate_as_anon();
SELECT throws_ok(
    $$
    INSERT INTO public.campus_reviews (
        target_id, target_type, target_category, rating, comment
    ) VALUES (
        'sanitario-t3-p1', 'poi', 'sanitarios', 5, 'Excelente'
    )
    $$,
    '42501',
    NULL,
    '27. Anon no puede insertar reseñas en campus_reviews'
);

-- 5.2 Estudiante 1 autenticado inserta reseña para sanitario-t3-p1
SELECT tests.authenticate_as('66000000-0000-0000-0000-000000000001');
SELECT lives_ok(
    $$
    INSERT INTO public.campus_reviews (
        user_id, target_id, target_type, target_category, rating, bathroom_tier,
        comment, tags, author_alias
    ) VALUES (
        '66000000-0000-0000-0000-000000000001',
        'sanitario-t3-p1',
        'poi',
        'sanitarios',
        5,
        'templo_dioses',
        'Impecable y con jabón siempre.',
        '{"has_water": true, "has_soap": true, "is_clean": true}'::jsonb,
        'EstudianteSistemas'
    )
    $$,
    '28. Estudiante 1 inserta reseña satisfactoriamente'
);

-- 5.3 Estudiante 2 autenticado inserta segunda reseña
SELECT tests.authenticate_as('66000000-0000-0000-0000-000000000002');
SELECT lives_ok(
    $$
    INSERT INTO public.campus_reviews (
        user_id, target_id, target_type, target_category, rating, bathroom_tier,
        comment, tags, author_alias
    ) VALUES (
        '66000000-0000-0000-0000-000000000002',
        'sanitario-t3-p1',
        'poi',
        'sanitarios',
        4,
        'disfrutable',
        'Buen servicio, agua constante.',
        '{"has_water": true, "has_paper": true}'::jsonb,
        'CivilTester'
    )
    $$,
    '29. Estudiante 2 inserta segunda reseña para el mismo sanitario'
);

-- Reset a postgres para verificar triggers y vista
RESET ROLE;
SET ROLE postgres;

-- 5.4 Verificar que el trigger asignó author_hash criptográfico
SELECT is(
    (SELECT author_hash FROM public.campus_reviews WHERE user_id = '66000000-0000-0000-0000-000000000001'),
    public.generate_author_hash('66000000-0000-0000-0000-000000000001'::uuid),
    '30. Trigger asigna correctamente author_hash derivado de user_id'
);

-- 5.5 Verificar agregados calculados en campus_rating_aggregates (5 + 4) / 2 = 4.50 -> disfrutable
SELECT is(
    (SELECT total_reviews FROM public.campus_rating_aggregates WHERE target_id = 'sanitario-t3-p1'),
    2::bigint,
    '31. Vista calcula total_reviews = 2'
);

SELECT is(
    (SELECT average_rating FROM public.campus_rating_aggregates WHERE target_id = 'sanitario-t3-p1'),
    4.50::numeric,
    '32. Vista calcula average_rating = 4.50'
);

SELECT is(
    (SELECT bathroom_class FROM public.campus_rating_aggregates WHERE target_id = 'sanitario-t3-p1'),
    'disfrutable'::text,
    '33. Vista categoriza correctamente como disfrutable según Escala Oficial'
);

SELECT is(
    (SELECT (tags_summary->>'has_water')::int FROM public.campus_rating_aggregates WHERE target_id = 'sanitario-t3-p1'),
    2,
    '34. Vista agrega tags_summary has_water = 2'
);

SELECT is(
    (SELECT (tags_summary->>'has_soap')::int FROM public.campus_rating_aggregates WHERE target_id = 'sanitario-t3-p1'),
    1,
    '35. Vista agrega tags_summary has_soap = 1'
);

-- =============================================================================
-- SECCIÓN 6: Pruebas del RPC get_target_reviews_with_authors
-- =============================================================================

-- Ejecución como anon del RPC
SELECT tests.authenticate_as_anon();

SELECT is(
    (SELECT COUNT(*)::int FROM public.get_target_reviews_with_authors('sanitario-t3-p1')),
    2,
    '36. RPC retorna 2 reseñas para anon'
);

SELECT is(
    (SELECT author_alias FROM public.get_target_reviews_with_authors('sanitario-t3-p1') WHERE rating = 5),
    'EstudianteSistemas'::text,
    '37. RPC expone author_alias correctamente'
);

SELECT is(
    (SELECT author_carrera FROM public.get_target_reviews_with_authors('sanitario-t3-p1') WHERE rating = 5),
    'sistemas'::text,
    '38. RPC resuelve carrera desde profiles respetando Zero-PII'
);

ROLLBACK;
