-- =============================================================================
-- Migración: 20261127010000_billing_subscription_hardening.sql
-- Endurece billing_apply_subscription_event:
--   1. Un plan `active` nunca queda con plan_expires_at NULL (vigencia infinita).
--      Si el webhook no trae período, se conserva la vigencia existente o se usa
--      un mes como respaldo (la fuente normal es GET /subscriptions/{id}).
--   2. Las notificaciones de facturación son idempotentes ante reintentos de Svix.
-- =============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.billing_apply_subscription_event(
  p_user_id uuid,
  p_plan_id text,
  p_recurrente_subscription_id text,
  p_recurrente_customer_id text,
  p_status text,
  p_period_start timestamptz,
  p_period_end timestamptz,
  p_cancel_at_period_end boolean DEFAULT false,
  p_sandbox_id text DEFAULT NULL,
  p_live_mode boolean DEFAULT true,
  p_event_type text DEFAULT 'subscription.update'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_sub_id uuid;
  v_cancel_at_end boolean := COALESCE(p_cancel_at_period_end, false);
  v_should_degrade boolean := false;
  v_effective_expiry timestamptz := p_period_end;
BEGIN
  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'p_user_id es obligatorio' USING ERRCODE = '22023';
  END IF;

  IF p_plan_id IS NULL OR NOT EXISTS (SELECT 1 FROM public.marketplace_plans mp WHERE mp.id = p_plan_id) THEN
    RAISE EXCEPTION 'p_plan_id inválido: %', p_plan_id USING ERRCODE = '22023';
  END IF;

  IF p_recurrente_subscription_id IS NULL OR length(trim(p_recurrente_subscription_id)) = 0 THEN
    RAISE EXCEPTION 'p_recurrente_subscription_id es obligatorio' USING ERRCODE = '22023';
  END IF;

  IF p_status NOT IN ('active', 'past_due', 'paused', 'cancelled') THEN
    RAISE EXCEPTION 'p_status inválido: %', p_status USING ERRCODE = '22023';
  END IF;

  -- Si entra una suscripción abierta nueva, cerrar cualquier otra suscripción abierta previa del mismo usuario
  IF p_status IN ('active', 'past_due', 'paused') THEN
    UPDATE public.marketplace_subscriptions
    SET status = 'cancelled',
        updated_at = now()
    WHERE user_id = p_user_id
      AND recurrente_subscription_id <> p_recurrente_subscription_id
      AND status IN ('active', 'past_due', 'paused');
  END IF;

  INSERT INTO public.marketplace_subscriptions (
    user_id,
    plan_id,
    recurrente_customer_id,
    recurrente_subscription_id,
    status,
    current_period_start,
    current_period_end,
    cancel_at_period_end,
    sandbox_id,
    live_mode
  )
  VALUES (
    p_user_id,
    p_plan_id,
    p_recurrente_customer_id,
    p_recurrente_subscription_id,
    p_status,
    p_period_start,
    p_period_end,
    v_cancel_at_end,
    p_sandbox_id,
    COALESCE(p_live_mode, true)
  )
  ON CONFLICT (recurrente_subscription_id) DO UPDATE
  SET plan_id = EXCLUDED.plan_id,
      recurrente_customer_id = COALESCE(EXCLUDED.recurrente_customer_id, public.marketplace_subscriptions.recurrente_customer_id),
      status = EXCLUDED.status,
      current_period_start = COALESCE(EXCLUDED.current_period_start, public.marketplace_subscriptions.current_period_start),
      current_period_end = COALESCE(EXCLUDED.current_period_end, public.marketplace_subscriptions.current_period_end),
      cancel_at_period_end = EXCLUDED.cancel_at_period_end,
      sandbox_id = COALESCE(EXCLUDED.sandbox_id, public.marketplace_subscriptions.sandbox_id),
      live_mode = EXCLUDED.live_mode,
      updated_at = now()
  RETURNING id INTO v_sub_id;

  -- Sincronizar seller_profiles según estado y vigencia
  v_should_degrade :=
    (p_status = 'cancelled' AND (NOT v_cancel_at_end OR p_period_end IS NULL OR p_period_end <= now()))
    OR (p_period_end IS NOT NULL AND p_period_end <= now() AND p_status <> 'active');

  IF p_status = 'active' OR (p_status = 'cancelled' AND v_cancel_at_end AND p_period_end IS NOT NULL AND p_period_end > now()) THEN
    -- Defensa: un plan activo sin período no debe quedar vigente para siempre.
    IF v_effective_expiry IS NULL AND p_status = 'active' THEN
      SELECT sp.plan_expires_at
      INTO v_effective_expiry
      FROM public.seller_profiles sp
      WHERE sp.user_id = p_user_id;

      IF v_effective_expiry IS NULL THEN
        v_effective_expiry := now() + interval '1 month';
      END IF;
    END IF;

    INSERT INTO public.seller_profiles (user_id, plan_id, plan_expires_at)
    VALUES (p_user_id, p_plan_id, v_effective_expiry)
    ON CONFLICT (user_id) DO UPDATE
    SET plan_id = EXCLUDED.plan_id,
        plan_expires_at = EXCLUDED.plan_expires_at,
        updated_at = now();
  ELSIF v_should_degrade THEN
    INSERT INTO public.seller_profiles (user_id, plan_id, plan_expires_at)
    VALUES (p_user_id, 'free', NULL)
    ON CONFLICT (user_id) DO UPDATE
    SET plan_id = 'free',
        plan_expires_at = NULL,
        updated_at = now();

    PERFORM public.reconcile_seller_plan_limits(p_user_id);
  END IF;

  -- Notificaciones de facturación al vendedor (idempotentes ante reintentos de Svix)
  IF p_status = 'past_due' THEN
    IF NOT EXISTS (
      SELECT 1
      FROM public.user_notifications un
      WHERE un.user_id = p_user_id
        AND un.type = 'billing_past_due'
        AND un.created_at > now() - interval '24 hours'
    ) THEN
      INSERT INTO public.user_notifications (user_id, type, title, body)
      VALUES (
        p_user_id,
        'billing_past_due',
        'Problema con tu método de pago',
        'No pudimos renovar tu suscripción del Marketplace. Actualiza tu tarjeta para conservar tus beneficios.'
      );
    END IF;
  ELSIF p_status = 'cancelled' THEN
    IF NOT EXISTS (
      SELECT 1
      FROM public.user_notifications un
      WHERE un.user_id = p_user_id
        AND un.type = 'billing_cancelled'
        AND un.created_at > now() - interval '1 hour'
    ) THEN
      INSERT INTO public.user_notifications (user_id, type, title, body)
      VALUES (
        p_user_id,
        'billing_cancelled',
        'Suscripción cancelada',
        CASE
          WHEN v_cancel_at_end AND p_period_end IS NOT NULL AND p_period_end > now() THEN
            'Tu suscripción no se renovará al finalizar el período actual.'
          ELSE
            'Tu suscripción del Marketplace ha sido cancelada y tu cuenta volvió al plan Estudiante.'
        END
      );
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'subscription_id', v_sub_id,
    'status', p_status,
    'plan_id', CASE WHEN v_should_degrade THEN 'free' ELSE p_plan_id END,
    'event_type', p_event_type
  );
END;
$$;

REVOKE ALL ON FUNCTION public.billing_apply_subscription_event(
  uuid, text, text, text, text, timestamptz, timestamptz, boolean, text, boolean, text
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.billing_apply_subscription_event(
  uuid, text, text, text, text, timestamptz, timestamptz, boolean, text, boolean, text
) TO service_role, postgres;

COMMIT;
