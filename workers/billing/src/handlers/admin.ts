import type { SupabaseClient } from '@supabase/supabase-js';
import type {
  AdminReprocessWebhookPayload,
  AdminSubscriptionAction,
  AdminSubscriptionActionPayload,
  Env,
  WebhookProcessingStatus,
} from '../types';
import { errorResponse, jsonResponse } from '../http';
import {
  RecurrenteApiError,
  cancelRecurrenteSubscription,
  getRecurrenteSubscription,
  updateRecurrenteSubscription,
} from '../recurrente';
import {
  authenticateUser,
  createServiceClient,
  isAdminUser,
  isStaffUser,
} from '../supabase';
import {
  markWebhookInbox,
  processRecurrenteEvent,
  type RecurrenteWebhookEvent,
} from './webhook';

const VALID_ACTIONS = new Set<AdminSubscriptionAction>([
  'cancel',
  'change_plan',
  'pause',
  'unpause',
]);

const VALID_WEBHOOK_STATUSES = new Set<WebhookProcessingStatus>([
  'received',
  'processed',
  'ignored',
  'failed',
]);

const WEBHOOK_SELECT_COLUMNS =
  'svix_id, event_type, sandbox_id, live_mode, processing_status, error_message, received_at, processed_at, payload';

const DEFAULT_WEBHOOKS_LIMIT = 50;
const MAX_WEBHOOKS_LIMIT = 200;

function redactSecrets(text: string, env: Env): string {
  let sanitized = text;
  for (const secret of [
    env.RECURRENTE_SECRET_KEY,
    env.RECURRENTE_WEBHOOK_SECRET,
    env.SUPABASE_SERVICE_ROLE_KEY,
  ]) {
    if (secret && secret.length >= 4) {
      sanitized = sanitized.split(secret).join('[REDACTED]');
    }
  }
  return sanitized;
}

function mapRecurrenteError(
  err: unknown,
  env: Env
): { status: number; code: string; message: string } {
  if (err instanceof RecurrenteApiError) {
    if (err.status === 404) {
      return {
        status: 404,
        code: 'subscription_not_found',
        message: 'Subscription not found in Recurrente',
      };
    }

    let detail = '';
    try {
      const parsed = JSON.parse(err.body) as Record<string, unknown>;
      const candidate = parsed?.error ?? parsed?.message ?? parsed?.detail;
      if (typeof candidate === 'string' && candidate.trim()) {
        detail = candidate.trim();
      }
    } catch {
      detail = err.body.trim();
    }

    const safeDetail = redactSecrets(detail, env).slice(0, 300);
    return {
      status: 502,
      code: 'recurrente_error',
      message: safeDetail
        ? `Recurrente API error (HTTP ${err.status}): ${safeDetail}`
        : `Recurrente API error (HTTP ${err.status})`,
    };
  }

  const rawMsg =
    err instanceof Error ? err.message : 'Unexpected error communicating with Recurrente';
  return {
    status: 502,
    code: 'recurrente_error',
    message: `Recurrente request failed: ${redactSecrets(rawMsg, env).slice(0, 300)}`,
  };
}

function parseSubscriptionId(raw: unknown): string | null {
  if (typeof raw !== 'string') return null;
  const trimmed = raw.trim();
  if (!trimmed.startsWith('su_')) return null;
  if (trimmed.length < 5 || trimmed.length > 128) return null;
  if (/[\s/?#]/.test(trimmed)) return null;
  return trimmed;
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

const MAX_AUDIT_NOTE_LENGTH = 500;

function normalizeAuditNote(raw: unknown): string | null {
  if (typeof raw !== 'string') return null;
  const note = raw.trim();
  if (!note) return null;
  return note.slice(0, MAX_AUDIT_NOTE_LENGTH);
}

/**
 * Registra la acción administrativa en marketplace_admin_audit.
 * Si la auditoría falla no se revierte la operación en Recurrente; solo se registra el aviso.
 */
async function writeBillingAudit(
  supabaseService: SupabaseClient,
  actorId: string,
  action: string,
  targetType: string,
  targetId: string,
  details: Record<string, unknown>,
  note: string | null
): Promise<void> {
  const { error } = await supabaseService.from('marketplace_admin_audit').insert({
    actor_id: actorId,
    action,
    target_type: targetType,
    target_id: targetId,
    details,
    note,
  });

  if (error) {
    console.warn('[billing-admin-audit] No se pudo registrar la auditoría:', error.message);
  }
}

async function requireAuthorizedRole(
  request: Request,
  env: Env,
  corsHeaders: Record<string, string>,
  requiredRole: 'staff' | 'admin'
): Promise<
  | { ok: true; userId: string; supabaseService: SupabaseClient }
  | { ok: false; response: Response }
> {
  const auth = await authenticateUser(request, env);
  if (!auth.ok) {
    return {
      ok: false,
      response: errorResponse(auth.status, auth.code, auth.message, corsHeaders),
    };
  }

  const supabaseService = createServiceClient(env);
  const check =
    requiredRole === 'admin'
      ? await isAdminUser(supabaseService, auth.user.id)
      : await isStaffUser(supabaseService, auth.user.id);

  if (check.error) {
    return {
      ok: false,
      response: errorResponse(
        500,
        'role_check_failed',
        `Failed to verify ${requiredRole} permissions`,
        corsHeaders
      ),
    };
  }

  if (!check.ok) {
    return {
      ok: false,
      response: errorResponse(
        403,
        'not_authorized',
        requiredRole === 'admin'
          ? 'Admin permissions required'
          : 'Staff permissions required',
        corsHeaders
      ),
    };
  }

  return { ok: true, userId: auth.user.id, supabaseService };
}

function matchesWebhookSearch(row: Record<string, unknown>, lowerTerm: string): boolean {
  for (const field of ['svix_id', 'event_type', 'error_message']) {
    const val = row[field];
    if (typeof val === 'string' && val.toLowerCase().includes(lowerTerm)) {
      return true;
    }
  }
  if (row.payload !== undefined && row.payload !== null) {
    try {
      if (JSON.stringify(row.payload).toLowerCase().includes(lowerTerm)) {
        return true;
      }
    } catch {
      // Ignore non-serializable values defensively
    }
  }
  return false;
}

export async function handleAdminGetSubscription(
  request: Request,
  env: Env,
  corsHeaders: Record<string, string>
): Promise<Response> {
  const authz = await requireAuthorizedRole(request, env, corsHeaders, 'staff');
  if (!authz.ok) return authz.response;

  const url = new URL(request.url);
  const subscriptionId = parseSubscriptionId(url.searchParams.get('subscription_id'));
  if (!subscriptionId) {
    return errorResponse(
      400,
      'invalid_subscription_id',
      'Query parameter subscription_id starting with su_ is required',
      corsHeaders
    );
  }

  try {
    const subscription = await getRecurrenteSubscription(env, subscriptionId);
    return jsonResponse({ subscription }, 200, corsHeaders);
  } catch (err) {
    const mapped = mapRecurrenteError(err, env);
    return errorResponse(mapped.status, mapped.code, mapped.message, corsHeaders);
  }
}

export async function handleAdminSubscriptionAction(
  request: Request,
  env: Env,
  corsHeaders: Record<string, string>
): Promise<Response> {
  const authz = await requireAuthorizedRole(request, env, corsHeaders, 'admin');
  if (!authz.ok) return authz.response;

  let rawBody: unknown;
  try {
    rawBody = await request.json();
  } catch {
    return errorResponse(400, 'invalid_json', 'Request body must be valid JSON', corsHeaders);
  }

  if (!isPlainObject(rawBody)) {
    return errorResponse(400, 'invalid_json', 'Request body must be a JSON object', corsHeaders);
  }

  const body = rawBody as AdminSubscriptionActionPayload;
  const subscriptionId = parseSubscriptionId(body.recurrente_subscription_id);
  if (!subscriptionId) {
    return errorResponse(
      400,
      'invalid_subscription_id',
      'A valid recurrente_subscription_id starting with su_ is required',
      corsHeaders
    );
  }

  const action = typeof body.action === 'string' ? body.action.trim() : '';
  if (!VALID_ACTIONS.has(action as AdminSubscriptionAction)) {
    return errorResponse(
      400,
      'invalid_action',
      'action must be one of cancel, change_plan, pause, unpause',
      corsHeaders
    );
  }

  let targetPlanId = '';
  let mode: 'now' | 'next_cycle' = 'next_cycle';
  if (action === 'change_plan') {
    targetPlanId = typeof body.plan_id === 'string' ? body.plan_id.trim() : '';
    if (!targetPlanId || targetPlanId === 'free') {
      return errorResponse(
        400,
        'invalid_plan',
        'A valid paid plan_id distinct from free is required for change_plan',
        corsHeaders
      );
    }

    if (body.mode !== undefined) {
      if (body.mode !== 'now' && body.mode !== 'next_cycle') {
        return errorResponse(
          400,
          'invalid_mode',
          'mode must be either now or next_cycle',
          corsHeaders
        );
      }
      mode = body.mode;
    }
  }

  const { data: localSub, error: subErr } = await authz.supabaseService
    .from('marketplace_subscriptions')
    .select('id, recurrente_subscription_id')
    .eq('recurrente_subscription_id', subscriptionId)
    .limit(1)
    .maybeSingle();

  if (subErr) {
    return errorResponse(
      500,
      'subscription_lookup_failed',
      'Failed to lookup subscription',
      corsHeaders
    );
  }

  if (!localSub) {
    return errorResponse(
      404,
      'subscription_not_found',
      'Subscription not found',
      corsHeaders
    );
  }

  let planPriceId: string | null = null;
  if (action === 'change_plan') {
    const { data: plan, error: planErr } = await authz.supabaseService
      .from('marketplace_plans')
      .select('id, price_monthly, recurrente_price_id, is_active')
      .eq('id', targetPlanId)
      .maybeSingle();

    if (planErr) {
      return errorResponse(
        500,
        'plan_lookup_failed',
        'Failed to lookup marketplace plan',
        corsHeaders
      );
    }

    if (
      !plan ||
      !plan.is_active ||
      Number(plan.price_monthly) <= 0 ||
      !plan.recurrente_price_id
    ) {
      return errorResponse(
        422,
        'plan_not_configured',
        `Plan '${targetPlanId}' is not active or missing recurrente_price_id`,
        corsHeaders
      );
    }

    planPriceId = String(plan.recurrente_price_id);
  }

  try {
    let subscription: unknown;
    if (action === 'cancel') {
      subscription = await cancelRecurrenteSubscription(env, subscriptionId);
    } else if (action === 'change_plan') {
      subscription = await updateRecurrenteSubscription(env, subscriptionId, {
        items: [{ price_id: planPriceId, quantity: 1 }],
        mode,
      });
    } else {
      subscription = await updateRecurrenteSubscription(env, subscriptionId, {
        act: action,
      });
    }

    await writeBillingAudit(
      authz.supabaseService,
      authz.userId,
      action === 'change_plan' ? 'subscription.change_plan' : `subscription.${action}`,
      'subscription',
      subscriptionId,
      {
        plan_id: action === 'change_plan' ? targetPlanId : null,
        mode: action === 'change_plan' ? mode : null,
        source: 'zanate-admin',
      },
      normalizeAuditNote(body.note)
    );

    return jsonResponse({ status: 'ok', subscription }, 200, corsHeaders);
  } catch (err) {
    const mapped = mapRecurrenteError(err, env);
    return errorResponse(mapped.status, mapped.code, mapped.message, corsHeaders);
  }
}

export async function handleAdminListWebhooks(
  request: Request,
  env: Env,
  corsHeaders: Record<string, string>
): Promise<Response> {
  const authz = await requireAuthorizedRole(request, env, corsHeaders, 'staff');
  if (!authz.ok) return authz.response;

  const url = new URL(request.url);
  const statusParam = url.searchParams.get('status')?.trim() || '';
  if (statusParam && !VALID_WEBHOOK_STATUSES.has(statusParam as WebhookProcessingStatus)) {
    return errorResponse(
      400,
      'invalid_status',
      'status must be one of received, processed, ignored, failed',
      corsHeaders
    );
  }

  const limitParam = url.searchParams.get('limit')?.trim() || '';
  let limit = DEFAULT_WEBHOOKS_LIMIT;
  if (limitParam) {
    if (!/^\d+$/.test(limitParam)) {
      return errorResponse(400, 'invalid_limit', 'limit must be a positive integer', corsHeaders);
    }
    const parsedLimit = Number.parseInt(limitParam, 10);
    if (parsedLimit < 1) {
      return errorResponse(400, 'invalid_limit', 'limit must be between 1 and 200', corsHeaders);
    }
    limit = Math.min(MAX_WEBHOOKS_LIMIT, parsedLimit);
  }

  const offsetParam = url.searchParams.get('offset')?.trim() || '';
  let offset = 0;
  if (offsetParam) {
    if (!/^\d+$/.test(offsetParam)) {
      return errorResponse(400, 'invalid_offset', 'offset must be a non-negative integer', corsHeaders);
    }
    offset = Number.parseInt(offsetParam, 10);
  }

  const searchParam = url.searchParams.get('search')?.trim() || '';

  let query = authz.supabaseService
    .from('recurrente_webhook_events')
    .select(WEBHOOK_SELECT_COLUMNS)
    .order('received_at', { ascending: false });

  if (statusParam) {
    query = query.eq('processing_status', statusParam);
  }

  if (!searchParam) {
    const { data, error } = await query.range(offset, offset + limit - 1);
    if (error) {
      return errorResponse(
        500,
        'webhooks_lookup_failed',
        'Failed to query webhook events',
        corsHeaders
      );
    }
    return jsonResponse({ events: data ?? [] }, 200, corsHeaders);
  }

  // Filter in memory over a bounded recent window so search also covers jsonb payload text safely.
  const scanLimit = Math.min(1000, Math.max(500, offset + limit));
  const { data, error } = await query.range(0, scanLimit - 1);
  if (error) {
    return errorResponse(
      500,
      'webhooks_lookup_failed',
      'Failed to query webhook events',
      corsHeaders
    );
  }

  const lowerTerm = searchParam.toLowerCase();
  const filtered = ((data ?? []) as Array<Record<string, unknown>>).filter((row) =>
    matchesWebhookSearch(row, lowerTerm)
  );
  return jsonResponse({ events: filtered.slice(offset, offset + limit) }, 200, corsHeaders);
}

export async function handleAdminReprocessWebhook(
  request: Request,
  env: Env,
  corsHeaders: Record<string, string>
): Promise<Response> {
  const authz = await requireAuthorizedRole(request, env, corsHeaders, 'admin');
  if (!authz.ok) return authz.response;

  let rawBody: unknown;
  try {
    rawBody = await request.json();
  } catch {
    return errorResponse(400, 'invalid_json', 'Request body must be valid JSON', corsHeaders);
  }

  if (!isPlainObject(rawBody)) {
    return errorResponse(400, 'invalid_json', 'Request body must be a JSON object', corsHeaders);
  }

  const body = rawBody as AdminReprocessWebhookPayload;
  const svixId = typeof body.svix_id === 'string' ? body.svix_id.trim() : '';
  if (!svixId) {
    return errorResponse(400, 'invalid_svix_id', 'svix_id is required', corsHeaders);
  }

  const { data: row, error: lookupErr } = await authz.supabaseService
    .from('recurrente_webhook_events')
    .select('svix_id, event_type, sandbox_id, live_mode, processing_status, payload')
    .eq('svix_id', svixId)
    .maybeSingle();

  if (lookupErr) {
    return errorResponse(
      500,
      'webhook_lookup_failed',
      'Failed to load webhook event',
      corsHeaders
    );
  }

  if (!row) {
    return errorResponse(404, 'webhook_not_found', 'Webhook event not found', corsHeaders);
  }

  if (row.processing_status === 'processed') {
    return errorResponse(
      409,
      'already_processed',
      'Webhook event has already been processed',
      corsHeaders
    );
  }

  if (!isPlainObject(row.payload)) {
    const msg = 'Stored webhook payload is not a valid JSON object';
    await markWebhookInbox(authz.supabaseService, svixId, 'failed', msg);
    return errorResponse(422, 'reprocess_failed', msg, corsHeaders);
  }

  const storedPayload = row.payload as RecurrenteWebhookEvent;
  const event: RecurrenteWebhookEvent = {
    ...storedPayload,
    ...(storedPayload.event_type || storedPayload.type
      ? {}
      : { event_type: row.event_type }),
    ...(storedPayload.sandbox_id !== undefined ? {} : { sandbox_id: row.sandbox_id }),
    ...(typeof storedPayload.live_mode === 'boolean'
      ? {}
      : { live_mode: row.live_mode }),
  };

  const result = await processRecurrenteEvent(event, env, authz.supabaseService);

  if (result.status === 'failed') {
    const message = redactSecrets(result.error || 'Webhook reprocessing failed', env);
    await markWebhookInbox(authz.supabaseService, svixId, 'failed', message);
    return errorResponse(422, 'reprocess_failed', message, corsHeaders);
  }

  await markWebhookInbox(authz.supabaseService, svixId, result.status, null);

  await writeBillingAudit(
    authz.supabaseService,
    authz.userId,
    'webhook.reprocess',
    'webhook_event',
    svixId,
    {
      event_type: row.event_type,
      previous_status: row.processing_status,
      result: result.status,
      source: 'zanate-admin',
    },
    null
  );

  return jsonResponse({ status: result.status, reprocessed: true }, 200, corsHeaders);
}
