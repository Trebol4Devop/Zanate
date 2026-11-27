import type { Env } from './types';
import { errorResponse } from './http';
import { handleHealth, handleRecurrenteHealth } from './handlers/health';
import { handleCreateCheckout, handleSetupCard } from './handlers/checkout';
import {
  handleCancelSubscription,
  handleUpdateSubscription,
} from './handlers/subscription';
import { handleRecurrenteWebhook } from './handlers/webhook';

export function getCorsHeaders(
  request: Request,
  allowedOriginsConfig?: string
): Record<string, string> {
  const origin = request.headers.get('Origin');
  const allowed = (allowedOriginsConfig || '*').split(',').map((s) => s.trim());

  let allowOrigin = '';
  if (allowed.includes('*')) {
    allowOrigin = origin || '*';
  } else if (origin && allowed.includes(origin)) {
    allowOrigin = origin;
  }

  if (!allowOrigin) {
    return {};
  }

  return {
    'Access-Control-Allow-Origin': allowOrigin,
    'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
    'Access-Control-Allow-Headers': 'authorization, content-type',
    'Access-Control-Max-Age': '86400',
    ...(allowOrigin !== '*' ? { Vary: 'Origin' } : {}),
  };
}

export default {
  async fetch(request: Request, env: Env, _ctx: ExecutionContext): Promise<Response> {
    const corsHeaders = getCorsHeaders(request, env.ALLOWED_ORIGINS);

    if (request.method === 'OPTIONS') {
      return new Response(null, { status: 204, headers: corsHeaders });
    }

    const { pathname } = new URL(request.url);

    try {
      if (pathname === '/api/v1/health' && request.method === 'GET') {
        return handleHealth(corsHeaders);
      }
      if (pathname === '/api/v1/health/recurrente' && request.method === 'GET') {
        return await handleRecurrenteHealth(request, env, corsHeaders);
      }
      if (pathname === '/api/v1/billing/checkout' && request.method === 'POST') {
        return await handleCreateCheckout(request, env, corsHeaders);
      }
      if (pathname === '/api/v1/billing/setup-card' && request.method === 'POST') {
        return await handleSetupCard(request, env, corsHeaders);
      }
      if (pathname === '/api/v1/billing/subscription' && request.method === 'PUT') {
        return await handleUpdateSubscription(request, env, corsHeaders);
      }
      if (pathname === '/api/v1/billing/subscription' && request.method === 'DELETE') {
        return await handleCancelSubscription(request, env, corsHeaders);
      }
      if (pathname === '/api/v1/webhooks/recurrente' && request.method === 'POST') {
        return await handleRecurrenteWebhook(request, env, corsHeaders);
      }

      return errorResponse(
        404,
        'not_found',
        `Endpoint ${request.method} ${pathname} not found`,
        corsHeaders
      );
    } catch (err) {
      console.error('[billing-worker-error] Unhandled error:', err);
      return errorResponse(
        500,
        'internal_server_error',
        'An unexpected internal error occurred',
        corsHeaders
      );
    }
  },
};
