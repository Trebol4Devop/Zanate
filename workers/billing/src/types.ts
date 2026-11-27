export type RecurrenteEnvironment = 'sandbox' | 'live';

export interface Env {
  RECURRENTE_ENVIRONMENT: RecurrenteEnvironment | string;
  RECURRENTE_EXPECTED_SANDBOX_ID?: string;
  RECURRENTE_SECRET_KEY: string;
  RECURRENTE_WEBHOOK_SECRET: string;
  SUPABASE_URL: string;
  SUPABASE_ANON_KEY: string;
  SUPABASE_SERVICE_ROLE_KEY: string;
  ALLOWED_ORIGINS: string;
}

export interface RecurrenteTestResponse {
  environment?: string;
  sandbox_id?: string | null;
  live_mode?: boolean;
  [key: string]: unknown;
}

export interface RecurrenteCheckoutResponse {
  id: string;
  checkout_url: string;
}

export interface RecurrenteSubscriptionResponse {
  id: string;
  status?: string;
  current_period_start?: string | null;
  current_period_end?: string | null;
  cancel_at_period_end?: boolean;
  [key: string]: unknown;
}

export interface CheckoutRequestPayload {
  plan_id: string;
  success_url?: string;
  cancel_url?: string;
}

export interface SetupCardRequestPayload {
  success_url?: string;
  cancel_url?: string;
}

export interface UpdateSubscriptionPayload {
  plan_id?: string;
  mode?: 'now' | 'next_cycle';
  act?: 'pause' | 'unpause';
  payment_method_id?: string;
}
