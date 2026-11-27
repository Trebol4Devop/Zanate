-- =============================================================================
-- Migración: 20261127000503_recurrente_marketplace_subscriptions.sql
-- ADR-007: Gestión de Suscripciones del Marketplace con Recurrente
-- =============================================================================

BEGIN;

-- 1. Mapear planes del Marketplace a IDs de Recurrente (específicos por ambiente)
ALTER TABLE public.marketplace_plans
  ADD COLUMN IF NOT EXISTS recurrente_product_id text,
  ADD COLUMN IF NOT EXISTS recurrente_price_id text;

-- 2. Ampliar tipos permitidos en public.user_notifications para alertas de facturación
ALTER TABLE public.user_notifications
  DROP CONSTRAINT IF EXISTS user_notifications_type_check;
ALTER TABLE public.user_notifications
  ADD CONSTRAINT user_notifications_type_check
  CHECK (type = ANY (ARRAY[
    'comment'::text,
    'reply'::text,
    'like'::text,
    'new_post'::text,
    'billing_past_due'::text,
    'billing_cancelled'::text
  ]));

-- 3. Estado de suscripción Recurrente por vendedor (1 suscripción abierta a la vez)
CREATE TABLE IF NOT EXISTS public.marketplace_subscriptions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  plan_id text NOT NULL REFERENCES public.marketplace_plans(id) ON UPDATE CASCADE,
  recurrente_customer_id text,
  recurrente_subscription_id text NOT NULL UNIQUE,
  status text NOT NULL CHECK (status IN ('active', 'past_due', 'paused', 'cancelled')),
  current_period_start timestamptz,
  current_period_end timestamptz,
  cancel_at_period_end boolean NOT NULL DEFAULT false,
  sandbox_id text,
  live_mode boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_marketplace_subscriptions_user
  ON public.marketplace_subscriptions (user_id, created_at DESC);

CREATE UNIQUE INDEX IF NOT EXISTS idx_marketplace_subscriptions_one_open
  ON public.marketplace_subscriptions (user_id)
  WHERE status IN ('active', 'past_due', 'paused');

DROP TRIGGER IF EXISTS trg_marketplace_subscriptions_updated_at ON public.marketplace_subscriptions;
CREATE TRIGGER trg_marketplace_subscriptions_updated_at
  BEFORE UPDATE ON public.marketplace_subscriptions
  FOR EACH ROW
  EXECUTE FUNCTION _triggers.set_updated_at();

ALTER TABLE public.marketplace_subscriptions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.marketplace_subscriptions FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.marketplace_subscriptions TO authenticated;
GRANT ALL ON TABLE public.marketplace_subscriptions TO service_role, postgres;

DROP POLICY IF EXISTS marketplace_subscriptions_select_own ON public.marketplace_subscriptions;
CREATE POLICY marketplace_subscriptions_select_own
  ON public.marketplace_subscriptions
  FOR SELECT TO authenticated
  USING (user_id = auth.uid() OR public.is_marketplace_staff(auth.uid()));

-- 4. Inbox idempotente de webhooks Svix / Recurrente (solo service_role)
CREATE TABLE IF NOT EXISTS public.recurrente_webhook_events (
  svix_id text PRIMARY KEY,
  event_type text NOT NULL,
  sandbox_id text,
  live_mode boolean NOT NULL DEFAULT true,
  payload jsonb NOT NULL,
  processing_status text NOT NULL DEFAULT 'received'
    CHECK (processing_status IN ('received', 'processed', 'ignored', 'failed')),
  error_message text,
  received_at timestamptz NOT NULL DEFAULT now(),
  processed_at timestamptz
);

ALTER TABLE public.recurrente_webhook_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.recurrente_webhook_events FROM PUBLIC, anon, authenticated;
GRANT ALL ON TABLE public.recurrente_webhook_events TO service_role, postgres;

-- 5. RPC privilegiado: aplicar evento de suscripción desde webhook Svix
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
    INSERT INTO public.seller_profiles (user_id, plan_id, plan_expires_at)
    VALUES (p_user_id, p_plan_id, p_period_end)
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

  -- Notificaciones de facturación al vendedor
  IF p_status = 'past_due' THEN
    INSERT INTO public.user_notifications (user_id, type, title, body)
    VALUES (
      p_user_id,
      'billing_past_due',
      'Problema con tu método de pago',
      'No pudimos renovar tu suscripción del Marketplace. Actualiza tu tarjeta para conservar tus beneficios.'
    );
  ELSIF p_status = 'cancelled' THEN
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

-- 6. RPC de lectura para el vendedor autenticado
CREATE OR REPLACE FUNCTION public.get_my_subscription()
RETURNS TABLE (
  id uuid,
  plan_id text,
  status text,
  current_period_start timestamptz,
  current_period_end timestamptz,
  cancel_at_period_end boolean,
  updated_at timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT
    ms.id,
    ms.plan_id,
    ms.status,
    ms.current_period_start,
    ms.current_period_end,
    ms.cancel_at_period_end,
    ms.updated_at
  FROM public.marketplace_subscriptions ms
  WHERE ms.user_id = auth.uid()
  ORDER BY
    (ms.status IN ('active', 'past_due', 'paused')) DESC,
    ms.updated_at DESC
  LIMIT 1;
$$;

REVOKE ALL ON FUNCTION public.get_my_subscription() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_my_subscription() TO authenticated, service_role;

COMMIT;
