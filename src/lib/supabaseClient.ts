import { createClient, type SupabaseClient } from '@supabase/supabase-js'

// NEXT_PUBLIC_* when the Supabase <-> Vercel integration sets them (these win: the project's old
// VITE_* values point at the retired CRM database); VITE_* when set by hand or locally.
// Only public values carry these prefixes (vite.config.ts envPrefix); the service-role key never does.
const env = import.meta.env
const url = (env.NEXT_PUBLIC_SUPABASE_URL ?? env.VITE_SUPABASE_URL) as string | undefined
const anonKey = (env.NEXT_PUBLIC_SUPABASE_ANON_KEY ?? env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY ??
  env.VITE_SUPABASE_ANON_KEY) as string | undefined

/** The one shared app account (Colin's decision 2026-10-21: "an app password not users").
 *  Set on Vercel as VITE_WPIE_APP_EMAIL so it is not in this public repo. It is not a secret
 *  (it ends up in the built page); the password is, and it lives only in Supabase Auth. */
export const appLoginEmail = ((env.VITE_WPIE_APP_EMAIL ?? env.NEXT_PUBLIC_WPIE_APP_EMAIL) as string | undefined)?.trim().toLowerCase() || ''

/** True when the Vercel / local env has both Supabase settings. */
export const supabaseConfigured = Boolean(url && anonKey)

// When the settings are missing the app shows a setup screen instead of crashing.
export const supabase: SupabaseClient = supabaseConfigured
  ? createClient(url!, anonKey!, { auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true } })
  : (null as unknown as SupabaseClient)
