import { describe, it, expect, vi, beforeEach } from 'vitest';
import {
  handleCancelSubscription,
  handleUpdateSubscription,
} from '../src/handlers/subscription';
import type { Env } from '../src/types';

const { state } = vi.hoisted(() => ({
  state: {
    subscription: {
      id: 'sub-db-1',
      plan_id: 'pro_student',
      recurrente_subscription_id: 'sub_rec_1',
      status: 'active',
    } as Record<string, unknown> | null,
    targetPlan: {
      id: 'business_local',
      recurrente_price_id: 'price_rec_biz',
      is_active: true,
    } as Record<string, unknown> | null,
    updateCalls: [] as Array<{ id: string; payload: Record<string, unknown> }>,
    cancelCalls: [] as string[],
  },
}));

vi.mock('../src/supabase', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../src/supabase')>();
  return {
    ...actual,
    authenticateUser: vi.fn(async (req: Request) => {
      if (!req.headers.get('authorization')) {
        return { ok: false as const, status: 401, code: 'unauthorized', message: 'Unauthorized' };
      }
      return { ok: true as const, user: { id: 'seller-uuid-1' } as never };
    }),
    createServiceClient: () => ({
      from: vi.fn((table: string) => {
        if (table === 'marketplace_subscriptions') {
          return {
            select: vi.fn(() => ({
              eq: vi.fn(() => ({
                in: vi.fn(() => ({
                  order: vi.fn(() => ({
                    limit: vi.fn(() => ({
                      maybeSingle: vi.fn(async () => ({ data: state.subscription, error: null })),
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
              eq: vi.fn(() => ({
                maybeSingle: vi.fn(async () => ({ data: state.targetPlan, error: null })),
              })),
            })),
          };
        }
        return {};
      }),
    }),
  };
});

vi.mock('../src/recurrente', () => ({
  updateRecurrenteSubscription: vi.fn(
    async (_env: Env, id: string, payload: Record<string, unknown>) => {
      state.updateCalls.push({ id, payload });
      return { id, status: 'active' };
    }
  ),
  cancelRecurrenteSubscription: vi.fn(async (_env: Env, id: string) => {
    state.cancelCalls.push(id);
    return { status: 'cancelled' };
  }),
}));

const env: Env = {
  RECURRENTE_ENVIRONMENT: 'sandbox',
  RECURRENTE_SECRET_KEY: 'sk_test_123',
  RECURRENTE_WEBHOOK_SECRET: 'whsec_123',
  SUPABASE_URL: 'http://127.0.0.1:54321',
  SUPABASE_ANON_KEY: 'anon',
  SUPABASE_SERVICE_ROLE_KEY: 'service',
  ALLOWED_ORIGINS: '*',
};

describe('Subscription handlers', () => {
  beforeEach(() => {
    state.subscription = {
      id: 'sub-db-1',
      plan_id: 'pro_student',
      recurrente_subscription_id: 'sub_rec_1',
      status: 'active',
    };
    state.updateCalls = [];
    state.cancelCalls = [];
  });

  it('cambia de plan usando mode next_cycle por defecto', async () => {
    const req = new Request('https://billing.test/api/v1/billing/subscription', {
      method: 'PUT',
      headers: { authorization: 'Bearer jwt' },
      body: JSON.stringify({ plan_id: 'business_local' }),
    });
    const res = await handleUpdateSubscription(req, env, {});
    expect(res.status).toBe(200);
    expect(state.updateCalls[0]).toEqual({
      id: 'sub_rec_1',
      payload: {
        items: [{ price_id: 'price_rec_biz', quantity: 1 }],
        mode: 'next_cycle',
      },
    });
  });

  it('pausa suscripción con act: "pause"', async () => {
    const req = new Request('https://billing.test/api/v1/billing/subscription', {
      method: 'PUT',
      headers: { authorization: 'Bearer jwt' },
      body: JSON.stringify({ act: 'pause' }),
    });
    const res = await handleUpdateSubscription(req, env, {});
    expect(res.status).toBe(200);
    expect(state.updateCalls[0]).toEqual({
      id: 'sub_rec_1',
      payload: { act: 'pause' },
    });
  });

  it('cancela suscripción del propietario vía DELETE', async () => {
    const req = new Request('https://billing.test/api/v1/billing/subscription', {
      method: 'DELETE',
      headers: { authorization: 'Bearer jwt' },
    });
    const res = await handleCancelSubscription(req, env, {});
    expect(res.status).toBe(200);
    expect(state.cancelCalls).toEqual(['sub_rec_1']);
  });

  it('devuelve 404 si el usuario no tiene suscripción abierta', async () => {
    state.subscription = null;
    const req = new Request('https://billing.test/api/v1/billing/subscription', {
      method: 'DELETE',
      headers: { authorization: 'Bearer jwt' },
    });
    const res = await handleCancelSubscription(req, env, {});
    expect(res.status).toBe(404);
  });
});
