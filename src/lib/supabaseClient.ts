import { createClient, type SupabaseClient } from '@supabase/supabase-js'

const url = import.meta.env.VITE_SUPABASE_URL as string | undefined
const anonKey = import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined

/** True when the Vercel / local env has both Supabase settings. */
export const supabaseConfigured = Boolean(url && anonKey)

// When the settings are missing the app shows a setup screen instead of crashing.
export const supabase: SupabaseClient = supabaseConfigured
  ? createClient(url!, anonKey!, { auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true } })
  : (null as unknown as SupabaseClient)
