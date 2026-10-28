// The package (Colin 2026-10-27, the partner model run Rick's way; migration 0085). The caller's first call never
// prices: it ends here, in a package Colin gets by email with everything in it. Muse adds the value and comps, Colin
// decides walk it or pass (and grades the package), and the caller's callback gets the yes-or-no agreement and books
// Colin's walk. No number on the phone (Colin 2026-10-28, migration 0114): Colin gives his at the house. Each state
// shows who is up and what they do.
import { useState } from 'react'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Badge, ErrorNote, Section, Select, Textarea } from '@/components/ui/form'
import { supabase } from '@/lib/supabaseClient'
import { fmtDateTime, isoToLocalInput, localInputToIso } from '@/lib/format'
import { useAuth } from '@/providers/AuthProvider'
import { api } from '@/lib/queries'
import { NEXT_STEP, callScript, packageFromCall } from '@/lib/callScript'
import type { Lead } from '@/lib/types'

export const CONDITION_ITEMS: { key: string; label: string; ask: string }[] = [
  { key: 'roof', label: 'Roof', ask: 'How old is the roof? Any leaks?' },
  { key: 'hvac', label: 'Furnace and AC', ask: 'How old are the furnace and the air? Both working?' },
  { key: 'water_heater', label: 'Water heater', ask: 'How old is the water heater?' },
  { key: 'foundation', label: 'Foundation and basement', ask: 'Any cracks, or water in the basement?' },
  { key: 'electrical', label: 'Electrical', ask: 'Breakers or the old fuse box? Old wiring?' },
  { key: 'plumbing', label: 'Plumbing', ask: 'Any leaks, or old pipes?' },
  { key: 'windows', label: 'Windows', ask: 'Original, or replaced?' },
  { key: 'kitchen_baths', label: 'Kitchen and baths', ask: 'When were they last updated?' },
  { key: 'yard', label: 'Yard and outside', ask: 'The yard, driveway, garage, trees near the house, a fence?' },
  { key: 'fix_first', label: 'Fix first', ask: 'If you listed it tomorrow, what would you have to fix first?' },
  { key: 'other', label: 'Anything else', ask: '' },
]

const FIELDS: { key: string; label: string; hint: string; long?: boolean }[] = [
  { key: 'need', label: 'Need', hint: 'Why they would sell, in their words', long: true },
  { key: 'timeline', label: 'Timeline', hint: 'Where they are moving, and when' },
  { key: 'their_number', label: 'Their number', hint: 'Word for word' },
  { key: 'their_basis', label: 'How they came up with it', hint: 'A payoff, back taxes, Zillow, a neighbor...' },
  { key: 'on_title', label: 'On the title / decision makers', hint: 'Every name' },
  { key: 'owed', label: 'What is owed', hint: 'Mortgage or liens, behind or not; roughly is fine' },
  { key: 'occupancy', label: 'Who lives there', hint: 'Them, tenants (and rents), or empty' },
  { key: 'photos', label: 'Photos', hint: 'Will they text some? Did they?' },
  { key: 'other_buyers', label: 'Other buyers or agents', hint: 'Who else they have talked to' },
  { key: 'concerns', label: 'What concerns them most', hint: '' },
  { key: 'motivation', label: 'Motivation learned in conversation', hint: 'One line for Colin', long: true },
]

const STATUS: Record<string, { label: string; tone: 'muted' | 'warn' | 'bad' | 'good' | 'info'; who: string }> = {
  waiting_value: { label: 'Waiting for the value', tone: 'info', who: 'Muse pulls the value and comps; Colin can decide without them' },
  waiting_number: { label: "Colin's turn: walk it or pass", tone: 'warn', who: 'Colin decides today' },
  go_walk: { label: 'Colin wants to walk it: callback', tone: 'good', who: 'The caller calls back at the time promised and books his walk' },
  counter: { label: 'Countered: back to Colin', tone: 'warn', who: 'Colin answers the counter' },
  number_ready: { label: 'Number ready: callback', tone: 'good', who: 'The caller calls back at the time promised' },
  agreed: { label: 'Agreed: book the walk', tone: 'good', who: "Book Colin's walk with everyone on the title there" },
  walk_booked: { label: 'Walk booked', tone: 'good', who: '' },
  declined: { label: 'Declined', tone: 'muted', who: '' },
  dead: { label: 'Closed', tone: 'muted', who: '' },
}

type Pkg = Record<string, unknown> & { id: string; status: string; condition: Record<string, string> | null; comps: unknown[] | null }
type Person = { interest_id: string; name: string; role: string; status: string }

// the script's one-tap answer labels, for turning the call's answers into package words
const CALL_LABELS: Record<string, string> = Object.fromEntries([...callScript(), NEXT_STEP].flatMap((q) => (q.choices ?? []).map((c) => [c.id, c.label])))

/** "the roof and the furnace you mentioned": the first two things she wrote down about the house, for the callback line */
function mentioned(cond: Record<string, string> | null): string {
  const names = CONDITION_ITEMS.filter((c) => cond?.[c.key] && !['fix_first', 'other'].includes(c.key)).slice(0, 2).map((c) => `the ${c.label[0].toLowerCase()}${c.label.slice(1)}`)
  return names.length ? `With ${names.join(' and ')} you mentioned` : 'With everything you told me about the place'
}

const money = (n: unknown) => (n == null || n === '' ? '' : `$${Math.round(Number(n)).toLocaleString('en-US')}`)
const OPEN = ['waiting_value', 'waiting_number', 'go_walk', 'number_ready', 'counter', 'agreed']
/** a promised callback within 3 hours (or past) and Colin has not said walk it or pass (0112 pushes Colin the same) */
export const numberNotReady = (pk: { status: string; callback_at?: unknown }, now = Date.now()) =>
  ['waiting_value', 'waiting_number'].includes(pk.status) && !!pk.callback_at && new Date(String(pk.callback_at)).getTime() < now + 3 * 3600_000

export function DealPackage({ lead }: { lead: Lead }) {
  const { isOwner } = useAuth()
  const qc = useQueryClient()
  const q = useQuery({ queryKey: ['package', lead.id], queryFn: async () => {
    const r = await supabase.from('deal_packages').select('*').eq('lead_id', lead.id).order('created_at', { ascending: false }).limit(1)
    if (r.error) throw new Error(r.error.message)
    return ((r.data ?? [])[0] ?? null) as Pkg | null
  } })
  const refresh = () => { void qc.invalidateQueries({ queryKey: ['package', lead.id] }); void qc.invalidateQueries({ queryKey: ['packages_open'] }); void qc.invalidateQueries({ queryKey: ['lead', lead.id] }) }
  const p = q.data
  const open = !!p && OPEN.includes(p.status)
  return (
    <div id="package" className="scroll-mt-16">
      <Section title="Package for Colin" right={p ? <Badge tone={STATUS[p.status]?.tone ?? 'muted'}>{STATUS[p.status]?.label ?? p.status}</Badge> : undefined}>
        <ErrorNote error={q.error} />
        {open ? <OpenPackage p={p!} lead={lead} isOwner={isOwner} onDone={refresh} /> : <SendPackage lead={lead} last={p ?? null} onDone={refresh} />}
      </Section>
    </div>
  )
}

function Summary({ p }: { p: Pkg }) {
  const cond = p.condition ?? {}
  return (
    <dl className="grid gap-x-3 gap-y-1 text-sm sm:grid-cols-[12rem_1fr]">
      {FIELDS.filter((f) => p[f.key]).map((f) => (
        <div key={f.key} className="contents"><dt className="text-muted-foreground">{f.label}</dt><dd>{String(p[f.key])}</dd></div>
      ))}
      {CONDITION_ITEMS.filter((c) => cond[c.key]).map((c) => (
        <div key={c.key} className="contents"><dt className="text-muted-foreground">{c.label}</dt><dd>{cond[c.key]}</dd></div>
      ))}
    </dl>
  )
}

function OpenPackage({ p, lead, isOwner, onDone }: { p: Pkg; lead: Lead; isOwner: boolean; onDone: () => void }) {
  const [err, setErr] = useState<string | null>(null)
  const [grade, setGrade] = useState('')
  const [note, setNote] = useState('')
  const [walkAt, setWalkAt] = useState('')
  const [newCb, setNewCb] = useState(() => isoToLocalInput(new Date(Date.now() + 24 * 3600_000).toISOString()))
  // Colin's walk, booked on the card the same way the call script books it (the belt moves the card to Walk booked,
  // which closes this package and its callback, and gives the caller the confirm call the day before)
  const bookWalk = async () => {
    const when = localInputToIso(walkAt)
    if (!when) { setErr('pick the day and time of the walk'); return }
    setErr(null)
    const r = await api.callAnswer(lead.id, 'next_step', { choices: ['walk'], kind: 'walk', when, at: when })
    if (r.error) { setErr(r.error.message); return }
    const d = r.data as { ok?: boolean; reason?: string } | null
    if (d && d.ok === false) { setErr(d.reason ?? 'not booked'); return }
    onDone()
  }
  const walkBox = (
    <div className="grid gap-2 sm:grid-cols-[1fr_auto]">
      <Input type="datetime-local" value={walkAt} onChange={(e) => setWalkAt(e.target.value)} aria-label="Day and time of Colin's walk" />
      <Button onClick={() => void bookWalk()}>Book Colin&apos;s walk</Button>
    </div>
  )
  const run = async (fn: string, args: Record<string, unknown>) => {
    setErr(null)
    const r = await supabase.rpc(fn, args)
    if (r.error) { setErr(r.error.message); return }
    const d = r.data as { ok?: boolean; reason?: string } | null
    if (d && d.ok === false) { setErr(d.reason ?? 'not saved'); return }
    onDone()
  }
  const comps = (p.comps ?? []) as { address?: string; price?: number; sold_price?: number; date?: string; sold_date?: string; sqft?: number; url?: string; note?: string }[]
  const say = 'rounded-md border-l-4 border-amber-400 bg-amber-50 p-2 dark:bg-amber-950/30'
  return (
    <div className="space-y-3 text-sm">
      <p className="text-muted-foreground">
        {STATUS[p.status]?.who}
        {p.callback_at ? ` · callback promised ${fmtDateTime(String(p.callback_at))}` : ''}
        {p.walk_booked_on_call ? ' · walk booked on the call' : ''}
        {p.hot ? ' · HOT' : ''}
      </p>
      <Summary p={p} />
      {p.arv != null && (
        <div className="rounded-lg bg-muted p-3">
          <p><span className="font-medium">Value (after repairs):</span> {money(p.arv)} <span className="text-muted-foreground">by {String(p.valued_by ?? 'Muse')}</span></p>
          {p.arv_basis != null && <p className="text-muted-foreground">{String(p.arv_basis)}</p>}
          {comps.length > 0 && (
            <ul className="mt-1 list-disc pl-5">
              {comps.slice(0, 8).map((c, i) => (
                <li key={i}>{c.url ? <a className="underline" href={c.url} target="_blank" rel="noreferrer">{c.address ?? 'comp'}</a> : c.address}
                  {' '}{money(c.sold_price ?? c.price)}{c.sold_date ?? c.date ? `, ${c.sold_date ?? c.date}` : ''}{c.sqft ? `, ${c.sqft} sf` : ''}{c.note ? ` (${c.note})` : ''}</li>
              ))}
            </ul>
          )}
        </div>
      )}
      {p.number_note != null && <p><span className="font-medium">Colin&apos;s note:</span> {String(p.number_note)}</p>}

      {isOwner && ['waiting_value', 'waiting_number', 'go_walk'].includes(p.status) && (
        <div className="space-y-2 rounded-lg border p-3">
          <p className="font-medium">{p.status === 'go_walk' ? 'You said walk it (change your mind?)' : 'Walk it or pass?'}</p>
          <div className="grid gap-2 sm:grid-cols-[7rem_1fr_auto_auto]">
            <Select value={grade} onChange={(e) => setGrade(e.target.value)} aria-label="Grade the package">
              <option value="">Grade</option><option value="A">A</option><option value="B">B</option><option value="C">C</option>
            </Select>
            <Input placeholder="Note for the caller (optional, never a number)" value={note} onChange={(e) => setNote(e.target.value)} />
            {p.status !== 'go_walk' && <Button onClick={() => void run('package_decide', { p_id: p.id, p_walk: true, p_note: note || null, p_grade: grade || null })}>Walk it</Button>}
            <Button variant="outline" onClick={() => void run('package_decide', { p_id: p.id, p_walk: false, p_note: note || null, p_grade: grade || null })}>Pass</Button>
          </div>
          <p className="text-xs text-muted-foreground">No number goes out on the phone. The caller books your walk with everyone on the title there, and you give your number at the house.</p>
        </div>
      )}

      {numberNotReady(p) && (
        <div className="space-y-2 rounded-lg border border-amber-400 p-3">
          <p className="font-medium">Callback {fmtDateTime(String(p.callback_at))}, and Colin hasn&apos;t decided yet</p>
          <p className="text-muted-foreground">Colin got a push. If he still hasn&apos;t decided at the time you promised, call anyway: never let a promised callback go quiet.</p>
          <blockquote className={say}>
            &quot;Hi, it&apos;s [your name]. I told you I&apos;d call today. My partner is still going over everything you told me. Can I call you back [day] at [time]?&quot;
          </blockquote>
          <div className="grid gap-2 sm:grid-cols-[1fr_auto]">
            <Input type="datetime-local" value={newCb} onChange={(e) => setNewCb(e.target.value)} aria-label="The new callback time" />
            <Button variant="outline" onClick={() => void run('package_move_callback', { p_id: p.id, p_at: localInputToIso(newCb) })}>Set the new callback</Button>
          </div>
        </div>
      )}

      {p.status === 'go_walk' && (
        <div className="space-y-2 rounded-lg border p-3">
          <p className="font-medium">The callback: book Colin&apos;s walk (no number on the phone)</p>
          <blockquote className={say}>
            &quot;Hi, it&apos;s [your name]. My partner and I went over everything you told me. {mentioned(p.condition)}, he&apos;d like to come see it himself. He only puts a number on a place once he&apos;s walked it, so it&apos;s a real number and not a guess.&quot;
          </blockquote>
          <p className="font-medium">Before the time, the yes-or-no question:</p>
          <blockquote className={say}>
            &quot;Before he comes out: if his number works for you, are you ready to give him a yes or a no that day? A no is completely fine.&quot;
          </blockquote>
          <p className="font-medium">A yes: book it.</p>
          <blockquote className={say}>
            &quot;When&apos;s a good time for him to come by? Will everyone on the title be there? It takes about 40 minutes.&quot;
          </blockquote>
          {walkBox}
          <p className="text-xs text-muted-foreground">If they push for a number: &quot;He doesn&apos;t guess over the phone. If it&apos;s not a fit when he&apos;s there, he&apos;ll tell you straight, and a no is fine too.&quot; Never a number, a range or a percentage.</p>
          <div className="grid gap-2 sm:grid-cols-[1fr_auto_auto]">
            <Input placeholder="What they said, their words" value={note} onChange={(e) => setNote(e.target.value)} />
            <Button variant="outline" onClick={() => void run('package_callback', { p_id: p.id, p_response: 'not_ready', p_note: note || null })}>Not ready to decide</Button>
            <Button variant="outline" onClick={() => void run('package_callback', { p_id: p.id, p_response: 'no', p_note: note || null })}>No</Button>
          </div>
          <p className="text-xs text-muted-foreground">Not ready: use the not-ready lines and log the call with a check-back date as usual.</p>
        </div>
      )}

      {!!p.hot && ['waiting_value', 'waiting_number'].includes(p.status) && !p.walk_booked_on_call && (
        <details className="rounded-lg border p-3">
          <summary className="cursor-pointer font-medium">Hot: book Colin&apos;s walk now instead of waiting for him</summary>
          <div className="mt-2">{walkBox}</div>
        </details>
      )}
      <div className="flex flex-wrap gap-2">
        <Button size="sm" variant="ghost" onClick={() => void run('package_close', { p_id: p.id, p_status: 'dead', p_note: 'closed from the card' })}>Close this package</Button>
      </div>
      {err && <p className="text-sm text-red-600">{err}</p>}
    </div>
  )
}

function SendPackage({ lead, last, onDone }: { lead: Lead; last: Pkg | null; onDone: () => void }) {
  const fromCall = packageFromCall((lead.call_facts ?? {}) as never, CALL_LABELS)
  const [openForm, setOpen] = useState(false)
  const [f, setF] = useState<Record<string, string>>(() => Object.fromEntries(Object.entries(fromCall.fields).filter(([, v]) => v)))
  const [cond, setCond] = useState<Record<string, string>>(fromCall.condition)
  const [hot, setHot] = useState(fromCall.hot)
  const [walk, setWalk] = useState(fromCall.walk)
  const [source, setSource] = useState('')
  const [interest, setInterest] = useState('')
  const [cb, setCb] = useState(isoToLocalInput(fromCall.callback ?? new Date(Date.now() + 24 * 3600_000).toISOString()))
  const [err, setErr] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const people = useQuery({ queryKey: ['card_interests', lead.id], enabled: openForm, queryFn: async () => {
    const r = await supabase.rpc('card_interests', { p_lead: lead.id })
    return ((r.data ?? []) as Person[]).filter((x) => x.status === 'active')
  } })
  const send = async () => {
    setBusy(true); setErr(null)
    const condition = Object.fromEntries(Object.entries(cond).filter(([, v]) => v.trim()))
    const r = await supabase.rpc('package_submit', { p: { lead_id: lead.id, interest_id: interest || null, source: source || null, hot,
      walk_booked_on_call: walk, callback_at: walk ? null : localInputToIso(cb), condition, ...f } })
    setBusy(false)
    if (r.error) { setErr(r.error.message); return }
    const d = r.data as { ok: boolean; reason?: string }
    if (!d.ok) { setErr(d.reason ?? 'not sent'); return }
    setOpen(false); setF({}); setCond({})
    onDone()
  }
  if (!openForm) {
    return (
      <div className="space-y-2 text-sm">
        {last && <p className="text-muted-foreground">Last package: {last.colin_call === 'pass' ? 'Colin passed' : STATUS[last.status]?.label ?? last.status}.</p>}
        {last?.colin_call === 'pass' && last.status === 'declined' && !last.delivered_at && (
          <blockquote className="rounded-md border-l-4 border-amber-400 bg-amber-50 p-2 dark:bg-amber-950/30">
            The promised callback, when Colin passed: &quot;Hi, it&apos;s [your name]. My partner and I went over everything, and we&apos;re not the right fit for this one right now. I didn&apos;t want to leave you waiting. If anything changes, keep this number.&quot; Then mark the callback Done.
          </blockquote>
        )}
        <p className="text-muted-foreground">After a good first call: everything you learned goes to Colin in one email. Never a number on the phone.{Object.values(fromCall.fields).some(Boolean) ? ' The answers you tapped in the call script are already filled in; check them and add the rest.' : ''}</p>
        <Button onClick={() => setOpen(true)}>Send package to Colin</Button>
      </div>
    )
  }
  return (
    <div className="space-y-3 text-sm">
      <div className="grid gap-2 sm:grid-cols-3">
        <Select value={interest} onChange={(e) => setInterest(e.target.value)} aria-label="Who you talked to">
          <option value="">Who you talked to</option>
          {(people.data ?? []).map((x) => <option key={x.interest_id} value={x.interest_id}>{x.name} ({x.role.replace(/_/g, ' ')})</option>)}
        </Select>
        <Select value={source} onChange={(e) => setSource(e.target.value)} aria-label="Where this lead came from">
          <option value="">Where it came from (auto)</option>
          <option value="hot_text">Hot lead from texting</option><option value="inbound">Inbound call</option><option value="cold_list">Cold call</option><option value="other">Other</option>
        </Select>
        <label className="flex items-center gap-2"><input type="checkbox" checked={hot} onChange={(e) => setHot(e.target.checked)} /> Hot (a need and a rough house; a need or a rough house inside 90 days; or a sale or move date)</label>
      </div>
      {FIELDS.map((x) => (
        <label key={x.key} className="block">
          <span className="font-medium">{x.label}</span>{x.hint && <span className="text-muted-foreground"> · {x.hint}</span>}
          {x.long
            ? <Textarea rows={2} value={f[x.key] ?? ''} onChange={(e) => setF({ ...f, [x.key]: e.target.value })} />
            : <Input value={f[x.key] ?? ''} onChange={(e) => setF({ ...f, [x.key]: e.target.value })} />}
        </label>
      ))}
      <fieldset className="space-y-2 rounded-lg border p-3">
        <legend className="px-1 font-medium">Condition checklist (their words; &quot;don&apos;t know&quot; is fine)</legend>
        {CONDITION_ITEMS.map((c) => (
          <label key={c.key} className="block">
            <span className="font-medium">{c.label}</span>{c.ask && <span className="text-muted-foreground"> · &quot;{c.ask}&quot;</span>}
            <Input value={cond[c.key] ?? ''} onChange={(e) => setCond({ ...cond, [c.key]: e.target.value })} />
          </label>
        ))}
      </fieldset>
      <div className="grid gap-2 sm:grid-cols-[auto_1fr] sm:items-center">
        <label className="flex items-center gap-2"><input type="checkbox" checked={walk} onChange={(e) => setWalk(e.target.checked)} /> Walk booked on this call (hot)</label>
        {!walk && (
          <label className="grid min-w-0 gap-1 sm:flex sm:items-center sm:gap-2"><span className="whitespace-nowrap">Callback promised</span>
            <Input className="min-w-0" type="datetime-local" value={cb} onChange={(e) => setCb(e.target.value)} /></label>
        )}
      </div>
      <div className="flex gap-2">
        <Button disabled={busy} onClick={() => void send()}>Send to Colin</Button>
        <Button variant="ghost" onClick={() => setOpen(false)}>Cancel</Button>
      </div>
      {err && <p className="text-sm text-red-600">{err}</p>}
    </div>
  )
}

type OpenRow = { package: Pkg; lead: { id: string; owner_name: string | null; property_address: string | null; municipality: string | null }; person: string | null; late: string | null }

/** Today: the packages that are someone's turn. Colin prices the same day; the caller calls back at the time promised. */
export function PackagesToday() {
  const { isOwner } = useAuth()
  const q = useQuery({ queryKey: ['packages_open'], refetchInterval: 120_000, queryFn: async () => {
    const r = await supabase.rpc('packages_open')
    if (r.error) throw new Error(r.error.message)
    return (r.data ?? []) as OpenRow[]
  } })
  const rows = (q.data ?? []).filter((x) => isOwner ? ['waiting_value', 'waiting_number'].includes(x.package.status)
    : x.package.status === 'go_walk' || numberNotReady(x.package))
  if (!q.data || rows.length === 0) return null
  return (
    <Section title={`${isOwner ? 'Packages: walk it or pass' : 'Callbacks: book Colin\u2019s walk'} (${rows.length})`}>
      <ErrorNote error={q.error} />
      <ul className="divide-y text-sm">
        {rows.map((x) => (
          <li key={x.package.id} className="flex flex-wrap items-center gap-2 py-2">
            <a className="font-medium underline" href={`/lead/${x.lead.id}#package`}>{x.person || x.lead.owner_name}, {x.lead.property_address}</a>
            <Badge tone={STATUS[x.package.status]?.tone ?? 'muted'}>{STATUS[x.package.status]?.label}</Badge>
            {x.package.hot ? <Badge tone="bad">HOT</Badge> : null}
            {x.package.callback_at ? <span className="text-muted-foreground">callback {fmtDateTime(String(x.package.callback_at))}</span> : null}
            {x.late && <Badge tone="bad">{x.late}</Badge>}
            {numberNotReady(x.package) && <Badge tone="warn">callback soon, Colin hasn&apos;t decided</Badge>}
          </li>
        ))}
      </ul>
    </Section>
  )
}

type FunnelRow = { week: string; source: string; calls: number; reached: number; packages: number; hot: number; valued: number; priced: number
  delivered: number; agreed: number; walks: number; grades: { A: number; B: number; C: number } }
const SOURCE_LABEL: Record<string, string> = { hot_text: 'Hot text', inbound: 'Inbound', cold_list: 'Cold call', other: 'Other' }

/** The Scoreboard funnel by list (Colin: "8 should be done somehow"): calls to walks, per week and source. */
export function DealsFunnel() {
  const q = useQuery({ queryKey: ['deals_funnel'], queryFn: async () => {
    const r = await supabase.rpc('deals_funnel', { p_weeks: 6 })
    if (r.error) throw new Error(r.error.message)
    return (r.data ?? []) as FunnelRow[]
  } })
  const rows = (q.data ?? []).filter((x) => x.calls || x.packages)
  return (
    <Section title="Deals funnel by list">
      <p className="mb-2 text-sm text-muted-foreground">Calls, then packages, Colin&apos;s walk-it calls, the callback and the walk, per week and by where the lead came from. Grades are Colin&apos;s A/B/C when he decides.</p>
      <ErrorNote error={q.error} />
      {rows.length === 0 ? <p className="text-sm text-muted-foreground">No calls or packages yet.</p> : (
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead><tr className="text-left text-muted-foreground">
              {['Week', 'List', 'Calls', 'Reached', 'Packages', 'Hot', 'Valued', 'Walk it', 'Called back', 'Yes', 'Walks', 'A/B/C'].map((h) => <th key={h} className="px-2 py-1 font-medium">{h}</th>)}
            </tr></thead>
            <tbody>
              {rows.map((x) => (
                <tr key={`${x.week}-${x.source}`} className="border-t">
                  <td className="px-2 py-1">{x.week}</td><td className="px-2 py-1">{SOURCE_LABEL[x.source] ?? x.source}</td>
                  <td className="px-2 py-1">{x.calls}</td><td className="px-2 py-1">{x.reached}</td><td className="px-2 py-1">{x.packages}</td>
                  <td className="px-2 py-1">{x.hot}</td><td className="px-2 py-1">{x.valued}</td><td className="px-2 py-1">{x.priced}</td>
                  <td className="px-2 py-1">{x.delivered}</td><td className="px-2 py-1">{x.agreed}</td><td className="px-2 py-1">{x.walks}</td>
                  <td className="px-2 py-1">{x.grades.A}/{x.grades.B}/{x.grades.C}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </Section>
  )
}
