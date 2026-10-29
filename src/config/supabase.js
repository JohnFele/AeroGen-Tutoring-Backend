import { createClient } from '@supabase/supabase-js';
import { ENV } from './env.config.js';

export const assertSupabaseConfigured = () => {
  const missing = ['SUPABASE_URL', 'SUPABASE_PUBLISHABLE_KEY'].filter((key) => !ENV[key]);
  if (missing.length) {
    throw new Error(`Missing required environment variables: ${missing.join(', ')}`);
  }
};

export const createUserSupabaseClient = (accessToken) => {
  assertSupabaseConfigured();
  return createClient(ENV.SUPABASE_URL, ENV.SUPABASE_PUBLISHABLE_KEY, {
    auth: { autoRefreshToken: false, persistSession: false },
    global: { headers: { Authorization: `Bearer ${accessToken}` } },
  });
};

export const createPublicSupabaseClient = () => {
  assertSupabaseConfigured();
  return createClient(ENV.SUPABASE_URL, ENV.SUPABASE_PUBLISHABLE_KEY, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
};
