// Power hour (Colin 2026-10-28: "theres no rapid click through to bang out 60 or 80 of the needed calls in our ui").
// One compact card at a time from power_dial_queue (the day's call list, then the texted-but-silent cards), one big
// Dial, one tap for the outcome, and the next card is up. "We talked" opens the full call script on the card for a
// real conversation. On a computer the keys do it all: D or Enter dials, 1-5 log, S skips. Auto-dial (off by default)
// calls the next card three seconds after an outcome unless she cancels.
// Someone who just texted back with a bit of interest (Muse's call_next, migration 0115) comes up next: the list
// refreshes every 30 seconds, and the card she is on never changes under her. A seller who called us and wasn't reached
// comes before everyone (0117), with their voicemail.
import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Badge, Empty, ErrorNote } from '@/components/ui/form'
import { CallScript, pickupLine } from '@/components/CallScript'
import { PHONE_SCRIPT } from '@/lib/callScript'
import { supabase } from '@/lib/supabaseClient'
import { api, useLead } from '@/lib/queries'
import { likelyDisconnected, useDialer } from '@/lib/dialer'
import { fmtDateTime, fmtPhone } from '@/lib/format'

type Item = {
  lead_id: string; task_id: string | null; source: 'missed_call' | 'callback' | 'replied' | 'checkin' | 'call_list' | 'texted_silent'; why: string | null; reply?: string | null
  task_note?: string | null
  package?: { id: string; status: string; colin_call: string | null; colin_asks: string | null; caller_answers: string | null; callback_at: string | null; number_note: string | null } | null
  missed_at?: string | null; voicemail?: boolean | null; voicemail_words?: string | null
  owner_name: string; address: string | null; municipality: string | null; reasons: string[] | null; lane: string | null
  texts_sent: number; first_text_at: string | null; last_text_at: string | null; dials_7d: number; dials_total?: number; last_dial: string | null
  phone: string; line_type: string | null; phone_person: string | null; other_phones: number
}
type Stats = { dials: number; reached: number; voicemails: number; interested: number; done: string[]; started: number | null }

const ENTITY = /\b(LLC|INC|CORP|CO|TRUST|TRUSTEE|ESTATE|LTD|LP|BANK|CHURCH|PROPERTIES|HOLDINGS|INVESTMENTS)\b/i
const title = (s: string) => s.toLowerCase().replace(/\b([a-z])/g, (c) => c.toUpperCase())
const firstName = (owner: string) => (ENTITY.test(owner) ? '' : title((owner.split(/[\s,]+/)[0] ?? '')))
const street = (a: string | null) => (a ? title(a.split(';')[0].trim()) : 'the property')
// a practice run on TEST cards (?test=1) keeps its own count
const isTest = () => typeof window !== 'undefined' && new URLSearchParams(window.location.search).get('test') === '1'
const todayKey = () => `power:${isTest() ? 'test:' : ''}${new Date().toISOString().slice(0, 10)}`
const empty = (): Stats => ({ dials: 0, reached: 0, voicemails: 0, interested: 0, done: [], started: null })
function loadStats(): Stats {
  try { const s = localStorage.getItem(todayKey()); return s ? { ...empty(), ...JSON.parse(s) } : empty() } catch { return empty() }
}
function saveStats(s: Stats) { try { localStorage.setItem(todayKey(), JSON.stringify(s)) } catch { /* private window: counts live for this sitting */ } }

// Rick: only four objections come up in the first 30 seconds (plus "who texted me?" for owners we texted)
const FIRST_30 = ['obj_who_are_you', 'obj_who_texted', 'obj_scam', 'obj_my_number', 'obj_flat_no']
  .map((id) => (PHONE_SCRIPT as unknown as { objections: { id: string; trigger: string; say: string }[] }).objections.find((o) => o.id === id))
  .filter((o): o is { id: string; trigger: string; say: string } => !!o)

const OUTCOMES = [
  { key: '1', id: 'no_answer', label: 'No answer', note: 'No answer (Power hour).' },
  { key: '2', id: 'voicemail', label: 'Left voicemail', note: 'Left a voicemail (Power hour).' },
  { key: '3', id: 'wrong_number', label: 'Wrong number', note: 'Not them (Power hour).' },
  { key: '4', id: 'not_interested', label: 'Not interested', note: 'Not interested (Power hour).' },
  { key: '6', id: 'disconnected', label: 'Disconnected', note: 'Disconnected number (Power hour).' },
] as const

export function PowerDial({ caller }: { caller: string }) {
  const qc = useQueryClient()
  const { active, incoming, start, dismiss, hangUp, supported } = useDialer()
  const q = useQuery({
    // a missed call has to reach the screen fast (Colin 2026-10-29: Adil could not see a seller who called back during
    // Power hour): poll every 10 s, keep polling while the phone's dialer has the browser in the background, and
    // refresh on coming back to the tab
    queryKey: ['power_dial'], staleTime: Infinity, refetchOnWindowFocus: true, refetchInterval: 10_000, refetchIntervalInBackground: true,
    queryFn: async () => {
      const test = typeof window !== 'undefined' && new URLSearchParams(window.location.search).get('test') === '1'
      const r = await supabase.rpc('power_dial_queue', test ? { p_limit: 150, p_test: true } : { p_limit: 150 })
      if (r.error) throw new Error(r.error.message)
      return (r.data ?? []) as Item[]
    },
  })
  const refetch = q.refetch
  const [stats, setStats] = useState<Stats>(loadStats)
  const [skipped, setSkipped] = useState<string[]>([])
  const [talking, setTalking] = useState<string | null>(null)
  // the card she dialed or is talking to stays on screen while a refresh brings a texter to the top, and stays even
  // when the refresh no longer lists it (a card with a call open drops out of the queue: Thalia 2026-10-28, "their info
  // only stays on the screen for a second before it automatically moves to the next lead, even while I'm still on the call")
  const [pin, setPin] = useState<string | null>(null)
  const pinItem = useRef<Item | null>(null)
  const [auto, setAuto] = useState(false)
  // hang up a call nobody answered after about five rings and log it as no answer (Twilio itself gives up at 30 s)
  const [ringLimit, setRingLimit] = useState(true)
  const RING_SECONDS = 22
  const pendingNoAnswer = useRef<string | null>(null)
  const noAnswerNote = useRef<string | null>(null)
  const [countdown, setCountdown] = useState<number | null>(null)
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState<string | null>(null)
  // a remark that goes with whichever outcome she taps (Thalia 2026-10-28: "add a remarks")
  const [remark, setRemark] = useState('')
  const update = useCallback((f: (s: Stats) => Stats) => setStats((s) => { const n = f(s); saveStats(n); return n }), [])

  const list = useMemo(() => {
    const all = (q.data ?? []).filter((x) => !stats.done.includes(x.lead_id))
    const ordered = [...all.filter((x) => !skipped.includes(x.lead_id)), ...all.filter((x) => skipped.includes(x.lead_id))]
    const held = pin ? (ordered.find((x) => x.lead_id === pin) ?? (pinItem.current?.lead_id === pin && !stats.done.includes(pin) ? pinItem.current : undefined)) : undefined
    return held ? [held, ...ordered.filter((x) => x.lead_id !== held.lead_id)] : ordered
  }, [q.data, stats.done, skipped, pin])
  const cur = list[0] ?? null
  const onThis = !!active && !!cur && active.leadId === cur.lead_id
  const live = onThis && ['connecting', 'ringing', 'in_call'].includes(active!.status)
  const callerName = caller.charAt(0).toUpperCase() + caller.slice(1)
  const vars: Record<string, string> = cur ? { first_name: firstName(cur.owner_name) || 'there', street: street(cur.address) } : { first_name: 'there', street: 'the property' }

  const dial = useCallback(() => {
    if (!cur || !supported || live || incoming || (active && ['connecting', 'ringing', 'in_call'].includes(active.status))) return
    setErr(null)
    setCountdown(null)
    if (active) dismiss()
    update((s) => ({ ...s, dials: s.dials + 1, started: s.started ?? Date.now() }))
    pinItem.current = cur
    setPin(cur.lead_id)
    void start({ to: cur.phone, label: `${title(cur.owner_name)} - ${street(cur.address)}`, leadId: cur.lead_id, contactId: null, quiet: true })
  }, [cur, supported, live, incoming, active, dismiss, start, update])

  const next = useCallback((id: string, logged: boolean) => {
    update((s) => ({ ...s, done: [...s.done, id] }))
    setTalking(null)
    setPin(null)
    void refetch()   // a seller who called back while this card was up comes straight to the top
    if (logged && auto) setCountdown(2)
  }, [auto, update, refetch])

  const log = useCallback(async (o: { id: string; note: string }) => {
    if (!cur || live || busy) return
    setBusy(true)
    setErr(null)
    const r = await api.logCall(cur.lead_id, cur.phone, o.id === 'voicemail' ? 'no_answer' : o.id, remark.trim() ? `${o.note} ${remark.trim()}` : o.note, null)
    setBusy(false)
    const d = r.data as { ok?: boolean; reason?: string } | null
    if (r.error || d?.ok === false) { setErr(r.error?.message ?? d?.reason ?? 'Not logged'); return }
    if (onThis) dismiss()
    setRemark('')
    update((s) => ({ ...s, voicemails: s.voicemails + (o.id === 'voicemail' ? 1 : 0), reached: s.reached + (['wrong_number', 'not_interested'].includes(o.id) ? 1 : 0) }))
    void qc.invalidateQueries({ queryKey: ['tasks'] })
    next(cur.lead_id, true)
  }, [cur, live, busy, onThis, dismiss, update, qc, next, remark])

  const skip = useCallback(() => {
    if (!cur || live) return
    if (onThis) dismiss()
    setSkipped((s) => [...s.filter((x) => x !== cur.lead_id), cur.lead_id])
    setTalking(null)
    setPin(null)
  }, [cur, live, onThis, dismiss])

  // five rings and nobody: hang up, and the no answer is logged when the call has ended
  const dialedAt = useRef<number | null>(null)
  useEffect(() => {
    if (!onThis || !active) { dialedAt.current = null; return }
    if (active.status === 'connecting' && dialedAt.current === null) dialedAt.current = Date.now()
    if (!ringLimit || !(active.status === 'connecting' || active.status === 'ringing')) return
    const left = RING_SECONDS * 1000 - (Date.now() - (dialedAt.current ?? Date.now()))
    const t = setTimeout(() => { pendingNoAnswer.current = cur?.lead_id ?? null; hangUp() }, Math.max(0, left))
    return () => clearTimeout(t)
  }, [onThis, active, ringLimit, hangUp, cur])
  useEffect(() => {
    if (!cur || !onThis || !active || pendingNoAnswer.current !== cur.lead_id) return
    if (active.status === 'ended' || active.status === 'error') {
      pendingNoAnswer.current = null
      const note = noAnswerNote.current ?? `No answer: rang ${RING_SECONDS} s, hung up (Power hour).`
      noAnswerNote.current = null
      void log({ ...OUTCOMES[0], note })
    }
  }, [cur, onThis, active, log])

  // two callers at once (0120): the card on my screen is mine for a few minutes, renewed while it stays up; when
  // someone else already has it, the list is fetched again and their card drops out of mine
  const claimed = useRef<string | null>(null)
  useEffect(() => {
    const id = cur?.lead_id
    if (!id) return
    let on = true
    const claim = async () => {
      const r = await supabase.rpc('power_claim', { p_lead_id: id })
      const d = r.data as { ok?: boolean } | null
      if (!on) return
      if (d && d.ok === false && pin !== id) { void q.refetch(); return }
      claimed.current = id
    }
    void claim()
    const t = setInterval(() => void claim(), 120_000)
    return () => {
      on = false
      clearInterval(t)
      if (claimed.current === id) { claimed.current = null; void supabase.rpc('power_release', { p_lead_id: id }) }
    }
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [cur?.lead_id])

  // a seller calling in comes first (Colin 2026-10-28): auto-dial stops, and a call still only ringing out is dropped
  // and logged as no answer, so the bar at the top can take theirs. A conversation already going is hers to end
  // ("Hang up and answer" on that bar); its card stays here, unlogged, for after.
  useEffect(() => {
    if (!incoming) return
    setCountdown(null)
    if (cur && onThis && active && (active.status === 'connecting' || active.status === 'ringing')) {
      pendingNoAnswer.current = cur.lead_id
      noAnswerNote.current = 'No answer: hung up while ringing to take a call coming in (Power hour).'
      hangUp()
    }
  }, [incoming, cur, onThis, active, hangUp])

  // auto-dial: 2, 1, dial (any key or Cancel stops it)
  useEffect(() => {
    if (countdown === null) return
    if (countdown <= 0) { setCountdown(null); dial(); return }
    const t = setTimeout(() => setCountdown((c) => (c === null ? null : c - 1)), 1000)
    return () => clearTimeout(t)
  }, [countdown, dial])

  // keys on a computer: D / Enter dial, 1-4 outcomes, 5 we talked, S skip, Esc cancels auto-dial
  const keys = useRef({ dial, log, skip, cur, live, incoming: !!incoming })
  keys.current = { dial, log, skip, cur, live, incoming: !!incoming }
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const t = e.target as HTMLElement | null
      if (t && (t.tagName === 'INPUT' || t.tagName === 'TEXTAREA' || t.tagName === 'SELECT' || t.isContentEditable)) return
      // Enter or Space on a focused button presses that button, nothing else (it used to also dial)
      if ((e.key === 'Enter' || e.key === ' ') && t && (t.tagName === 'BUTTON' || t.tagName === 'A')) return
      if (e.metaKey || e.ctrlKey || e.altKey) return
      const k = keys.current
      if (e.key === 'Escape') { setCountdown(null); return }
      if ((e.key === 'h' || e.key === 'H') && k.live) { hangUp(); return }
      if (talking || k.incoming) return   // a call coming in: the keys wait for the bar at the top
      if (e.key === 'd' || e.key === 'D' || e.key === 'Enter') { e.preventDefault(); k.dial() }
      else if (e.key === 's' || e.key === 'S') k.skip()
      else if (e.key === '5' && k.cur && !k.live) { if (k.cur) { update((s) => ({ ...s, reached: s.reached + 1 })); setTalking(k.cur.lead_id); pinItem.current = k.cur; setPin(k.cur.lead_id) } }
      else { const o = OUTCOMES.find((x) => x.key === e.key); if (o) void k.log(o) }
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [talking, update, hangUp])

  const minutes = stats.started ? Math.max(1, Math.round((Date.now() - stats.started) / 60000)) : 0
  return (
    <div className="space-y-3" data-testid="power-dial">
      <div className="flex flex-wrap items-center gap-2 rounded-lg border bg-muted/40 p-2 text-sm">
        <span className="font-semibold">{stats.dials} dialed</span>
        <span>{stats.reached} reached</span>
        <span>{stats.voicemails} voicemails</span>
        <span className="text-muted-foreground">{list.length} left{minutes ? ` · ${minutes} min` : ''}</span>
        <label className="ml-auto flex items-center gap-1.5"><input type="checkbox" checked={auto} onChange={(e) => { setAuto(e.target.checked); setCountdown(null) }} /> Auto-dial next</label>
        <label className="flex items-center gap-1.5"><input type="checkbox" checked={ringLimit} onChange={(e) => setRingLimit(e.target.checked)} /> Hang up after 5 rings</label>
      </div>
      <ErrorNote error={q.error} />
      {incoming && <p role="status" className="rounded-lg border-2 border-emerald-400 bg-emerald-50 p-2 text-sm font-medium dark:bg-emerald-950/30">A seller is calling in: take it at the top of the screen. Power hour waits; their card opens when you answer.</p>}
      {q.isLoading && <Empty>Loading the calls...</Empty>}
      {!q.isLoading && !cur && <Empty>Nobody left to dial right now. <Button variant="link" onClick={() => void q.refetch()}>Check again</Button></Empty>}
      {cur && pin === cur.lead_id && list.slice(1).some((x) => x.source === 'replied' || x.source === 'missed_call') && (
        <p role="status" className="rounded-lg border-2 border-amber-300 bg-amber-50 p-2 text-sm font-medium dark:bg-amber-950/30">
          {list.slice(1).some((x) => x.source === 'missed_call') ? 'Missed call: a seller called us back' : 'Someone just texted back'}: they are next, right after this card.</p>
      )}
      {cur && (
        <section className="space-y-3 rounded-lg border-2 border-primary/40 bg-card p-3" data-testid="power-card">
          <div>
            <div className="flex flex-wrap items-center gap-2">
              <h2 className="text-lg font-semibold">{title(cur.owner_name)}</h2>
              <Badge tone={cur.source === 'missed_call' || cur.source === 'callback' ? 'bad' : cur.source === 'replied' ? 'warn' : cur.source === 'call_list' ? 'info' : undefined}>
                {cur.source === 'missed_call' ? 'Missed call: call back now' : cur.source === 'callback' ? 'Promised callback' : cur.source === 'checkin' ? '90-day check-in call' : cur.source === 'replied' ? 'Texted back: call now' : cur.source === 'call_list' ? 'On today’s list' : 'Texted, no reply'}</Badge>
            </div>
            <p className="text-sm">{street(cur.address)}{cur.municipality ? `, ${cur.municipality}` : ''}</p>
            <p className="mt-1 text-xs text-muted-foreground">
              {cur.source === 'missed_call' ? `They called us ${fmtDateTime(cur.missed_at ?? null)}${cur.voicemail ? ' and left a voicemail' : ''}` : cur.source === 'replied' ? 'They texted back' : cur.texts_sent ? `${cur.texts_sent} text${cur.texts_sent > 1 ? 's' : ''}, last ${fmtDateTime(cur.last_text_at)}, no reply` : 'Never texted'}
              {cur.dials_7d ? ` · dialed ${cur.dials_7d}x this week` : ''}
              {cur.reasons?.length ? ` · on the list for: ${cur.reasons.join(', ')} (never say this)` : ''}
            </p>
          </div>

          {cur.source === 'missed_call' && (
            <p className="rounded-md border-2 border-red-300 bg-red-50 p-2 text-sm dark:bg-red-950/30">
              {cur.voicemail_words ? <><span className="font-semibold">Their voicemail:</span> &ldquo;{cur.voicemail_words}&rdquo;</> : <span className="font-semibold">Missed call: they called us and nobody picked up.{cur.voicemail ? ' The voicemail is still being written out.' : ''}</span>}
            </p>
          )}
          {cur.source === 'checkin' && (
            <p className="rounded-md border-2 border-sky-300 bg-sky-50 p-2 text-sm dark:bg-sky-950/30">
              <span className="font-semibold">90-day check-in call.</span> {cur.task_note ?? 'We tried them before with no answer; this is the check-in.'}
            </p>
          )}
          {cur.source === 'replied' && cur.reply && (
            <p className="rounded-md border-2 border-amber-300 bg-amber-50 p-2 text-sm dark:bg-amber-950/30"><span className="font-semibold">They texted:</span> &ldquo;{cur.reply}&rdquo;</p>
          )}
          {cur.source === 'callback' && <CallbackPlan item={cur} caller={callerName} street={vars.street} busy={busy} live={live}
            onDone={async (note) => {
              setBusy(true)
              const r = await supabase.rpc('callback_done', { p_lead_id: cur.lead_id, p_note: note })
              setBusy(false)
              if (r.error) { setErr(r.error.message); return }
              if (onThis) dismiss()
              update((st) => ({ ...st, reached: st.reached + 1 }))
              void qc.invalidateQueries({ queryKey: ['tasks'] })
              next(cur.lead_id, true)
            }} />}
          <History leadId={cur.lead_id} open={cur.source === 'replied' || cur.source === 'missed_call' || cur.source === 'callback'} />
          <div className="rounded-md bg-muted p-2 text-sm">
            <p><span className="font-semibold">Open with:</span> &ldquo;{cur.source === 'callback'
              ? `Hi${vars.first_name === 'there' ? '' : `, is this ${vars.first_name}?`}${vars.first_name === 'there' ? ', this' : ' This'} is ${callerName}, calling you back about ${vars.street} like I said I would.`
              : cur.source === 'missed_call'
              ? `Hi${vars.first_name === 'there' ? '' : `, is this ${vars.first_name}?`}${vars.first_name === 'there' ? ', this' : ' This'} is ${callerName}, returning your call about ${vars.street}.`
              : pickupLine(caller, cur.source === 'replied' ? 'hot_text' : 'cold', vars)}&rdquo;</p>
            {cur.source === 'callback' ? (
              <p className="mt-1"><span className="font-semibold">Then:</span> what&apos;s in the red box above, for what Colin decided.</p>
            ) : cur.source === 'missed_call' ? (
              <p className="mt-1"><span className="font-semibold">Then:</span> let them tell you why they called, and tap <span className="font-medium">We talked</span>. No answer: leave a short voicemail (&ldquo;Hi{vars.first_name === 'there' ? '' : ` ${vars.first_name}`}, it&apos;s {callerName} returning your call about {vars.street}. Call me back at this number when you can.&rdquo;), then tap <span className="font-medium">Left voicemail</span>.</p>
            ) : cur.source === 'replied' ? (
              <p className="mt-1"><span className="font-semibold">Then:</span> &ldquo;What&apos;s got you thinking about it?&rdquo; and tap <span className="font-medium">We talked</span>. No answer: tap No answer, and Muse texts them back.</p>
            ) : (
            <p className="mt-1"><span className="font-semibold">Then:</span> &ldquo;Any interest in selling it?&rdquo; Yes: &ldquo;What&apos;s got you thinking about it?&rdquo; and tap <span className="font-medium">We talked</span>. A flat no: &ldquo;Before I go, do you own anything else you&apos;d ever consider selling?&rdquo; then <span className="font-medium">Not interested</span>.</p>
            )}
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


          {talking === cur.lead_id ? (
            <TalkPanel leadId={cur.lead_id} phone={cur.phone} onLogged={(o) => {
              update((s) => ({ ...s, interested: s.interested + (o === 'interested' ? 1 : 0) }))
              if (onThis) dismiss()
              next(cur.lead_id, false)
            }} />
          ) : (
            <>
            <Input placeholder="Remark (optional): saved with the button you tap" className="h-10" value={remark}
              onChange={(e) => setRemark(e.target.value)} aria-label="Remark" />
            <div className="grid grid-cols-2 gap-2 sm:grid-cols-3">
              {OUTCOMES.map((o) => (
                <Button key={o.id} variant="outline" className="h-12" disabled={live || busy} onClick={() => void log(o)}>
                  {o.label}<span className="ml-1 hidden text-xs text-muted-foreground sm:inline">({o.key})</span>
                </Button>
              ))}
              <Button className="h-12" disabled={busy} onClick={() => { update((s) => ({ ...s, reached: s.reached + 1 })); setTalking(cur.lead_id); pinItem.current = cur; setPin(cur.lead_id) }}>
                We talked: script<span className="ml-1 hidden text-xs sm:inline">(5)</span>
              </Button>
              <Button variant="ghost" className="h-12" disabled={live} onClick={skip}>Skip<span className="ml-1 hidden text-xs text-muted-foreground sm:inline">(S)</span></Button>
            </div>
            </>
          )}
          {cur.source === 'replied' || cur.source === 'missed_call' || cur.source === 'callback' ? null : (cur.dials_total ?? 0) >= 2 ? (
            <p className="rounded-md border border-amber-300 bg-amber-50 p-2 text-sm dark:bg-amber-950/30"><span className="font-semibold">Try {(cur.dials_total ?? 0) + 1}: leave this voicemail (under 20 s):</span> &ldquo;Hi{vars.first_name === 'there' ? '' : ` ${vars.first_name}`}, it&apos;s {callerName}. I had a quick question about the place on {vars.street}. Give me a call when you get a minute.&rdquo;</p>
          ) : (
            <p className="rounded-md bg-muted p-2 text-sm text-muted-foreground"><span className="font-semibold">Try {(cur.dials_total ?? 0) + 1}: no voicemail.</span> If it goes to voicemail, hang up and tap No answer. Leave one short voicemail on the third try; the first two make them curious.</p>
          )}
          <details className="rounded-md border p-2 text-sm">
            <summary className="cursor-pointer font-medium">If they say... (the first 30 seconds)</summary>
            <ul className="mt-1 space-y-1">
              {FIRST_30.map((o) => <li key={o.id}><span className="text-muted-foreground">{o.trigger}</span> &rarr; &ldquo;{o.say.replace(/\{caller\}/g, callerName)}&rdquo;</li>)}
            </ul>
          </details>
          {onThis && active?.status === 'error' && likelyDisconnected(active.error) && (
            <div className="flex flex-wrap items-center gap-2 rounded-md border-2 border-red-300 bg-red-50 p-2 text-sm dark:bg-red-950/30">
              <span className="flex-1">The call failed before it rang: usually a disconnected number.</span>
              <Button size="sm" disabled={busy} onClick={() => void log(OUTCOMES.find((o) => o.id === 'disconnected')!)}>Disconnected</Button>
            </div>
          )}
          {err && <p className="text-sm text-red-700">{err}</p>}
          <p className="hidden text-xs text-muted-foreground sm:block">Keys: D or Enter dials · H hangs up · 1 no answer · 2 voicemail · 3 wrong number · 4 not interested · 5 we talked · 6 disconnected · S skip · Esc stops auto-dial</p>
        </section>
      )}
    </div>
  )
}

type HistoryRow = { id: string; direction: 'in' | 'out'; channel: string; body: string | null; status: string | null; sent_at: string }

/** What already happened with this owner, on the card itself (Colin 2026-10-28: "how does thalia know about the context
 *  ... whats been texted back and forth with him and the fact that he left a voicemail"): the last texts both ways,
 *  calls and voicemails, oldest first. Open for someone who texted or called us; folded for a cold card. */
function History({ leadId, open }: { leadId: string; open: boolean }) {
  const q = useQuery({ queryKey: ['power_history', leadId], staleTime: 30_000, queryFn: async () => {
    const r = await supabase.from('messages').select('id, direction, channel, body, status, sent_at').eq('lead_id', leadId)
      .in('channel', ['sms', 'call']).order('sent_at', { ascending: false }).limit(12)
    if (r.error) throw new Error(r.error.message)
    return ((r.data ?? []) as HistoryRow[]).reverse()
  } })
  const rows = q.data ?? []
  if (!rows.length) return null
  const who = (m: HistoryRow) => m.channel === 'call'
    ? (m.direction === 'in' ? 'They called' : 'We called') + (m.status ? ` (${m.status.replace(/_/g, ' ')})` : '')
    : m.direction === 'in' ? 'They texted' : 'We texted'
  return (
    <details className="rounded-md border p-2 text-sm" open={open}>
      <summary className="cursor-pointer font-medium">What already happened ({rows.length})</summary>
      <ul className="mt-1 max-h-56 space-y-1 overflow-y-auto">
        {rows.map((m) => (
          <li key={m.id} className={m.direction === 'in' ? 'rounded bg-amber-50 p-1 dark:bg-amber-950/30' : 'p-1'}>
            <span className="font-medium">{who(m)}</span> <span className="text-xs text-muted-foreground">{fmtDateTime(m.sent_at)}</span>
            {m.body ? <span className="block whitespace-pre-line text-muted-foreground">{m.body.length > 400 ? `${m.body.slice(0, 400)}...` : m.body}</span> : null}
          </li>
        ))}
      </ul>
    </details>
  )
}

/** A promised callback (0124): what Colin decided on the package, the words for it, and how to finish. */
function CallbackPlan({ item, caller, street, busy, live, onDone }: { item: Item; caller: string; street: string; busy: boolean; live: boolean
  onDone: (note: string) => Promise<void> }) {
  const p = item.package
  const say = 'rounded-md border-l-4 border-amber-400 bg-amber-50 p-2 dark:bg-amber-950/30'
  const open = <a className="underline" href={`/lead/${item.lead_id}#package`}>Open his card</a>
  let title = 'The callback you promised'
  let body: React.ReactNode = <p>Call at the time you promised. {open} for the package.</p>
  let doneLabel = 'Callback done'
  if (p && p.colin_call === 'pass') {
    title = 'Colin passed: close politely'
    body = <blockquote className={say}>&ldquo;Hi, it&apos;s {caller}. My partner and I went over everything, and we&apos;re not the right fit for this one right now. I didn&apos;t want to leave you waiting. If anything changes, keep this number.&rdquo;</blockquote>
    doneLabel = 'Told them: callback done'
  } else if (p && p.status === 'go_walk') {
    title = 'Colin wants to walk it: book his walk'
    body = <>
      <blockquote className={say}>&ldquo;My partner and I went over everything you told me. He&apos;d like to come see it himself. He only puts a number on a place once he&apos;s walked it.&rdquo; Then: &ldquo;If his number works for you, are you ready to give him a yes or a no that day? A no is completely fine.&rdquo;</blockquote>
      <p>A yes: {open} and tap <b>Book Colin&apos;s walk</b> (it closes the callback). Never a number on the phone.</p>
    </>
    doneLabel = ''
  } else if (p && p.colin_asks && !p.caller_answers) {
    title = 'Colin needs answers first'
    body = <>
      <p className="whitespace-pre-line rounded bg-muted p-2">{p.colin_asks}</p>
      <p>&ldquo;My partner is going over everything you told me and had a couple of quick questions.&rdquo; Then {open} and type their answers under <b>Colin needs to know first</b>, and set the next callback.</p>
    </>
    doneLabel = ''
  } else if (p && ['waiting_value', 'waiting_number'].includes(p.status)) {
    title = "Colin hasn't decided yet"
    body = <>
      <blockquote className={say}>&ldquo;Hi, it&apos;s {caller}. I told you I&apos;d call today. My partner is still going over everything you told me. Can I call you back [day] at [time]?&rdquo;</blockquote>
      <p>Then {open} and tap <b>Set the new callback</b>.</p>
    </>
    doneLabel = ''
  }
  return (
    <div className="space-y-2 rounded-md border-2 border-red-300 p-2 text-sm">
      <p className="font-semibold">{title}</p>
      {item.task_note && <p className="text-xs text-muted-foreground">{item.task_note}</p>}
      {body}
      {doneLabel && <Button size="sm" disabled={busy || live} onClick={() => void onDone(doneLabel === 'Callback done' ? 'callback made' : `told them: ${title.toLowerCase()} (${street})`)}>{doneLabel}</Button>}
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
