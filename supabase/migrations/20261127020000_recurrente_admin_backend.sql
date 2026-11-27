-- =============================================================================
-- Migración: 20261127020000_recurrente_admin_backend.sql
-- Módulo: Marketplace — Panel administrativo de suscripciones y webhooks Recurrente
--
-- Objetivo:
--   Exponer RPCs SECURITY DEFINER restringidas a staff/admin para consultar
--   suscripciones de Recurrente, inspeccionar el inbox de webhooks Svix y
--   administrar el mapeo de productos/precios de Recurrente en `marketplace_plans`.
--
-- Idempotente. No modifica migraciones previas.
-- =============================================================================

BEGIN;

-- =============================================================================
-- 1. Listado administrativo de suscripciones del Marketplace
-- =============================================================================

CREATE OR REPLACE FUNCTION public.admin_list_marketplace_subscriptions(
    p_search text DEFAULT NULL,
    p_status text DEFAULT NULL,
    p_limit integer DEFAULT 100,
    p_offset integer DEFAULT 0
)
RETURNS TABLE (
    subscription_id uuid,
    user_id uuid,
    seller_public_id uuid,
    full_name text,
    email text,
    business_name text,
    plan_id text,
    plan_name text,
    status text,
    recurrente_subscription_id text,
    recurrente_customer_id text,
    current_period_start timestamptz,
    current_period_end timestamptz,
    cancel_at_period_end boolean,
    sandbox_id text,
    live_mode boolean,
    created_at timestamptz,
    updated_at timestamptz,
    effective_plan_id text,
    plan_expires_at timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_limit  integer;
    v_offset integer;
    v_search text;
    v_status text;
BEGIN
    IF NOT public.is_marketplace_staff(auth.uid()) THEN
        RAISE EXCEPTION 'Solo el personal de PEMTREE (administrador o moderador) puede listar suscripciones del Marketplace'
            USING ERRCODE = '42501';
    END IF;

    v_status := NULLIF(btrim(COALESCE(p_status, '')), '');
    IF v_status = 'all' THEN
        v_status := NULL;
    ELSIF v_status IS NOT NULL
          AND v_status NOT IN ('active', 'past_due', 'paused', 'cancelled') THEN
        RAISE EXCEPTION 'Estado de suscripción inválido: % (válidos: active, past_due, paused, cancelled, all)', p_status
            USING ERRCODE = '22023';
    END IF;

    v_limit  := LEAST(GREATEST(COALESCE(p_limit, 100), 1), 500);
    v_offset := GREATEST(COALESCE(p_offset, 0), 0);
    v_search := NULLIF(btrim(COALESCE(p_search, '')), '');

    RETURN QUERY
    SELECT
        ms.id AS subscription_id,
        ms.user_id,
        sp.public_id AS seller_public_id,
        fn.full_name,
        au.email::text AS email,
        sp.business_name,
        ms.plan_id,
        COALESCE(mp.name, ms.plan_id)::text AS plan_name,
        ms.status,
        ms.recurrente_subscription_id,
        ms.recurrente_customer_id,
        ms.current_period_start,
        ms.current_period_end,
        ms.cancel_at_period_end,
        ms.sandbox_id,
        ms.live_mode,
        ms.created_at,
        ms.updated_at,
        COALESCE(ep.id, 'free')::text AS effective_plan_id,
        sp.plan_expires_at
    FROM public.marketplace_subscriptions ms
    LEFT JOIN auth.users au ON au.id = ms.user_id
    LEFT JOIN public.profiles p ON p.id = ms.user_id
    LEFT JOIN public.seller_profiles sp ON sp.user_id = ms.user_id
    LEFT JOIN public.marketplace_plans mp ON mp.id = ms.plan_id
    LEFT JOIN LATERAL public.get_effective_seller_plan(ms.user_id) ep ON true
    CROSS JOIN LATERAL (
        SELECT NULLIF(btrim(p.alias), '')::text AS full_name
    ) fn
    WHERE (v_status IS NULL OR ms.status = v_status)
      AND (
          v_search IS NULL
          OR COALESCE(fn.full_name, '') ILIKE '%' || v_search || '%'
          OR COALESCE(sp.business_name, '') ILIKE '%' || v_search || '%'
          OR COALESCE(au.email::text, '') ILIKE '%' || v_search || '%'
          OR COALESCE(ms.recurrente_subscription_id, '') ILIKE '%' || v_search || '%'
          OR COALESCE(ms.recurrente_customer_id, '') ILIKE '%' || v_search || '%'
          OR ms.user_id::text ILIKE '%' || v_search || '%'
      )
    ORDER BY
        (ms.status IN ('active', 'past_due', 'paused')) DESC,
        ms.updated_at DESC,
        ms.id DESC
    LIMIT v_limit
    OFFSET v_offset;
END;
$$;

COMMENT ON FUNCTION public.admin_list_marketplace_subscriptions(text, text, integer, integer) IS
    'Listado administrativo de suscripciones Recurrente con perfil de vendedor y plan efectivo (solo staff).';

REVOKE ALL ON FUNCTION public.admin_list_marketplace_subscriptions(text, text, integer, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_list_marketplace_subscriptions(text, text, integer, integer) TO authenticated, service_role;

-- =============================================================================
-- 2. Detalle administrativo de una suscripción del Marketplace
-- =============================================================================

CREATE OR REPLACE FUNCTION public.admin_get_marketplace_subscription(
    p_user_id uuid DEFAULT NULL,
    p_recurrente_subscription_id text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_rec_sub_id text;
    v_sub        public.marketplace_subscriptions;
    v_seller     jsonb;
    v_plan       jsonb;
BEGIN
    IF NOT public.is_marketplace_staff(auth.uid()) THEN
        RAISE EXCEPTION 'Solo el personal de PEMTREE (administrador o moderador) puede consultar el detalle de una suscripción'
            USING ERRCODE = '42501';
    END IF;

    v_rec_sub_id := NULLIF(btrim(COALESCE(p_recurrente_subscription_id, '')), '');

    IF p_user_id IS NULL AND v_rec_sub_id IS NULL THEN
        RAISE EXCEPTION 'Debe proporcionar p_user_id o p_recurrente_subscription_id'
            USING ERRCODE = '22023';
    END IF;

    SELECT ms.*
    INTO v_sub
    FROM public.marketplace_subscriptions ms
    WHERE (v_rec_sub_id IS NOT NULL AND ms.recurrente_subscription_id = v_rec_sub_id)
       OR (p_user_id IS NOT NULL AND ms.user_id = p_user_id)
    ORDER BY
        (v_rec_sub_id IS NOT NULL AND ms.recurrente_subscription_id = v_rec_sub_id) DESC,
        (ms.status IN ('active', 'past_due', 'paused')) DESC,
        ms.updated_at DESC,
        ms.created_at DESC,
        ms.id DESC
    LIMIT 1;

    IF NOT FOUND THEN
        RETURN NULL;
    END IF;

    SELECT jsonb_build_object(
        'full_name', NULLIF(btrim(p.alias), ''),
        'email', au.email::text,
        'business_name', sp.business_name,
        'seller_type', sp.seller_type,
        'verification_status', sp.verification_status,
        'plan_expires_at', sp.plan_expires_at,
        'is_verified', public.is_verified_seller(v_sub.user_id),
        'effective_plan_id', COALESCE(ep.id, 'free')
    )
    INTO v_seller
    FROM auth.users au
    LEFT JOIN public.profiles p ON p.id = au.id
    LEFT JOIN public.seller_profiles sp ON sp.user_id = au.id
    LEFT JOIN LATERAL public.get_effective_seller_plan(au.id) ep ON true
    WHERE au.id = v_sub.user_id;

    SELECT jsonb_build_object(
        'id', mp.id,
        'name', mp.name,
        'price_monthly', mp.price_monthly
    )
    INTO v_plan
    FROM public.marketplace_plans mp
    WHERE mp.id = v_sub.plan_id;

    RETURN jsonb_build_object(
        'subscription', to_jsonb(v_sub),
        'seller', COALESCE(v_seller, '{}'::jsonb),
        'plan', COALESCE(v_plan, '{}'::jsonb)
    );
END;
$$;

COMMENT ON FUNCTION public.admin_get_marketplace_subscription(uuid, text) IS
    'Devuelve el detalle de una suscripción Recurrente junto con vendedor y plan (solo staff).';

REVOKE ALL ON FUNCTION public.admin_get_marketplace_subscription(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_get_marketplace_subscription(uuid, text) TO authenticated, service_role;

-- =============================================================================
-- 3. Listado administrativo de webhooks de Recurrente / Svix
-- =============================================================================

CREATE OR REPLACE FUNCTION public.admin_list_recurrente_webhook_events(
    p_status text DEFAULT NULL,
    p_search text DEFAULT NULL,
    p_limit integer DEFAULT 100,
    p_offset integer DEFAULT 0
)
RETURNS TABLE (
    svix_id text,
    event_type text,
    sandbox_id text,
    live_mode boolean,
    processing_status text,
    error_message text,
    received_at timestamptz,
    processed_at timestamptz,
    payload jsonb,
    payload_user_id text,
    payload_plan_id text,
    payload_subscription_id text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_limit  integer;
    v_offset integer;
    v_search text;
    v_status text;
BEGIN
    IF NOT public.is_marketplace_staff(auth.uid()) THEN
        RAISE EXCEPTION 'Solo el personal de PEMTREE (administrador o moderador) puede consultar los webhooks de Recurrente'
            USING ERRCODE = '42501';
    END IF;

    v_status := NULLIF(btrim(COALESCE(p_status, '')), '');
    IF v_status = 'all' THEN
        v_status := NULL;
    ELSIF v_status IS NOT NULL
          AND v_status NOT IN ('received', 'processed', 'ignored', 'failed') THEN
        RAISE EXCEPTION 'Estado de webhook inválido: % (válidos: received, processed, ignored, failed, all)', p_status
            USING ERRCODE = '22023';
    END IF;

    v_limit  := LEAST(GREATEST(COALESCE(p_limit, 100), 1), 500);
    v_offset := GREATEST(COALESCE(p_offset, 0), 0);
    v_search := NULLIF(btrim(COALESCE(p_search, '')), '');

    RETURN QUERY
    SELECT
        e.svix_id,
        e.event_type,
        e.sandbox_id,
        e.live_mode,
        e.processing_status,
        e.error_message,
        e.received_at,
        e.processed_at,
        e.payload,
        ex.payload_user_id,
        ex.payload_plan_id,
        ex.payload_subscription_id
    FROM public.recurrente_webhook_events e
    CROSS JOIN LATERAL (
        SELECT
            COALESCE(
                NULLIF(btrim(e.payload -> 'metadata' ->> 'user_id'), ''),
                NULLIF(btrim(e.payload -> 'checkout' -> 'metadata' ->> 'user_id'), ''),
                NULLIF(btrim(e.payload -> 'payment' -> 'paymentable' -> 'metadata' ->> 'user_id'), '')
            ) AS payload_user_id,
            COALESCE(
                NULLIF(btrim(e.payload -> 'metadata' ->> 'plan_id'), ''),
                NULLIF(btrim(e.payload -> 'checkout' -> 'metadata' ->> 'plan_id'), ''),
                NULLIF(btrim(e.payload -> 'payment' -> 'paymentable' -> 'metadata' ->> 'plan_id'), '')
            ) AS payload_plan_id,
            COALESCE(
                CASE WHEN e.event_type LIKE 'subscription.%' THEN NULLIF(btrim(e.payload ->> 'id'), '') END,
                NULLIF(btrim(e.payload -> 'subscription' ->> 'id'), ''),
                NULLIF(btrim(e.payload -> 'payment' -> 'paymentable' ->> 'id'), '')
            ) AS payload_subscription_id
    ) ex
    WHERE (v_status IS NULL OR e.processing_status = v_status)
      AND (
          v_search IS NULL
          OR e.svix_id ILIKE '%' || v_search || '%'
          OR e.event_type ILIKE '%' || v_search || '%'
          OR COALESCE(e.error_message, '') ILIKE '%' || v_search || '%'
          OR COALESCE(ex.payload_user_id, '') ILIKE '%' || v_search || '%'
          OR COALESCE(ex.payload_plan_id, '') ILIKE '%' || v_search || '%'
          OR COALESCE(ex.payload_subscription_id, '') ILIKE '%' || v_search || '%'
      )
    ORDER BY e.received_at DESC, e.svix_id DESC
    LIMIT v_limit
    OFFSET v_offset;
END;
$$;

COMMENT ON FUNCTION public.admin_list_recurrente_webhook_events(text, text, integer, integer) IS
    'Listado administrativo de eventos webhook recibidos desde Recurrente / Svix con extracción de IDs (solo staff).';

REVOKE ALL ON FUNCTION public.admin_list_recurrente_webhook_events(text, text, integer, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_list_recurrente_webhook_events(text, text, integer, integer) TO authenticated, service_role;

-- =============================================================================
-- 4. Extensión de planes del Marketplace con mapeo de Recurrente
-- =============================================================================

DROP FUNCTION IF EXISTS public.admin_list_marketplace_plans();

CREATE FUNCTION public.admin_list_marketplace_plans()
RETURNS TABLE (
    id                      text,
    name                    text,
    price_monthly           numeric,
    max_active_items        integer,
    max_images_per_item     integer,
    allow_video             boolean,
    auto_sponsor_items      boolean,
    hide_competitor_related boolean,
    default_badge_text      text,
    features                jsonb,
    sort_order              integer,
    is_active               boolean,
    sellers_count           bigint,
    active_items            bigint,
    created_at              timestamptz,
    updated_at              timestamptz,
    recurrente_product_id   text,
    recurrente_price_id     text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    IF NOT public.is_marketplace_staff(auth.uid()) THEN
        RAISE EXCEPTION 'Solo el personal de PEMTREE (administrador o moderador) puede consultar el catálogo administrativo de planes'
            USING ERRCODE = '42501';
    END IF;

    RETURN QUERY
    WITH effective AS (
        SELECT sp.user_id, COALESCE(ep.id, 'free') AS plan_id
        FROM public.seller_profiles sp
        LEFT JOIN LATERAL public.get_effective_seller_plan(sp.user_id) ep ON true
    ),
    seller_counts AS (
        SELECT e.plan_id, count(*)::bigint AS cnt
        FROM effective e
        GROUP BY e.plan_id
    ),
    active_by_seller AS (
        SELECT mi.user_id, count(*)::bigint AS cnt
        FROM public.marketplace_items mi
        WHERE mi.deleted_at IS NULL
          AND mi.status IN ('available', 'reserved')
        GROUP BY mi.user_id
    ),
    item_counts AS (
        SELECT e.plan_id, sum(a.cnt)::bigint AS cnt
        FROM effective e
        JOIN active_by_seller a ON a.user_id = e.user_id
        GROUP BY e.plan_id
    )
    SELECT
        mp.id,
        mp.name,
        mp.price_monthly,
        mp.max_active_items,
        mp.max_images_per_item,
        mp.allow_video,
        mp.auto_sponsor_items,
        mp.hide_competitor_related,
        mp.default_badge_text,
        mp.features,
        mp.sort_order,
        mp.is_active,
        COALESCE(sc.cnt, 0)::bigint AS sellers_count,
        COALESCE(ic.cnt, 0)::bigint AS active_items,
        mp.created_at,
        mp.updated_at,
        mp.recurrente_product_id,
        mp.recurrente_price_id
    FROM public.marketplace_plans mp
    LEFT JOIN seller_counts sc ON sc.plan_id = mp.id
    LEFT JOIN item_counts   ic ON ic.plan_id = mp.id
    ORDER BY mp.sort_order, mp.id;
END;
$$;

COMMENT ON FUNCTION public.admin_list_marketplace_plans() IS
    'Catálogo completo de planes con conteos y mapeo de IDs de Recurrente (solo staff).';

REVOKE ALL ON FUNCTION public.admin_list_marketplace_plans() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_list_marketplace_plans() TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.admin_upsert_marketplace_plan(p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_actor          uuid := auth.uid();
    v_id             text;
    v_existing       public.marketplace_plans;
    v_name           text;
    v_price          numeric;
    v_max_items      integer;
    v_max_imgs       integer;
    v_video          boolean;
    v_auto           boolean;
    v_hide           boolean;
    v_badge          text;
    v_features       jsonb;
    v_sort           integer;
    v_active         boolean;
    v_rec_product_id text;
    v_rec_price_id   text;
    v_rec_key        text;
    v_rec_val        text;
BEGIN
    -- Los planes son configuración global: solo el administrador (no moderador).
    IF NOT public.is_pemtree_admin(v_actor) THEN
        RAISE EXCEPTION 'Solo un administrador de PEMTREE puede crear o modificar planes del Marketplace'
            USING ERRCODE = '42501';
    END IF;

    IF p_payload IS NULL OR jsonb_typeof(p_payload) <> 'object' THEN
        RAISE EXCEPTION 'El payload del plan debe ser un objeto JSON'
            USING ERRCODE = '22023';
    END IF;

    v_id := NULLIF(btrim(COALESCE(p_payload ->> 'id', '')), '');
    IF v_id IS NULL OR v_id !~ '^[a-z0-9_]{2,40}$' THEN
        RAISE EXCEPTION 'Identificador de plan inválido: debe cumplir ^[a-z0-9_]{2,40}$'
            USING ERRCODE = '22023';
    END IF;

    SELECT * INTO v_existing
    FROM public.marketplace_plans mp
    WHERE mp.id = v_id;

    -- name: obligatorio en alta, no vacío y <= 60 caracteres.
    -- El plan base `free` es inmutable en nombre y precio.
    IF v_id = 'free' THEN
        v_name := 'Estudiante';
    ELSIF p_payload ? 'name' THEN
        v_name := NULLIF(btrim(p_payload ->> 'name'), '');
        IF v_name IS NULL OR length(v_name) > 60 THEN
            RAISE EXCEPTION 'El nombre del plan es obligatorio y no puede superar 60 caracteres'
                USING ERRCODE = '22023';
        END IF;
    ELSIF v_existing.id IS NULL THEN
        RAISE EXCEPTION 'El nombre del plan es obligatorio'
            USING ERRCODE = '22023';
    ELSE
        v_name := v_existing.name;
    END IF;

    -- price_monthly >= 0
    IF v_id = 'free' THEN
        v_price := 0;
    ELSIF p_payload ? 'price_monthly' THEN
        BEGIN
            v_price := (p_payload ->> 'price_monthly')::numeric;
        EXCEPTION WHEN others THEN
            RAISE EXCEPTION 'price_monthly debe ser numérico'
                USING ERRCODE = '22023';
        END;
        IF v_price < 0 THEN
            RAISE EXCEPTION 'price_monthly no puede ser negativo'
                USING ERRCODE = '22023';
        END IF;
    ELSIF v_existing.id IS NULL THEN
        v_price := 0;
    ELSE
        v_price := v_existing.price_monthly;
    END IF;

    -- max_active_items >= 0 (0 = ilimitado)
    IF p_payload ? 'max_active_items' THEN
        BEGIN
            v_max_items := (p_payload ->> 'max_active_items')::integer;
        EXCEPTION WHEN others THEN
            RAISE EXCEPTION 'max_active_items debe ser un entero'
                USING ERRCODE = '22023';
        END;
        IF v_max_items < 0 THEN
            RAISE EXCEPTION 'max_active_items no puede ser negativo (0 = ilimitado)'
                USING ERRCODE = '22023';
        END IF;
    ELSIF v_existing.id IS NULL THEN
        v_max_items := 3;
    ELSE
        v_max_items := v_existing.max_active_items;
    END IF;

    -- max_images_per_item entre 0 y 20
    IF p_payload ? 'max_images_per_item' THEN
        BEGIN
            v_max_imgs := (p_payload ->> 'max_images_per_item')::integer;
        EXCEPTION WHEN others THEN
            RAISE EXCEPTION 'max_images_per_item debe ser un entero'
                USING ERRCODE = '22023';
        END;
        IF v_max_imgs < 0 OR v_max_imgs > 20 THEN
            RAISE EXCEPTION 'max_images_per_item debe estar entre 0 y 20'
                USING ERRCODE = '22023';
        END IF;
    ELSIF v_existing.id IS NULL THEN
        v_max_imgs := 2;
    ELSE
        v_max_imgs := v_existing.max_images_per_item;
    END IF;

    IF p_payload ? 'allow_video' THEN
        BEGIN
            v_video := (p_payload ->> 'allow_video')::boolean;
        EXCEPTION WHEN others THEN
            RAISE EXCEPTION 'allow_video debe ser booleano' USING ERRCODE = '22023';
        END;
    ELSIF v_existing.id IS NULL THEN
        v_video := false;
    ELSE
        v_video := v_existing.allow_video;
    END IF;

    IF p_payload ? 'auto_sponsor_items' THEN
        BEGIN
            v_auto := (p_payload ->> 'auto_sponsor_items')::boolean;
        EXCEPTION WHEN others THEN
            RAISE EXCEPTION 'auto_sponsor_items debe ser booleano' USING ERRCODE = '22023';
        END;
    ELSIF v_existing.id IS NULL THEN
        v_auto := false;
    ELSE
        v_auto := v_existing.auto_sponsor_items;
    END IF;

    IF p_payload ? 'hide_competitor_related' THEN
        BEGIN
            v_hide := (p_payload ->> 'hide_competitor_related')::boolean;
        EXCEPTION WHEN others THEN
            RAISE EXCEPTION 'hide_competitor_related debe ser booleano' USING ERRCODE = '22023';
        END;
    ELSIF v_existing.id IS NULL THEN
        v_hide := false;
    ELSE
        v_hide := v_existing.hide_competitor_related;
    END IF;

    IF p_payload ? 'default_badge_text' THEN
        v_badge := NULLIF(btrim(COALESCE(p_payload ->> 'default_badge_text', '')), '');
    ELSIF v_existing.id IS NULL THEN
        v_badge := NULL;
    ELSE
        v_badge := v_existing.default_badge_text;
    END IF;

    IF v_badge IS NOT NULL AND length(v_badge) > 40 THEN
        RAISE EXCEPTION 'default_badge_text no puede superar los 40 caracteres'
            USING ERRCODE = '23514';
    END IF;

    -- features: arreglo JSON de cadenas.
    IF p_payload ? 'features' THEN
        v_features := p_payload -> 'features';
        IF v_features IS NULL OR jsonb_typeof(v_features) <> 'array' THEN
            RAISE EXCEPTION 'features debe ser un arreglo JSON de cadenas'
                USING ERRCODE = '22023';
        END IF;
        IF EXISTS (
            SELECT 1
            FROM jsonb_array_elements(v_features) AS f(elem)
            WHERE jsonb_typeof(f.elem) <> 'string'
        ) THEN
            RAISE EXCEPTION 'features solo admite cadenas de texto'
                USING ERRCODE = '22023';
        END IF;
    ELSIF v_existing.id IS NULL THEN
        v_features := '[]'::jsonb;
    ELSE
        v_features := v_existing.features;
    END IF;

    IF p_payload ? 'sort_order' THEN
        BEGIN
            v_sort := (p_payload ->> 'sort_order')::integer;
        EXCEPTION WHEN others THEN
            RAISE EXCEPTION 'sort_order debe ser un entero' USING ERRCODE = '22023';
        END;
    ELSIF v_existing.id IS NULL THEN
        v_sort := 0;
    ELSE
        v_sort := v_existing.sort_order;
    END IF;

    IF p_payload ? 'is_active' THEN
        BEGIN
            v_active := (p_payload ->> 'is_active')::boolean;
        EXCEPTION WHEN others THEN
            RAISE EXCEPTION 'is_active debe ser booleano' USING ERRCODE = '22023';
        END;
    ELSIF v_existing.id IS NULL THEN
        v_active := true;
    ELSE
        v_active := v_existing.is_active;
    END IF;

    -- El plan base del Marketplace no puede quedar inactivo.
    IF v_id = 'free' AND v_active = false THEN
        RAISE EXCEPTION 'El plan free es obligatorio y no puede desactivarse'
            USING ERRCODE = '23514';
    END IF;

    -- Mapeo de Recurrente: trim, vacío -> NULL, máximo 80 chars.
    -- El plan `free` siempre fuerza ambos identificadores a NULL.
    IF v_id = 'free' THEN
        v_rec_product_id := NULL;
        v_rec_price_id   := NULL;
    ELSE
        FOREACH v_rec_key IN ARRAY ARRAY['recurrente_product_id', 'recurrente_price_id'] LOOP
            IF p_payload ? v_rec_key THEN
                IF jsonb_typeof(p_payload -> v_rec_key) NOT IN ('string', 'null') THEN
                    RAISE EXCEPTION '% debe ser una cadena de texto', v_rec_key
                        USING ERRCODE = '22023';
                END IF;
                v_rec_val := NULLIF(btrim(COALESCE(p_payload ->> v_rec_key, '')), '');
                IF v_rec_val IS NOT NULL AND length(v_rec_val) > 80 THEN
                    RAISE EXCEPTION '% no puede superar los 80 caracteres', v_rec_key
                        USING ERRCODE = '23514';
                END IF;
            ELSIF v_existing.id IS NULL THEN
                v_rec_val := NULL;
            ELSIF v_rec_key = 'recurrente_product_id' THEN
                v_rec_val := v_existing.recurrente_product_id;
            ELSE
                v_rec_val := v_existing.recurrente_price_id;
            END IF;

            IF v_rec_key = 'recurrente_product_id' THEN
                v_rec_product_id := v_rec_val;
            ELSE
                v_rec_price_id := v_rec_val;
            END IF;
        END LOOP;
    END IF;

    INSERT INTO public.marketplace_plans (
        id, name, price_monthly, max_active_items, max_images_per_item,
        allow_video, auto_sponsor_items, hide_competitor_related,
        default_badge_text, features, sort_order, is_active,
        recurrente_product_id, recurrente_price_id
    ) VALUES (
        v_id, v_name, v_price, v_max_items, v_max_imgs,
        v_video, v_auto, v_hide,
        v_badge, v_features, v_sort, v_active,
        v_rec_product_id, v_rec_price_id
    )
    ON CONFLICT (id) DO UPDATE SET
        name                    = EXCLUDED.name,
        price_monthly           = EXCLUDED.price_monthly,
        max_active_items        = EXCLUDED.max_active_items,
        max_images_per_item     = EXCLUDED.max_images_per_item,
        allow_video             = EXCLUDED.allow_video,
        auto_sponsor_items      = EXCLUDED.auto_sponsor_items,
        hide_competitor_related = EXCLUDED.hide_competitor_related,
        default_badge_text      = EXCLUDED.default_badge_text,
        features                = EXCLUDED.features,
        sort_order              = EXCLUDED.sort_order,
        is_active               = EXCLUDED.is_active,
        recurrente_product_id   = EXCLUDED.recurrente_product_id,
        recurrente_price_id     = EXCLUDED.recurrente_price_id,
        updated_at              = now();

    INSERT INTO public.marketplace_admin_audit (
        actor_id, action, target_type, target_id, details, note
    ) VALUES (
        v_actor,
        'plan.upsert',
        'plan',
        v_id,
        jsonb_build_object(
            'created',               v_existing.id IS NULL,
            'name',                  v_name,
            'price_monthly',         v_price,
            'max_active_items',      v_max_items,
            'max_images_per_item',   v_max_imgs,
            'is_active',             v_active,
            'recurrente_product_id', v_rec_product_id,
            'recurrente_price_id',   v_rec_price_id
        ),
        NULL
    );

    RETURN jsonb_build_object('ok', true, 'plan_id', v_id);
END;
$$;

COMMENT ON FUNCTION public.admin_upsert_marketplace_plan(jsonb) IS
    'Crea o edita un plan del Marketplace con validación estricta y mapeo de Recurrente (solo administrador).';

REVOKE ALL ON FUNCTION public.admin_upsert_marketplace_plan(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_upsert_marketplace_plan(jsonb) TO authenticated, service_role;

COMMIT;
