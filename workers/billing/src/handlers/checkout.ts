import type { CheckoutRequestPayload, Env, SetupCardRequestPayload } from '../types';
import { errorResponse, jsonResponse } from '../http';
import { createRecurrenteCheckout } from '../recurrente';
import { authenticateUser, createServiceClient } from '../supabase';

export async function handleCreateCheckout(
  request: Request,
  env: Env,
  corsHeaders: Record<string, string>
): Promise<Response> {
  const auth = await authenticateUser(request, env);
  if (!auth.ok) {
    return errorResponse(auth.status, auth.code, auth.message, corsHeaders);
  }

  let body: CheckoutRequestPayload;
  try {
    body = (await request.json()) as CheckoutRequestPayload;
  } catch {
    return errorResponse(400, 'invalid_json', 'Request body must be valid JSON', corsHeaders);
  }

  const planId = body?.plan_id?.trim();
  if (!planId || planId === 'free') {
    return errorResponse(400, 'invalid_plan', 'A valid paid plan_id is required', corsHeaders);
  }

  const supabaseService = createServiceClient(env);
  const { data: plan, error: planErr } = await supabaseService
    .from('marketplace_plans')
    .select('id, name, price_monthly, recurrente_price_id, is_active')
    .eq('id', planId)
    .maybeSingle();

  if (planErr) {
    return errorResponse(500, 'plan_lookup_failed', 'Failed to lookup marketplace plan', corsHeaders);
  }

  if (!plan || !plan.is_active || Number(plan.price_monthly) <= 0) {
    return errorResponse(404, 'plan_not_found', 'Active paid plan not found', corsHeaders);
  }

  if (!plan.recurrente_price_id) {
    return errorResponse(
      422,
      'plan_not_configured',
      `Plan '${planId}' does not have a recurrente_price_id configured`,
      corsHeaders
    );
  }

  const checkoutPayload: Record<string, unknown> = {
    items: [{ price_id: plan.recurrente_price_id, quantity: 1 }],
    metadata: {
      user_id: auth.user.id,
      plan_id: plan.id,
    },
    ...(body.success_url ? { success_url: body.success_url } : {}),
    ...(body.cancel_url ? { cancel_url: body.cancel_url } : {}),
  };

  const checkout = await createRecurrenteCheckout(env, checkoutPayload);
  return jsonResponse(
    {
      checkout_id: checkout.id,
      checkout_url: checkout.checkout_url,
    },
    201,
    corsHeaders
  );
}

export async function handleSetupCard(
  request: Request,
  env: Env,
  corsHeaders: Record<string, string>
): Promise<Response> {
  const auth = await authenticateUser(request, env);
  if (!auth.ok) {
    return errorResponse(auth.status, auth.code, auth.message, corsHeaders);
  }

  let body: SetupCardRequestPayload = {};
  try {
    const text = await request.text();
    if (text.trim()) {
      body = JSON.parse(text) as SetupCardRequestPayload;
    }
  } catch {
    return errorResponse(400, 'invalid_json', 'Request body must be valid JSON', corsHeaders);
  }

  const checkoutPayload: Record<string, unknown> = {
    mode: 'setup',
    metadata: {
      user_id: auth.user.id,
      purpose: 'update_card',
    },
    ...(body.success_url ? { success_url: body.success_url } : {}),
    ...(body.cancel_url ? { cancel_url: body.cancel_url } : {}),
  };

  const checkout = await createRecurrenteCheckout(env, checkoutPayload);
  return jsonResponse(
    {
      checkout_id: checkout.id,
      checkout_url: checkout.checkout_url,
    },
    201,
    corsHeaders
  );
}
