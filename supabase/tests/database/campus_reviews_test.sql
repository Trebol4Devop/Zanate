-- =============================================================================
-- pgTAP: contrato de reseñas del campus (esquema real de producción)
-- Cubre: tablas, restricciones, RLS y recálculo de agregados por trigger.
-- =============================================================================
begin;

select plan(11);

create extension if not exists pgtap;

-- 1) Tablas del módulo
select has_table('public', 'campus_reviews', 'campus_reviews existe');
select has_table('public', 'campus_rating_aggregates', 'campus_rating_aggregates existe');
select has_table('public', 'campus_review_reactions', 'campus_review_reactions existe');

-- 2) Restricciones de unicidad y validez
select col_type_is('public', 'campus_reviews', 'target_id', 'text', 'target_id es text');
select col_not_null('public', 'campus_reviews', 'user_id', 'user_id es obligatorio');

select ok(
    exists (
        select 1 from pg_constraint
        where conname = 'uq_user_target_review'
          and conrelid = 'public.campus_reviews'::regclass
    ),
    'existe la restricción única (user_id, target_id) para el upsert'
);

-- 3) RPC con pseudónimos
select ok(
    exists (
        select 1 from pg_proc p
        join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public'
          and p.proname = 'get_target_reviews_with_authors'
          and pg_get_function_identity_arguments(p.oid) = 'p_target_id text, p_limit integer, p_offset integer'
    ),
    'existe el RPC get_target_reviews_with_authors(text, integer, integer)'
);

-- 4) RLS habilitado
select ok(
    (select relrowsecurity from pg_class where oid = 'public.campus_reviews'::regclass),
    'RLS habilitado en campus_reviews'
);
select ok(
    (select relrowsecurity from pg_class where oid = 'public.campus_rating_aggregates'::regclass),
    'RLS habilitado en campus_rating_aggregates'
);

-- 5) El trigger recalcula agregados (fixture aislado dentro de la transacción)
select tests.create_supabase_user('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb');

insert into public.campus_reviews (
    id, target_id, target_type, target_category, user_id, rating, comment, moderation_status
) values (
    'cccccccc-cccc-cccc-cccc-cccccccccccc',
    'building-test-trigger',
    'building',
    'general',
    'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
    4,
    'Reseña de prueba del trigger de agregados',
    1
);

select is(
    (select total_reviews from public.campus_rating_aggregates where target_id = 'building-test-trigger'),
    1,
    'el trigger crea el agregado con total_reviews = 1'
);

update public.campus_reviews
   set moderation_status = 2
 where id = 'cccccccc-cccc-cccc-cccc-cccccccccccc';

select is(
    (select total_reviews from public.campus_rating_aggregates where target_id = 'building-test-trigger'),
    0,
    'el agregado ignora reseñas ocultas (moderation_status = 2)'
);

select * from finish();
rollback;
