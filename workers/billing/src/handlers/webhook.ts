import { Webhook } from 'svix';
import type { Env } from '../types';
import { errorResponse, jsonResponse } from '../http';
import { updateRecurrenteSubscription } from '../recurrente';
import { createServiceClient } from '../supabase';

interface RecurrenteWebhookEvent {
  event_type?: string;
  type?: string;
  sandbox_id?: string | null;
  live_mode?: boolean;
  metadata?: Record<string, unknown>;
  data?: Record<string, unknown>;
  subscription?: Record<string, unknown>;
  payment_method?: { id?: string };
  customer?: { id?: string };
  [key: string]: unknown;
}

const LEGACY_IGNORED_EVENTS = new Set(['payment_intent.succeeded']);

const EVENT_TO_STATUS: Record<string, 'active' | 'past_due' | 'paused' | 'cancelled'> = {
  'subscription.create': 'active',
  'intent.succeeded': 'active',
  'subscription.past_due': 'past_due',
  'intent.failed': 'past_due',
  'subscription.pause': 'paused',
  'subscription.cancel': 'cancelled',
};

function validateEnvironment(event: RecurrenteWebhookEvent, env: Env): string | null {
  const expectedEnv = env.RECURRENTE_ENVIRONMENT || 'sandbox';
  if (expectedEnv === 'sandbox') {
    if (event.live_mode === true) {
      return 'Rejected live_mode=true event in sandbox environment';
    }
    if (
      env.RECURRENTE_EXPECTED_SANDBOX_ID &&
      event.sandbox_id !== env.RECURRENTE_EXPECTED_SANDBOX_ID
    ) {
      return `Sandbox mismatch: expected '${env.RECURRENTE_EXPECTED_SANDBOX_ID}', got '${event.sandbox_id ?? 'null'}'`;
    }
  } else if (expectedEnv === 'live' && event.live_mode === false) {
    return 'Rejected live_mode=false event in live environment';
  }
  return null;
}

export async function handleRecurrenteWebhook(
  request: Request,
  env: Env,
  corsHeaders: Record<string, string>
): Promise<Response> {
  const svixId = request.headers.get('svix-id');
  const svixTimestamp = request.headers.get('svix-timestamp');
  const svixSignature = request.headers.get('svix-signature');

  if (!svixId || !svixTimestamp || !svixSignature) {
    return errorResponse(400, 'missing_svix_headers', 'Missing required Svix signature headers', corsHeaders);
  }

  // Leer cuerpo crudo ANTES de parsear JSON para verificación criptográfica exacta
  const rawBody = await request.text();

  let event: RecurrenteWebhookEvent;
  try {
    const wh = new Webhook(env.RECURRENTE_WEBHOOK_SECRET);
    event = wh.verify(rawBody, {
      'svix-id': svixId,
      'svix-timestamp': svixTimestamp,
      'svix-signature': svixSignature,
    }) as RecurrenteWebhookEvent;
  } catch {
    return errorResponse(401, 'invalid_signature', 'Invalid Svix webhook signature', corsHeaders);
  }

  const envError = validateEnvironment(event, env);
  if (envError) {
    return errorResponse(400, 'environment_mismatch', envError, corsHeaders);
  }

  const eventType = String(event.event_type || event.type || 'unknown');
  const supabaseService = createServiceClient(env);

  // Deduplicación idempotente por svix_id
  const { error: insertErr } = await supabaseService.from('recurrente_webhook_events').insert({
    svix_id: svixId,
    event_type: eventType,
    sandbox_id: event.sandbox_id ?? null,
    live_mode: event.live_mode ?? true,
    payload: event,
    processing_status: LEGACY_IGNORED_EVENTS.has(eventType) ? 'ignored' : 'received',
  });

  if (insertErr) {
    if (insertErr.code === '23505') {
      return jsonResponse({ received: true, deduplicated: true }, 200, corsHeaders);
    }
    return errorResponse(500, 'webhook_inbox_failed', 'Failed to persist webhook event', corsHeaders);
  }

  if (LEGACY_IGNORED_EVENTS.has(eventType)) {
    return jsonResponse({ received: true, ignored: true }, 200, corsHeaders);
  }

  try {
    const meta = (event.metadata ||
      (event.data?.metadata as Record<string, unknown> | undefined) ||
      {}) as Record<string, unknown>;
    const userId = typeof meta.user_id === 'string' ? meta.user_id : null;

    if (eventType === 'setup_intent.succeeded' && meta.purpose === 'update_card' && userId) {
      const paymentMethodId =
        event.payment_method?.id ||
        ((event.data?.payment_method as Record<string, unknown> | undefined)?.id as string | undefined);

      if (paymentMethodId) {
        const { data: openSub } = await supabaseService
          .from('marketplace_subscriptions')
          .select('recurrente_subscription_id')
          .eq('user_id', userId)
          .in('status', ['active', 'past_due', 'paused'])
          .order('updated_at', { ascending: false })
          .limit(1)
          .maybeSingle();

        if (openSub?.recurrente_subscription_id) {
          await updateRecurrenteSubscription(env, openSub.recurrente_subscription_id, {
            payment_method_id: paymentMethodId,
          });
        }
      }

      await supabaseService
        .from('recurrente_webhook_events')
        .update({ processing_status: 'processed', processed_at: new Date().toISOString() })
        .eq('svix_id', svixId);

      return jsonResponse({ received: true }, 200, corsHeaders);
    }

    const mappedStatus = EVENT_TO_STATUS[eventType];
    if (!mappedStatus) {
      await supabaseService
        .from('recurrente_webhook_events')
        .update({ processing_status: 'ignored', processed_at: new Date().toISOString() })
        .eq('svix_id', svixId);
      return jsonResponse({ received: true, ignored: true }, 200, corsHeaders);
    }

    const subObj = (event.subscription || event.data || {}) as Record<string, unknown>;
    const recSubId =
      (typeof subObj.id === 'string' ? subObj.id : null) ||
      (typeof event.subscription_id === 'string' ? event.subscription_id : null);
    const planId = typeof meta.plan_id === 'string' ? meta.plan_id : null;

    if (!userId || !planId || !recSubId) {
      await supabaseService
        .from('recurrente_webhook_events')
        .update({
          processing_status: 'ignored',
          error_message: 'Missing user_id, plan_id or subscription_id in webhook payload',
          processed_at: new Date().toISOString(),
        })
        .eq('svix_id', svixId);
      return jsonResponse({ received: true, ignored: true }, 200, corsHeaders);
    }

    const { error: rpcErr } = await supabaseService.rpc('billing_apply_subscription_event', {
      p_user_id: userId,
      p_plan_id: planId,
      p_recurrente_subscription_id: recSubId,
      p_recurrente_customer_id: event.customer?.id ?? (subObj.customer_id as string | null) ?? null,
      p_status: mappedStatus,
      p_period_start: (subObj.current_period_start as string | null) ?? null,
      p_period_end: (subObj.current_period_end as string | null) ?? null,
      p_cancel_at_period_end: Boolean(subObj.cancel_at_period_end),
      p_sandbox_id: event.sandbox_id ?? null,
      p_live_mode: event.live_mode ?? true,
      p_event_type: eventType,
    });

    if (rpcErr) {
      throw new Error(rpcErr.message);
    }

    await supabaseService
      .from('recurrente_webhook_events')
      .update({ processing_status: 'processed', processed_at: new Date().toISOString() })
      .eq('svix_id', svixId);

    return jsonResponse({ received: true }, 200, corsHeaders);
  } catch (err) {
    const message = err instanceof Error ? err.message : 'Unknown error';
    await supabaseService
      .from('recurrente_webhook_events')
      .update({
        processing_status: 'failed',
        error_message: message,
        processed_at: new Date().toISOString(),
      })
      .eq('svix_id', svixId);

    return errorResponse(500, 'webhook_processing_failed', message, corsHeaders);
  }
}
