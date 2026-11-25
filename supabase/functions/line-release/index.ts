// line-release: release a retired phone number once sellers have stopped calling and texting it (0326). Colin
// 2026-11-25, of the two numbers shown as spam on his phone: "release them 1 month after no response from this date,
// put a biweekly cron on this". pg_cron (wpie-line-release, the 1st and the 15th) calls here with the cron secret.
//
// line_release_due says which numbers have had 30 quiet days. Each is deleted at Twilio (a release cannot be undone),
// recorded with line_released, and Colin is told. A number still in the text sender pool (CAMPAIGN_OPENER_FROM) is
// never released, whatever the table says. Body {"dry": true}: say what would happen and change nothing.
// Secrets: TWILIO_ACCOUNT_SID with TWILIO_API_KEY_SID + TWILIO_API_KEY_SECRET (or TWILIO_AUTH_TOKEN), the VAPID keys.
import { createClient } from 'npm:@supabase/supabase-js@2.56.1'
import { pushToPerson } from '../_shared/notifyDeno.ts'

type Due = { lines: { number: string; last_inbound_at: string | null; due_on: string }[]; due: string[] }

Deno.serve(async (req) => {
  const json = (body: unknown, status = 200) => Response.json(body, { status })
  if (req.method !== 'POST') return json({ ok: false, error: 'POST only' }, 405)
  const sb = createClient(Deno.env.get('SUPABASE_URL') ?? '', Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '', { auth: { persistSession: false } })
  const ok = await sb.rpc('cron_secret_ok', { p_secret: req.headers.get('x-wpie-cron-secret') ?? '' })
  if (ok.error || ok.data !== true) return json({ ok: false, error: 'forbidden' }, 403)
  const body = await req.json().catch(() => ({})) as { dry?: unknown }
  const dry = body.dry === true

  const d = await sb.rpc('line_release_due', {})
  if (d.error) return json({ ok: false, error: d.error.message }, 500)
  const due = (d.data ?? { lines: [], due: [] }) as Due
  const sending = new Set((Deno.env.get('CAMPAIGN_OPENER_FROM') ?? '').split(',').map((x) => x.trim()).filter(Boolean))

  const sid = (Deno.env.get('TWILIO_ACCOUNT_SID') ?? '').trim()
  const keySid = (Deno.env.get('TWILIO_API_KEY_SID') ?? '').trim()
  const keySecret = (Deno.env.get('TWILIO_API_KEY_SECRET') ?? '').trim()
  const token = (Deno.env.get('TWILIO_AUTH_TOKEN') ?? '').trim()
  const user = keySid && keySecret ? keySid : sid
  const pass = keySid && keySecret ? keySecret : token
  const auth = `Basic ${btoa(`${user}:${pass}`)}`
  const api = `https://api.twilio.com/2010-04-01/Accounts/${sid}`

  const results: { number: string; released: boolean; why: string }[] = []
  for (const n of due.due ?? []) {
    if (sending.has(n)) { results.push({ number: n, released: false, why: 'still in the text sender pool' }); continue }
    if (!sid || !pass) { results.push({ number: n, released: false, why: 'the phone company settings are not on this server' }); continue }
    try {
      const r = await fetch(`${api}/IncomingPhoneNumbers.json?PhoneNumber=${encodeURIComponent(n)}`, { headers: { authorization: auth } })
      const pn = ((await r.json()) as { incoming_phone_numbers?: { sid: string }[] }).incoming_phone_numbers?.[0]
      if (!r.ok || !pn) { results.push({ number: n, released: false, why: r.ok ? 'not on the account' : `lookup answered ${r.status}` }); continue }
      if (dry) { results.push({ number: n, released: false, why: 'dry run: would release' }); continue }
      const del = await fetch(`${api}/IncomingPhoneNumbers/${pn.sid}.json`, { method: 'DELETE', headers: { authorization: auth } })
      if (del.status !== 204) { results.push({ number: n, released: false, why: `release answered ${del.status}` }); continue }
      const line = due.lines.find((l) => l.number === n)
      await sb.rpc('line_released', { p_number: n, p_note: `released at Twilio; last seller contact ${line?.last_inbound_at ?? 'none since retiring'}` })
      results.push({ number: n, released: true, why: 'released' })
      const push = pushToPerson(sb)
      const pretty = `${n.slice(2, 5)}-${n.slice(5, 8)}-${n.slice(8)}`
      if (push) await push('colin', { title: 'Phone number released', body: `${pretty} had no seller call or text for 30 days and was released, as you set on Nov 25.`, url: 'https://deals.junkcarsmequon.com/today' }).catch(() => 0)
    } catch (e) {
      results.push({ number: n, released: false, why: e instanceof Error ? e.message.slice(0, 160) : 'failed' })
    }
  }
  return json({ ok: true, dry, lines: due.lines, results })
})
