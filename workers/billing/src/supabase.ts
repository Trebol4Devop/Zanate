import { createClient, type SupabaseClient, type User } from '@supabase/supabase-js';
import type { Env } from './types';

export function createAnonClient(env: Env): SupabaseClient {
  return createClient(env.SUPABASE_URL, env.SUPABASE_ANON_KEY, {
    auth: {
      persistSession: false,
      autoRefreshToken: false,
    },
  });
}

export function createServiceClient(env: Env): SupabaseClient {
  return createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, {
    auth: {
      persistSession: false,
      autoRefreshToken: false,
    },
  });
}

export type AuthResult =
  | { ok: true; user: User }
  | { ok: false; status: number; code: string; message: string };

export async function authenticateUser(request: Request, env: Env): Promise<AuthResult> {
  const authHeader = request.headers.get('authorization') || '';
  if (!authHeader.toLowerCase().startsWith('bearer ')) {
    return {
      ok: false,
      status: 401,
      code: 'unauthorized',
      message: 'Missing or invalid Authorization header',
    };
  }

  const token = authHeader.slice(7).trim();
  if (!token) {
    return {
      ok: false,
      status: 401,
      code: 'unauthorized',
      message: 'Bearer token cannot be empty',
    };
  }

  const supabaseAnon = createAnonClient(env);
  const { data, error } = await supabaseAnon.auth.getUser(token);
  if (error || !data?.user || data.user.is_anonymous) {
    return {
      ok: false,
      status: 401,
      code: 'unauthorized',
      message: 'Invalid or expired authentication session',
    };
  }

  return { ok: true, user: data.user };
}

export async function isStaffUser(
  supabaseService: SupabaseClient,
  userId: string
): Promise<{ ok: boolean; error?: string }> {
  const { data, error } = await supabaseService
    .from('user_roles')
    .select('role')
    .eq('user_id', userId)
    .maybeSingle();

  if (error) {
    return { ok: false, error: error.message };
  }

  const role = data?.role;
  return { ok: role === 'admin' || role === 'moderator' };
}
