// DEV ONLY: no Supabase in the phone-layout preview.
export const supabaseConfigured = true
export const appLoginEmail = 'owner@example.com'
export const supabase = {
  rpc: async () => ({ data: null, error: null }),
  functions: { invoke: async () => ({ data: { outcome: 'tested', pushes_ok: 1, pushes_failed: 0, emails: 1, email_errors: [], push_configured: true, email_configured: true }, error: null }) },
} as unknown as import('@supabase/supabase-js').SupabaseClient
