import { Webhook } from 'svix';
import type { SupabaseClient } from '@supabase/supabase-js';
import type { Env, RecurrenteSubscriptionResponse } from '../types';
import { errorResponse, jsonResponse } from '../http';
import { getRecurrenteSubscription, updateRecurrenteSubscription } from '../recurrente';
import { createServiceClient } from '../supabase';

type BillingStatus = 'active' | 'past_due' | 'paused' | 'cancelled';

export interface ProcessRecurrenteResult {
  status: 'processed' | 'ignored' | 'failed';
  error?: string;
}

export interface RecurrenteWebhookEvent {
  id?: string;
  event_type?: string;
  type?: string;
  status?: string;
  live_mode?: boolean;
  sandbox_id?: string | null;
  metadata?: unknown;
  data?: unknown;
  checkout?: unknown;
  payment?: unknown;
  subscription?: unknown;
  payment_method?: unknown;
  customer?: unknown;
  customer_id?: unknown;
  items?: unknown;
  product?: unknown;
  cancel_at?: unknown;
  cancel_at_period_end?: unknown;
  current_period_start?: unknown;
  current_period_end?: unknown;
  [key: string]: unknown;
}

const NO_OP_EVENTS = new Set([
  'intent.pending',
  'intent.canceled',
  'intent.paid',
  'setup_intent.cancelled',
  'subscription.item_added',
  'subscription.item_removed',
  'subscription.invoice_item_added',
]);

/**
 * Recurrente conserva los eventos legacy por método de pago además del formato
 * unificado `intent.*`. Se ignoran para no aplicar un mismo cobro dos veces.
 */
const LEGACY_EVENT_PATTERN =
  /^(payment_intent|bank_transfer_intent|automated_bank_transfer_intent|balance_intent|crypto_intent|cash_intent)\./;

const ALLOWED_STATUSES: BillingStatus[] = ['active', 'past_due', 'paused', 'cancelled'];

function asRecord(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
}

function pickString(value: unknown): string | null {
  return typeof value === 'string' && value.trim().length > 0 ? value.trim() : null;
}

function uniqueStrings(values: Array<string | null>): string[] {
  return [...new Set(values.filter((v): v is string => Boolean(v)))];
}

function normalizeStatus(value: unknown): BillingStatus | null {
  const raw = pickString(value)?.toLowerCase();
  return raw && (ALLOWED_STATUSES as string[]).includes(raw) ? (raw as BillingStatus) : null;
}

/**
 * La metadata puede venir en la raíz (subscription.*) o anidada en el checkout /
 * payment intent (intent.succeeded, setup_intent.succeeded).
 */
function resolveMetadata(event: RecurrenteWebhookEvent): Record<string, unknown> {
  const data = asRecord(event.data);
  const checkout = asRecord(event.checkout);
  const dataCheckout = asRecord(data?.checkout);
  const payment = asRecord(event.payment);
  const paymentable = asRecord(payment?.paymentable);
  const dataPayment = asRecord(data?.payment);
  const dataPaymentable = asRecord(dataPayment?.paymentable);

  const candidates = [
    event.metadata,
    checkout?.metadata,
    paymentable?.metadata,
    data?.metadata,
    dataCheckout?.metadata,
    dataPaymentable?.metadata,
  ];

  for (const candidate of candidates) {
    const record = asRecord(candidate);
    if (record && Object.keys(record).length > 0) return record;
  }
  for (const candidate of candidates) {
    const record = asRecord(candidate);
    if (record) return record;
  }
  return {};
}

/**
 * En `subscription.*` el ID de la suscripción viaja en `event.id`.
 * En `intent.*` viaja en `subscription.id` o en `payment.paymentable.id`.
 */
function resolveSubscriptionId(
  event: RecurrenteWebhookEvent,
  eventType: string
): string | null {
  const data = asRecord(event.data);
  const subscription = asRecord(event.subscription);
  const dataSubscription = asRecord(data?.subscription);
  const payment = asRecord(event.payment);
  const paymentable = asRecord(payment?.paymentable);
  const dataPayment = asRecord(data?.payment);
  const dataPaymentable = asRecord(dataPayment?.paymentable);

  const candidates: unknown[] = [];
  if (eventType.startsWith('subscription.')) {
    candidates.push(event.id, data?.id);
  }
  candidates.push(
    subscription?.id,
    event.subscription_id,
    paymentable?.type === 'Subscription' ? paymentable.id : null,
    dataSubscription?.id,
    data?.subscription_id,
    dataPaymentable?.type === 'Subscription' ? dataPaymentable.id : null
  );

  for (const candidate of candidates) {
    const value = pickString(candidate);
    if (value) return value;
  }
  return null;
}

function resolveLiveMode(event: RecurrenteWebhookEvent): boolean | undefined {
  if (typeof event.live_mode === 'boolean') return event.live_mode;

  const checkout = asRecord(event.checkout);
  if (typeof checkout?.live_mode === 'boolean') {
    return checkout.live_mode as boolean;
  }

  const dataCheckout = asRecord(asRecord(event.data)?.checkout);
  if (typeof dataCheckout?.live_mode === 'boolean') {
    return dataCheckout.live_mode as boolean;
  }

  return undefined;
}

function validateEnvironment(event: RecurrenteWebhookEvent, env: Env): string | null {
  const expectedEnv = env.RECURRENTE_ENVIRONMENT || 'live';
  const liveMode = resolveLiveMode(event);

  if (expectedEnv === 'sandbox') {
    if (liveMode === true) {
      return 'Rejected live_mode=true event in sandbox environment';
    }
    // Los webhooks no incluyen sandbox_id; solo se valida si el emisor lo envía.
    if (
      env.RECURRENTE_EXPECTED_SANDBOX_ID &&
      typeof event.sandbox_id === 'string' &&
      event.sandbox_id !== env.RECURRENTE_EXPECTED_SANDBOX_ID
    ) {
      return `Sandbox mismatch: expected '${env.RECURRENTE_EXPECTED_SANDBOX_ID}', got '${event.sandbox_id}'`;
    }
  } else if (liveMode === false) {
    return 'Rejected live_mode=false event in live environment';
  }

  return null;
}

function collectPriceIds(event: RecurrenteWebhookEvent): string[] {
  const data = asRecord(event.data);
  const checkout = asRecord(event.checkout);
  const dataCheckout = asRecord(data?.checkout);
  const product = asRecord(event.product);

  const itemLists = [event.items, checkout?.items, data?.items, dataCheckout?.items];
  const priceIds: Array<string | null> = [];

  for (const list of itemLists) {
    if (!Array.isArray(list)) continue;
    for (const item of list) {
      priceIds.push(pickString(asRecord(item)?.price_id));
    }
  }

  if (Array.isArray(product?.prices)) {
    for (const price of product.prices) {
      priceIds.push(pickString(asRecord(price)?.id));
    }
  }

  return uniqueStrings(priceIds);
}

function collectProductIds(event: RecurrenteWebhookEvent): string[] {
  const data = asRecord(event.data);
  const checkout = asRecord(event.checkout);
  const dataCheckout = asRecord(data?.checkout);
  const product = asRecord(event.product);

  const itemLists = [event.items, checkout?.items, data?.items, dataCheckout?.items];
  const productIds: Array<string | null> = [pickString(product?.id)];

  for (const list of itemLists) {
    if (!Array.isArray(list)) continue;
    for (const item of list) {
      productIds.push(pickString(asRecord(item)?.product_id));
    }
  }

  return uniqueStrings(productIds);
}

async function resolvePlanId(
  supabaseService: SupabaseClient,
  event: RecurrenteWebhookEvent,
  metadata: Record<string, unknown>
): Promise<string | null> {
  const fromMetadata = pickString(metadata.plan_id);
  if (fromMetadata) return fromMetadata;

  const priceIds = collectPriceIds(event);
  if (priceIds.length > 0) {
    const { data } = await supabaseService
      .from('marketplace_plans')
      .select('id')
      .in('recurrente_price_id', priceIds)
      .limit(1)
      .maybeSingle();
    const planId = pickString(data?.id);
    if (planId) return planId;
  }

  const productIds = collectProductIds(event);
  if (productIds.length > 0) {
    const { data } = await supabaseService
      .from('marketplace_plans')
      .select('id')
      .in('recurrente_product_id', productIds)
      .limit(1)
      .maybeSingle();
    const planId = pickString(data?.id);
    if (planId) return planId;
  }

  return null;
}

async function fetchSubscriptionSafe(
  env: Env,
  subscriptionId: string | null
): Promise<RecurrenteSubscriptionResponse | null> {
  if (!subscriptionId) return null;
  try {
    return await getRecurrenteSubscription(env, subscriptionId);
  } catch (err) {
    console.warn(
      `[billing-webhook] No se pudo consultar la suscripción '${subscriptionId}':`,
      err instanceof Error ? err.message : err
    );
    return null;
  }
}

function resolveStatus(
  eventType: string,
  event: RecurrenteWebhookEvent,
  remoteSubscription: RecurrenteSubscriptionResponse | null
): BillingStatus | null {
  const remoteStatus = normalizeStatus(remoteSubscription?.status);

  switch (eventType) {
    case 'subscription.create':
    case 'subscription.reactivate':
    case 'subscription.unpause':
      return remoteStatus ?? 'active';
    case 'subscription.past_due':
      return 'past_due';
    case 'subscription.pause':
      return 'paused';
    case 'subscription.cancel':
      return 'cancelled';
    case 'subscription.update':
      return remoteStatus ?? normalizeStatus(event.status);
    case 'intent.succeeded':
      return remoteStatus ?? 'active';
    case 'intent.failed':
      return 'past_due';
    default:
      return null;
  }
}

function resolvePayloadPeriod(
  event: RecurrenteWebhookEvent,
  field: 'current_period_start' | 'current_period_end'
): string | null {
  const subscription = asRecord(event.subscription);
  const data = asRecord(event.data);
  const dataSubscription = asRecord(data?.subscription);

  return (
    pickString(event[field]) ??
    pickString(subscription?.[field]) ??
    pickString(data?.[field]) ??
    pickString(dataSubscription?.[field])
  );
}

export async function markWebhookInbox(
  supabaseService: SupabaseClient,
  svixId: string,
  processingStatus: 'processed' | 'ignored' | 'failed' | 'received',
  errorMessage: string | null = null
): Promise<void> {
  await supabaseService
    .from('recurrente_webhook_events')
    .update({
      processing_status: processingStatus,
      error_message: errorMessage,
      processed_at:
        processingStatus === 'processed' || processingStatus === 'ignored' || processingStatus === 'failed'
          ? new Date().toISOString()
          : null,
    })
    .eq('svix_id', svixId);
}

/**
 * Procesa un evento de Recurrente ya verificado sin mutar la tabla inbox.
 * Reutilizado tanto por el webhook HTTP como por el endpoint de reproceso admin.
 */
export async function processRecurrenteEvent(
  event: RecurrenteWebhookEvent,
  env: Env,
  supabaseService: SupabaseClient
): Promise<ProcessRecurrenteResult> {
  const eventType = String(event.event_type || event.type || 'unknown');
  const liveMode = resolveLiveMode(event) ?? env.RECURRENTE_ENVIRONMENT !== 'sandbox';

  try {
    if (NO_OP_EVENTS.has(eventType) || LEGACY_EVENT_PATTERN.test(eventType)) {
      return { status: 'ignored' };
    }

    const metadata = resolveMetadata(event);
    const subscriptionId = resolveSubscriptionId(event, eventType);

    // Actualización de tarjeta: tokenización sin cobro
    if (eventType === 'setup_intent.succeeded') {
      const userId = pickString(metadata.user_id);

      if (metadata.purpose !== 'update_card' || !userId) {
        return { status: 'ignored' };
      }

      const paymentMethodId =
        pickString(asRecord(event.payment_method)?.id) ??
        pickString(asRecord(asRecord(event.checkout)?.payment_method)?.id) ??
        pickString(asRecord(asRecord(event.data)?.payment_method)?.id);

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

      return { status: 'processed' };
    }

    const remoteSubscription = await fetchSubscriptionSafe(env, subscriptionId);
    const remoteMetadata = asRecord(remoteSubscription?.metadata) ?? {};

    const mappedStatus = resolveStatus(eventType, event, remoteSubscription);
    if (!mappedStatus) {
      return { status: 'ignored' };
    }

    const userId =
      pickString(metadata.user_id) ?? pickString(remoteMetadata.user_id);
    const planId = await resolvePlanId(supabaseService, event, {
      ...remoteMetadata,
      ...metadata,
    });

    if (!userId || !planId || !subscriptionId) {
      const message =
        'Incomplete webhook payload ' +
        `(user_id=${Boolean(userId)}, plan_id=${Boolean(planId)}, subscription_id=${Boolean(subscriptionId)})`;

      return { status: 'failed', error: message };
    }

    const cancelAtPeriodEnd =
      typeof remoteSubscription?.cancel_at_period_end === 'boolean'
        ? remoteSubscription.cancel_at_period_end
        : event.cancel_at_period_end === true ||
          asRecord(event.subscription)?.cancel_at_period_end === true;

    const periodStart =
      pickString(remoteSubscription?.current_period_start) ??
      resolvePayloadPeriod(event, 'current_period_start');
    const periodEnd =
      pickString(remoteSubscription?.current_period_end) ??
      resolvePayloadPeriod(event, 'current_period_end') ??
      (cancelAtPeriodEnd ? pickString(remoteSubscription?.cancel_at ?? event.cancel_at) : null);

    const customerId =
      pickString(event.customer_id) ??
      pickString(asRecord(event.customer)?.id) ??
      pickString(remoteSubscription?.customer_id);

    const { error: rpcErr } = await supabaseService.rpc('billing_apply_subscription_event', {
      p_user_id: userId,
      p_plan_id: planId,
      p_recurrente_subscription_id: subscriptionId,
      p_recurrente_customer_id: customerId,
      p_status: mappedStatus,
      p_period_start: periodStart,
      p_period_end: periodEnd,
      p_cancel_at_period_end: cancelAtPeriodEnd,
      p_sandbox_id: pickString(event.sandbox_id),
      p_live_mode: liveMode,
      p_event_type: eventType,
    });

    if (rpcErr) {
      throw new Error(rpcErr.message);
    }

    return { status: 'processed' };
  } catch (err) {
    const message = err instanceof Error ? err.message : 'Unknown error';
    return { status: 'failed', error: message };
  }
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
  const liveMode = resolveLiveMode(event) ?? env.RECURRENTE_ENVIRONMENT !== 'sandbox';
  const supabaseService = createServiceClient(env);

  // Inbox idempotente por svix_id
  const { error: insertErr } = await supabaseService.from('recurrente_webhook_events').insert({
    svix_id: svixId,
    event_type: eventType,
    sandbox_id: pickString(event.sandbox_id),
    live_mode: liveMode,
    payload: event,
    processing_status: 'received',
  });

  if (insertErr) {
    if (insertErr.code !== '23505') {
      return errorResponse(500, 'webhook_inbox_failed', 'Failed to persist webhook event', corsHeaders);
    }

    // Reintento de Svix con el mismo svix-id: solo se descarta si ya se procesó.
    const { data: existing, error: existingErr } = await supabaseService
      .from('recurrente_webhook_events')
      .select('processing_status')
      .eq('svix_id', svixId)
      .maybeSingle();

    if (existingErr) {
      return errorResponse(500, 'webhook_inbox_failed', 'Failed to read webhook event', corsHeaders);
    }

    if (
      !existing ||
      existing.processing_status === 'processed' ||
      existing.processing_status === 'ignored'
    ) {
      return jsonResponse({ received: true, deduplicated: true }, 200, corsHeaders);
    }

    await markWebhookInbox(supabaseService, svixId, 'received');
  }

  const result = await processRecurrenteEvent(event, env, supabaseService);

  if (result.status === 'ignored') {
    await markWebhookInbox(supabaseService, svixId, 'ignored');
    return jsonResponse({ received: true, ignored: true }, 200, corsHeaders);
  }

  if (result.status === 'failed') {
    const message = result.error || 'Unknown error';
    const code = message.startsWith('Incomplete webhook payload')
      ? 'webhook_incomplete_payload'
      : 'webhook_processing_failed';
    // Se responde 5xx para que Svix reintente: no se pierde el evento en silencio.
    await markWebhookInbox(supabaseService, svixId, 'failed', message);
    return errorResponse(500, code, message, corsHeaders);
  }

  await markWebhookInbox(supabaseService, svixId, 'processed');
  return jsonResponse({ received: true }, 200, corsHeaders);
}
