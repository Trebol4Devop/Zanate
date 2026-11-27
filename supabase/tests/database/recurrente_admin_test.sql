-- =============================================================================
-- PEMTREE / Zanate · pgTAP Test: Backend administrativo de Recurrente
-- Archivo: supabase/tests/database/recurrente_admin_test.sql
-- Migración objetivo: 20261127020000_recurrente_admin_backend.sql
--
-- Cobertura:
--   * Control de acceso (anon, authenticated no-staff, moderador, admin).
--   * admin_list_marketplace_subscriptions: filtros, búsqueda y orden abierto-primero.
--   * admin_get_marketplace_subscription: detalle JSON, prioridad y validaciones.
--   * admin_list_recurrente_webhook_events: aislamiento RLS + extracción de IDs.
--   * admin_list_marketplace_plans y admin_upsert_marketplace_plan con mapeo Recurrente.
--
-- Fixtures con prefijo 55... para no colisionar con otras suites.
-- =============================================================================
begin;

select plan(34);

create extension if not exists pgtap;

reset role;
set role postgres;
select set_config('request.jwt.claims', '', true);
select set_config('request.jwt.claim.sub', '', true);
select set_config('request.jwt.claim.role', '', true);
select set_config('request.jwt.claim.email', '', true);

-- -----------------------------------------------------------------------------
-- Fixtures (prefijo 55...)
-- -----------------------------------------------------------------------------
do $$
begin
    perform tests.create_supabase_user('55000000-0000-0000-0000-000000000001', 'u01_recadm@test.com');
    perform tests.create_supabase_user('55000000-0000-0000-0000-000000000002', 'u02_recadm@test.com');
    perform tests.create_supabase_user('55000000-0000-0000-0000-000000000003', 'vendedor55_alpha@test.com');
    perform tests.create_supabase_user('55000000-0000-0000-0000-000000000004', 'vendedor55_beta@test.com');
    perform tests.create_supabase_user('55000000-0000-0000-0000-000000000005', 'u05_nostaff@test.com');

    insert into public.profiles (id, carrera, is_verified, alias)
    values
        ('55000000-0000-0000-0000-000000000003', 'sistemas', true, 'Ana López'),
        ('55000000-0000-0000-0000-000000000004', 'sistemas', false, 'Carlos Méndez'),
        ('55000000-0000-0000-0000-000000000005', 'sistemas', true, 'NoStaff')
    on conflict (id) do update set
        carrera = excluded.carrera,
        is_verified = excluded.is_verified,
        alias = excluded.alias;

    insert into public.seller_profiles (
        user_id, plan_id, seller_type, verification_status, business_name, plan_expires_at
    ) values
        (
            '55000000-0000-0000-0000-000000000003',
            'pro_student',
            'student',
            'approved',
            'Librería Ingeniería 55',
            now() + interval '25 days'
        ),
        (
            '55000000-0000-0000-0000-000000000004',
            'business_local',
            'local_business',
            'approved',
            'Cafetería Campus 55',
            now() + interval '10 days'
        )
    on conflict (user_id) do update set
        plan_id = excluded.plan_id,
        seller_type = excluded.seller_type,
        verification_status = excluded.verification_status,
        business_name = excluded.business_name,
        plan_expires_at = excluded.plan_expires_at;

    -- Suscripciones: una cancelada más reciente en updated_at y dos abiertas
    insert into public.marketplace_subscriptions (
        id, user_id, plan_id, recurrente_customer_id, recurrente_subscription_id,
        status, current_period_start, current_period_end, cancel_at_period_end,
        sandbox_id, live_mode, created_at, updated_at
    ) values
        (
            '55000000-0000-0000-0000-000000000201',
            '55000000-0000-0000-0000-000000000003',
            'pro_student',
            'cus_55_old',
            'sub_55_cancelled',
            'cancelled',
            now() - interval '60 days',
            now() - interval '30 days',
            false,
            'sbx_55',
            false,
            now() - interval '60 days',
            now()
        ),
        (
            '55000000-0000-0000-0000-000000000202',
            '55000000-0000-0000-0000-000000000003',
            'pro_student',
            'cus_55_alpha',
            'sub_55_active',
            'active',
            now() - interval '5 days',
            now() + interval '25 days',
            false,
            'sbx_55',
            false,
            now() - interval '5 days',
            now() - interval '2 days'
        ),
        (
            '55000000-0000-0000-0000-000000000203',
            '55000000-0000-0000-0000-000000000004',
            'business_local',
            'cus_55_beta',
            'sub_55_pastdue',
            'past_due',
            now() - interval '20 days',
            now() + interval '10 days',
            true,
            null,
            true,
            now() - interval '20 days',
            now() - interval '1 day'
        )
    on conflict (recurrente_subscription_id) do nothing;

    -- Webhooks Svix cubriendo las 3 variantes de payload
    insert into public.recurrente_webhook_events (
        svix_id, event_type, sandbox_id, live_mode, processing_status,
        error_message, received_at, processed_at, payload
    ) values
        (
            'msg_55_sub',
            'subscription.created',
            'sbx_55',
            false,
            'processed',
            null,
            now() - interval '3 hours',
            now() - interval '3 hours',
            jsonb_build_object(
                'id', 'sub_55_active',
                'metadata', jsonb_build_object(
                    'user_id', '55000000-0000-0000-0000-000000000003',
                    'plan_id', 'pro_student'
                )
            )
        ),
        (
            'msg_55_chk',
            'checkout.completed',
            'sbx_55',
            false,
            'ignored',
            null,
            now() - interval '2 hours',
            now() - interval '2 hours',
            jsonb_build_object(
                'checkout', jsonb_build_object(
                    'metadata', jsonb_build_object(
                        'user_id', '55000000-0000-0000-0000-000000000004',
                        'plan_id', 'business_local'
                    )
                ),
                'subscription', jsonb_build_object('id', 'sub_55_from_chk')
            )
        ),
        (
            'msg_55_pay',
            'payment_intent.failed',
            null,
            true,
            'failed',
            'Timeout al consultar Recurrente',
            now() - interval '1 hour',
            null,
            jsonb_build_object(
                'payment', jsonb_build_object(
                    'paymentable', jsonb_build_object(
                        'id', 'sub_55_pastdue',
                        'metadata', jsonb_build_object(
                            'user_id', '55000000-0000-0000-0000-000000000004',
                            'plan_id', 'business_local'
                        )
                    )
                )
            )
        )
    on conflict (svix_id) do nothing;
end $$;

-- =============================================================================
-- 1) anon no puede ejecutar ninguna RPC nueva ni consultar planes admin
-- =============================================================================

select tests.authenticate_as_anon();

select throws_ok(
    $$select * from public.admin_list_marketplace_subscriptions()$$,
    '42501',
    null,
    '1. anon no puede ejecutar admin_list_marketplace_subscriptions (42501)'
);

select throws_ok(
    $$select public.admin_get_marketplace_subscription('55000000-0000-0000-0000-000000000003')$$,
    '42501',
    null,
    '2. anon no puede ejecutar admin_get_marketplace_subscription (42501)'
);

select throws_ok(
    $$select * from public.admin_list_recurrente_webhook_events()$$,
    '42501',
    null,
    '3. anon no puede ejecutar admin_list_recurrente_webhook_events (42501)'
);

select throws_ok(
    $$select * from public.admin_list_marketplace_plans()$$,
    '42501',
    null,
    '4. anon no puede ejecutar admin_list_marketplace_plans (42501)'
);

-- =============================================================================
-- 2) Usuario autenticado sin rol de staff no puede acceder
-- =============================================================================

select tests.authenticate_as('55000000-0000-0000-0000-000000000005');

select throws_ok(
    $$select * from public.admin_list_marketplace_subscriptions()$$,
    '42501',
    null,
    '5. usuario sin staff no puede listar suscripciones (42501)'
);

select throws_ok(
    $$select public.admin_get_marketplace_subscription('55000000-0000-0000-0000-000000000003')$$,
    '42501',
    null,
    '6. usuario sin staff no puede ver detalle de suscripción (42501)'
);

select throws_ok(
    $$select * from public.admin_list_recurrente_webhook_events()$$,
    '42501',
    null,
    '7. usuario sin staff no puede listar webhooks (42501)'
);

select throws_ok(
    $$select * from public.recurrente_webhook_events$$,
    '42501',
    null,
    '8. authenticated no puede leer recurrente_webhook_events directamente (42501)'
);

-- =============================================================================
-- 3) Moderador puede listar suscripciones, ver detalle y listar webhooks
-- =============================================================================

select tests.authenticate_as_moderator('55000000-0000-0000-0000-000000000002');

select ok(
    (select count(*) from public.admin_list_marketplace_subscriptions('55_')) >= 3,
    '9. moderador puede listar suscripciones'
);

select ok(
    (select count(*) from public.admin_list_recurrente_webhook_events(null, 'msg_55_')) = 3,
    '10. moderador puede listar webhooks a través del RPC'
);

select throws_ok(
    $$select * from public.recurrente_webhook_events$$,
    '42501',
    null,
    '11. ni siquiera el staff tiene acceso directo a la tabla recurrente_webhook_events (42501)'
);

select throws_ok(
    $$select public.admin_upsert_marketplace_plan('{"id":"test_rec55","name":"Plan Mod"}'::jsonb)$$,
    '42501',
    null,
    '12. moderador no puede modificar planes (42501)'
);

-- =============================================================================
-- 4) Admin: listados, filtros, búsqueda, orden y detalle
-- =============================================================================

select tests.authenticate_as_admin('55000000-0000-0000-0000-000000000001');

select is(
    (select array_agg(recurrente_subscription_id)
     from public.admin_list_marketplace_subscriptions('sub_55_', 'all')),
    array['sub_55_pastdue', 'sub_55_active', 'sub_55_cancelled']::text[],
    '13. suscripciones abiertas se ordenan primero y luego por updated_at DESC'
);

select is(
    (select count(*)::integer
     from public.admin_list_marketplace_subscriptions('sub_55_', 'past_due')),
    1,
    '14. filtro p_status = past_due filtra correctamente'
);

select throws_ok(
    $$select * from public.admin_list_marketplace_subscriptions(null, 'invalido')$$,
    '22023',
    null,
    '15. p_status inválido en suscripciones lanza 22023'
);

select is(
    (select count(*)::integer
     from public.admin_list_marketplace_subscriptions('Librería Ingeniería 55')),
    2,
    '16. p_search busca por business_name'
);

select is(
    (select recurrente_subscription_id
     from public.admin_list_marketplace_subscriptions('cus_55_beta')),
    'sub_55_pastdue',
    '17. p_search busca por recurrente_customer_id'
);

select is(
    (select recurrente_subscription_id
     from public.admin_list_marketplace_subscriptions('Carlos Méndez')
     limit 1),
    'sub_55_pastdue',
    '18. p_search busca por alias del perfil'
);

select is(
    (select count(*)::integer
     from public.admin_list_marketplace_subscriptions('vendedor55_alpha@test.com')),
    2,
    '19. p_search busca por email de auth.users'
);

select is(
    (select recurrente_subscription_id
     from public.admin_list_marketplace_subscriptions('55000000-0000-0000-0000-000000000004')
     limit 1),
    'sub_55_pastdue',
    '20. p_search busca por UUID de usuario'
);

-- Detalle de suscripción
select throws_ok(
    $$select public.admin_get_marketplace_subscription(null, null)$$,
    '22023',
    null,
    '21. admin_get_marketplace_subscription exige al menos un parámetro (22023)'
);

select is(
    public.admin_get_marketplace_subscription('55000000-0000-0000-0000-000000000099', null),
    null::jsonb,
    '22. admin_get_marketplace_subscription devuelve NULL si no existe'
);

select ok(
    (
        select (d ? 'subscription')
           and (d ? 'seller')
           and (d ? 'plan')
           and (d -> 'subscription' ->> 'recurrente_subscription_id') = 'sub_55_active'
           and (d -> 'seller' ->> 'email') = 'vendedor55_alpha@test.com'
           and (d -> 'seller' ->> 'full_name') = 'Ana López'
           and (d -> 'seller' ->> 'effective_plan_id') = 'pro_student'
           and (d -> 'seller' ->> 'is_verified')::boolean = true
           and (d -> 'plan' ->> 'id') = 'pro_student'
           and (d -> 'plan' ? 'price_monthly')
        from (
            select public.admin_get_marketplace_subscription('55000000-0000-0000-0000-000000000003') as d
        ) s
    ),
    '23. admin_get_marketplace_subscription devuelve subscription, seller y plan completos'
);

select is(
    (public.admin_get_marketplace_subscription(
        '55000000-0000-0000-0000-000000000003',
        'sub_55_cancelled'
    ) -> 'subscription' ->> 'recurrente_subscription_id'),
    'sub_55_cancelled',
    '24. admin_get_marketplace_subscription prioriza p_recurrente_subscription_id si ambos vienen'
);

-- =============================================================================
-- 5) Webhooks: filtros, búsqueda y extracción de payload
-- =============================================================================

select throws_ok(
    $$select * from public.admin_list_recurrente_webhook_events('otro')$$,
    '22023',
    null,
    '25. p_status inválido en webhooks lanza 22023'
);

select results_eq(
    $$select svix_id, payload_user_id, payload_plan_id, payload_subscription_id
      from public.admin_list_recurrente_webhook_events('all', 'msg_55_')
      order by received_at desc$$,
    $$values
        ('msg_55_pay'::text, '55000000-0000-0000-0000-000000000004'::text, 'business_local'::text, 'sub_55_pastdue'::text),
        ('msg_55_chk'::text, '55000000-0000-0000-0000-000000000004'::text, 'business_local'::text, 'sub_55_from_chk'::text),
        ('msg_55_sub'::text, '55000000-0000-0000-0000-000000000003'::text, 'pro_student'::text,    'sub_55_active'::text)$$,
    '26. admin_list_recurrente_webhook_events extrae user_id, plan_id y subscription_id en las 3 variantes'
);

select is(
    (select svix_id
     from public.admin_list_recurrente_webhook_events('failed', 'Timeout')),
    'msg_55_pay',
    '27. filtro p_status y p_search por error_message funcionan en webhooks'
);

select is(
    (select svix_id
     from public.admin_list_recurrente_webhook_events(null, 'sub_55_from_chk')),
    'msg_55_chk',
    '28. p_search encuentra webhooks por payload_subscription_id extraído'
);

-- =============================================================================
-- 6) Planes y mapeo de Recurrente
-- =============================================================================

select ok(
    exists (
        select 1
        from information_schema.columns
        where table_schema = 'public' and table_name = 'marketplace_plans'
    ) and (
        select pg_typeof(recurrente_product_id)::text || ',' || pg_typeof(recurrente_price_id)::text
        from public.admin_list_marketplace_plans()
        limit 1
    ) = 'text,text',
    '29. admin_list_marketplace_plans devuelve las dos columnas nuevas recurrente_product_id y recurrente_price_id'
);

select lives_ok(
    $$select public.admin_upsert_marketplace_plan(
        '{"id":"test_rec55","name":"Plan Recurrente 55","price_monthly":49.5,
          "recurrente_product_id":"  prod_rec_55  ","recurrente_price_id":"  price_rec_55  "}'::jsonb
    )$$,
    '30. admin guarda recurrente_product_id y recurrente_price_id haciendo trim'
);

select results_eq(
    $$select recurrente_product_id, recurrente_price_id
      from public.admin_list_marketplace_plans()
      where id = 'test_rec55'$$,
    $$values ('prod_rec_55'::text, 'price_rec_55'::text)$$,
    '31. admin_list_marketplace_plans refleja los IDs guardados sin espacios'
);

select throws_ok(
    $$select public.admin_upsert_marketplace_plan(
        jsonb_build_object(
            'id', 'test_rec55',
            'recurrente_product_id', repeat('p', 81)
        )
    )$$,
    '23514',
    null,
    '32. recurrente_product_id mayor a 80 caracteres es rechazado (23514)'
);

select lives_ok(
    $$select public.admin_upsert_marketplace_plan(
        '{"id":"free","recurrente_product_id":"prod_no_debe","recurrente_price_id":"price_no_debe"}'::jsonb
    )$$,
    '33. admin puede actualizar free y fuerza mapeo Recurrente a NULL'
);

reset role;
set role postgres;
select set_config('request.jwt.claims', '', true);
select set_config('request.jwt.claim.sub', '', true);

select ok(
    (
        select mp.recurrente_product_id is null and mp.recurrente_price_id is null
        from public.marketplace_plans mp
        where mp.id = 'free'
    ) and exists (
        select 1
        from public.marketplace_admin_audit a
        where a.action = 'plan.upsert'
          and a.target_type = 'plan'
          and a.target_id = 'test_rec55'
          and a.details ->> 'recurrente_product_id' = 'prod_rec_55'
          and a.details ->> 'recurrente_price_id' = 'price_rec_55'
    ),
    '34. free fuerza IDs a NULL y la auditoría plan.upsert incluye el mapeo de Recurrente'
);

select * from finish();
rollback;
