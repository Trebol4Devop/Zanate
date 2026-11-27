import { describe, it, expect, vi, beforeEach } from 'vitest';
import worker from '../src/index';
import { RecurrenteApiError } from '../src/recurrente';
import type { Env } from '../src/types';

const USER_ID = '9037e5be-daa0-4a34-a442-fd6870fe8128';
const SUBSCRIPTION_ID = 'su_utd93kqh';

interface MockPlan {
  id: string;
  price_monthly: number;
  recurrente_price_id: string | null;
  recurrente_product_id?: string | null;
  is_active: boolean;
}

interface MockWebhookRow {
  svix_id: string;
  event_type: string;
  sandbox_id: string | null;
  live_mode: boolean;
  processing_status: 'received' | 'processed' | 'ignored' | 'failed';
  error_message: string | null;
  received_at: string;
  processed_at: string | null;
  payload: unknown;
}

const { state } = vi.hoisted(() => ({
  state: {
    authUsers: new Map<string, { id: string; is_anonymous: boolean }>(),
    userRoles: new Map<string, string>(),
    localSubscriptions: new Set<string>(),
    plans: new Map<string, MockPlan>(),
    webhookEvents: new Map<string, MockWebhookRow>(),
    inboxUpdates: [] as Array<{ svixId: string; patch: Record<string, unknown> }>,
    unexpectedMutations: [] as Array<{ table: string; op: string }>,
    auditInserts: [] as Array<Record<string, unknown>>,
    rpcCalls: [] as Array<{ name: string; params: Record<string, unknown> }>,
    rpcError: null as { message: string } | null,
    remoteSubscription: null as Record<string, unknown> | null,
    remoteSubscriptionError: null as Error | null,
    updateCalls: [] as Array<{ id: string; payload: Record<string, unknown> }>,
    updateError: null as Error | null,
    cancelCalls: [] as string[],
    cancelError: null as Error | null,
  },
}));

vi.mock('../src/supabase', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../src/supabase')>();
  return {
    ...actual,
    authenticateUser: vi.fn(async (req: Request) => {
      const header = req.headers.get('authorization') || '';
      if (!header.toLowerCase().startsWith('bearer ')) {
        return {
          ok: false as const,
          status: 401,
          code: 'unauthorized',
          message: 'Missing or invalid Authorization header',
        };
      }
      const token = header.slice(7).trim();
      const user = state.authUsers.get(token);
      if (!user) {
        return {
          ok: false as const,
          status: 401,
          code: 'unauthorized',
          message: 'Invalid or expired authentication session',
        };
      }
      return { ok: true as const, user: user as never };
    }),
    createServiceClient: () => ({
      from: vi.fn((table: string) => {
        if (table === 'user_roles') {
          return {
            select: vi.fn(() => ({
              eq: vi.fn((_col: string, userId: string) => ({
                maybeSingle: vi.fn(async () => {
                  const role = state.userRoles.get(userId);
                  return { data: role ? { role } : null, error: null };
                }),
              })),
            })),
          };
        }

        if (table === 'marketplace_subscriptions') {
          return {
            select: vi.fn(() => ({
              eq: vi.fn((col: string, value: string) => {
                if (col === 'recurrente_subscription_id') {
                  return {
                    limit: vi.fn(() => ({
                      maybeSingle: vi.fn(async () => ({
                        data: state.localSubscriptions.has(value)
                          ? { id: 'sub-db-1', recurrente_subscription_id: value }
                          : null,
                        error: null,
                      })),
                    })),
                  };
                }
                return {
                  in: vi.fn(() => ({
                    order: vi.fn(() => ({
                      limit: vi.fn(() => ({
                        maybeSingle: vi.fn(async () => ({ data: null, error: null })),
                      })),
                    })),
                  })),
                };
              }),
            })),
            insert: vi.fn(async () => {
              state.unexpectedMutations.push({ table, op: 'insert' });
              return { error: null };
            }),
            update: vi.fn(() => {
              state.unexpectedMutations.push({ table, op: 'update' });
              return { eq: vi.fn(async () => ({ error: null })) };
            }),
          };
        }

        if (table === 'seller_profiles') {
          return {
            insert: vi.fn(async () => {
              state.unexpectedMutations.push({ table, op: 'insert' });
              return { error: null };
            }),
            update: vi.fn(() => {
              state.unexpectedMutations.push({ table, op: 'update' });
              return { eq: vi.fn(async () => ({ error: null })) };
            }),
          };
        }

        if (table === 'marketplace_plans') {
          return {
            select: vi.fn(() => ({
              eq: vi.fn((_col: string, planId: string) => ({
                maybeSingle: vi.fn(async () => ({
                  data: state.plans.get(planId) ?? null,
                  error: null,
                })),
              })),
              in: vi.fn((col: string, values: string[]) => ({
                limit: vi.fn(() => ({
                  maybeSingle: vi.fn(async () => {
                    const match = [...state.plans.values()].find((p) =>
                      col === 'recurrente_price_id'
                        ? Boolean(p.recurrente_price_id && values.includes(p.recurrente_price_id))
                        : Boolean(p.recurrente_product_id && values.includes(p.recurrente_product_id))
                    );
                    return { data: match ? { id: match.id } : null, error: null };
                  }),
                })),
              })),
            })),
          };
        }

        if (table === 'recurrente_webhook_events') {          const listRange = (statusFilter?: string) => ({
            range: vi.fn(async (from: number, to: number) => {
              let rows = [...state.webhookEvents.values()].sort((a, b) =>
                b.received_at.localeCompare(a.received_at)
              );
              if (statusFilter) {
                rows = rows.filter((r) => r.processing_status === statusFilter);
              }
              return { data: rows.slice(from, to + 1), error: null };
            }),
          });

          return {
            select: vi.fn(() => ({
              eq: vi.fn((_col: string, svixId: string) => ({
                maybeSingle: vi.fn(async () => ({
                  data: state.webhookEvents.get(svixId) ?? null,
                  error: null,
                })),
              })),
              order: vi.fn(() => ({
                eq: vi.fn((_col: string, statusFilter: string) => listRange(statusFilter)),
                ...listRange(),
              })),
            })),
            update: vi.fn((patch: Record<string, unknown>) => ({
              eq: vi.fn(async (_col: string, svixId: string) => {
                state.inboxUpdates.push({ svixId, patch });
                const current = state.webhookEvents.get(svixId);
                if (current) {
                  state.webhookEvents.set(svixId, {
                    ...current,
                    ...(patch as Partial<MockWebhookRow>),
                  });
                }
                return { error: null };
              }),
            })),
          };
        }

        if (table === 'marketplace_admin_audit') {
          return {
            insert: vi.fn(async (row: Record<string, unknown>) => {
              state.auditInserts.push(row);
              return { error: null };
            }),
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
  };
});

vi.mock('../src/recurrente', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../src/recurrente')>();
  return {
    ...actual,
    getRecurrenteSubscription: vi.fn(async () => {
      if (state.remoteSubscriptionError) throw state.remoteSubscriptionError;
      return state.remoteSubscription;
    }),
    updateRecurrenteSubscription: vi.fn(
      async (_env: Env, id: string, payload: Record<string, unknown>) => {
        if (state.updateError) throw state.updateError;
        state.updateCalls.push({ id, payload });
        return { id, status: 'active', ...payload };
      }
    ),
    cancelRecurrenteSubscription: vi.fn(async (_env: Env, id: string) => {
      if (state.cancelError) throw state.cancelError;
      state.cancelCalls.push(id);
      return { id, status: 'cancelled' };
    }),
  };
});

const env: Env = {
  RECURRENTE_ENVIRONMENT: 'sandbox',
  RECURRENTE_EXPECTED_SANDBOX_ID: 'sbx_usac_1',
  RECURRENTE_SECRET_KEY: 'sk_test_secret_leak_999',
  RECURRENTE_WEBHOOK_SECRET: 'whsec_secret_leak_888',
  SUPABASE_URL: 'http://127.0.0.1:54321',
  SUPABASE_ANON_KEY: 'anon',
  SUPABASE_SERVICE_ROLE_KEY: 'service_secret_777',
  ALLOWED_ORIGINS:
    'https://zanate.pages.dev,http://localhost:3000,http://localhost:8080,http://localhost:5173,http://127.0.0.1:5173',
};

const ctx = {} as ExecutionContext;

function makeRequest(
  path: string,
  options: { method?: string; token?: string; body?: unknown; origin?: string } = {}
): Request {
  const headers: Record<string, string> = {};
  if (options.token) {
    headers.authorization = `Bearer ${options.token}`;
  }
  if (options.origin) {
    headers.Origin = options.origin;
  }
  if (options.body !== undefined) {
    headers['Content-Type'] = 'application/json';
  }
  return new Request(`https://billing.test${path}`, {
    method: options.method ?? 'GET',
    headers,
    ...(options.body !== undefined ? { body: JSON.stringify(options.body) } : {}),
  });
}

function subscriptionCreatePayload() {
  return {
    id: SUBSCRIPTION_ID,
    status: 'active',
    event_type: 'subscription.create',
    live_mode: false,
    customer_id: 'cus_2hjinu9c',
    cancel_at_period_end: false,
    items: [{ price_id: 'price_fhqoditt', product_id: 'prod_4e6e4jcl', quantity: 1 }],
    metadata: { plan_id: 'pro_student', user_id: USER_ID },
  };
}

function intentSucceededPayload() {
  return {
    id: 'in_aabdgs2u',
    type: 'bank_transfer',
    status: 'succeeded',
    event_type: 'intent.succeeded',
    customer_id: 'cus_2hjinu9c',
    subscription: { id: SUBSCRIPTION_ID },
    checkout: {
      id: 'ch_aaxlxwatsw87hdzw',
      status: 'paid',
      live_mode: false,
      metadata: { plan_id: 'pro_student', user_id: USER_ID },
      items: [{ price_id: 'price_fhqoditt', quantity: 1 }],
    },
  };
}

describe('Admin billing endpoints', () => {
  beforeEach(() => {
    state.authUsers.clear();
    state.userRoles.clear();
    state.localSubscriptions.clear();
    state.plans.clear();
    state.webhookEvents.clear();
    state.inboxUpdates = [];
    state.unexpectedMutations = [];
    state.auditInserts = [];
    state.rpcCalls = [];
    state.rpcError = null;
    state.remoteSubscriptionError = null;
    state.updateCalls = [];
    state.updateError = null;
    state.cancelCalls = [];
    state.cancelError = null;

    state.authUsers.set('jwt-admin', { id: 'admin-1', is_anonymous: false });
    state.authUsers.set('jwt-mod', { id: 'mod-1', is_anonymous: false });
    state.authUsers.set('jwt-user', { id: 'user-1', is_anonymous: false });

    state.userRoles.set('admin-1', 'admin');
    state.userRoles.set('mod-1', 'moderator');
    state.userRoles.set('user-1', 'user');

    state.localSubscriptions.add(SUBSCRIPTION_ID);

    state.plans.set('pro_student', {
      id: 'pro_student',
      price_monthly: 25,
      recurrente_price_id: 'price_fhqoditt',
      recurrente_product_id: 'prod_4e6e4jcl',
      is_active: true,
    });
    state.plans.set('business_local', {
      id: 'business_local',
      price_monthly: 99,
      recurrente_price_id: 'price_rec_biz',
      is_active: true,
    });
    state.plans.set('unconfigured_plan', {
      id: 'unconfigured_plan',
      price_monthly: 50,
      recurrente_price_id: null,
      is_active: true,
    });

    state.remoteSubscription = {
      id: SUBSCRIPTION_ID,
      status: 'active',
      current_period_start: '2026-11-26T20:10:01.513-06:00',
      current_period_end: '2026-12-26T20:10:01.513-06:00',
      cancel_at_period_end: false,
      metadata: { plan_id: 'pro_student', user_id: USER_ID },
    };

    state.webhookEvents.set('msg_failed_1', {
      svix_id: 'msg_failed_1',
      event_type: 'subscription.create',
      sandbox_id: 'sbx_usac_1',
      live_mode: false,
      processing_status: 'failed',
      error_message: 'Incomplete webhook payload',
      received_at: '2026-11-26T20:10:02.000Z',
      processed_at: '2026-11-26T20:10:03.000Z',
      payload: subscriptionCreatePayload(),
    });
    state.webhookEvents.set('msg_processed_1', {
      svix_id: 'msg_processed_1',
      event_type: 'subscription.create',
      sandbox_id: 'sbx_usac_1',
      live_mode: false,
      processing_status: 'processed',
      error_message: null,
      received_at: '2026-11-26T20:05:00.000Z',
      processed_at: '2026-11-26T20:05:01.000Z',
      payload: subscriptionCreatePayload(),
    });
    state.webhookEvents.set('msg_ignored_1', {
      svix_id: 'msg_ignored_1',
      event_type: 'intent.succeeded',
      sandbox_id: null,
      live_mode: false,
      processing_status: 'ignored',
      error_message: null,
      received_at: '2026-11-26T20:00:00.000Z',
      processed_at: '2026-11-26T20:00:01.000Z',
      payload: intentSucceededPayload(),
    });
  });

  it('1. rechaza peticiones sin JWT con 401', async () => {
    const responses = await Promise.all([
      worker.fetch(
        makeRequest(`/api/v1/billing/admin/subscription?subscription_id=${SUBSCRIPTION_ID}`),
        env,
        ctx
      ),
      worker.fetch(
        makeRequest('/api/v1/billing/admin/subscription/action', {
          method: 'POST',
          body: { recurrente_subscription_id: SUBSCRIPTION_ID, action: 'cancel' },
        }),
        env,
        ctx
      ),
      worker.fetch(makeRequest('/api/v1/billing/admin/webhooks'), env, ctx),
      worker.fetch(
        makeRequest('/api/v1/billing/admin/webhooks/reprocess', {
          method: 'POST',
          body: { svix_id: 'msg_failed_1' },
        }),
        env,
        ctx
      ),
    ]);

    for (const res of responses) {
      expect(res.status).toBe(401);
    }
  });

  it('2. rechaza usuario sin rol staff con 403 en GET', async () => {
    const getSub = await worker.fetch(
      makeRequest(`/api/v1/billing/admin/subscription?subscription_id=${SUBSCRIPTION_ID}`, {
        token: 'jwt-user',
      }),
      env,
      ctx
    );
    expect(getSub.status).toBe(403);

    const getWebhooks = await worker.fetch(
      makeRequest('/api/v1/billing/admin/webhooks', { token: 'jwt-user' }),
      env,
      ctx
    );
    expect(getWebhooks.status).toBe(403);
  });

  it('3. moderador puede GET suscripción y GET webhooks con filtros', async () => {
    const subRes = await worker.fetch(
      makeRequest(`/api/v1/billing/admin/subscription?subscription_id=${SUBSCRIPTION_ID}`, {
        token: 'jwt-mod',
      }),
      env,
      ctx
    );
    expect(subRes.status).toBe(200);
    const subBody = (await subRes.json()) as { subscription: Record<string, unknown> };
    expect(subBody.subscription.id).toBe(SUBSCRIPTION_ID);

    const hooksRes = await worker.fetch(
      makeRequest('/api/v1/billing/admin/webhooks?status=ignored&search=ch_aaxlxwatsw87hdzw&limit=10&offset=0', {
        token: 'jwt-mod',
      }),
      env,
      ctx
    );
    expect(hooksRes.status).toBe(200);
    const hooksBody = (await hooksRes.json()) as { events: MockWebhookRow[] };
    expect(hooksBody.events).toHaveLength(1);
    expect(hooksBody.events[0].svix_id).toBe('msg_ignored_1');
  });

  it('4. moderador no puede POST action ni POST reprocess (403)', async () => {
    const actionRes = await worker.fetch(
      makeRequest('/api/v1/billing/admin/subscription/action', {
        method: 'POST',
        token: 'jwt-mod',
        body: { recurrente_subscription_id: SUBSCRIPTION_ID, action: 'cancel' },
      }),
      env,
      ctx
    );
    expect(actionRes.status).toBe(403);

    const reprocessRes = await worker.fetch(
      makeRequest('/api/v1/billing/admin/webhooks/reprocess', {
        method: 'POST',
        token: 'jwt-mod',
        body: { svix_id: 'msg_failed_1' },
      }),
      env,
      ctx
    );
    expect(reprocessRes.status).toBe(403);
    expect(state.cancelCalls).toHaveLength(0);
    expect(state.rpcCalls).toHaveLength(0);
  });

  it('5. admin puede cancelar, cambiar de plan, pausar y reanudar sin mutar BD local', async () => {
    const cancelRes = await worker.fetch(
      makeRequest('/api/v1/billing/admin/subscription/action', {
        method: 'POST',
        token: 'jwt-admin',
        body: {
          recurrente_subscription_id: SUBSCRIPTION_ID,
          action: 'cancel',
          note: 'Cancelación solicitada por soporte',
        },
      }),
      env,
      ctx
    );
    expect(cancelRes.status).toBe(200);
    expect(state.cancelCalls).toEqual([SUBSCRIPTION_ID]);

    const changeDefaultRes = await worker.fetch(
      makeRequest('/api/v1/billing/admin/subscription/action', {
        method: 'POST',
        token: 'jwt-admin',
        body: {
          recurrente_subscription_id: SUBSCRIPTION_ID,
          action: 'change_plan',
          plan_id: 'business_local',
        },
      }),
      env,
      ctx
    );
    expect(changeDefaultRes.status).toBe(200);

    const changeNowRes = await worker.fetch(
      makeRequest('/api/v1/billing/admin/subscription/action', {
        method: 'POST',
        token: 'jwt-admin',
        body: {
          recurrente_subscription_id: SUBSCRIPTION_ID,
          action: 'change_plan',
          plan_id: 'business_local',
          mode: 'now',
        },
      }),
      env,
      ctx
    );
    expect(changeNowRes.status).toBe(200);

    const pauseRes = await worker.fetch(
      makeRequest('/api/v1/billing/admin/subscription/action', {
        method: 'POST',
        token: 'jwt-admin',
        body: { recurrente_subscription_id: SUBSCRIPTION_ID, action: 'pause' },
      }),
      env,
      ctx
    );
    expect(pauseRes.status).toBe(200);

    const unpauseRes = await worker.fetch(
      makeRequest('/api/v1/billing/admin/subscription/action', {
        method: 'POST',
        token: 'jwt-admin',
        body: { recurrente_subscription_id: SUBSCRIPTION_ID, action: 'unpause' },
      }),
      env,
      ctx
    );
    expect(unpauseRes.status).toBe(200);

    expect(state.updateCalls).toEqual([
      {
        id: SUBSCRIPTION_ID,
        payload: {
          items: [{ price_id: 'price_rec_biz', quantity: 1 }],
          mode: 'next_cycle',
        },
      },
      {
        id: SUBSCRIPTION_ID,
        payload: {
          items: [{ price_id: 'price_rec_biz', quantity: 1 }],
          mode: 'now',
        },
      },
      {
        id: SUBSCRIPTION_ID,
        payload: { act: 'pause' },
      },
      {
        id: SUBSCRIPTION_ID,
        payload: { act: 'unpause' },
      },
    ]);
    expect(state.unexpectedMutations).toHaveLength(0);

    expect(state.auditInserts).toHaveLength(5);
    expect(state.auditInserts.map((row) => row.action)).toEqual([
      'subscription.cancel',
      'subscription.change_plan',
      'subscription.change_plan',
      'subscription.pause',
      'subscription.unpause',
    ]);
    expect(state.auditInserts[0]).toMatchObject({
      actor_id: 'admin-1',
      action: 'subscription.cancel',
      target_type: 'subscription',
      target_id: SUBSCRIPTION_ID,
      note: 'Cancelación solicitada por soporte',
    });
    expect(state.auditInserts[2]).toMatchObject({
      action: 'subscription.change_plan',
      details: { plan_id: 'business_local', mode: 'now', source: 'zanate-admin' },
    });
  });

  it('6. change_plan con plan sin recurrente_price_id devuelve 422', async () => {
    const res = await worker.fetch(
      makeRequest('/api/v1/billing/admin/subscription/action', {
        method: 'POST',
        token: 'jwt-admin',
        body: {
          recurrente_subscription_id: SUBSCRIPTION_ID,
          action: 'change_plan',
          plan_id: 'unconfigured_plan',
        },
      }),
      env,
      ctx
    );
    expect(res.status).toBe(422);
    const body = (await res.json()) as { code: string };
    expect(body.code).toBe('plan_not_configured');
    expect(state.updateCalls).toHaveLength(0);
  });

  it('7. reprocesa un evento failed con payload real de subscription.create y aplica RPC', async () => {
    const res = await worker.fetch(
      makeRequest('/api/v1/billing/admin/webhooks/reprocess', {
        method: 'POST',
        token: 'jwt-admin',
        body: { svix_id: 'msg_failed_1' },
      }),
      env,
      ctx
    );
    expect(res.status).toBe(200);
    const body = (await res.json()) as { status: string; reprocessed: boolean };
    expect(body).toEqual({ status: 'processed', reprocessed: true });

    expect(state.rpcCalls).toHaveLength(1);
    expect(state.rpcCalls[0].name).toBe('billing_apply_subscription_event');
    expect(state.rpcCalls[0].params.p_user_id).toBe(USER_ID);
    expect(state.rpcCalls[0].params.p_plan_id).toBe('pro_student');
    expect(state.rpcCalls[0].params.p_recurrente_subscription_id).toBe(SUBSCRIPTION_ID);
    expect(state.rpcCalls[0].params.p_status).toBe('active');

    const row = state.webhookEvents.get('msg_failed_1');
    expect(row?.processing_status).toBe('processed');
    expect(row?.error_message).toBeNull();
    expect(row?.processed_at).toBeTruthy();

    expect(state.auditInserts).toHaveLength(1);
    expect(state.auditInserts[0]).toMatchObject({
      action: 'webhook.reprocess',
      target_type: 'webhook_event',
      target_id: 'msg_failed_1',
      details: {
        event_type: 'subscription.create',
        previous_status: 'failed',
        result: 'processed',
        source: 'zanate-admin',
      },
    });
  });

  it('8. rechaza reprocesar un evento ya processed con 409', async () => {
    const res = await worker.fetch(
      makeRequest('/api/v1/billing/admin/webhooks/reprocess', {
        method: 'POST',
        token: 'jwt-admin',
        body: { svix_id: 'msg_processed_1' },
      }),
      env,
      ctx
    );
    expect(res.status).toBe(409);
    const body = (await res.json()) as { code: string };
    expect(body.code).toBe('already_processed');
    expect(state.rpcCalls).toHaveLength(0);
  });

  it('9. reprocesa un evento ignored histórico con payload válido a processed', async () => {
    const res = await worker.fetch(
      makeRequest('/api/v1/billing/admin/webhooks/reprocess', {
        method: 'POST',
        token: 'jwt-admin',
        body: { svix_id: 'msg_ignored_1' },
      }),
      env,
      ctx
    );
    expect(res.status).toBe(200);
    const body = (await res.json()) as { status: string; reprocessed: boolean };
    expect(body).toEqual({ status: 'processed', reprocessed: true });
    expect(state.rpcCalls).toHaveLength(1);
    expect(state.rpcCalls[0].params.p_user_id).toBe(USER_ID);
    expect(state.webhookEvents.get('msg_ignored_1')?.processing_status).toBe('processed');
  });

  it('10. mapea errores de Recurrente a 502 sin filtrar secretos y 404 cuando no existe', async () => {
    state.remoteSubscriptionError = new RecurrenteApiError(
      500,
      JSON.stringify({
        error: `Upstream failed with key ${env.RECURRENTE_SECRET_KEY} and ${env.RECURRENTE_WEBHOOK_SECRET}`,
      })
    );

    const getErrRes = await worker.fetch(
      makeRequest(`/api/v1/billing/admin/subscription?subscription_id=${SUBSCRIPTION_ID}`, {
        token: 'jwt-mod',
      }),
      env,
      ctx
    );
    expect(getErrRes.status).toBe(502);
    const getErrText = await getErrRes.text();
    expect(getErrText).toContain('recurrente_error');
    expect(getErrText).not.toContain(env.RECURRENTE_SECRET_KEY);
    expect(getErrText).not.toContain(env.RECURRENTE_WEBHOOK_SECRET);

    state.remoteSubscriptionError = new RecurrenteApiError(404, 'Not found');
    const get404Res = await worker.fetch(
      makeRequest(`/api/v1/billing/admin/subscription?subscription_id=${SUBSCRIPTION_ID}`, {
        token: 'jwt-mod',
      }),
      env,
      ctx
    );
    expect(get404Res.status).toBe(404);

    state.updateError = new Error(`Network boom ${env.RECURRENTE_SECRET_KEY}`);
    const actionErrRes = await worker.fetch(
      makeRequest('/api/v1/billing/admin/subscription/action', {
        method: 'POST',
        token: 'jwt-admin',
        body: { recurrente_subscription_id: SUBSCRIPTION_ID, action: 'pause' },
      }),
      env,
      ctx
    );
    expect(actionErrRes.status).toBe(502);
    const actionErrText = await actionErrRes.text();
    expect(actionErrText).toContain('recurrente_error');
    expect(actionErrText).not.toContain(env.RECURRENTE_SECRET_KEY);
  });

  it('permite CORS para orígenes locales de Vite (5173) y devuelve 422 si reprocess falla', async () => {
    const corsRes = await worker.fetch(
      makeRequest('/api/v1/billing/admin/webhooks', {
        method: 'OPTIONS',
        origin: 'http://localhost:5173',
      }),
      env,
      ctx
    );
    expect(corsRes.status).toBe(204);
    expect(corsRes.headers.get('Access-Control-Allow-Origin')).toBe('http://localhost:5173');

    state.webhookEvents.set('msg_bad_payload', {
      svix_id: 'msg_bad_payload',
      event_type: 'subscription.create',
      sandbox_id: 'sbx_usac_1',
      live_mode: false,
      processing_status: 'failed',
      error_message: 'old',
      received_at: '2026-11-26T19:00:00.000Z',
      processed_at: null,
      payload: { event_type: 'subscription.create', live_mode: false },
    });
    state.remoteSubscription = null;

    const reprocessFail = await worker.fetch(
      makeRequest('/api/v1/billing/admin/webhooks/reprocess', {
        method: 'POST',
        token: 'jwt-admin',
        body: { svix_id: 'msg_bad_payload' },
      }),
      env,
      ctx
    );
    expect(reprocessFail.status).toBe(422);
    const failBody = (await reprocessFail.json()) as { code: string };
    expect(failBody.code).toBe('reprocess_failed');
    expect(state.webhookEvents.get('msg_bad_payload')?.processing_status).toBe('failed');
  });
});
