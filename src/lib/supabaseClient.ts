import { createClient, type SupabaseClient } from '@supabase/supabase-js'

// NEXT_PUBLIC_* when the Supabase <-> Vercel integration sets them (these win: the project's old
// VITE_* values point at the retired CRM database); VITE_* when set by hand or locally.
// Only public values carry these prefixes (vite.config.ts envPrefix); the service-role key never does.
const env = import.meta.env
const url = (env.NEXT_PUBLIC_SUPABASE_URL ?? env.VITE_SUPABASE_URL) as string | undefined
const anonKey = (env.NEXT_PUBLIC_SUPABASE_ANON_KEY ?? env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY ??
  env.VITE_SUPABASE_ANON_KEY) as string | undefined

/** True when the Vercel / local env has both Supabase settings. */
export const supabaseConfigured = Boolean(url && anonKey)

// When the settings are missing the app shows a setup screen instead of crashing.
export const supabase: SupabaseClient = supabaseConfigured
  ? createClient(url!, anonKey!, { auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true } })
  : (null as unknown as SupabaseClient)
