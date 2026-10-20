import { createClient, type SupabaseClient } from '@supabase/supabase-js'

// VITE_* when set by hand; NEXT_PUBLIC_* when the Supabase <-> Vercel integration sets them.
// Only public values carry these prefixes (vite.config.ts envPrefix); the service-role key never does.
const env = import.meta.env
const url = (env.VITE_SUPABASE_URL ?? env.NEXT_PUBLIC_SUPABASE_URL) as string | undefined
const anonKey = (env.VITE_SUPABASE_ANON_KEY ?? env.NEXT_PUBLIC_SUPABASE_ANON_KEY ??
  env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY) as string | undefined

/** True when the Vercel / local env has both Supabase settings. */
export const supabaseConfigured = Boolean(url && anonKey)

// When the settings are missing the app shows a setup screen instead of crashing.
export const supabase: SupabaseClient = supabaseConfigured
  ? createClient(url!, anonKey!, { auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true } })
  : (null as unknown as SupabaseClient)
