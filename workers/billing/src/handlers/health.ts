import type { Env } from '../types';
import { errorResponse, jsonResponse } from '../http';
import { testRecurrenteCredentials } from '../recurrente';
import { authenticateUser, createServiceClient, isStaffUser } from '../supabase';

export function handleHealth(corsHeaders: Record<string, string>): Response {
  return jsonResponse(
    { status: 'ok', service: 'comunidad-usac-billing' },
    200,
    corsHeaders
  );
}

export async function handleRecurrenteHealth(
  request: Request,
  env: Env,
  corsHeaders: Record<string, string>
): Promise<Response> {
  const auth = await authenticateUser(request, env);
  if (!auth.ok) {
    return errorResponse(auth.status, auth.code, auth.message, corsHeaders);
  }

  const supabaseService = createServiceClient(env);
  const staff = await isStaffUser(supabaseService, auth.user.id);
  if (staff.error) {
    return errorResponse(500, 'role_check_failed', 'Failed to verify staff permissions', corsHeaders);
  }
  if (!staff.ok) {
    return errorResponse(403, 'not_authorized', 'Staff permissions required', corsHeaders);
  }

  const info = await testRecurrenteCredentials(env);
  const actualEnv = info.environment || (info.live_mode === false ? 'sandbox' : 'live');
  const expectedEnv = env.RECURRENTE_ENVIRONMENT || 'sandbox';

  if (actualEnv !== expectedEnv) {
    return errorResponse(
      500,
      'environment_mismatch',
      `Expected Recurrente environment '${expectedEnv}', got '${actualEnv}'`,
      corsHeaders
    );
  }

  if (
    expectedEnv === 'sandbox' &&
    env.RECURRENTE_EXPECTED_SANDBOX_ID &&
    info.sandbox_id &&
    info.sandbox_id !== env.RECURRENTE_EXPECTED_SANDBOX_ID
  ) {
    return errorResponse(
      500,
      'sandbox_mismatch',
      `Expected sandbox_id '${env.RECURRENTE_EXPECTED_SANDBOX_ID}', got '${info.sandbox_id}'`,
      corsHeaders
    );
  }

  return jsonResponse(
    {
      status: 'ok',
      environment: actualEnv,
      sandbox_id: info.sandbox_id ?? null,
    },
    200,
    corsHeaders
  );
}
