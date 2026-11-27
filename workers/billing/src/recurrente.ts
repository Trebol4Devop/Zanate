import type {
  Env,
  RecurrenteCheckoutResponse,
  RecurrenteSubscriptionResponse,
  RecurrenteTestResponse,
} from './types';

export const RECURRENTE_BASE_URL = 'https://app.recurrente.com/api';

export class RecurrenteApiError extends Error {
  constructor(
    public readonly status: number,
    public readonly body: string
  ) {
    super(`Recurrente API error (${status}): ${body}`);
    this.name = 'RecurrenteApiError';
  }
}

async function recurrenteFetch<T>(
  env: Env,
  path: string,
  init: RequestInit = {}
): Promise<T> {
  const res = await fetch(`${RECURRENTE_BASE_URL}${path}`, {
    ...init,
    headers: {
      'Content-Type': 'application/json',
      'X-SECRET-KEY': env.RECURRENTE_SECRET_KEY,
      ...(init.headers || {}),
    },
  });

  const text = await res.text();
  if (!res.ok) {
    throw new RecurrenteApiError(res.status, text);
  }

  return (text ? JSON.parse(text) : {}) as T;
}

export function testRecurrenteCredentials(env: Env): Promise<RecurrenteTestResponse> {
  return recurrenteFetch<RecurrenteTestResponse>(env, '/test', { method: 'GET' });
}

export function createRecurrenteCheckout(
  env: Env,
  payload: Record<string, unknown>
): Promise<RecurrenteCheckoutResponse> {
  return recurrenteFetch<RecurrenteCheckoutResponse>(env, '/checkouts', {
    method: 'POST',
    body: JSON.stringify(payload),
  });
}

export function updateRecurrenteSubscription(
  env: Env,
  subscriptionId: string,
  payload: Record<string, unknown>
): Promise<RecurrenteSubscriptionResponse> {
  return recurrenteFetch<RecurrenteSubscriptionResponse>(
    env,
    `/subscriptions/${encodeURIComponent(subscriptionId)}`,
    {
      method: 'PUT',
      body: JSON.stringify(payload),
    }
  );
}

export function cancelRecurrenteSubscription(
  env: Env,
  subscriptionId: string
): Promise<Record<string, unknown>> {
  return recurrenteFetch<Record<string, unknown>>(
    env,
    `/subscriptions/${encodeURIComponent(subscriptionId)}`,
    {
      method: 'DELETE',
    }
  );
}
