import { describe, it, expect, vi, beforeEach } from 'vitest';
import { Webhook } from 'svix';
import { handleRecurrenteWebhook } from '../src/handlers/webhook';
import type { Env } from '../src/types';

// Clave Svix válida (base64 de 32 bytes con prefijo whsec_)
const TEST_WEBHOOK_SECRET = 'whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw';

const USER_ID = '9037e5be-daa0-4a34-a442-fd6870fe8128';
const SUBSCRIPTION_ID = 'su_utd93kqh';

const { state } = vi.hoisted(() => ({
  state: {
    events: new Map<string, { processing_status: string; error_message?: string | null }>(),
    rpcCalls: [] as Array<{ name: string; params: Record<string, unknown> }>,
    rpcError: null as { message: string } | null,
    openSubscriptionId: 'sub_rec_existing' as string | null,
    recurrenteUpdates: [] as Array<{ id: string; payload: Record<string, unknown> }>,
    remoteSubscription: null as Record<string, unknown> | null,
    remoteSubscriptionError: null as Error | null,
    planByPrice: 'pro_student' as string | null,
  },
}));

vi.mock('../src/supabase', () => ({
  createServiceClient: () => ({
    from: vi.fn((table: string) => {
      if (table === 'recurrente_webhook_events') {
        return {
          insert: vi.fn(async (row: { svix_id: string; processing_status?: string }) => {
            if (state.events.has(row.svix_id)) {
              return { error: { code: '23505', message: 'duplicate key' } };
            }
            state.events.set(row.svix_id, {
              processing_status: row.processing_status ?? 'received',
            });
            return { error: null };
          }),
          select: vi.fn(() => ({
            eq: vi.fn((_column: string, svixId: string) => ({
              maybeSingle: vi.fn(async () => ({
                data: state.events.get(svixId) ?? null,
                error: null,
              })),
            })),
          })),
          update: vi.fn((patch: { processing_status?: string; error_message?: string | null }) => ({
            eq: vi.fn(async (_column: string, svixId: string) => {
              const current = state.events.get(svixId);
              state.events.set(svixId, { ...(current ?? {}), ...patch } as {
                processing_status: string;
                error_message?: string | null;
              });
              return { error: null };
            }),
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
      if (table === 'marketplace_plans') {
        return {
          select: vi.fn(() => ({
            in: vi.fn(() => ({
              limit: vi.fn(() => ({
                maybeSingle: vi.fn(async () => ({
                  data: state.planByPrice ? { id: state.planByPrice } : null,
                  error: null,
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
      return state.rpcError
        ? { data: null, error: state.rpcError }
        : { data: { ok: true }, error: null };
    }),
  }),
}));

vi.mock('../src/recurrente', () => ({
  getRecurrenteSubscription: vi.fn(async () => {
    if (state.remoteSubscriptionError) throw state.remoteSubscriptionError;
    return state.remoteSubscription;
  }),
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

function buildSignedRequest(
  svixId: string,
  payload: Record<string, unknown>,
  secret = TEST_WEBHOOK_SECRET
): Request {
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

// Payload real de Recurrente (resumido): el ID de la suscripción viaja en `id`
// y la metadata en la raíz. No incluye fechas de período.
function subscriptionCreatePayload(overrides: Record<string, unknown> = {}) {
  return {
    id: SUBSCRIPTION_ID,
    status: 'active',
    event_type: 'subscription.create',
    api_version: '2024-04-24',
    created_at: '2026-11-26T20:10:01.513-06:00',
    customer_id: 'cus_2hjinu9c',
    cancel_at_period_end: false,
    items: [{ price_id: 'price_fhqoditt', product_id: 'prod_4e6e4jcl', quantity: 1 }],
    product: { id: 'prod_4e6e4jcl' },
    payment: {
      id: 'pa_cqd3uy1v',
      paymentable: {
        id: SUBSCRIPTION_ID,
        type: 'Subscription',
        metadata: { plan_id: 'pro_student', user_id: USER_ID },
      },
    },
    metadata: { plan_id: 'pro_student', user_id: USER_ID },
    ...overrides,
  };
}

// Payload real de `intent.succeeded`: sin metadata en la raíz, con la
// suscripción en `subscription.id` y metadata anidada en `checkout`.
function intentSucceededPayload(overrides: Record<string, unknown> = {}) {
  return {
    id: 'in_aabdgs2u',
    type: 'bank_transfer',
    status: 'succeeded',
    event_type: 'intent.succeeded',
    api_version: '2026-06-01',
    created_at: '2026-11-26T20:10:01.876-06:00',
    customer_id: 'cus_2hjinu9c',
    subscription: { id: SUBSCRIPTION_ID },
    checkout: {
      id: 'ch_aaxlxwatsw87hdzw',
      status: 'paid',
      live_mode: false,
      metadata: { plan_id: 'pro_student', user_id: USER_ID },
      items: [{ price_id: 'price_fhqoditt', quantity: 1, metadata: {} }],
    },
    payment: {
      id: 'pa_cqd3uy1v',
      paymentable: {
        id: SUBSCRIPTION_ID,
        type: 'Subscription',
        metadata: { plan_id: 'pro_student', user_id: USER_ID },
      },
    },
    ...overrides,
  };
}

describe('POST /api/v1/webhooks/recurrente', () => {
  beforeEach(() => {
    state.events.clear();
    state.rpcCalls = [];
    state.rpcError = null;
    state.recurrenteUpdates = [];
    state.openSubscriptionId = 'sub_rec_existing';
    state.remoteSubscriptionError = null;
    state.planByPrice = 'pro_student';
    state.remoteSubscription = {
      id: SUBSCRIPTION_ID,
      status: 'active',
      current_period_start: '2026-11-26T20:10:01.513-06:00',
      current_period_end: '2026-12-26T20:10:01.513-06:00',
      cancel_at_period_end: false,
      metadata: { plan_id: 'pro_student', user_id: USER_ID },
    };
  });

  it('rechaza firma Svix inválida con 401', async () => {
    const req = buildSignedRequest(
      'msg_bad_sig',
      subscriptionCreatePayload(),
      'whsec_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='
    );
    const res = await handleRecurrenteWebhook(req, baseEnv, {});
    expect(res.status).toBe(401);
    expect(state.rpcCalls).toHaveLength(0);
  });

  it('rechaza checkout.live_mode=true en ambiente sandbox con 400', async () => {
    const req = buildSignedRequest('msg_wrong_sbx', {
      ...intentSucceededPayload(),
      checkout: {
        ...(intentSucceededPayload().checkout as Record<string, unknown>),
        live_mode: true,
      },
    });
    const res = await handleRecurrenteWebhook(req, baseEnv, {});
    expect(res.status).toBe(400);
    expect(state.rpcCalls).toHaveLength(0);
  });

  it('procesa subscription.create con el ID en event.id y metadata en la raíz', async () => {
    const res = await handleRecurrenteWebhook(
      buildSignedRequest('msg_sub_create', subscriptionCreatePayload()),
      baseEnv,
      {}
    );

    expect(res.status).toBe(200);
    expect(state.rpcCalls).toHaveLength(1);

    const params = state.rpcCalls[0].params;
    expect(state.rpcCalls[0].name).toBe('billing_apply_subscription_event');
    expect(params.p_user_id).toBe(USER_ID);
    expect(params.p_plan_id).toBe('pro_student');
    expect(params.p_recurrente_subscription_id).toBe(SUBSCRIPTION_ID);
    expect(params.p_status).toBe('active');
    // Las fechas vienen de la API de Recurrente, no del webhook
    expect(params.p_period_start).toBe('2026-11-26T20:10:01.513-06:00');
    expect(params.p_period_end).toBe('2026-12-26T20:10:01.513-06:00');
    expect(params.p_live_mode).toBe(false);
    expect(state.events.get('msg_sub_create')?.processing_status).toBe('processed');
  });

  it('procesa intent.succeeded con metadata anidada en checkout', async () => {
    const res = await handleRecurrenteWebhook(
      buildSignedRequest('msg_intent_ok', intentSucceededPayload()),
      baseEnv,
      {}
    );

    expect(res.status).toBe(200);
    expect(state.rpcCalls).toHaveLength(1);
    expect(state.rpcCalls[0].params.p_user_id).toBe(USER_ID);
    expect(state.rpcCalls[0].params.p_plan_id).toBe('pro_student');
    expect(state.rpcCalls[0].params.p_recurrente_subscription_id).toBe(SUBSCRIPTION_ID);
    expect(state.rpcCalls[0].params.p_status).toBe('active');
    expect(state.rpcCalls[0].params.p_period_end).toBe('2026-12-26T20:10:01.513-06:00');
  });

  it('usa la metadata de la suscripción y el price_id cuando el webhook no trae metadata', async () => {
    state.remoteSubscription = {
      ...state.remoteSubscription,
      metadata: { user_id: USER_ID },
    };

    const payload = subscriptionCreatePayload() as Record<string, unknown>;
    delete payload.metadata;
    delete (payload.payment as Record<string, unknown>).paymentable;

    const res = await handleRecurrenteWebhook(
      buildSignedRequest('msg_remote_meta', payload),
      baseEnv,
      {}
    );

    expect(res.status).toBe(200);
    expect(state.rpcCalls[0].params.p_user_id).toBe(USER_ID);
    expect(state.rpcCalls[0].params.p_plan_id).toBe('pro_student');
  });

  it('deduplica reintentos con el mismo svix-id sin volver a aplicar el evento', async () => {
    const payload = subscriptionCreatePayload();

    const first = await handleRecurrenteWebhook(
      buildSignedRequest('msg_dup_1', payload),
      baseEnv,
      {}
    );
    expect(first.status).toBe(200);
    expect(state.rpcCalls).toHaveLength(1);

    const second = await handleRecurrenteWebhook(
      buildSignedRequest('msg_dup_1', payload),
      baseEnv,
      {}
    );
    expect(second.status).toBe(200);
    const body = (await second.json()) as { deduplicated?: boolean };
    expect(body.deduplicated).toBe(true);
    expect(state.rpcCalls).toHaveLength(1);
  });

  it('reprocesa el evento si el intento anterior falló (Svix reintenta)', async () => {
    const payload = subscriptionCreatePayload();
    state.rpcError = { message: 'database temporarily unavailable' };

    const failed = await handleRecurrenteWebhook(
      buildSignedRequest('msg_retry_1', payload),
      baseEnv,
      {}
    );
    expect(failed.status).toBe(500);
    expect(state.events.get('msg_retry_1')?.processing_status).toBe('failed');

    state.rpcError = null;
    const retried = await handleRecurrenteWebhook(
      buildSignedRequest('msg_retry_1', payload),
      baseEnv,
      {}
    );
    expect(retried.status).toBe(200);
    expect(state.rpcCalls).toHaveLength(2);
    expect(state.events.get('msg_retry_1')?.processing_status).toBe('processed');
  });

  it('ignora eventos legacy bank_transfer_intent.succeeded sin aplicar RPC', async () => {
    const res = await handleRecurrenteWebhook(
      buildSignedRequest('msg_legacy_1', {
        event_type: 'bank_transfer_intent.succeeded',
        live_mode: false,
      }),
      baseEnv,
      {}
    );
    expect(res.status).toBe(200);
    const body = (await res.json()) as { ignored?: boolean };
    expect(body.ignored).toBe(true);
    expect(state.rpcCalls).toHaveLength(0);
  });

  it('actualiza payment_method_id al recibir setup_intent.succeeded con metadata anidada', async () => {
    const req = buildSignedRequest('msg_setup_1', {
      event_type: 'setup_intent.succeeded',
      live_mode: false,
      checkout: {
        live_mode: false,
        metadata: { user_id: USER_ID, purpose: 'update_card' },
        payment_method: { id: 'pm_new_card_99' },
      },
    });

    const res = await handleRecurrenteWebhook(req, baseEnv, {});
    expect(res.status).toBe(200);
    expect(state.recurrenteUpdates).toEqual([
      { id: 'sub_rec_existing', payload: { payment_method_id: 'pm_new_card_99' } },
    ]);
  });
});
