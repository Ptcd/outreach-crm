// Power hour (Colin 2026-10-28: "theres no rapid click through to bang out 60 or 80 of the needed calls in our ui").
// One compact card at a time from power_dial_queue (the day's call list, then the texted-but-silent cards), one big
// Dial, one tap for the outcome, and the next card is up. "We talked" opens the full call script on the card for a
// real conversation. On a computer the keys do it all: D or Enter dials, 1-5 log, S skips. Auto-dial (off by default)
// calls the next card three seconds after an outcome unless she cancels.
import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { Button } from '@/components/ui/button'
import { Badge, Empty, ErrorNote } from '@/components/ui/form'
import { CallScript, pickupLine } from '@/components/CallScript'
import { supabase } from '@/lib/supabaseClient'
import { api, useLead } from '@/lib/queries'
import { useDialer } from '@/lib/dialer'
import { fmtDateTime, fmtPhone } from '@/lib/format'

type Item = {
  lead_id: string; task_id: string | null; source: 'call_list' | 'texted_silent'; why: string | null
  owner_name: string; address: string | null; municipality: string | null; reasons: string[] | null; lane: string | null
  texts_sent: number; first_text_at: string | null; last_text_at: string | null; dials_7d: number; last_dial: string | null
  phone: string; line_type: string | null; phone_person: string | null; other_phones: number
}
type Stats = { dials: number; reached: number; voicemails: number; interested: number; done: string[]; started: number | null }

const ENTITY = /\b(LLC|INC|CORP|CO|TRUST|TRUSTEE|ESTATE|LTD|LP|BANK|CHURCH|PROPERTIES|HOLDINGS|INVESTMENTS)\b/i
const title = (s: string) => s.toLowerCase().replace(/\b([a-z])/g, (c) => c.toUpperCase())
const firstName = (owner: string) => (ENTITY.test(owner) ? '' : title((owner.split(/[\s,]+/)[0] ?? '')))
const street = (a: string | null) => (a ? title(a.split(';')[0].trim()) : 'the property')
const todayKey = () => `power:${new Date().toISOString().slice(0, 10)}`
const empty = (): Stats => ({ dials: 0, reached: 0, voicemails: 0, interested: 0, done: [], started: null })
function loadStats(): Stats {
  try { const s = localStorage.getItem(todayKey()); return s ? { ...empty(), ...JSON.parse(s) } : empty() } catch { return empty() }
}
function saveStats(s: Stats) { try { localStorage.setItem(todayKey(), JSON.stringify(s)) } catch { /* private window: counts live for this sitting */ } }

const OUTCOMES = [
  { key: '1', id: 'no_answer', label: 'No answer', note: 'No answer (Power hour).' },
  { key: '2', id: 'voicemail', label: 'Left voicemail', note: 'Left a voicemail (Power hour).' },
  { key: '3', id: 'wrong_number', label: 'Wrong number', note: 'Not them (Power hour).' },
  { key: '4', id: 'not_interested', label: 'Not interested', note: 'Not interested (Power hour).' },
] as const

export function PowerDial({ caller }: { caller: string }) {
  const qc = useQueryClient()
  const { active, start, dismiss, hangUp, supported } = useDialer()
  const q = useQuery({
    queryKey: ['power_dial'], staleTime: Infinity, refetchOnWindowFocus: false,
    queryFn: async () => {
      const r = await supabase.rpc('power_dial_queue', { p_limit: 150 })
      if (r.error) throw new Error(r.error.message)
      return (r.data ?? []) as Item[]
    },
  })
  const [stats, setStats] = useState<Stats>(loadStats)
  const [skipped, setSkipped] = useState<string[]>([])
  const [talking, setTalking] = useState<string | null>(null)
  const [auto, setAuto] = useState(false)
  const [countdown, setCountdown] = useState<number | null>(null)
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState<string | null>(null)
  const update = useCallback((f: (s: Stats) => Stats) => setStats((s) => { const n = f(s); saveStats(n); return n }), [])

  const list = useMemo(() => {
    const all = (q.data ?? []).filter((x) => !stats.done.includes(x.lead_id))
    return [...all.filter((x) => !skipped.includes(x.lead_id)), ...all.filter((x) => skipped.includes(x.lead_id))]
  }, [q.data, stats.done, skipped])
  const cur = list[0] ?? null
  const onThis = !!active && !!cur && active.leadId === cur.lead_id
  const live = onThis && ['connecting', 'ringing', 'in_call'].includes(active!.status)
  const callerName = caller.charAt(0).toUpperCase() + caller.slice(1)
  const vars: Record<string, string> = cur ? { first_name: firstName(cur.owner_name) || 'there', street: street(cur.address) } : { first_name: 'there', street: 'the property' }

  const dial = useCallback(() => {
    if (!cur || !supported || live || (active && ['connecting', 'ringing', 'in_call'].includes(active.status))) return
    setErr(null)
    setCountdown(null)
    if (active) dismiss()
    update((s) => ({ ...s, dials: s.dials + 1, started: s.started ?? Date.now() }))
    void start({ to: cur.phone, label: `${title(cur.owner_name)} - ${street(cur.address)}`, leadId: cur.lead_id, contactId: null, quiet: true })
  }, [cur, supported, live, active, dismiss, start, update])

  const next = useCallback((id: string, logged: boolean) => {
    update((s) => ({ ...s, done: [...s.done, id] }))
    setTalking(null)
    if (logged && auto) setCountdown(3)
  }, [auto, update])

  const log = useCallback(async (o: (typeof OUTCOMES)[number]) => {
    if (!cur || live || busy) return
    setBusy(true)
    setErr(null)
    const r = await api.logCall(cur.lead_id, cur.phone, o.id === 'voicemail' ? 'no_answer' : o.id, o.note, null)
    setBusy(false)
    const d = r.data as { ok?: boolean; reason?: string } | null
    if (r.error || d?.ok === false) { setErr(r.error?.message ?? d?.reason ?? 'Not logged'); return }
    if (onThis) dismiss()
    update((s) => ({ ...s, voicemails: s.voicemails + (o.id === 'voicemail' ? 1 : 0), reached: s.reached + (['wrong_number', 'not_interested'].includes(o.id) ? 1 : 0) }))
    void qc.invalidateQueries({ queryKey: ['tasks'] })
    next(cur.lead_id, true)
  }, [cur, live, busy, onThis, dismiss, update, qc, next])

  const skip = useCallback(() => {
    if (!cur || live) return
    if (onThis) dismiss()
    setSkipped((s) => [...s.filter((x) => x !== cur.lead_id), cur.lead_id])
    setTalking(null)
  }, [cur, live, onThis, dismiss])

  // auto-dial: 3, 2, 1, dial (any key or Cancel stops it)
  useEffect(() => {
    if (countdown === null) return
    if (countdown <= 0) { setCountdown(null); dial(); return }
    const t = setTimeout(() => setCountdown((c) => (c === null ? null : c - 1)), 1000)
    return () => clearTimeout(t)
  }, [countdown, dial])

  // keys on a computer: D / Enter dial, 1-4 outcomes, 5 we talked, S skip, Esc cancels auto-dial
  const keys = useRef({ dial, log, skip, cur, live })
  keys.current = { dial, log, skip, cur, live }
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const t = e.target as HTMLElement | null
      if (t && (t.tagName === 'INPUT' || t.tagName === 'TEXTAREA' || t.tagName === 'SELECT' || t.isContentEditable)) return
      if (e.metaKey || e.ctrlKey || e.altKey) return
      const k = keys.current
      if (e.key === 'Escape') { setCountdown(null); return }
      if (talking) return
      if (e.key === 'd' || e.key === 'D' || e.key === 'Enter') { e.preventDefault(); k.dial() }
      else if (e.key === 's' || e.key === 'S') k.skip()
      else if (e.key === '5' && k.cur && !k.live) { if (k.cur) { update((s) => ({ ...s, reached: s.reached + 1 })); setTalking(k.cur.lead_id) } }
      else { const o = OUTCOMES.find((x) => x.key === e.key); if (o) void k.log(o) }
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [talking, update])

  const minutes = stats.started ? Math.max(1, Math.round((Date.now() - stats.started) / 60000)) : 0
  return (
    <div className="space-y-3" data-testid="power-dial">
      <div className="flex flex-wrap items-center gap-2 rounded-lg border bg-muted/40 p-2 text-sm">
        <span className="font-semibold">{stats.dials} dialed</span>
        <span>{stats.reached} reached</span>
        <span>{stats.voicemails} voicemails</span>
        <span className="text-muted-foreground">{list.length} left{minutes ? ` · ${minutes} min` : ''}</span>
        <label className="ml-auto flex items-center gap-1.5"><input type="checkbox" checked={auto} onChange={(e) => { setAuto(e.target.checked); setCountdown(null) }} /> Auto-dial next</label>
      </div>
      <ErrorNote error={q.error} />
      {q.isLoading && <Empty>Loading the calls...</Empty>}
      {!q.isLoading && !cur && <Empty>Nobody left to dial right now. <Button variant="link" onClick={() => void q.refetch()}>Check again</Button></Empty>}
      {cur && (
        <section className="space-y-3 rounded-lg border-2 border-primary/40 bg-card p-3" data-testid="power-card">
          <div>
            <div className="flex flex-wrap items-center gap-2">
              <h2 className="text-lg font-semibold">{title(cur.owner_name)}</h2>
              <Badge tone={cur.source === 'call_list' ? 'info' : undefined}>{cur.source === 'call_list' ? 'On today’s list' : 'Texted, no reply'}</Badge>
            </div>
            <p className="text-sm">{street(cur.address)}{cur.municipality ? `, ${cur.municipality}` : ''}</p>
            <p className="mt-1 text-xs text-muted-foreground">
              {cur.texts_sent ? `${cur.texts_sent} text${cur.texts_sent > 1 ? 's' : ''}, last ${fmtDateTime(cur.last_text_at)}, no reply` : 'Never texted'}
              {cur.dials_7d ? ` · dialed ${cur.dials_7d}x this week` : ''}
              {cur.reasons?.length ? ` · on the list for: ${cur.reasons.join(', ')} (never say this)` : ''}
            </p>
          </div>

          <div className="flex flex-wrap items-center gap-3">
            {live ? (
              <Button className="h-14 flex-1 text-lg" variant="destructive" onClick={hangUp}>Hang up</Button>
            ) : (
              <Button className="h-14 flex-1 text-lg" disabled={!supported || busy} onClick={dial}>
                {countdown !== null ? `Dialing in ${countdown}...` : `Dial ${fmtPhone(cur.phone)}`}
              </Button>
            )}
            {countdown !== null && <Button variant="outline" className="h-14" onClick={() => setCountdown(null)}>Cancel</Button>}
          </div>
          <p className="text-xs text-muted-foreground">
            {cur.line_type ?? 'phone'}{cur.phone_person && !/^\s*$/.test(cur.phone_person) ? ` · ${title(cur.phone_person)}` : ''}
            {cur.other_phones ? ` · ${cur.other_phones} other number${cur.other_phones > 1 ? 's' : ''} on the card` : ''}
            {onThis && active?.status ? ` · ${active.status === 'in_call' ? 'in call' : active.status}` : ''}{onThis && active?.error ? ` - ${active.error}` : ''}
          </p>

          <div className="rounded-md bg-muted p-2 text-sm">
            <p><span className="font-semibold">Open with:</span> &ldquo;{pickupLine(caller, 'cold', vars)}&rdquo;</p>
            <p className="mt-1"><span className="font-semibold">Voicemail (under 20 s):</span> &ldquo;Hi {vars.first_name === 'there' ? '' : `${vars.first_name}, `}it&apos;s {callerName}. I had a quick question about the place on {vars.street}. Give me a call when you get a minute.&rdquo;</p>
          </div>

          {talking === cur.lead_id ? (
            <TalkPanel leadId={cur.lead_id} phone={cur.phone} onLogged={(o) => {
              update((s) => ({ ...s, interested: s.interested + (o === 'interested' ? 1 : 0) }))
              if (onThis) dismiss()
              next(cur.lead_id, false)
            }} />
          ) : (
            <div className="grid grid-cols-2 gap-2 sm:grid-cols-3">
              {OUTCOMES.map((o) => (
                <Button key={o.id} variant="outline" className="h-12" disabled={live || busy} onClick={() => void log(o)}>
                  {o.label}<span className="ml-1 hidden text-xs text-muted-foreground sm:inline">({o.key})</span>
                </Button>
              ))}
              <Button className="h-12" disabled={busy} onClick={() => { update((s) => ({ ...s, reached: s.reached + 1 })); setTalking(cur.lead_id) }}>
                We talked: script<span className="ml-1 hidden text-xs sm:inline">(5)</span>
              </Button>
              <Button variant="ghost" className="h-12" disabled={live} onClick={skip}>Skip<span className="ml-1 hidden text-xs text-muted-foreground sm:inline">(S)</span></Button>
            </div>
          )}
          {err && <p className="text-sm text-red-700">{err}</p>}
          <p className="hidden text-xs text-muted-foreground sm:block">Keys: D or Enter dials · 1 no answer · 2 voicemail · 3 wrong number · 4 not interested · 5 we talked · S skip · Esc stops auto-dial</p>
        </section>
      )}
    </div>
  )
}

/** A real conversation: the card's full call script, and its Log this call moves Power hour on. */
function TalkPanel({ leadId, phone, onLogged }: { leadId: string; phone: string; onLogged: (outcome: string) => void }) {
  const q = useLead(leadId)
  if (q.isLoading) return <Empty>Loading the script...</Empty>
  if (q.error) return <ErrorNote error={q.error} />
  if (!q.data) return <Empty>That card is gone.</Empty>
  const { lead, contacts, messages, gates } = q.data
  return (
    <CallScript lead={lead} contacts={contacts} messages={messages} replyFacts={q.data.facts ?? {}} latestGate={gates[0] ?? null}
      phone={phone} startOpen canOverride={false} onLogged={onLogged} />
  )
}
