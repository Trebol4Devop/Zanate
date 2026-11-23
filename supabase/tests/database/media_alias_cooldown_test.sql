-- =============================================================================
-- pgTAP Tests: Fase 3 (posts.video_url, profiles.alias único y cooldown 30 s)
-- Archivo: supabase/tests/database/media_alias_cooldown_test.sql
-- =============================================================================
BEGIN;

SELECT plan(14);

CREATE EXTENSION IF NOT EXISTS pgtap;

RESET ROLE;
SET ROLE postgres;
SELECT set_config('request.jwt.claims', '', true);
SELECT set_config('request.jwt.claim.sub', '', true);
SELECT set_config('request.jwt.claim.role', '', true);
SELECT set_config('request.jwt.claim.email', '', true);

DO $$
DECLARE
    v_u1 uuid := 'aa000000-0000-0000-0000-000000000001';
    v_u2 uuid := 'aa000000-0000-0000-0000-000000000002';
BEGIN
    PERFORM tests.create_supabase_user(v_u1, 'media_u1@test.com');
    PERFORM tests.create_supabase_user(v_u2, 'media_u2@test.com');

    INSERT INTO public.profiles (id, carrera)
    VALUES
        (v_u1, 'sistemas'),
        (v_u2, 'sistemas')
    ON CONFLICT (id) DO NOTHING;
END $$;

-- 1-6: Verificación estructural
SELECT has_column('public', 'posts', 'video_url', '1. public.posts posee columna video_url');
SELECT has_column('public', 'profiles', 'alias', '2. public.profiles posee columna alias');
SELECT has_index('public', 'profiles', 'idx_profiles_alias_unique', '3. índice único idx_profiles_alias_unique existe');
SELECT has_index('public', 'posts', 'idx_posts_user_created_at', '4. índice cooldown idx_posts_user_created_at existe');
SELECT has_index('public', 'student_groups', 'idx_student_groups_user_created_at', '5. índice cooldown idx_student_groups_user_created_at existe');
SELECT has_index('public', 'marketplace_items', 'idx_marketplace_items_user_created_at', '6. índice cooldown idx_marketplace_items_user_created_at existe');

-- 7-10: Alias único libre por cuenta
SELECT tests.authenticate_as('aa000000-0000-0000-0000-000000000001');

SELECT is(
    public.claim_unique_alias('  Anonymus  '),
    '{"ok": true, "alias": "Anonymus"}'::jsonb,
    '7. usuario 1 reclama alias libre Anonymus'
);

SELECT is(
    public.claim_unique_alias('ANONYMUS'),
    '{"ok": true, "alias": "ANONYMUS"}'::jsonb,
    '8. usuario 1 puede actualizar mayúsculas/minúsculas de su propio alias'
);

SELECT is(
    (public.claim_unique_alias('X') ->> 'code'),
    'invalid_alias',
    '9. alias de menos de 2 caracteres es rechazado con invalid_alias'
);

SELECT tests.authenticate_as('aa000000-0000-0000-0000-000000000002');

SELECT is(
    (public.claim_unique_alias('anonymus') ->> 'code'),
    'alias_taken',
    '10. usuario 2 no puede reclamar el mismo alias ignorando mayúsculas (alias_taken)'
);

-- 11-14: Video en posts y cooldown de 30 segundos por usuario
SELECT tests.authenticate_as('aa000000-0000-0000-0000-000000000001');

SELECT lives_ok(
    $$INSERT INTO public.posts (title, content, category, carrera, author_alias, user_id, video_url)
      VALUES ('Demo Video', 'Contenido válido de prueba para video', 'general', 'sistemas', 'Anonymus', 'aa000000-0000-0000-0000-000000000001', 'https://comunidad-usac-storage.carlosdelcidramirez.workers.dev/images/forum_videos/demo.mp4')$$,
    '11. usuario 1 publica post con alias libre y video_url https válido'
);

SELECT throws_ok(
    $$INSERT INTO public.posts (title, content, category, carrera, author_alias, user_id)
      VALUES ('Segundo rápido', 'Intento consecutivo en menos de 30s', 'general', 'sistemas', 'Anonymus', 'aa000000-0000-0000-0000-000000000001')$$,
    '23514',
    NULL,
    '12. segundo post de usuario 1 antes de 30s es rechazado por cooldown (23514)'
);

SELECT tests.authenticate_as('aa000000-0000-0000-0000-000000000002');

SELECT lives_ok(
    $$INSERT INTO public.posts (title, content, category, carrera, author_alias, user_id)
      VALUES ('Post Usuario 2', 'Publicación independiente de otro usuario', 'general', 'sistemas', 'OtroAlias', 'aa000000-0000-0000-0000-000000000002')$$,
    '13. usuario 2 puede publicar inmediatamente (cooldown aislado por usuario)'
);

SELECT throws_ok(
    $$INSERT INTO public.posts (title, content, category, carrera, author_alias, user_id, video_url)
      VALUES ('Video Inválido', 'Esquema inseguro rechazado', 'general', 'sistemas', 'OtroAlias', 'aa000000-0000-0000-0000-000000000002', 'javascript:alert(1)')$$,
    '23514',
    NULL,
    '14. video_url con esquema no https es rechazado (23514)'
);

SELECT * FROM finish();
ROLLBACK;
