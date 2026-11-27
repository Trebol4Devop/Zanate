import type { Env, UpdateSubscriptionPayload } from '../types';
import { errorResponse, jsonResponse } from '../http';
import { cancelRecurrenteSubscription, updateRecurrenteSubscription } from '../recurrente';
import { authenticateUser, createServiceClient } from '../supabase';

async function findOwnedOpenSubscription(env: Env, userId: string) {
  const supabaseService = createServiceClient(env);
  const { data, error } = await supabaseService
    .from('marketplace_subscriptions')
    .select('id, plan_id, recurrente_subscription_id, status')
    .eq('user_id', userId)
    .in('status', ['active', 'past_due', 'paused'])
    .order('updated_at', { ascending: false })
    .limit(1)
    .maybeSingle();

  return { data, error, supabaseService };
}

export async function handleUpdateSubscription(
  request: Request,
  env: Env,
  corsHeaders: Record<string, string>
): Promise<Response> {
  const auth = await authenticateUser(request, env);
  if (!auth.ok) {
    return errorResponse(auth.status, auth.code, auth.message, corsHeaders);
  }

  let body: UpdateSubscriptionPayload;
  try {
    body = (await request.json()) as UpdateSubscriptionPayload;
  } catch {
    return errorResponse(400, 'invalid_json', 'Request body must be valid JSON', corsHeaders);
  }

  const { data: sub, error: subErr, supabaseService } = await findOwnedOpenSubscription(
    env,
    auth.user.id
  );
  if (subErr) {
    return errorResponse(500, 'subscription_lookup_failed', 'Failed to lookup subscription', corsHeaders);
  }
  if (!sub) {
    return errorResponse(404, 'subscription_not_found', 'No active subscription found', corsHeaders);
  }

  const updatePayload: Record<string, unknown> = {};
  if (body.plan_id) {
    const { data: plan, error: planErr } = await supabaseService
      .from('marketplace_plans')
      .select('id, recurrente_price_id, is_active')
      .eq('id', body.plan_id)
      .maybeSingle();

    if (planErr || !plan || !plan.is_active || !plan.recurrente_price_id) {
      return errorResponse(400, 'invalid_plan', 'Target plan is not available for billing', corsHeaders);
    }
    updatePayload.items = [{ price_id: plan.recurrente_price_id, quantity: 1 }];
    updatePayload.mode = body.mode || 'next_cycle';
  } else if (body.act === 'pause' || body.act === 'unpause') {
    updatePayload.act = body.act;
  } else if (body.payment_method_id) {
    updatePayload.payment_method_id = body.payment_method_id;
  } else {
    return errorResponse(
      400,
      'invalid_update_payload',
      'Provide plan_id, act (pause|unpause), or payment_method_id',
      corsHeaders
    );
  }

  const updated = await updateRecurrenteSubscription(
    env,
    sub.recurrente_subscription_id,
    updatePayload
  );

  return jsonResponse({ status: 'ok', subscription: updated }, 200, corsHeaders);
}

export async function handleCancelSubscription(
  request: Request,
  env: Env,
  corsHeaders: Record<string, string>
): Promise<Response> {
  const auth = await authenticateUser(request, env);
  if (!auth.ok) {
    return errorResponse(auth.status, auth.code, auth.message, corsHeaders);
  }

  const { data: sub, error: subErr } = await findOwnedOpenSubscription(env, auth.user.id);
  if (subErr) {
    return errorResponse(500, 'subscription_lookup_failed', 'Failed to lookup subscription', corsHeaders);
  }
  if (!sub) {
    return errorResponse(404, 'subscription_not_found', 'No active subscription found', corsHeaders);
  }

  await cancelRecurrenteSubscription(env, sub.recurrente_subscription_id);
  return jsonResponse({ status: 'cancelled' }, 200, corsHeaders);
}
