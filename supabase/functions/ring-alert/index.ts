// ring-alert: pm-phone calls this the moment a seller's call starts ringing a caller's app (2026-11-07; Adil in
// Pakistan: "It rings like it's a blip ... or it doesn't ring"). It pushes "X is calling now, answer in the app" to that
// caller's registered phones (push_subscriptions_for, 0171), so the phone buzzes even when the app is in the background,
// and the second ring in pm-phone gives them time to open it. Called with the project's service key (the same key
// pm-phone uses for inbound_call_ring); anything else is refused. Nothing here reaches a seller.
import { createClient } from 'npm:@supabase/supabase-js@2.56.1'
import { pushToPerson } from '../_shared/notifyDeno.ts'

const PEOPLE = new Set(['thalia', 'adil', 'colin'])

function roleOf(auth: string): string {
  const t = auth.replace(/^Bearer\s+/i, '').trim().split('.')
  if (t.length < 2) return ''
  try { return String(JSON.parse(atob(t[1].replace(/-/g, '+').replace(/_/g, '/'))).role ?? '') } catch { return '' }
}

Deno.serve(async (req) => {
  const json = (body: unknown, status = 200) => Response.json(body, { status })
  if (req.method !== 'POST') return json({ ok: false, error: 'POST only' }, 405)
  if (roleOf(req.headers.get('Authorization') ?? '') !== 'service_role') return json({ ok: false, error: 'forbidden' }, 403)
  const body = await req.json().catch(() => ({})) as { persons?: unknown; from?: unknown; call_sid?: unknown; card?: { lead_id?: string; owner_name?: string; address?: string; municipality?: string } | null }
  const persons = (Array.isArray(body.persons) ? body.persons : []).map(String).filter((p) => PEOPLE.has(p))
  if (!persons.length) return json({ ok: true, pushed: 0, note: 'nobody to buzz' })
  const sb = createClient(Deno.env.get('SUPABASE_URL') ?? '', Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '', { auth: { persistSession: false } })
  const push = pushToPerson(sb)
  if (!push) return json({ ok: true, pushed: 0, note: 'push not set up (VAPID)' })
  const appUrl = Deno.env.get('NOTIFY_APP_URL') || 'https://deals.junkcarsmequon.com'
  const digits = String(body.from ?? '').replace(/\D/g, '').slice(-10)
  const phone = digits.length === 10 ? `(${digits.slice(0, 3)}) ${digits.slice(3, 6)}-${digits.slice(6)}` : String(body.from ?? '')
  const card = body.card ?? null
  const name = card?.owner_name?.trim() || phone
  const where = [card?.address, card?.municipality].filter(Boolean).join(', ')
  const sid = String(body.call_sid ?? '').slice(0, 40)
  const message = {
    title: `${name} is calling now`,
    body: `${where ? where + ' · ' : ''}${phone}. Open the app to answer; it rings twice.`,
    url: card?.lead_id ? `${appUrl}/lead/${card.lead_id}` : `${appUrl}/calls`,
  }
  let pushed = 0
  const errors: string[] = []
  for (const p of persons) {
    try { pushed += await push(p, { ...message, url: `${message.url}#ring-${sid || Date.now()}` }) }
    catch (e) { errors.push(`${p}: ${String(e).slice(0, 120)}`) }
  }
  return json({ ok: true, pushed, persons, errors })
})
