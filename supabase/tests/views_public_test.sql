-- =============================================================================
-- Zanate · pgTAP Test: Vistas Públicas y Seguras (moderation_status 0, 1, 3 vs 2)
-- =============================================================================
begin;

select plan(38);

create extension if not exists pgtap;

set role postgres;

-- -----------------------------------------------------------------------------
-- Fixtures
-- -----------------------------------------------------------------------------
do $$
declare
    v_user_a uuid := '11111111-1111-1111-1111-111111111111';
    v_user_b uuid := '22222222-2222-2222-2222-222222222222';
    v_hash_a text;
    v_hash_b text;
    v_post_id uuid := '80000000-0000-0000-0000-000000000001';
    v_post_blocked uuid := '80000000-0000-0000-0000-000000000002';
    v_post_approved uuid := '80000000-0000-0000-0000-000000000003';
    v_post_review uuid := '80000000-0000-0000-0000-000000000004';
begin
    perform tests.create_supabase_user(v_user_a, 'user_a@test.com');
    perform tests.create_supabase_user(v_user_b, 'user_b@test.com');

    v_hash_a := public.generate_author_hash(v_user_a);
    v_hash_b := public.generate_author_hash(v_user_b);

    -- 1. Posts con distintos estados de moderación (0: pendiente, 1: aprobado, 2: bloqueado, 3: revisión)
    insert into public.posts (
        id, user_id, title, content, category, carrera, author_alias, author_hash, moderation_status
    ) values (
        v_post_id, v_user_a, 'Post de Discusion Hash', 'Contenido visible pendiente', 'general', 'sistemas', 'Compilador Desvelado', v_hash_a, 0
    ) on conflict (id) do nothing;

    insert into public.posts (
        id, user_id, title, content, category, carrera, author_alias, author_hash, moderation_status
    ) values (
        v_post_blocked, v_user_a, 'Post Bloqueado Oculto', 'Censurado', 'general', 'sistemas', 'Compilador Desvelado', v_hash_a, 2
    ) on conflict (id) do nothing;

    insert into public.posts (
        id, user_id, title, content, category, carrera, author_alias, author_hash, moderation_status
    ) values (
        v_post_approved, v_user_a, 'Post Aprobado Valido', 'Aprobado por moderacion', 'general', 'sistemas', 'Compilador Desvelado', v_hash_a, 1
    ) on conflict (id) do nothing;

    insert into public.posts (
        id, user_id, title, content, category, carrera, author_alias, author_hash, moderation_status
    ) values (
        v_post_review, v_user_a, 'Post En Revision', 'En revision humana preliminar', 'general', 'sistemas', 'Compilador Desvelado', v_hash_a, 3
    ) on conflict (id) do nothing;

    -- 2. Comentarios asociados a Post 1 (conserva comment_count = 2 para Tests 1 y 13)
    -- C1: moderation_status = 0 (Usuario A)
    insert into public.comments (
        id, post_id, user_id, content, author_alias, author_hash, moderation_status
    ) values (
        '90000000-0000-0000-0000-000000000001', v_post_id, v_user_a, 'Respuesta del autor original', 'Compilador Desvelado', v_hash_a, 0
    ) on conflict (id) do nothing;

    -- C2: moderation_status = 0 (Usuario B)
    insert into public.comments (
        id, post_id, user_id, content, author_alias, author_hash, moderation_status
    ) values (
        '90000000-0000-0000-0000-000000000002', v_post_id, v_user_b, 'Aporte de companero B', 'Puntero Nocturno', v_hash_b, 0
    ) on conflict (id) do nothing;

    -- C3: moderation_status = 2 (Usuario B, bloqueado)
    insert into public.comments (
        id, post_id, user_id, content, author_alias, author_hash, moderation_status
    ) values (
        '90000000-0000-0000-0000-000000000003', v_post_id, v_user_b, 'Comentario con spam bloqueado', 'Puntero Nocturno', v_hash_b, 2
    ) on conflict (id) do nothing;

    -- Comentarios asociados al Post Aprobado (v_post_approved)
    -- C4: moderation_status = 1 (aprobado)
    insert into public.comments (
        id, post_id, user_id, content, author_alias, author_hash, moderation_status
    ) values (
        '90000000-0000-0000-0000-000000000004', v_post_approved, v_user_b, 'Comentario aprobado valido', 'Puntero Nocturno', v_hash_b, 1
    ) on conflict (id) do nothing;

    -- C5: moderation_status = 3 (revisión humana)
    insert into public.comments (
        id, post_id, user_id, content, author_alias, author_hash, moderation_status
    ) values (
        '90000000-0000-0000-0000-000000000005', v_post_approved, v_user_b, 'Comentario en revision', 'Puntero Nocturno', v_hash_b, 3
    ) on conflict (id) do nothing;

    -- C6: moderation_status = 2 (bloqueado)
    insert into public.comments (
        id, post_id, user_id, content, author_alias, author_hash, moderation_status
    ) values (
        '90000000-0000-0000-0000-000000000006', v_post_approved, v_user_b, 'Comentario ofensivo bloqueado', 'Puntero Nocturno', v_hash_b, 2
    ) on conflict (id) do nothing;

    -- 3. Grupos estudiantiles (student_groups) de Usuario A
    insert into public.student_groups (
        id, user_id, title, description, carrera, curso, section, link, author_alias, moderation_status
    ) values
        ('70000000-0000-0000-0000-000000000001', v_user_a, 'Grupo Pendiente', 'Desc', 'sistemas', 'Curso A', 'A', 'https://chat.whatsapp.com/g0', 'Compilador Desvelado', 0),
        ('70000000-0000-0000-0000-000000000002', v_user_a, 'Grupo Aprobado', 'Desc', 'sistemas', 'Curso B', 'B', 'https://chat.whatsapp.com/g1', 'Compilador Desvelado', 1),
        ('70000000-0000-0000-0000-000000000003', v_user_a, 'Grupo Bloqueado', 'Desc', 'sistemas', 'Curso C', 'C', 'https://chat.whatsapp.com/g2', 'Compilador Desvelado', 2),
        ('70000000-0000-0000-0000-000000000004', v_user_a, 'Grupo En Revision', 'Desc', 'sistemas', 'Curso D', 'D', 'https://chat.whatsapp.com/g3', 'Compilador Desvelado', 3)
    on conflict (id) do nothing;

    -- 4. Artículos de marketplace (marketplace_items) de Usuario A
    insert into public.marketplace_items (
        id, user_id, title, description, price, is_free, category, facultad, status, moderation_status, author_alias
    ) values
        ('60000000-0000-0000-0000-000000000001', v_user_a, 'Item Pendiente', 'Desc', 50.0, false, 'otros_articulos', '08', 'available', 0, 'Compilador Desvelado'),
        ('60000000-0000-0000-0000-000000000002', v_user_a, 'Item Aprobado', 'Desc', 60.0, false, 'otros_articulos', '08', 'available', 1, 'Compilador Desvelado'),
        ('60000000-0000-0000-0000-000000000003', v_user_a, 'Item Bloqueado', 'Desc', 70.0, false, 'otros_articulos', '08', 'available', 2, 'Compilador Desvelado'),
        ('60000000-0000-0000-0000-000000000004', v_user_a, 'Item En Revision', 'Desc', 80.0, false, 'otros_articulos', '08', 'available', 3, 'Compilador Desvelado')
    on conflict (id) do nothing;
end $$;

-- -----------------------------------------------------------------------------
-- Bloque 1: Perspectiva de Usuario A (autor de posts y comentarios 1)
-- -----------------------------------------------------------------------------
select tests.authenticate_as('11111111-1111-1111-1111-111111111111');

-- Test 1: comment_count excluye comentarios bloqueados (cuenta 2, excluye C3)
select is(
    (select comment_count from public.v_public_posts where id = '80000000-0000-0000-0000-000000000001'),
    2,
    'v_public_posts calcula comment_count ignorando comentarios con moderation_status = 2'
);

-- Test 2: is_my_post es true para el autor del post
select is(
    (select is_my_post from public.v_public_posts where id = '80000000-0000-0000-0000-000000000001'),
    true,
    'v_public_posts marca is_my_post = true cuando el author_hash coincide con la sesion del autor'
);

-- Test 3: post con moderation_status = 2 queda excluido de la vista
select is(
    (select count(*)::integer from public.v_public_posts where id = '80000000-0000-0000-0000-000000000002'),
    0,
    'v_public_posts filtra posts con moderation_status = 2'
);

-- Test 4: is_post_author es true para C1 (mismo hash que el post)
select is(
    (select is_post_author from public.v_public_comments where id = '90000000-0000-0000-0000-000000000001'),
    true,
    'v_public_comments marca is_post_author = true cuando author_hash del comentario coincide con el post'
);

-- Test 5: is_my_comment es true para C1 desde la sesión de Usuario A
select is(
    (select is_my_comment from public.v_public_comments where id = '90000000-0000-0000-0000-000000000001'),
    true,
    'v_public_comments marca is_my_comment = true para comentarios propios de Usuario A'
);

-- Test 6: is_post_author es false para C2 (hash de Usuario B)
select is(
    (select is_post_author from public.v_public_comments where id = '90000000-0000-0000-0000-000000000002'),
    false,
    'v_public_comments marca is_post_author = false cuando el comentario es de otro usuario'
);

-- Test 7: is_my_comment es false para C2 desde la sesión de Usuario A
select is(
    (select is_my_comment from public.v_public_comments where id = '90000000-0000-0000-0000-000000000002'),
    false,
    'v_public_comments marca is_my_comment = false para comentarios ajenos'
);

-- Test 8: C3 (bloqueado) queda excluido de v_public_comments
select is(
    (select count(*)::integer from public.v_public_comments where id = '90000000-0000-0000-0000-000000000003'),
    0,
    'v_public_comments excluye comentarios con moderation_status = 2'
);

-- Test 9: Usuario A ve su propio grupo bloqueado en safe_student_groups (is_mine = true)
select is(
    (select count(*)::integer from public.safe_student_groups where id = '70000000-0000-0000-0000-000000000003'),
    1,
    'safe_student_groups permite al autor ver su propio grupo bloqueado'
);

-- Test 10: Usuario A ve su propio marketplace item bloqueado en safe_marketplace_items (is_mine = true)
select is(
    (select count(*)::integer from public.safe_marketplace_items where id = '60000000-0000-0000-0000-000000000003'),
    1,
    'safe_marketplace_items permite al autor ver su propio item bloqueado'
);

-- -----------------------------------------------------------------------------
-- Bloque 2: Perspectiva de Usuario B (no autor de las publicaciones/grupos de A)
-- -----------------------------------------------------------------------------
select tests.authenticate_as('22222222-2222-2222-2222-222222222222');

-- Test 11: is_my_post es false para Usuario B sobre el post de Usuario A
select is(
    (select is_my_post from public.v_public_posts where id = '80000000-0000-0000-0000-000000000001'),
    false,
    'v_public_posts marca is_my_post = false para usuarios que no crearon el post'
);

-- Test 12: is_my_comment es true para C2 desde la sesión de Usuario B
select is(
    (select is_my_comment from public.v_public_comments where id = '90000000-0000-0000-0000-000000000002'),
    true,
    'v_public_comments marca is_my_comment = true para el autor del comentario C2'
);

-- Test 13: is_my_comment es false para C1 desde la sesión de Usuario B
select is(
    (select is_my_comment from public.v_public_comments where id = '90000000-0000-0000-0000-000000000001'),
    false,
    'v_public_comments marca is_my_comment = false para C1 visto por Usuario B'
);

-- Test 14: Usuario B ve post con moderation_status = 1 (aprobado) en safe_posts_feed
select is(
    (select count(*)::integer from public.safe_posts_feed where id = '80000000-0000-0000-0000-000000000003'),
    1,
    'safe_posts_feed muestra posts con moderation_status = 1 (aprobado) a otros usuarios'
);

-- Test 15: Usuario B ve post con moderation_status = 3 (revisión humana) en safe_posts_feed
select is(
    (select count(*)::integer from public.safe_posts_feed where id = '80000000-0000-0000-0000-000000000004'),
    1,
    'safe_posts_feed muestra posts con moderation_status = 3 (revisión) a otros usuarios'
);

-- Test 16: Usuario B NO ve post con moderation_status = 2 (bloqueado) en safe_posts_feed
select is(
    (select count(*)::integer from public.safe_posts_feed where id = '80000000-0000-0000-0000-000000000002'),
    0,
    'safe_posts_feed oculta posts con moderation_status = 2 a otros usuarios'
);

-- Test 17: Usuario B ve comentario con moderation_status = 1 (aprobado) en safe_comments
select is(
    (select count(*)::integer from public.safe_comments where id = '90000000-0000-0000-0000-000000000004'),
    1,
    'safe_comments muestra comentarios con moderation_status = 1'
);

-- Test 18: Usuario B ve comentario con moderation_status = 3 (revisión) en safe_comments
select is(
    (select count(*)::integer from public.safe_comments where id = '90000000-0000-0000-0000-000000000005'),
    1,
    'safe_comments muestra comentarios con moderation_status = 3'
);

-- Test 19: Usuario B NO ve comentario con moderation_status = 2 (bloqueado) en safe_comments
select is(
    (select count(*)::integer from public.safe_comments where id = '90000000-0000-0000-0000-000000000006'),
    0,
    'safe_comments oculta comentarios con moderation_status = 2'
);

-- Test 20: Usuario B ve grupo con moderation_status = 1 en safe_student_groups
select is(
    (select count(*)::integer from public.safe_student_groups where id = '70000000-0000-0000-0000-000000000002'),
    1,
    'safe_student_groups muestra grupos con moderation_status = 1 a no autores'
);

-- Test 21: Usuario B ve grupo con moderation_status = 3 en safe_student_groups
select is(
    (select count(*)::integer from public.safe_student_groups where id = '70000000-0000-0000-0000-000000000004'),
    1,
    'safe_student_groups muestra grupos con moderation_status = 3 a no autores'
);

-- Test 22: Usuario B NO ve grupo con moderation_status = 2 en safe_student_groups (no autor)
select is(
    (select count(*)::integer from public.safe_student_groups where id = '70000000-0000-0000-0000-000000000003'),
    0,
    'safe_student_groups oculta grupos con moderation_status = 2 a no autores'
);

-- Test 23: Usuario B ve marketplace item con moderation_status = 1 en safe_marketplace_items
select is(
    (select count(*)::integer from public.safe_marketplace_items where id = '60000000-0000-0000-0000-000000000002'),
    1,
    'safe_marketplace_items muestra items con moderation_status = 1 a no autores'
);

-- Test 24: Usuario B ve marketplace item con moderation_status = 3 en safe_marketplace_items
select is(
    (select count(*)::integer from public.safe_marketplace_items where id = '60000000-0000-0000-0000-000000000004'),
    1,
    'safe_marketplace_items muestra items con moderation_status = 3 a no autores'
);

-- Test 25: Usuario B NO ve marketplace item con moderation_status = 2 en safe_marketplace_items (no autor)
select is(
    (select count(*)::integer from public.safe_marketplace_items where id = '60000000-0000-0000-0000-000000000003'),
    0,
    'safe_marketplace_items oculta items con moderation_status = 2 a no autores'
);

-- -----------------------------------------------------------------------------
-- Bloque 3: Perspectiva anon (visitante público)
-- -----------------------------------------------------------------------------
select tests.authenticate_as_anon();

-- Test 26: is_my_post es siempre false para anon
select is(
    (select is_my_post from public.v_public_posts where id = '80000000-0000-0000-0000-000000000001'),
    false,
    'v_public_posts devuelve is_my_post = false para anon sin romper la consulta'
);

-- Test 27: comment_count es visible y correcto para anon (2 visibles, excluye C3 bloqueado)
select is(
    (select comment_count from public.v_public_posts where id = '80000000-0000-0000-0000-000000000001'),
    2,
    'v_public_posts calcula comment_count de forma consistente para visitantes publicos'
);

-- Test 28: is_my_comment es siempre false para anon
select is(
    (select is_my_comment from public.v_public_comments where id = '90000000-0000-0000-0000-000000000001'),
    false,
    'v_public_comments devuelve is_my_comment = false para sesiones anonimas'
);

-- Test 29: Anon ve post con moderation_status = 1 en safe_posts_feed
select is(
    (select count(*)::integer from public.safe_posts_feed where id = '80000000-0000-0000-0000-000000000003'),
    1,
    'Anon ve posts aprobados (moderation_status = 1)'
);

-- Test 30: Anon ve post con moderation_status = 3 en safe_posts_feed
select is(
    (select count(*)::integer from public.safe_posts_feed where id = '80000000-0000-0000-0000-000000000004'),
    1,
    'Anon ve posts en revisión humana (moderation_status = 3)'
);

-- Test 31: Anon NO ve post con moderation_status = 2 en safe_posts_feed
select is(
    (select count(*)::integer from public.safe_posts_feed where id = '80000000-0000-0000-0000-000000000002'),
    0,
    'Anon no ve posts con moderation_status = 2'
);

-- Test 32: Anon ve comentario con moderation_status = 1
select is(
    (select count(*)::integer from public.safe_comments where id = '90000000-0000-0000-0000-000000000004'),
    1,
    'Anon ve comentarios con moderation_status = 1'
);

-- Test 33: Anon ve comentario con moderation_status = 3
select is(
    (select count(*)::integer from public.safe_comments where id = '90000000-0000-0000-0000-000000000005'),
    1,
    'Anon ve comentarios con moderation_status = 3'
);

-- Test 34: Anon NO ve comentario con moderation_status = 2
select is(
    (select count(*)::integer from public.safe_comments where id = '90000000-0000-0000-0000-000000000006'),
    0,
    'Anon no ve comentarios con moderation_status = 2'
);

-- Test 35: Anon ve grupos estudiantiles con status 1 y 3
select is(
    (select count(*)::integer from public.safe_student_groups where id in ('70000000-0000-0000-0000-000000000002', '70000000-0000-0000-0000-000000000004')),
    2,
    'Anon ve grupos estudiantiles con status 1 y 3'
);

-- Test 36: Anon no ve grupos estudiantiles con status 2
select is(
    (select count(*)::integer from public.safe_student_groups where id = '70000000-0000-0000-0000-000000000003'),
    0,
    'Anon no ve grupos estudiantiles con moderation_status = 2'
);

-- Test 37: Anon ve marketplace items con status 1 y 3
select is(
    (select count(*)::integer from public.safe_marketplace_items where id in ('60000000-0000-0000-0000-000000000002', '60000000-0000-0000-0000-000000000004')),
    2,
    'Anon ve marketplace items con status 1 y 3'
);

-- Test 38: Anon no ve marketplace items con status 2
select is(
    (select count(*)::integer from public.safe_marketplace_items where id = '60000000-0000-0000-0000-000000000003'),
    0,
    'Anon no ve marketplace items con moderation_status = 2'
);

select * from finish();
rollback;
