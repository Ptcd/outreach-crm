// ring-test: a test call to one person's phone, the way a seller's call reaches it (Colin 2026-11-14: "Test calling
// me", with the app shut). The steps are in _shared/ringTest: buzz the phone, then try the app's softphone every few
// seconds for 45 seconds until it is answered. Who may ask: a signed-in team member for their own phone (Settings,
// "Test a call to this phone"; the owner may name someone else), or the desk through public.ring_test(person), which
// calls here with the cron secret. It answers at once and carries on in the background; what happened is written to
// public.ring_tests. Nothing here touches a seller, a seller line or a card.
// Secrets: TWILIO_ACCOUNT_SID with TWILIO_API_KEY_SID + TWILIO_API_KEY_SECRET (or TWILIO_AUTH_TOKEN), and the VAPID keys.
import { createClient } from 'npm:@supabase/supabase-js@2.56.1'
import { pushToPerson } from '../_shared/notifyDeno.ts'
import { RING_TEST_TWIML, runRingTest, type TryStatus } from '../_shared/ringTest.ts'

declare const EdgeRuntime: { waitUntil(p: Promise<unknown>): void } | undefined

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-wpie-cron-secret',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}
const PEOPLE = new Set(['thalia', 'adil', 'colin'])

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS })
  const json = (body: unknown, status = 200) => Response.json(body, { status, headers: CORS })
  if (req.method !== 'POST') return json({ ok: false, error: 'POST only' }, 405)
  const url = Deno.env.get('SUPABASE_URL') ?? ''
  const sb = createClient(url, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '', { auth: { persistSession: false } })
  const body = await req.json().catch(() => ({})) as { person?: unknown; delay?: unknown; asked_by?: unknown }

  // who is asking, and whose phone
  let askedBy = ''
  let person = ''
  const cron = req.headers.get('x-wpie-cron-secret')
  if (cron) {
    const ok = await sb.rpc('cron_secret_ok', { p_secret: cron })
    if (ok.error || ok.data !== true) return json({ ok: false, error: 'forbidden' }, 403)
    askedBy = String(body.asked_by ?? 'desk').slice(0, 40)
    person = String(body.person ?? '')
  } else {
    const asUser = createClient(url, Deno.env.get('SUPABASE_ANON_KEY') ?? '', {
      global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } }, auth: { persistSession: false } })
    const email = ((await asUser.auth.getUser()).data.user?.email ?? '').toLowerCase()
    const me = email ? await asUser.from('team_members').select('person, role').eq('email', email).maybeSingle() : { data: null }
    if (!me.data) return json({ ok: false, error: 'not on the team' }, 403)
    askedBy = String(me.data.person)
    person = me.data.role === 'owner' && body.person ? String(body.person) : String(me.data.person)
  }
  if (!PEOPLE.has(person)) return json({ ok: false, error: 'no softphone for that person' }, 400)
  const delay = Math.max(0, Math.min(30, Number(body.delay ?? 0) || 0))

  const sid = (Deno.env.get('TWILIO_ACCOUNT_SID') ?? '').trim()
  const keySid = (Deno.env.get('TWILIO_API_KEY_SID') ?? '').trim()
  const keySecret = (Deno.env.get('TWILIO_API_KEY_SECRET') ?? '').trim()
  const token = (Deno.env.get('TWILIO_AUTH_TOKEN') ?? '').trim()
  const user = keySid && keySecret ? keySid : sid
  const pass = keySid && keySecret ? keySecret : token
  if (!sid || !pass) return json({ ok: false, error: 'the phone company settings are not on this server' }, 503)
  const auth = `Basic ${btoa(`${user}:${pass}`)}`
  const api = `https://api.twilio.com/2010-04-01/Accounts/${sid}/Calls`

  const row = await sb.from('ring_tests').insert({ person, asked_by: askedBy, delay_s: delay }).select('id').single()
  const id = row.data?.id as string | undefined
  const push = pushToPerson(sb)
  const appUrl = Deno.env.get('NOTIFY_APP_URL') || 'https://deals.junkcarsmequon.com'

  const work = (async () => {
    if (delay) await new Promise((r) => setTimeout(r, delay * 1000))
    const result = await runRingTest({
      now: () => Date.now(),
      sleep: (ms) => new Promise((r) => setTimeout(r, ms)),
      push: async () => push ? await push(person, {
        title: 'Test call is calling now',
        body: 'A test from the desk, not a seller. Tap Answer. It keeps ringing for about 40 seconds.',
        url: `${appUrl}/today#ring-test-${id ?? Date.now()}`,
      }, { ttl: 60 }) : 0,
      place: async (seconds) => {
        const res = await fetch(`${api}.json`, {
          method: 'POST', headers: { Authorization: auth, 'Content-Type': 'application/x-www-form-urlencoded' },
          body: new URLSearchParams({ To: `client:${person}`, From: 'client:desk_test', Timeout: String(seconds), Twiml: RING_TEST_TWIML }).toString(),
        })
        if (!res.ok) return null
        return String(((await res.json()) as { sid?: string }).sid ?? '') || null
      },
      status: async (callSid) => {
        const res = await fetch(`${api}/${callSid}.json`, { headers: { Authorization: auth } })
        const j = (await res.json()) as { status?: string; duration?: string | null }
        return { status: (j.status ?? 'failed') as TryStatus, duration: Number(j.duration ?? 0) || 0 }
      },
    })
    if (id) {
      await sb.from('ring_tests').update({
        pushed: result.pushed, tries: result.tries, answered: result.answered, answered_after_s: result.answeredAfterS,
        note: result.note, finished_at: new Date().toISOString(),
      }).eq('id', id)
    }
  })().catch((e) => console.error('[ring-test]', String(e).slice(0, 300)))
  if (typeof EdgeRuntime !== 'undefined') EdgeRuntime.waitUntil(work)
  return json({ ok: true, id, person, delay })
})
