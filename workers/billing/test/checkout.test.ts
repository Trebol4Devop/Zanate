import { describe, it, expect, vi, beforeEach } from 'vitest';
import { handleCreateCheckout, handleSetupCard } from '../src/handlers/checkout';
import type { Env } from '../src/types';

const { state } = vi.hoisted(() => ({
  state: {
    user: { id: 'seller-uuid-1', is_anonymous: false } as { id: string; is_anonymous: boolean } | null,
    plan: {
      id: 'pro_student',
      name: 'Emprendedor',
      price_monthly: 25,
      recurrente_price_id: 'price_rec_pro',
      is_active: true,
    } as Record<string, unknown> | null,
    checkoutCalls: [] as Array<Record<string, unknown>>,
  },
}));

vi.mock('../src/supabase', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../src/supabase')>();
  return {
    ...actual,
    authenticateUser: vi.fn(async (req: Request) => {
      if (!req.headers.get('authorization') || !state.user) {
        return { ok: false as const, status: 401, code: 'unauthorized', message: 'Unauthorized' };
      }
      return { ok: true as const, user: state.user as never };
    }),
    createServiceClient: () => ({
      from: vi.fn(() => ({
        select: vi.fn(() => ({
          eq: vi.fn(() => ({
            maybeSingle: vi.fn(async () => ({ data: state.plan, error: null })),
          })),
        })),
      })),
    }),
  };
});

vi.mock('../src/recurrente', () => ({
  createRecurrenteCheckout: vi.fn(async (_env: Env, payload: Record<string, unknown>) => {
    state.checkoutCalls.push(payload);
    return {
      id: 'chk_123',
      checkout_url: 'https://app.recurrente.com/c/chk_123',
    };
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

describe('Checkout handlers', () => {
  beforeEach(() => {
    state.user = { id: 'seller-uuid-1', is_anonymous: false };
    state.plan = {
      id: 'pro_student',
      name: 'Emprendedor',
      price_monthly: 25,
      recurrente_price_id: 'price_rec_pro',
      is_active: true,
    };
    state.checkoutCalls = [];
  });

  it('rechaza checkout sin JWT válido con 401', async () => {
    const req = new Request('https://billing.test/api/v1/billing/checkout', {
      method: 'POST',
      body: JSON.stringify({ plan_id: 'pro_student' }),
    });
    const res = await handleCreateCheckout(req, env, {});
    expect(res.status).toBe(401);
  });

  it('rechaza plan free con 400', async () => {
    const req = new Request('https://billing.test/api/v1/billing/checkout', {
      method: 'POST',
      headers: { authorization: 'Bearer valid-jwt' },
      body: JSON.stringify({ plan_id: 'free' }),
    });
    const res = await handleCreateCheckout(req, env, {});
    expect(res.status).toBe(400);
  });

  it('crea checkout con metadata { user_id, plan_id } y devuelve 201', async () => {
    const req = new Request('https://billing.test/api/v1/billing/checkout', {
      method: 'POST',
      headers: { authorization: 'Bearer valid-jwt' },
      body: JSON.stringify({ plan_id: 'pro_student' }),
    });
    const res = await handleCreateCheckout(req, env, {});
    expect(res.status).toBe(201);
    const body = (await res.json()) as { checkout_id: string; checkout_url: string };
    expect(body.checkout_id).toBe('chk_123');
    expect(state.checkoutCalls[0].metadata).toEqual({
      user_id: 'seller-uuid-1',
      plan_id: 'pro_student',
    });
  });

  it('crea setup-card en mode: "setup" con purpose: "update_card"', async () => {
    const req = new Request('https://billing.test/api/v1/billing/setup-card', {
      method: 'POST',
      headers: { authorization: 'Bearer valid-jwt' },
    });
    const res = await handleSetupCard(req, env, {});
    expect(res.status).toBe(201);
    expect(state.checkoutCalls[0]).toMatchObject({
      mode: 'setup',
      metadata: {
        user_id: 'seller-uuid-1',
        purpose: 'update_card',
      },
    });
  });
});
