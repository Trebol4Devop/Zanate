-- =============================================================================
-- Zanate · pgTAP Test: Suscripciones Marketplace Recurrente (ADR-007)
-- Archivo: supabase/tests/database/marketplace_subscriptions_test.sql
-- =============================================================================
begin;

select plan(18);

create extension if not exists pgtap;

reset role;
set role postgres;
select set_config('request.jwt.claims', '', true);
select set_config('request.jwt.claim.sub', '', true);
select set_config('request.jwt.claim.role', '', true);
select set_config('request.jwt.claim.email', '', true);

do $$
begin
    perform tests.create_supabase_user('61000000-0000-0000-0000-000000000001', 'sub_u1@test.com');
    perform tests.create_supabase_user('61000000-0000-0000-0000-000000000002', 'sub_u2@test.com');

    insert into public.profiles (id, carrera, is_verified)
    values
        ('61000000-0000-0000-0000-000000000001', 'sistemas', true),
        ('61000000-0000-0000-0000-000000000002', 'sistemas', true)
    on conflict (id) do update set is_verified = true;
end $$;

-- 1-3: Estructura de tablas y columnas nuevas
select has_column('public', 'marketplace_plans', 'recurrente_product_id', 'marketplace_plans tiene recurrente_product_id');
select has_column('public', 'marketplace_plans', 'recurrente_price_id', 'marketplace_plans tiene recurrente_price_id');
select has_table('public', 'marketplace_subscriptions', 'Tabla marketplace_subscriptions existe');
select has_table('public', 'recurrente_webhook_events', 'Tabla recurrente_webhook_events existe');

-- 5: service_role puede ejecutar billing_apply_subscription_event (hace upsert en seller_profiles aunque no exista fila previa)
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);

select lives_ok(
    $$select public.billing_apply_subscription_event(
        '61000000-0000-0000-0000-000000000001'::uuid,
        'pro_student',
        'sub_rec_001',
        'cus_rec_001',
        'active',
        now(),
        now() + interval '30 days',
        false,
        'sbx_test_1',
        false,
        'subscription.create'
    )$$,
    'service_role puede aplicar evento active y crear seller_profiles'
);

-- 6: Verifica que seller_profiles quedó sincronizado con pro_student
select is(
    (select plan_id from public.seller_profiles where user_id = '61000000-0000-0000-0000-000000000001'::uuid),
    'pro_student',
    'seller_profiles actualizado a pro_student'
);

-- 7: Idempotencia en recurrente_webhook_events (svix_id PK)
insert into public.recurrente_webhook_events (svix_id, event_type, sandbox_id, live_mode, payload, processing_status)
values ('msg_svix_1', 'subscription.create', 'sbx_test_1', false, '{"id":"sub_rec_001"}'::jsonb, 'processed');

select throws_ok(
    $$insert into public.recurrente_webhook_events (svix_id, event_type, payload)
      values ('msg_svix_1', 'subscription.create', '{}'::jsonb)$$,
    '23505',
    null,
    'svix_id duplicado es rechazado por PK'
);

-- 8: Índice único de 1 suscripción abierta por usuario
select throws_ok(
    $$insert into public.marketplace_subscriptions (user_id, plan_id, recurrente_subscription_id, status)
      values ('61000000-0000-0000-0000-000000000001'::uuid, 'business_local', 'sub_rec_manual_dup', 'active')$$,
    '23505',
    null,
    'No se permiten dos suscripciones abiertas simultáneas por vendedor'
);

-- 9-11: RLS para anon y authenticated
reset role;
set local role anon;
select set_config('request.jwt.claims', '{}', true);

select throws_ok(
    $$select * from public.marketplace_subscriptions$$,
    '42501',
    null,
    'anon no puede leer marketplace_subscriptions'
);

select throws_ok(
    $$select * from public.recurrente_webhook_events$$,
    '42501',
    null,
    'anon no puede leer recurrente_webhook_events'
);

reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', '61000000-0000-0000-0000-000000000001', true);
select set_config('request.jwt.claims', '{"sub":"61000000-0000-0000-0000-000000000001","role":"authenticated"}', true);

select is(
    (select count(*)::integer from public.marketplace_subscriptions),
    1,
    'authenticated ve su propia suscripción'
);

select is(
    (select plan_id from public.get_my_subscription()),
    'pro_student',
    'get_my_subscription devuelve el plan vigente del usuario autenticado'
);

select throws_ok(
    $$select * from public.recurrente_webhook_events$$,
    '42501',
    null,
    'authenticated no tiene acceso a recurrente_webhook_events'
);

-- Usuario 2 no ve suscripción de Usuario 1
select set_config('request.jwt.claim.sub', '61000000-0000-0000-0000-000000000002', true);
select set_config('request.jwt.claims', '{"sub":"61000000-0000-0000-0000-000000000002","role":"authenticated"}', true);

select is(
    (select count(*)::integer from public.marketplace_subscriptions),
    0,
    'authenticated no ve suscripciones de otros vendedores'
);

-- 15-16: Notificación past_due y degradación al cancelar inmediatamente
reset role;
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);

select lives_ok(
    $$select public.billing_apply_subscription_event(
        '61000000-0000-0000-0000-000000000001'::uuid,
        'pro_student',
        'sub_rec_001',
        'cus_rec_001',
        'past_due',
        now(),
        now() + interval '30 days',
        false,
        'sbx_test_1',
        false,
        'subscription.past_due'
    )$$,
    'past_due inserta notificación billing_past_due sin violar user_notifications_type_check'
);

-- Reintento del mismo past_due: la notificación no se duplica
select public.billing_apply_subscription_event(
    '61000000-0000-0000-0000-000000000001'::uuid,
    'pro_student',
    'sub_rec_001',
    'cus_rec_001',
    'past_due',
    now(),
    now() + interval '30 days',
    false,
    'sbx_test_1',
    false,
    'subscription.past_due'
);

select is(
    (select count(*)::integer from public.user_notifications
     where user_id = '61000000-0000-0000-0000-000000000001'::uuid
       and type = 'billing_past_due'),
    1,
    'past_due repetido no duplica la notificación billing_past_due'
);

-- Plan activo sin período explícito no queda con vigencia infinita
select public.billing_apply_subscription_event(
    '61000000-0000-0000-0000-000000000001'::uuid,
    'pro_student',
    'sub_rec_001',
    'cus_rec_001',
    'active',
    now(),
    null,
    false,
    'sbx_test_1',
    false,
    'subscription.create'
);

select ok(
    (select plan_expires_at is not null from public.seller_profiles
     where user_id = '61000000-0000-0000-0000-000000000001'::uuid),
    'active sin period_end conserva una vigencia no nula'
);

-- Crear 5 items disponibles (plan free permite máximo 3) y cancelar inmediatamente
reset role;
set role postgres;
select set_config('request.jwt.claims', '', true);
select set_config('request.jwt.claim.sub', '', true);
insert into public.marketplace_items (user_id, title, description, price, category, status)
select
    '61000000-0000-0000-0000-000000000001'::uuid,
    'Item prueba ' || gs,
    'Descripción válida de prueba para reconciliación',
    10.00,
    (select id from public.categorias_marketplace limit 1),
    'available'
from generate_series(1, 5) as gs;

set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);

select public.billing_apply_subscription_event(
    '61000000-0000-0000-0000-000000000001'::uuid,
    'pro_student',
    'sub_rec_001',
    'cus_rec_001',
    'cancelled',
    now() - interval '1 day',
    now(),
    false,
    'sbx_test_1',
    false,
    'subscription.cancel'
);

reset role;
set role postgres;
select is(
    (select count(*)::integer from public.marketplace_items
     where user_id = '61000000-0000-0000-0000-000000000001'::uuid and status = 'available'),
    3,
    'Al cancelar inmediatamente, reconcile_seller_plan_limits pausa excedente a máximo 3 items del plan free'
);

select * from finish();
rollback;
