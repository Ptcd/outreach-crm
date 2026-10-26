// Colin's Google Calendar (2026-10-26): the Muse texting agent books seller calls and visits into his real open time.
// Here Colin connects the calendar (one click to Google's own consent page; the token stays on the server, sealed),
// picks which calendar the bookings go on and which ones count as busy, and sets the hours he takes calls and visits,
// the slot lengths, the buffer between them, the notice and how far ahead people can book.
import { useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { ErrorNote, Select } from '@/components/ui/form'
import { supabase } from '@/lib/supabaseClient'
import { fmtDateTime } from '@/lib/format'

type Day = 'sun' | 'mon' | 'tue' | 'wed' | 'thu' | 'fri' | 'sat'
type Hours = Partial<Record<Day, [string, string][]>>
type Rules = { time_zone: string; call_hours: Hours; visit_hours: Hours; call_minutes: number; visit_minutes: number; buffer_minutes: number
  min_notice_minutes: number; days_ahead: number }
type Booking = { booking_id: string; lead_id: string; kind: 'call' | 'visit'; starts_at: string; owner_name: string; address: string | null; html_link: string | null }
type Settings = { client_ready: boolean; connected: boolean; google_email: string | null; calendar_id: string; calendar_name: string | null
  busy_calendar_ids: string[]; last_sync_at: string | null; last_error: string | null; rules: Rules; upcoming: Booking[] }
type Slots = { suggest: string[]; slots: { label: string }[] }

const DAYS: [Day, string][] = [['mon', 'Mon'], ['tue', 'Tue'], ['wed', 'Wed'], ['thu', 'Thu'], ['fri', 'Fri'], ['sat', 'Sat'], ['sun', 'Sun']]
const BASE = ((import.meta.env.NEXT_PUBLIC_SUPABASE_URL ?? import.meta.env.VITE_SUPABASE_URL) as string | undefined) || 'https://jyfetargyaaxcqmxdgft.supabase.co'
export const CALENDAR_REDIRECT_URI = `${BASE.replace(/\/+$/, '')}/functions/v1/calendar`

async function calendarFn<T = Record<string, unknown>>(body: Record<string, unknown>): Promise<T> {
  const r = await supabase.functions.invoke('calendar', { body })
  if (r.error) {
    const ctx = (r.error as { context?: Response }).context
    const j = ctx ? await ctx.json().catch(() => null) as { error?: string } | null : null
    throw new Error(j?.error ?? r.error.message)
  }
  return r.data as T
}

export function CalendarPanel() {
  const qc = useQueryClient()
  const s = useQuery({ queryKey: ['calendar_settings'], queryFn: async () => {
    const r = await supabase.rpc('calendar_settings')
    if (r.error) throw new Error(r.error.message)
    return r.data as Settings
  } })
  const [err, setErr] = useState<Error | null>(null)
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null)
  const [busy, setBusy] = useState(false)
  const refresh = () => void qc.invalidateQueries({ queryKey: ['calendar_settings'] })

  // back from Google's page
  useEffect(() => {
    const q = new URLSearchParams(window.location.search)
    const c = q.get('calendar')
    if (!c) return
    setMsg(c === 'connected' ? { ok: true, text: 'Connected. Pick the calendar below, then check the hours.' } : { ok: false, text: q.get('why') ?? 'Not connected.' })
    window.history.replaceState(null, '', window.location.pathname)
  }, [])

  const run = async (f: () => Promise<void>) => {
    setBusy(true); setErr(null); setMsg(null)
    try { await f() } catch (e) { setErr(e instanceof Error ? e : new Error(String(e))) } finally { setBusy(false) }
  }
  const connect = () => run(async () => {
    const r = await calendarFn<{ url: string }>({ action: 'connect' })
    window.location.href = r.url
  })
  const disconnect = () => run(async () => {
    if (!window.confirm('Disconnect the calendar? The texting agent stops booking calls until you connect it again.')) return
    await calendarFn({ action: 'disconnect' })
    refresh()
  })

  const d = s.data
  return (
    <div className="space-y-4 text-sm">
      <p className="text-muted-foreground">
        The texting agent offers sellers your open times from your Google Calendar and books the one they pick: it lands on your
        calendar with their name, number, address and what they told us, and the card moves to Call booked (or Visit booked).
        Move or delete the event on your calendar and the card follows within 10 minutes.
      </p>
      <ErrorNote error={err ?? s.error} />
      {msg && <p className={msg.ok ? 'font-medium text-emerald-700' : 'text-red-700'}>{msg.text}</p>}
      {d && !d.client_ready && <ClientSetup onDone={() => { refresh(); setMsg({ ok: true, text: 'Saved. Now press Connect Google Calendar.' }) }} />}
      {d && d.client_ready && !d.connected && (
        <Button className="h-11" disabled={busy} onClick={() => void connect()}>Connect Google Calendar</Button>
      )}
      {d?.connected && (
        <div className="space-y-3 rounded-lg border p-3">
          <div className="flex flex-wrap items-center gap-2">
            <p className="min-w-0 flex-1">Connected{d.google_email ? <> as <strong>{d.google_email}</strong></> : ''}.
              {d.last_sync_at && <span className="text-xs text-muted-foreground"> Last checked {fmtDateTime(d.last_sync_at)}.</span>}</p>
            <Button size="sm" variant="outline" disabled={busy} onClick={() => void disconnect()}>Disconnect</Button>
          </div>
          {d.last_error && <p className="text-xs text-red-700">Last problem: {d.last_error}{/reconnect|connect the calendar again/i.test(d.last_error) && (
            <> <button className="underline" onClick={() => void connect()}>Connect again</button></>)}</p>}
          <CalendarChoice settings={d} onSaved={refresh} />
        </div>
      )}
      {d && <RulesEditor rules={d.rules} onSaved={refresh} />}
      {d?.connected && <Preview />}
      {d && d.upcoming.length > 0 && (
        <div>
          <p className="mb-1 font-medium">Booked</p>
          <ul className="divide-y rounded-lg border">
            {d.upcoming.map((b) => (
              <li key={b.booking_id} className="flex flex-wrap items-center gap-2 p-2">
                <span className="w-44 shrink-0">{fmtDateTime(b.starts_at)}</span>
                <span className="text-xs uppercase text-muted-foreground">{b.kind}</span>
                <Link className="min-w-0 flex-1 truncate underline" to={`/lead/${b.lead_id}`}>{b.owner_name}{b.address ? `, ${b.address}` : ''}</Link>
                {b.html_link && <a className="text-xs underline" href={b.html_link} target="_blank" rel="noreferrer">On calendar</a>}
              </li>
            ))}
          </ul>
        </div>
      )}
    </div>
  )
}

/** Once: the Google sign-in app (an OAuth client) the connection runs through. The file goes straight to the server. */
function ClientSetup({ onDone }: { onDone: () => void }) {
  const [err, setErr] = useState<Error | null>(null)
  const [warn, setWarn] = useState<string | null>(null)
  const [copied, setCopied] = useState(false)
  const upload = async (f: File | undefined) => {
    setErr(null); setWarn(null)
    if (!f) return
    try {
      const r = await calendarFn<{ redirect_uri_ok: boolean | null }>({ action: 'save_client', client_json: await f.text() })
      if (r.redirect_uri_ok === false) setWarn('Saved, but that Google client does not list the address below as a redirect URI. Add it in Google, or Connect will fail.')
      onDone()
    } catch (e) { setErr(e instanceof Error ? e : new Error(String(e))) }
  }
  return (
    <div className="space-y-2 rounded-lg border-2 border-dashed p-3">
      <p className="font-medium">First, once: the Google sign-in file</p>
      <p className="text-muted-foreground">
        Google needs a sign-in app (an "OAuth client", type Web application) before it will ask you to allow calendar access. It has this
        address as its redirect URI. Download its JSON file from Google and choose it here; it goes straight to the server.
      </p>
      <div className="flex items-center gap-2 rounded-lg bg-muted px-3 py-2">
        <code className="min-w-0 flex-1 truncate text-xs">{CALENDAR_REDIRECT_URI}</code>
        <Button size="sm" variant="outline" onClick={() => void navigator.clipboard.writeText(CALENDAR_REDIRECT_URI).then(() => setCopied(true))}>
          {copied ? 'Copied' : 'Copy'}</Button>
      </div>
      <Input type="file" accept="application/json,.json" className="h-11" onChange={(e) => void upload(e.target.files?.[0])} aria-label="Google client file" />
      <ErrorNote error={err} />
      {warn && <p className="text-amber-700">{warn}</p>}
    </div>
  )
}

function CalendarChoice({ settings, onSaved }: { settings: Settings; onSaved: () => void }) {
  const cals = useQuery({ queryKey: ['calendar_list'], queryFn: () => calendarFn<{ calendars: { id: string; summary: string; primary?: boolean }[] }>({ action: 'calendars' }) })
  const [cal, setCal] = useState(settings.calendar_id)
  const [busyIds, setBusyIds] = useState<string[]>(settings.busy_calendar_ids ?? [])
  const [err, setErr] = useState<Error | null>(null)
  const [saved, setSaved] = useState(false)
  const list = cals.data?.calendars ?? []
  const idOf = (c: { id: string; primary?: boolean }) => (c.primary ? 'primary' : c.id)
  const save = async () => {
    setErr(null); setSaved(false)
    const c = list.find((x) => idOf(x) === cal)
    const r = await supabase.rpc('calendar_choose', { p_calendar_id: cal, p_calendar_name: c?.summary ?? null, p_busy: busyIds })
    if (r.error) setErr(new Error(r.error.message)); else { setSaved(true); onSaved() }
  }
  return (
    <div className="space-y-2">
      <ErrorNote error={err ?? cals.error} />
      <label className="block font-medium">Bookings go on
        <Select className="mt-1" value={cal} onChange={(e) => setCal(e.target.value)}>
          {!list.some((c) => idOf(c) === cal) && <option value={cal}>{settings.calendar_name ?? cal}</option>}
          {list.map((c) => <option key={c.id} value={idOf(c)}>{c.summary}{c.primary ? ' (main)' : ''}</option>)}
        </Select>
      </label>
      {list.length > 1 && (
        <fieldset>
          <legend className="font-medium">Events on these calendars block a time</legend>
          {list.map((c) => (
            <label key={c.id} className="mr-4 inline-flex items-center gap-2">
              <input type="checkbox" checked={busyIds.includes(idOf(c)) || idOf(c) === cal}
                onChange={(e) => setBusyIds((b) => e.target.checked ? [...b, idOf(c)] : b.filter((x) => x !== idOf(c)))} />{c.summary}
            </label>
          ))}
        </fieldset>
      )}
      <div className="flex items-center gap-3">
        <Button size="sm" onClick={() => void save()}>Save calendar</Button>
        {saved && <span className="text-emerald-700">Saved.</span>}
      </div>
    </div>
  )
}

function RulesEditor({ rules, onSaved }: { rules: Rules; onSaved: () => void }) {
  const [r, setR] = useState<Rules>(rules)
  const [err, setErr] = useState<Error | null>(null)
  const [saved, setSaved] = useState(false)
  useEffect(() => setR(rules), [rules])
  const setDay = (which: 'call_hours' | 'visit_hours', day: Day, w: [string, string] | null) =>
    setR((x) => { const h = { ...x[which] }; if (w) h[day] = [w]; else delete h[day]; return { ...x, [which]: h } })
  const num = (k: keyof Rules, v: string, scale = 1) => setR((x) => ({ ...x, [k]: Math.round(Number(v) * scale) }))
  const save = async () => {
    setErr(null); setSaved(false)
    const res = await supabase.rpc('calendar_set_rules', { p: r })
    if (res.error) setErr(new Error(res.error.message)); else { setSaved(true); onSaved() }
  }
  const table = (which: 'call_hours' | 'visit_hours', title: string) => (
    <div>
      <p className="mb-1 font-medium">{title}</p>
      <div className="space-y-1">
        {DAYS.map(([day, label]) => {
          const w = r[which]?.[day]?.[0] ?? null
          return (
            <div key={day} className="flex items-center gap-2">
              <label className="inline-flex w-16 items-center gap-2">
                <input type="checkbox" checked={!!w} onChange={(e) => setDay(which, day, e.target.checked ? ['09:00', '17:00'] : null)} />{label}
              </label>
              {w ? (<>
                <Input type="time" step={900} className="h-9 w-32" value={w[0]} onChange={(e) => setDay(which, day, [e.target.value, w[1]])} aria-label={`${label} start`} />
                <span>to</span>
                <Input type="time" step={900} className="h-9 w-32" value={w[1]} onChange={(e) => setDay(which, day, [w[0], e.target.value])} aria-label={`${label} end`} />
              </>) : <span className="text-muted-foreground">off</span>}
            </div>
          )
        })}
      </div>
    </div>
  )
  return (
    <div className="space-y-3 rounded-lg border p-3">
      <p className="font-medium">Your booking hours (Central time)</p>
      <div className="grid gap-4 md:grid-cols-2">
        {table('call_hours', 'Seller calls')}
        {table('visit_hours', 'Visits (walk-throughs)')}
      </div>
      <div className="grid gap-3 sm:grid-cols-3 lg:grid-cols-5">
        <label>Call length (min)<Input type="number" min={10} max={180} className="mt-1 h-10" value={r.call_minutes} onChange={(e) => num('call_minutes', e.target.value)} /></label>
        <label>Visit length (min)<Input type="number" min={15} max={240} className="mt-1 h-10" value={r.visit_minutes} onChange={(e) => num('visit_minutes', e.target.value)} /></label>
        <label>Gap between (min)<Input type="number" min={0} max={120} className="mt-1 h-10" value={r.buffer_minutes} onChange={(e) => num('buffer_minutes', e.target.value)} /></label>
        <label>Notice (hours)<Input type="number" min={0} max={48} step={0.5} className="mt-1 h-10" value={r.min_notice_minutes / 60} onChange={(e) => num('min_notice_minutes', e.target.value, 60)} /></label>
        <label>Book up to (days ahead)<Input type="number" min={1} max={60} className="mt-1 h-10" value={r.days_ahead} onChange={(e) => num('days_ahead', e.target.value)} /></label>
      </div>
      <div className="flex items-center gap-3">
        <Button className="h-11" onClick={() => void save()}>Save hours</Button>
        {saved && <span className="text-emerald-700">Saved. The agent uses these from its next booking.</span>}
      </div>
      <ErrorNote error={err} />
    </div>
  )
}

function Preview() {
  const [p, setP] = useState<{ call: Slots; visit: Slots } | null>(null)
  const [err, setErr] = useState<Error | null>(null)
  const load = async () => {
    setErr(null)
    try { setP(await calendarFn<{ call: Slots; visit: Slots }>({ action: 'slots' })) } catch (e) { setErr(e instanceof Error ? e : new Error(String(e))) }
  }
  return (
    <div className="space-y-2">
      <Button size="sm" variant="outline" onClick={() => void load()}>Show my next open times</Button>
      <ErrorNote error={err} />
      {p && (
        <div className="grid gap-3 sm:grid-cols-2">
          <div><p className="font-medium">Calls</p><p className="text-muted-foreground">{p.call.slots.map((x) => x.label).join(' · ') || 'none in the window'}</p></div>
          <div><p className="font-medium">Visits</p><p className="text-muted-foreground">{p.visit.slots.map((x) => x.label).join(' · ') || 'none in the window'}</p></div>
        </div>
      )}
    </div>
  )
}
