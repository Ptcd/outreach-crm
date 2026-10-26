// calendar: Colin's Google Calendar connection (2026-10-26). Three doors, one function:
//   GET  ?code=&state=      Google sends Colin back here after he clicks Allow: the code becomes a refresh token, sealed
//                            and stored (calendar_link), and Colin lands on the app's Settings page again.
//   POST x-wpie-cron-secret {"action":"sync"} from pg_cron every 10 minutes: Colin's edits to booked events reach the cards.
//   POST Authorization (the app, Colin only; calendar_settings refuses anyone else):
//        connect      -> { url } Google's consent page for Colin to click through
//        save_client  { client_json } or { client_id, client_secret }: the Google OAuth client, the secret sealed
//        calendars    -> the calendars he can write to;  slots -> a preview of the next open times
//        disconnect   revokes the token at Google and forgets it
// Secrets: CALENDAR_TOKEN_KEY (seals the client secret and the refresh token), NOTIFY_APP_URL (where Colin is sent back).
// Nothing here prints or logs a token or a secret.
import { createClient } from 'npm:@supabase/supabase-js@2.56.1'
import { CalendarError, authUrl, connect, emailFromIdToken, exchangeCode, findSlots, randomHex, seal, sha256Hex, syncBookings, unseal,
  type Runtime } from '../_shared/calendar.ts'

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-wpie-cron-secret',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
}
const env = (k: string) => Deno.env.get(k) ?? ''
const APP_URL = (env('NOTIFY_APP_URL') || 'https://deals.junkcarsmequon.com').replace(/\/+$/, '')
const REDIRECT_URI = `${env('SUPABASE_URL').replace(/\/+$/, '')}/functions/v1/calendar`

/** Only the app's own addresses may be sent back to. */
function returnTo(origin: string | null): string {
  const o = (origin ?? '').replace(/\/+$/, '')
  if (o === APP_URL || /^https:\/\/[a-z0-9-]+\.vercel\.app$/.test(o) || /^http:\/\/(localhost|127\.0\.0\.1):\d+$/.test(o)) return o
  return APP_URL
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS })
  const json = (body: unknown, status = 200) => Response.json(body, { status, headers: CORS })
  const sb = createClient(env('SUPABASE_URL'), env('SUPABASE_SERVICE_ROLE_KEY'), { auth: { persistSession: false } })
  const rpc = async (fn: string, args: Record<string, unknown>) => {
    const r = await sb.rpc(fn, args)
    if (r.error) throw new Error(r.error.message)
    return r.data
  }
  const key = env('CALENDAR_TOKEN_KEY')
  const url = new URL(req.url)

  // ---------------------------------------------------------------- Google sends Colin back
  if (req.method === 'GET') {
    const state = url.searchParams.get('state') ?? ''
    const back = state ? await rpc('calendar_oauth_finish', { p_state_sha256: await sha256Hex(state) }).catch(() => null) as string | null : null
    const go = (to: string, q: Record<string, string>) => Response.redirect(`${to}/settings?${new URLSearchParams(q)}`, 302)
    if (!back) return go(APP_URL, { calendar: 'error', why: 'That sign-in link expired. Press Connect again.' })
    if (url.searchParams.get('error')) return go(back, { calendar: 'error', why: 'Google sign-in was cancelled.' })
    try {
      const rt = await rpc('calendar_runtime', {}) as Runtime
      if (!rt.client_id || !rt.client_secret_enc) throw new Error('the Google client is not set up')
      const t = await exchangeCode(fetch, rt.client_id, await unseal(rt.client_secret_enc, key), REDIRECT_URI, url.searchParams.get('code') ?? '')
      const scopes = String(t.scope ?? '')
      if (!scopes.includes('calendar.events') || !scopes.includes('calendar.readonly')) {
        return go(back, { calendar: 'error', why: 'Google did not give calendar access. Press Connect again and leave both calendar boxes ticked.' })
      }
      if (!t.refresh_token && !rt.refresh_token_enc) throw new Error('Google sent no refresh token')
      await rpc('calendar_store_token', { p_refresh_enc: t.refresh_token ? await seal(t.refresh_token, key) : null,
        p_email: emailFromIdToken(t.id_token), p_scopes: scopes, p_by: 'colin' })
      return go(back, { calendar: 'connected' })
    } catch (e) {
      const why = e instanceof Error ? e.message : String(e)
      await rpc('calendar_note', { p_error: 'connect: ' + why, p_synced: false }).catch(() => null)
      return go(back, { calendar: 'error', why: why.slice(0, 160) })
    }
  }
  if (req.method !== 'POST') return json({ error: 'GET or POST' }, 405)
  const body = await req.json().catch(() => ({})) as Record<string, unknown>

  // ---------------------------------------------------------------- the sync timer
  const cron = req.headers.get('x-wpie-cron-secret')
  if (cron) {
    if (!(await rpc('cron_secret_ok', { p_secret: cron }))) return json({ error: 'bad secret' }, 401)
    try {
      return json(await syncBookings(rpc, await connect(rpc, key)))
    } catch (e) {
      if (e instanceof CalendarError && e.code === 'not_connected') return json({ skipped: 'not connected' })
      return json({ error: e instanceof Error ? e.message : String(e) }, 500)
    }
  }

  // ---------------------------------------------------------------- Colin, in the app
  const asUser = createClient(env('SUPABASE_URL'), env('SUPABASE_ANON_KEY'), {
    global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } }, auth: { persistSession: false } })
  const me = await asUser.rpc('calendar_settings')
  if (me.error) return json({ error: 'only Colin can set up the calendar' }, 403)
  if (!key) return json({ error: 'The calendar key is missing on the server (CALENDAR_TOKEN_KEY).' }, 503)
  try {
    switch (String(body.action ?? '')) {
      case 'save_client': {
        let id = String(body.client_id ?? '').trim(); let secret = String(body.client_secret ?? '').trim()
        let uris: string[] = []
        if (body.client_json) {
          const j = JSON.parse(String(body.client_json)) as Record<string, { client_id?: string; client_secret?: string; redirect_uris?: string[] }>
          const w = j.web ?? j.installed ?? {}
          id = String(w.client_id ?? ''); secret = String(w.client_secret ?? ''); uris = w.redirect_uris ?? []
        }
        const r = await rpc('calendar_store_client', { p_client_id: id, p_secret_enc: secret ? await seal(secret, key) : '', p_by: 'colin' }) as { ok: boolean; reason?: string }
        if (!r.ok) return json({ error: r.reason }, 400)
        return json({ ok: true, redirect_uri: REDIRECT_URI, redirect_uri_ok: body.client_json ? uris.includes(REDIRECT_URI) : null })
      }
      case 'connect': {
        const rt = await rpc('calendar_runtime', {}) as Runtime
        if (!rt.client_id) return json({ error: 'Add the Google client first.' }, 400)
        const state = randomHex(32)
        await rpc('calendar_oauth_start', { p_state_sha256: await sha256Hex(state), p_return_to: returnTo(req.headers.get('origin')), p_by: 'colin' })
        return json({ url: authUrl(rt.client_id, REDIRECT_URI, state, body.login_hint ? String(body.login_hint) : undefined) })
      }
      case 'calendars': {
        const cal = await connect(rpc, key)
        return json({ calendars: await cal.google.listCalendars() })
      }
      case 'slots': {
        const cal = await connect(rpc, key)
        const [call, visit] = await Promise.all([findSlots(rpc, cal, { kind: 'call', limit: 8 }), findSlots(rpc, cal, { kind: 'visit', limit: 8 })])
        return json({ call, visit })
      }
      case 'disconnect': {
        const rt = await rpc('calendar_runtime', {}) as Runtime
        if (rt.refresh_token_enc) {
          const tok = await unseal(rt.refresh_token_enc, key).catch(() => '')
          if (tok) await fetch('https://oauth2.googleapis.com/revoke', { method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded' },
            body: new URLSearchParams({ token: tok }).toString() }).catch(() => null)
        }
        await rpc('calendar_disconnect_clear', {})
        return json({ ok: true })
      }
    }
    return json({ error: 'unknown action' }, 400)
  } catch (e) {
    return json({ error: e instanceof Error ? e.message : String(e) }, e instanceof CalendarError && e.code !== 'google' ? 409 : 500)
  }
})
