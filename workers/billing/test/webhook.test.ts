import { describe, it, expect, vi, beforeEach } from 'vitest';
import { Webhook } from 'svix';
import { handleRecurrenteWebhook } from '../src/handlers/webhook';
import type { Env } from '../src/types';

// Clave Svix válida (base64 de 32 bytes con prefijo whsec_)
const TEST_WEBHOOK_SECRET = 'whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw';

const { state } = vi.hoisted(() => ({
  state: {
    seenSvixIds: new Set<string>(),
    rpcCalls: [] as Array<{ name: string; params: Record<string, unknown> }>,
    openSubscriptionId: 'sub_rec_existing' as string | null,
    recurrenteUpdates: [] as Array<{ id: string; payload: Record<string, unknown> }>,
  },
}));

vi.mock('../src/supabase', () => ({
  createServiceClient: () => ({
    from: vi.fn((table: string) => {
      if (table === 'recurrente_webhook_events') {
        return {
          insert: vi.fn(async (row: { svix_id: string }) => {
            if (state.seenSvixIds.has(row.svix_id)) {
              return { error: { code: '23505', message: 'duplicate key' } };
            }
            state.seenSvixIds.add(row.svix_id);
            return { error: null };
          }),
          update: vi.fn(() => ({
            eq: vi.fn(async () => ({ error: null })),
          })),
        };
      }
      if (table === 'marketplace_subscriptions') {
        return {
          select: vi.fn(() => ({
            eq: vi.fn(() => ({
              in: vi.fn(() => ({
                order: vi.fn(() => ({
                  limit: vi.fn(() => ({
                    maybeSingle: vi.fn(async () => ({
                      data: state.openSubscriptionId
                        ? { recurrente_subscription_id: state.openSubscriptionId }
                        : null,
                      error: null,
                    })),
                  })),
                })),
              })),
            })),
          })),
        };
      }
      return {};
    }),
    rpc: vi.fn(async (name: string, params: Record<string, unknown>) => {
      state.rpcCalls.push({ name, params });
      return { data: { ok: true }, error: null };
    }),
  }),
}));

vi.mock('../src/recurrente', () => ({
  updateRecurrenteSubscription: vi.fn(
    async (_env: Env, id: string, payload: Record<string, unknown>) => {
      state.recurrenteUpdates.push({ id, payload });
      return { id, ...payload };
    }
  ),
}));

const baseEnv: Env = {
  RECURRENTE_ENVIRONMENT: 'sandbox',
  RECURRENTE_EXPECTED_SANDBOX_ID: 'sbx_usac_1',
  RECURRENTE_SECRET_KEY: 'sk_test_123',
  RECURRENTE_WEBHOOK_SECRET: TEST_WEBHOOK_SECRET,
  SUPABASE_URL: 'http://127.0.0.1:54321',
  SUPABASE_ANON_KEY: 'anon',
  SUPABASE_SERVICE_ROLE_KEY: 'service',
  ALLOWED_ORIGINS: '*',
};

function buildSignedRequest(svixId: string, payload: Record<string, unknown>, secret = TEST_WEBHOOK_SECRET): Request {
  const rawBody = JSON.stringify(payload);
  const now = new Date();
  const wh = new Webhook(secret);
  const signature = wh.sign(svixId, now, rawBody);
  const timestamp = Math.floor(now.getTime() / 1000).toString();

  return new Request('https://billing.test/api/v1/webhooks/recurrente', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'svix-id': svixId,
      'svix-timestamp': timestamp,
      'svix-signature': signature,
    },
    body: rawBody,
  });
}

describe('POST /api/v1/webhooks/recurrente', () => {
  beforeEach(() => {
    state.seenSvixIds.clear();
    state.rpcCalls = [];
    state.recurrenteUpdates = [];
    state.openSubscriptionId = 'sub_rec_existing';
  });

  it('rechaza firma Svix inválida con 401', async () => {
    const req = buildSignedRequest(
      'msg_bad_sig',
      { event_type: 'subscription.create', sandbox_id: 'sbx_usac_1', live_mode: false },
      'whsec_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='
    );
    const res = await handleRecurrenteWebhook(req, baseEnv, {});
    expect(res.status).toBe(401);
    expect(state.rpcCalls).toHaveLength(0);
  });

  it('rechaza sandbox_id incorrecto en ambiente sandbox con 400', async () => {
    const req = buildSignedRequest('msg_wrong_sbx', {
      event_type: 'subscription.create',
      sandbox_id: 'sbx_otro',
      live_mode: false,
    });
    const res = await handleRecurrenteWebhook(req, baseEnv, {});
    expect(res.status).toBe(400);
    expect(state.rpcCalls).toHaveLength(0);
  });

  it('procesa subscription.create y deduplica reintentos con el mismo svix-id', async () => {
    const payload = {
      event_type: 'subscription.create',
      sandbox_id: 'sbx_usac_1',
      live_mode: false,
      metadata: { user_id: 'user-1', plan_id: 'pro_student' },
      subscription: {
        id: 'sub_rec_123',
        current_period_start: '2026-11-26T00:00:00Z',
        current_period_end: '2026-12-26T00:00:00Z',
        cancel_at_period_end: false,
      },
    };

    const res1 = await handleRecurrenteWebhook(
      buildSignedRequest('msg_dup_1', payload),
      baseEnv,
      {}
    );
    expect(res1.status).toBe(200);
    expect(state.rpcCalls).toHaveLength(1);
    expect(state.rpcCalls[0].name).toBe('billing_apply_subscription_event');
    expect(state.rpcCalls[0].params.p_status).toBe('active');

    const res2 = await handleRecurrenteWebhook(
      buildSignedRequest('msg_dup_1', payload),
      baseEnv,
      {}
    );
    expect(res2.status).toBe(200);
    const body2 = (await res2.json()) as { deduplicated?: boolean };
    expect(body2.deduplicated).toBe(true);
    expect(state.rpcCalls).toHaveLength(1);
  });

  it('ignora evento legacy payment_intent.succeeded sin aplicar RPC', async () => {
    const req = buildSignedRequest('msg_legacy_1', {
      event_type: 'payment_intent.succeeded',
      sandbox_id: 'sbx_usac_1',
      live_mode: false,
    });
    const res = await handleRecurrenteWebhook(req, baseEnv, {});
    expect(res.status).toBe(200);
    const body = (await res.json()) as { ignored?: boolean };
    expect(body.ignored).toBe(true);
    expect(state.rpcCalls).toHaveLength(0);
  });

  it('actualiza payment_method_id automáticamente al recibir setup_intent.succeeded', async () => {
    const req = buildSignedRequest('msg_setup_1', {
      event_type: 'setup_intent.succeeded',
      sandbox_id: 'sbx_usac_1',
      live_mode: false,
      metadata: { user_id: 'user-1', purpose: 'update_card' },
      payment_method: { id: 'pm_new_card_99' },
    });
    const res = await handleRecurrenteWebhook(req, baseEnv, {});
    expect(res.status).toBe(200);
    expect(state.recurrenteUpdates).toEqual([
      { id: 'sub_rec_existing', payload: { payment_method_id: 'pm_new_card_99' } },
    ]);
  });
});
