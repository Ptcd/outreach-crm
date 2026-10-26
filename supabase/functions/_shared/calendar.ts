// Colin's Google Calendar behind the booking (2026-10-26). The Muse texting agent offers a seller Colin's real open times
// (his booking hours from calendar_rules, minus what Google free/busy says is taken, minus our own live holds) and books
// the one they pick: an event on his calendar with the seller, the phone, the address, the 4 pillars and a link to the
// card, and the card moves the way the app's booking moves it (calendar_confirm -> belt_event 'next_step'). Colin moving
// or deleting the event flows back to the card through syncBookings (pg_cron every 10 minutes).
// No double booking: calendar_hold locks and refuses an overlap with any other booking or live hold, then Google
// free/busy is checked again before the event is made. The refresh token and the OAuth client secret are sealed here
// (AES-GCM, key CALENDAR_TOKEN_KEY) and only the sealed text is stored; nothing here logs either.
// Plain TypeScript (fetch + WebCrypto), so the same code runs in the Edge Functions and in the tests.

export type Kind = 'call' | 'visit'
export type Day = 'sun' | 'mon' | 'tue' | 'wed' | 'thu' | 'fri' | 'sat'
export const DAYS: Day[] = ['sun', 'mon', 'tue', 'wed', 'thu', 'fri', 'sat']
export type Hours = Partial<Record<Day, [string, string][]>>
export interface Rules {
  time_zone: string; call_hours: Hours; visit_hours: Hours; call_minutes: number; visit_minutes: number
  buffer_minutes: number; min_notice_minutes: number; days_ahead: number
}
export interface Interval { start: string; end: string }
export interface Slot { start: string; end: string; label: string }
export type Rpc = (fn: string, args: Record<string, unknown>) => Promise<unknown>

export const SCOPES = ['openid', 'email', 'https://www.googleapis.com/auth/calendar.events', 'https://www.googleapis.com/auth/calendar.readonly']
const MIN = 60_000

// ------------------------------------------------------------------ time zones without a library
function zoneParts(tz: string, d: Date) {
  const p = new Intl.DateTimeFormat('en-US', { timeZone: tz, hourCycle: 'h23', year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', second: '2-digit', weekday: 'short' }).formatToParts(d)
  const g = (t: string) => p.find((x) => x.type === t)?.value ?? '0'
  return { y: Number(g('year')), m: Number(g('month')), d: Number(g('day')), hh: Number(g('hour')) % 24, mm: Number(g('minute')),
    ss: Number(g('second')), dow: g('weekday').slice(0, 3).toLowerCase() as Day }
}
function offsetMs(tz: string, at: number): number {
  const p = zoneParts(tz, new Date(at))
  return Date.UTC(p.y, p.m - 1, p.d, p.hh, p.mm, p.ss) - Math.floor(at / 1000) * 1000
}
/** The instant a wall-clock time in `tz` happens (y-m-d hh:mm). */
export function zonedToUtc(y: number, m: number, d: number, hh: number, mm: number, tz: string): Date {
  const guess = Date.UTC(y, m - 1, d, hh, mm)
  let t = guess - offsetMs(tz, guess)
  const again = guess - offsetMs(tz, t)
  if (again !== t) t = again
  return new Date(t)
}
export function slotLabel(iso: string, tz: string): string {
  return new Intl.DateTimeFormat('en-US', { timeZone: tz, weekday: 'short', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' })
    .format(new Date(iso))
}

// ------------------------------------------------------------------ open slots
const hm = (s: string) => { const [h, m] = s.split(':').map(Number); return { h, m } }
export const minutesFor = (r: Rules, kind: Kind) => (kind === 'visit' ? r.visit_minutes : r.call_minutes)

/** Every open start time from `from` (default now + notice) up to the rules' days ahead, in order. A slot is open when it
 * sits inside that day's hours for the kind, starts after the notice, and clears every busy interval by the buffer. */
export function openSlots(rules: Rules, kind: Kind, now: Date, busy: Interval[], opts: { limit?: number; from?: Date } = {}): Slot[] {
  const tz = rules.time_zone
  const len = minutesFor(rules, kind) * MIN
  const step = (minutesFor(rules, kind) >= 30 ? 30 : 15) * MIN
  const buf = rules.buffer_minutes * MIN
  const earliest = Math.max(now.getTime() + rules.min_notice_minutes * MIN, opts.from?.getTime() ?? 0)
  const lastDay = now.getTime() + rules.days_ahead * 24 * 60 * MIN
  const hours = (kind === 'visit' ? rules.visit_hours : rules.call_hours) ?? {}
  const b = busy.map((x) => [new Date(x.start).getTime(), new Date(x.end).getTime()] as const)
  const out: Slot[] = []
  const today = zoneParts(tz, now)
  for (let i = 0; i <= rules.days_ahead + 1; i++) {
    const noon = zonedToUtc(today.y, today.m, today.d, 12, 0, tz).getTime() + i * 24 * 60 * MIN
    const day = zoneParts(tz, new Date(noon))
    for (const [a, z] of hours[day.dow] ?? []) {
      const s = hm(a); const e = hm(z)
      const open = zonedToUtc(day.y, day.m, day.d, s.h, s.m, tz).getTime()
      const close = e.h === 24 ? zonedToUtc(day.y, day.m, day.d, 23, 59, tz).getTime() + MIN : zonedToUtc(day.y, day.m, day.d, e.h, e.m, tz).getTime()
      for (let t = open; t + len <= close; t += step) {
        if (t < earliest || t > lastDay) continue
        if (b.some(([bs, be]) => bs < t + len + buf && be > t - buf)) continue
        const start = new Date(t).toISOString()
        out.push({ start, end: new Date(t + len).toISOString(), label: slotLabel(start, tz) })
        if (opts.limit && out.length >= opts.limit) return out
      }
    }
  }
  return out
}

export function isOpenSlot(rules: Rules, kind: Kind, start: Date, now: Date, busy: Interval[]): boolean {
  return openSlots(rules, kind, now, busy, { from: start }).some((s) => new Date(s.start).getTime() === start.getTime())
}

/** Two or three to offer: the first open time, then the first on another day or at least three hours later, and so on. */
export function suggestSlots(slots: Slot[], tz: string, n = 3): Slot[] {
  const picked: Slot[] = []
  for (const s of slots) {
    const d = zoneParts(tz, new Date(s.start))
    const far = picked.every((p) => {
      const q = zoneParts(tz, new Date(p.start))
      return q.d !== d.d || Math.abs(new Date(p.start).getTime() - new Date(s.start).getTime()) >= 3 * 60 * MIN
    })
    if (far) picked.push(s)
    if (picked.length >= n) break
  }
  return picked
}

// ------------------------------------------------------------------ sealing the tokens
const b64 = (u: Uint8Array) => btoa(String.fromCharCode(...u))
const unb64 = (s: string) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0))
async function aesKey(keyB64: string) {
  const raw = unb64(keyB64)
  if (raw.length !== 32) throw new Error('CALENDAR_TOKEN_KEY must be 32 bytes, base64')
  return crypto.subtle.importKey('raw', raw, 'AES-GCM', false, ['encrypt', 'decrypt'])
}
export async function seal(plain: string, keyB64: string): Promise<string> {
  const iv = crypto.getRandomValues(new Uint8Array(12))
  const ct = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv }, await aesKey(keyB64), new TextEncoder().encode(plain)))
  const all = new Uint8Array(iv.length + ct.length); all.set(iv); all.set(ct, iv.length)
  return 'v1:' + b64(all)
}
export async function unseal(sealed: string, keyB64: string): Promise<string> {
  if (!sealed.startsWith('v1:')) throw new Error('not a sealed value')
  const all = unb64(sealed.slice(3))
  const pt = await crypto.subtle.decrypt({ name: 'AES-GCM', iv: all.slice(0, 12) }, await aesKey(keyB64), all.slice(12))
  return new TextDecoder().decode(pt)
}
export async function sha256Hex(s: string): Promise<string> {
  const h = new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(s)))
  return [...h].map((x) => x.toString(16).padStart(2, '0')).join('')
}
export const randomHex = (n = 32) => [...crypto.getRandomValues(new Uint8Array(n))].map((x) => x.toString(16).padStart(2, '0')).join('')

// ------------------------------------------------------------------ Google
export class CalendarError extends Error {
  constructor(message: string, readonly code: 'not_connected' | 'reconnect' | 'google' = 'google') { super(message) }
}

export function authUrl(clientId: string, redirectUri: string, state: string, loginHint?: string): string {
  const q = new URLSearchParams({ client_id: clientId, redirect_uri: redirectUri, response_type: 'code', scope: SCOPES.join(' '),
    access_type: 'offline', prompt: 'select_account consent', include_granted_scopes: 'true', state })
  if (loginHint) q.set('login_hint', loginHint)
  return 'https://accounts.google.com/o/oauth2/v2/auth?' + q.toString()
}

async function tokenCall(f: typeof fetch, body: Record<string, string>) {
  const r = await f('https://oauth2.googleapis.com/token', { method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams(body).toString() })
  const j = await r.json().catch(() => ({})) as Record<string, string>
  if (!r.ok) {
    if (j.error === 'invalid_grant') throw new CalendarError('Google turned the connection off: Colin connects the calendar again in Settings', 'reconnect')
    throw new CalendarError(`Google sign-in failed (${j.error ?? r.status})`)
  }
  return j
}
export function exchangeCode(f: typeof fetch, clientId: string, secret: string, redirectUri: string, code: string) {
  return tokenCall(f, { grant_type: 'authorization_code', code, client_id: clientId, client_secret: secret, redirect_uri: redirectUri })
}
export async function refreshAccess(f: typeof fetch, clientId: string, secret: string, refreshToken: string): Promise<string> {
  return (await tokenCall(f, { grant_type: 'refresh_token', refresh_token: refreshToken, client_id: clientId, client_secret: secret })).access_token
}
export function emailFromIdToken(idToken: string | undefined): string | null {
  try {
    const p = idToken!.split('.')[1].replace(/-/g, '+').replace(/_/g, '/')
    return (JSON.parse(atob(p + '='.repeat((4 - (p.length % 4)) % 4))) as { email?: string }).email ?? null
  } catch { return null }
}

export interface GEvent { id: string; status?: string; htmlLink?: string; start?: { dateTime?: string; date?: string }; end?: { dateTime?: string; date?: string } }
export interface Google {
  freeBusy(ids: string[], from: string, to: string): Promise<Interval[]>
  insertEvent(calendarId: string, ev: Record<string, unknown>): Promise<GEvent>
  getEvent(calendarId: string, id: string): Promise<GEvent | null>
  deleteEvent(calendarId: string, id: string): Promise<void>
  listCalendars(): Promise<{ id: string; summary: string; primary?: boolean; accessRole: string }[]>
}

export function googleApi(accessToken: string, f: typeof fetch = fetch): Google {
  const base = 'https://www.googleapis.com/calendar/v3'
  const call = async (method: string, path: string, body?: unknown, okMissing = false) => {
    const r = await f(base + path, { method, headers: { authorization: `Bearer ${accessToken}`, ...(body ? { 'content-type': 'application/json' } : {}) },
      body: body ? JSON.stringify(body) : undefined })
    if (okMissing && (r.status === 404 || r.status === 410)) return null
    if (r.status === 204) return {}
    const j = await r.json().catch(() => ({})) as Record<string, unknown>
    if (!r.ok) throw new CalendarError(`Google Calendar said ${r.status}: ${String((j.error as { message?: string } | undefined)?.message ?? '').slice(0, 200)}`)
    return j
  }
  const enc = encodeURIComponent
  return {
    async freeBusy(ids, from, to) {
      const j = await call('POST', '/freeBusy', { timeMin: from, timeMax: to, items: ids.map((id) => ({ id })) }) as
        { calendars?: Record<string, { busy?: Interval[]; errors?: { reason: string }[] }> }
      const out: Interval[] = []
      for (const id of ids) {
        const c = j.calendars?.[id]
        if (!c || c.errors?.length) throw new CalendarError(`Google could not read the calendar ${id} (${c?.errors?.[0]?.reason ?? 'missing'})`)
        out.push(...(c.busy ?? []))
      }
      return out
    },
    insertEvent: async (cal, ev) => await call('POST', `/calendars/${enc(cal)}/events?sendUpdates=none`, ev) as unknown as GEvent,
    getEvent: async (cal, id) => await call('GET', `/calendars/${enc(cal)}/events/${enc(id)}`, undefined, true) as unknown as GEvent | null,
    deleteEvent: async (cal, id) => { await call('DELETE', `/calendars/${enc(cal)}/events/${enc(id)}?sendUpdates=none`, undefined, true) },
    async listCalendars() {
      const j = await call('GET', '/users/me/calendarList?minAccessRole=writer') as { items?: { id: string; summary: string; primary?: boolean; accessRole: string }[] }
      return (j.items ?? []).map(({ id, summary, primary, accessRole }) => ({ id, summary, primary, accessRole }))
    },
  }
}

// ------------------------------------------------------------------ the connection
export interface Runtime {
  connected: boolean; client_id: string | null; client_secret_enc: string | null; refresh_token_enc: string | null
  google_email: string | null; calendar_id: string; busy_calendar_ids: string[]; rules: Rules
}
export interface Cal { google: Google; rt: Runtime }

/** The live connection, or a CalendarError('not_connected' / 'reconnect'). */
export async function connect(rpc: Rpc, tokenKey: string, f: typeof fetch = fetch): Promise<Cal> {
  const rt = await rpc('calendar_runtime', {}) as Runtime
  if (!rt?.connected || !rt.client_id || !rt.client_secret_enc || !rt.refresh_token_enc) {
    throw new CalendarError("Colin's calendar is not connected yet (Settings > Calendar). Offer \"later today or tomorrow morning\" and mark_card hot as before.", 'not_connected')
  }
  if (!tokenKey) throw new CalendarError('the calendar key is missing on the server (CALENDAR_TOKEN_KEY)')
  try {
    const access = await refreshAccess(f, rt.client_id, await unseal(rt.client_secret_enc, tokenKey), await unseal(rt.refresh_token_enc, tokenKey))
    return { google: googleApi(access, f), rt }
  } catch (e) {
    if (e instanceof CalendarError) await rpc('calendar_note', { p_error: e.message, p_synced: false }).catch(() => null)
    throw e
  }
}

// ------------------------------------------------------------------ the flows the agent door and the app use
const iso = (t: number) => new Date(t).toISOString()
const asIntervals = (v: unknown) => (Array.isArray(v) ? v as Interval[] : [])

export async function findSlots(rpc: Rpc, cal: Cal, a: { kind?: string; limit?: number; after?: string | null }, now = new Date()) {
  const kind: Kind = a.kind === 'visit' ? 'visit' : 'call'
  const r = cal.rt.rules
  const after = a.after ? new Date(a.after) : null
  const from = iso(Math.max(now.getTime(), after && !isNaN(after.getTime()) ? after.getTime() : 0) - 60 * MIN)
  const to = iso(now.getTime() + (r.days_ahead + 1) * 24 * 60 * MIN)
  const busy = [...await cal.google.freeBusy(cal.rt.busy_calendar_ids, from, to), ...asIntervals(await rpc('calendar_busy', { p_from: from, p_to: to, p_except_lead: null, p_now: now.toISOString() }))]
  const slots = openSlots(r, kind, now, busy, { limit: Math.min(Math.max(a.limit ?? 12, 1), 40), from: after && !isNaN(after.getTime()) ? after : undefined })
  return { kind, time_zone: r.time_zone, minutes: minutesFor(r, kind), slots, suggest: suggestSlots(slots, r.time_zone).map((s) => s.label),
    note: slots.length ? 'Times are Central. Offer two or three in your text ("Would Tue 2:00 or Wed 10:00 work?"), then book_slot the one they pick.'
      : 'No open times in the booking window: tell Colin, and mark_card hot so he calls them.' }
}

export interface Pillars { why?: string; condition?: string; timeline?: string; their_number?: string; who_signs?: string }
export interface BookArgs { lead_id: string; start: string; kind?: string; phone?: string | null; pillars?: Pillars | null; note?: string | null }

type Card = { lead_id: string; owner_name: string; address: string | null; city: string | null; zip: string | null
  phones?: { phone: string; type?: string; textable?: boolean; name?: string }[] | null; what_we_know?: Record<string, unknown> }

const fmtPhone = (p: string) => { const d = p.replace(/\D/g, '').slice(-10); return d.length === 10 ? `(${d.slice(0, 3)}) ${d.slice(3, 6)}-${d.slice(6)}` : p }
const clean = (s: unknown, n = 500) => String(s ?? '').replace(/\s+/g, ' ').trim().slice(0, n)

export function eventBody(card: Card, a: { kind: Kind; start: string; end: string; phone: string | null; pillars: Pillars; note: string },
  bookingId: string, tz: string, appUrl: string, by: string) {
  const street = card.address ?? 'the property'
  const place = [card.address, card.city, card.zip].filter(Boolean).join(', ')
  const phone = a.phone ? fmtPhone(a.phone) : ''
  const p = a.pillars
  const lines = [
    `Seller: ${card.owner_name}`, phone ? `Phone: ${phone}` : null, `Property: ${place || street}`, '',
    `Why selling: ${clean(p.why) || '(not asked yet)'}`, `Condition: ${clean(p.condition) || '(not asked yet)'}`,
    `Timeline: ${clean(p.timeline) || '(not asked yet)'}`, `Their number: ${clean(p.their_number) || '(not given)'}`,
    `Who signs: ${clean(p.who_signs) || '(not asked yet)'}`, a.note ? `Note: ${clean(a.note, 1000)}` : null, '',
    `Card: ${appUrl.replace(/\/+$/, '')}/lead/${card.lead_id}`, `Booked by ${by} through WPIE.`,
  ].filter((x): x is string => x !== null)
  return {
    summary: a.kind === 'visit' ? `Visit: ${street} (${card.owner_name})` : `Seller call: ${card.owner_name}${phone ? ' ' + phone : ''} - ${street}`,
    ...(a.kind === 'visit' && place ? { location: place } : {}),
    description: lines.join('\n'),
    start: { dateTime: a.start, timeZone: tz }, end: { dateTime: a.end, timeZone: tz },
    extendedProperties: { private: { wpie_booking: bookingId, wpie_lead: card.lead_id, wpie_kind: a.kind } },
    reminders: { useDefault: true },
  }
}

const pickPhone = (card: Card, asked: string | null | undefined) => {
  const d = (asked ?? '').replace(/\D/g, '').slice(-10)
  if (d.length === 10) return d
  const ph = card.phones ?? []
  return (ph.find((p) => p.textable) ?? ph.find((p) => p.type === 'mobile') ?? ph[0])?.phone ?? null
}

export async function bookSlot(rpc: Rpc, cal: Cal, a: BookArgs, by: string, appUrl: string, now = new Date()) {
  const kind: Kind = a.kind === 'visit' ? 'visit' : 'call'
  const r = cal.rt.rules
  const start = new Date(a.start)
  if (isNaN(start.getTime())) return { status: 'refused', reason: 'start must be an ISO time from open_slots' }
  const end = new Date(start.getTime() + minutesFor(r, kind) * MIN)
  const card = await rpc('agent_card', { p_lead: a.lead_id }) as Card | null
  if (!card?.lead_id) return { status: 'refused', reason: 'no such card' }
  const pillars: Pillars = {}
  for (const k of ['why', 'condition', 'timeline', 'their_number', 'who_signs'] as const) if (a.pillars?.[k]) pillars[k] = clean(a.pillars[k])
  const alternatives = async () => (await findSlots(rpc, cal, { kind, limit: 6, after: iso(start.getTime() - 24 * 60 * MIN) }, now).catch(() => null))?.slots.slice(0, 6) ?? []

  const hold = await rpc('calendar_hold', { p_lead_id: card.lead_id, p_kind: kind, p_start: start.toISOString(), p_end: end.toISOString(),
    p_by: by, p_notes: { pillars, note: clean(a.note, 1000) || null }, p_now: now.toISOString() }) as
    { ok: boolean; reason?: string; booking_id?: string; replaces?: { booking_id: string; calendar_id: string | null; event_id: string | null; start: string; end: string } | null }
  if (!hold.ok) return { status: 'refused', reason: hold.reason, alternatives: hold.reason === 'that time was just taken' ? await alternatives() : undefined }
  const bid = hold.booking_id!
  let ev: GEvent
  try {
    // re-checked now, after the hold: Google free/busy for the day around the slot and our other live holds
    const from = iso(start.getTime() - 24 * 60 * MIN); const to = iso(end.getTime() + 24 * 60 * MIN)
    const own = hold.replaces ? [new Date(hold.replaces.start).getTime(), new Date(hold.replaces.end).getTime()] : null
    const gBusy = (await cal.google.freeBusy(cal.rt.busy_calendar_ids, from, to))
      .filter((x) => !own || new Date(x.start).getTime() !== own[0] || new Date(x.end).getTime() !== own[1])
    const ours = asIntervals(await rpc('calendar_busy', { p_from: from, p_to: to, p_except_lead: card.lead_id, p_now: now.toISOString() }))
    if (!isOpenSlot(r, kind, start, now, [...gBusy, ...ours])) {
      await rpc('calendar_release', { p_booking_id: bid, p_reason: 'not open on the calendar' })
      return { status: 'refused', reason: "that time is not open: it is taken on Colin's calendar or outside his booking hours. Offer one of these instead.",
        alternatives: await alternatives() }
    }
    ev = await cal.google.insertEvent(cal.rt.calendar_id, eventBody(card, { kind, start: start.toISOString(), end: end.toISOString(),
      phone: pickPhone(card, a.phone), pillars, note: clean(a.note, 1000) }, bid, r.time_zone, appUrl, by))
  } catch (e) {
    await rpc('calendar_release', { p_booking_id: bid, p_reason: e instanceof Error ? e.message : String(e) }).catch(() => null)
    throw e
  }
  let conf: Record<string, unknown>
  try {
    conf = await rpc('calendar_confirm', { p_booking_id: bid, p_calendar_id: cal.rt.calendar_id, p_event_id: ev.id, p_html_link: ev.htmlLink ?? null,
      p_by: by, p_now: now.toISOString() }) as Record<string, unknown>
    if (conf.ok === false) throw new Error(String(conf.reason ?? 'could not confirm the booking'))
  } catch (e) {
    await cal.google.deleteEvent(cal.rt.calendar_id, ev.id).catch(() => null)
    await rpc('calendar_release', { p_booking_id: bid, p_reason: e instanceof Error ? e.message : String(e) }).catch(() => null)
    throw e
  }
  if (hold.replaces?.event_id) await cal.google.deleteEvent(hold.replaces.calendar_id ?? cal.rt.calendar_id, hold.replaces.event_id).catch(() => null)
  const label = slotLabel(start.toISOString(), r.time_zone)
  return { status: 'booked', kind, booking_id: bid, start: start.toISOString(), end: end.toISOString(), label, moved_from: hold.replaces?.start ?? null,
    belt: conf.belt, stage: conf.stage, named_date: conf.named_date,
    note: `Booked. Confirm it in your text in plain words ("You're set: Colin will ${kind === 'visit' ? 'come by' : 'call you'} ${label}.").` }
}

export async function cancelBooking(rpc: Rpc, cal: Cal, a: { lead_id: string; reason?: string | null }, by: string, now = new Date()) {
  const b = await rpc('calendar_active_booking', { p_lead_id: a.lead_id, p_now: now.toISOString() }) as
    { booking_id: string; calendar_id: string | null; event_id: string | null } | null
  if (!b?.booking_id) return { status: 'none', reason: 'this card has no booked call or visit coming up' }
  if (b.event_id) await cal.google.deleteEvent(b.calendar_id ?? cal.rt.calendar_id, b.event_id)
  const res = await rpc('calendar_cancel', { p_booking_id: b.booking_id, p_reason: clean(a.reason, 300) || 'the seller cancelled', p_by: by,
    p_now: now.toISOString() }) as Record<string, unknown>
  return { status: 'cancelled', ...res }
}

/** Colin's edits flow back: an event he deleted cancels the booking, an event he moved moves the card. */
export async function syncBookings(rpc: Rpc, cal: Cal, now = new Date()) {
  const targets = await rpc('calendar_sync_targets', { p_now: now.toISOString() }) as
    { booking_id: string; calendar_id: string | null; event_id: string; start: string; end: string }[]
  const out = { checked: 0, moved: 0, cancelled: 0, errors: [] as string[] }
  for (const t of targets ?? []) {
    try {
      const ev = await cal.google.getEvent(t.calendar_id ?? cal.rt.calendar_id, t.event_id)
      let what = 'same'; let s: string | null = null; let e: string | null = null
      if (!ev || ev.status === 'cancelled') what = 'cancelled'
      else if (ev.start?.dateTime && ev.end?.dateTime) {
        s = new Date(ev.start.dateTime).toISOString(); e = new Date(ev.end.dateTime).toISOString()
        if (s !== new Date(t.start).toISOString() || e !== new Date(t.end).toISOString()) what = 'moved'
      }
      await rpc('calendar_sync_apply', { p_booking_id: t.booking_id, p_what: what, p_start: s, p_end: e, p_now: now.toISOString() })
      out.checked++
      if (what === 'moved') out.moved++
      if (what === 'cancelled') out.cancelled++
    } catch (err) {
      out.errors.push(`${t.booking_id}: ${err instanceof Error ? err.message : String(err)}`.slice(0, 200))
    }
  }
  await rpc('calendar_note', { p_error: out.errors[0] ?? null, p_synced: true }).catch(() => null)
  return out
}

// ------------------------------------------------------------------ the agent door's tools (sender key)
export interface CalendarDoor {
  slots(a: { kind?: string; limit?: number; after?: string | null }): Promise<unknown>
  book(a: BookArgs, agent: string): Promise<unknown>
  cancel(a: { lead_id: string; reason?: string | null }, agent: string): Promise<unknown>
}

const S = (description: string) => ({ type: 'string', description })
export const CALENDAR_TOOLS = [
  { role: 'sender' as const, name: 'open_slots',
    description: "Colin's next open times for a seller call (or a visit), from his real Google Calendar and the booking hours he set (Central time). Busy events on his calendar and other bookings are already taken out. Offer two or three from `suggest` in your text (\"Would Tue 2:00 or Wed 10:00 work?\"), then book the one they pick with book_slot. after = an ISO time to look from (they said \"next week\" or \"after 3\").",
    inputSchema: { type: 'object', properties: { kind: S('call (default) or visit'), after: S('ISO time to start looking from, optional'),
      limit: { type: 'integer', maximum: 40 } } } },
  { role: 'sender' as const, name: 'book_slot',
    description: "Book the time a seller picked. It goes on Colin's Google Calendar with their name, phone, address, the 4 pillars and a link to the card, and the card moves to call_booked (visit_booked for a visit) with named_date at that time, the same move the app's booking makes. The time must be a start from open_slots; it is checked against his calendar again now, and a time that was taken comes back refused with fresh alternatives. A card that already has a booking is moved to the new time (the old event comes off). Refused for a closed or do-not-contact card, and for an older, ill or grieving owner (the team calls them).",
    inputSchema: { type: 'object', properties: { lead_id: S('card id'), start: S('the slot start, exactly as open_slots gave it'),
      kind: S('call (default) or visit'), phone: S('the number Colin should call, if not the one they texted from'),
      pillars: { type: 'object', description: 'what you learned, in their words', properties: { why: S('why selling'), condition: S('condition, who lives there'),
        timeline: S('the date or event they are working toward'), their_number: S('their number and how they got it'), who_signs: S('who is on the title / has a say') } },
      note: S('anything else Colin should know before the call') }, required: ['lead_id', 'start'] } },
  { role: 'sender' as const, name: 'cancel_booking',
    description: "Take a booked call or visit off Colin's calendar when the seller cancels and does not want a new time yet. The card goes back to 'said yes, not booked' so a person calls to set a new time. To move a booking to another time, book_slot the new time instead.",
    inputSchema: { type: 'object', properties: { lead_id: S('card id'), reason: S('what they said') }, required: ['lead_id'] } },
]
export const isCalendarTool = (name: string) => CALENDAR_TOOLS.some((t) => t.name === name)

export async function callCalendarTool(name: string, args: Record<string, unknown>, agent: string, door: CalendarDoor | undefined):
  Promise<{ value: unknown; isError?: boolean }> {
  if (!door) return { value: { error: "Colin's calendar is not wired to this door" }, isError: true }
  try {
    if (name === 'open_slots') {
      return { value: await door.slots({ kind: args.kind ? String(args.kind) : 'call', after: args.after ? String(args.after) : null,
        limit: Number.isFinite(Number(args.limit)) ? Number(args.limit) : 12 }) }
    }
    if (name === 'book_slot') {
      const v = await door.book({ lead_id: String(args.lead_id ?? ''), start: String(args.start ?? ''), kind: args.kind ? String(args.kind) : 'call',
        phone: args.phone ? String(args.phone) : null, pillars: (args.pillars && typeof args.pillars === 'object' ? args.pillars : null) as Pillars | null,
        note: args.note ? String(args.note) : null }, agent) as { status?: string }
      return { value: v, isError: v?.status !== 'booked' }
    }
    if (name === 'cancel_booking') return { value: await door.cancel({ lead_id: String(args.lead_id ?? ''), reason: args.reason ? String(args.reason) : null }, agent) }
  } catch (e) {
    return { value: { error: e instanceof Error ? e.message : String(e) }, isError: true }
  }
  return { value: { error: `no tool ${name}` }, isError: true }
}
