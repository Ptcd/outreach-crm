// The deal sheet (0270; Colin 2026-11-21: "how can this be designed so thalia and Tyler, people from overseas with no
// knowledge of our local market, can capture insane value on properties without becoming specialists"). One call
// (deal_sheet_get) gives the seller's own arithmetic, the number to say and the steps a caller may go up. The caller
// asks five things in order, taps what the seller said, and says one number at a time. The server works every figure;
// nothing is calculated here. Colin sees the ceiling, the gate and his own controls; a caller never does.
// It ships for Colin only (mode 'owner'); a caller's login gets null and this renders nothing.
import { useState } from 'react'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Badge, ErrorNote, Textarea } from '@/components/ui/form'
import { supabase } from '@/lib/supabaseClient'
import { useAuth } from '@/providers/AuthProvider'
import { cn } from '@/lib/utils'

type Row = { i: number; inside: string; repairs: number | null; basis: string | null; no_offer: boolean }
type Owed = { kind?: string; creditor?: string | null; amount?: number | null; basis?: string | null; follows_house?: string; note?: string | null }
type SaidEvent = { at: string; by: string | null; number: number; response: string; words: string | null; counter: number | null }
export type Sheet = {
  lead_id: string; mode: 'off' | 'owner' | 'on'; owner: boolean
  stage: 'ready' | 'needs_value' | 'needs_owed' | 'colin_prices' | 'no_fit' | 'no_number' | 'passed'
  kind: 'nothing_left' | 'some_left' | 'a_lot' | null; why: string | null; source: 'math' | 'colin' | 'their_floor' | 'agent'
  missing: { what: string; who: string }[]; property_kind: string; gate?: string[]
  math: { finished: number | null; needs: number | null; needs_for: string | null; needs_assumed: boolean; selling_costs: number | null
    to_clear: number; other_owed: number; walk_away: number | null; owed_known: boolean; open_owed: Owed[]; cost_words: string }
  rows: Row[]; inside: number | null; comps: { address: string; sold_price: number; sold_date: string | null }[]; sold_comps: number
  owed: Owed[]; brief_ready: boolean; number: number | null; steps: number[]; limit: number | null
  ceiling?: number | null; rule_opening?: number | null; gap?: number | null
  theirs: { number: number | null; floor: number | null; owed_said: number | null }
  facts: Record<string, unknown>; said: SaidEvent[]
  colin: { open: number | null; top: number | null; note: string | null; pass: boolean; at: string | null; asked_at: string | null; asked_words: string | null }
  owner_name: string | null; address: string | null; caller: string | null
}

export const usd = (n: number | null | undefined) => (n == null ? '?' : `${n < 0 ? '-' : ''}$${Math.abs(Math.round(n)).toLocaleString('en-US')}`)
const num = (s: string) => { const v = Number(s.replace(/[^0-9.]/g, '')); return Number.isFinite(v) && v > 0 ? v : null }
const month = (d: string | null) => {
  if (!d) return ''
  const t = new Date(`${d.slice(0, 10)}T12:00:00`)
  return Number.isNaN(t.getTime()) ? '' : t.toLocaleString('en-US', { month: 'long', year: 'numeric' })
}
const SOURCES = ['a realtor', 'Zillow or a website', 'an appraisal', 'what I paid or put in', 'an offer I turned down', 'a listing that did not sell',
  'a neighbour’s sale', 'what I owe', 'no source, a feeling']
const DECIDES: [string, string][] = [['alone', 'Just them'], ['on_line', 'Someone else, on the line'], ['absent', 'Someone else, not here']]

/** What the seller said back to a number, and the reply that held in 73 recorded calls (research/acquisition-system/findings/five-moves.md). */
export const PUSHBACKS: { id: string; they: string; say: string; response: string }[] = [
  { id: 'counter', response: 'counter', they: 'They name a number of their own',
    say: 'Write it down. "What is that number for?" If it is at or under the next step, say "I can do that." If not, the next step, once, with one reason.' },
  { id: 'low', response: 'no', they: '"That’s too low" / "that’s insulting"',
    say: 'Do not defend the number. "I hear you. What would you need it to be, and what is that for?" Write down the figure and the reason.' },
  { id: 'think', response: 'think', they: '"I need to think about it"',
    say: '"Of course. Which part: the number, or something else?" Then a day and a time for the next call, on the card before you hang up.' },
  { id: 'spouse', response: 'spouse', they: '"I have to ask my wife / husband / sister"',
    say: 'No more price talk. "That makes sense. When are you both free? I’ll call then." Book it with both on the line.' },
  { id: 'offer', response: 'other_offer', they: '"Someone offered more"',
    say: '"Was that in writing? Did they see the place? What stopped you taking it?" If it is real and higher: "Then you should take it. If it falls through, call me." Never go lower.' },
  { id: 'zillow', response: 'no', they: '"Zillow / the realtor / the appraisal says more"',
    say: '"That figure is for a finished house. It has not seen the roof or the furnace you told me about." Then their own list of what it needs, and the arithmetic again.' },
  { id: 'nosell', response: 'no', they: '"I don’t have to sell"',
    say: 'No number. "That’s fine. When would be a better time to check back?" A date on the card.' },
  { id: 'scam', response: 'think', they: '"Who are you? Is this a scam?"',
    say: 'The plain truth. "We buy houses here ourselves. A title company handles the closing: you sign there and they pay you there. You pay nothing."' },
]

function useSheet(leadId: string) {
  return useQuery({
    queryKey: ['deal_sheet', leadId],
    retry: false,
    queryFn: async () => {
      const r = await supabase.rpc('deal_sheet_get', { p_lead_id: leadId })
      if (r.error) throw new Error(r.error.message)
      return (r.data ?? null) as Sheet | null
    },
  })
}

const chip = (on: boolean) => cn('min-h-9 rounded-md border px-2.5 text-xs font-medium hover:bg-accent', on && 'border-primary bg-primary/10')

function Step({ n, title, children }: { n: number; title: string; children: React.ReactNode }) {
  return (
    <li className="rounded-md border p-3">
      <p className="text-sm font-semibold"><span className="mr-2 inline-flex h-5 w-5 items-center justify-center rounded-full bg-primary text-[11px] text-primary-foreground">{n}</span>{title}</p>
      <div className="mt-2 space-y-2 text-sm">{children}</div>
    </li>
  )
}
const Say = ({ children }: { children: React.ReactNode }) => <p className="rounded bg-muted px-2 py-1.5 text-sm"><span className="mr-1 text-xs font-semibold uppercase text-muted-foreground">Say</span>{children}</p>

export function DealSheet({ leadId }: { leadId: string }) {
  const { isOwner } = useAuth()
  const qc = useQueryClient()
  const q = useSheet(leadId)
  const [err, setErr] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [theirs, setTheirs] = useState(''); const [owed, setOwed] = useState(''); const [floor, setFloor] = useState('')
  const [counter, setCounter] = useState(''); const [words, setWords] = useState(''); const [ask, setAsk] = useState('')
  const [open, setOpen] = useState<string | null>(null)
  const [cOpen, setCOpen] = useState(''); const [cTop, setCTop] = useState(''); const [cNote, setCNote] = useState('')
  const s = q.data
  if (!s) return null                                   // not switched on for this login, no such card, or it could not be read

  const run = async (fn: string, args: Record<string, unknown>) => {
    setBusy(true); setErr(null)
    try {
      const r = await supabase.rpc(fn, { p_lead_id: leadId, ...args })
      if (r.error) throw new Error(r.error.message)
      const d = r.data as { ok?: boolean; reason?: string; sheet?: Sheet | null } | null
      if (d && d.ok === false) { setErr(d.reason ?? 'That did not save.'); return false }
      if (d?.sheet) qc.setQueryData(['deal_sheet', leadId], d.sheet); else void qc.invalidateQueries({ queryKey: ['deal_sheet', leadId] })
      for (const k of [['card_brief', leadId], ['lead', leadId], ['tasks'], ['my_nudges']]) void qc.invalidateQueries({ queryKey: k })
      return true
    } catch (e) { setErr(e instanceof Error ? e.message : String(e)); return false } finally { setBusy(false) }
  }
  const fact = (key: string, value: unknown) => run('deal_sheet_fact', { p_key: key, p_value: value })
  const f = s.facts as Record<string, string | number | boolean | undefined>
  const lastSaid = s.said.length ? s.said[s.said.length - 1] : null
  const agreed = lastSaid?.response === 'yes' ? lastSaid.number : null
  // one number at a time: the first, then the next step up only after one has been said and turned down
  const current = s.steps.length === 0 ? null : lastSaid && s.steps.includes(lastSaid.number) && lastSaid.response !== 'yes'
    ? (s.steps.find((x) => x > lastSaid.number) ?? null) : (lastSaid ? null : s.steps[0])
  const atLimit = !!lastSaid && lastSaid.response !== 'yes' && current === null
  const absent = f.decides === 'absent'
  const m = s.math
  const comp = s.comps[0]
  const record = async (response: string) => {
    if (current == null) return
    const ok = await run('deal_sheet_said', { p_number: current, p_response: response, p_words: words || null, p_counter: response === 'counter' ? num(counter) : null })
    if (ok) { setWords(''); setCounter(''); setOpen(null) }
  }

  return (
    <section className="rounded-lg border bg-card p-4" aria-label="Deal sheet">
      <div className="flex flex-wrap items-center gap-2">
        <h2 className="text-base font-semibold">Deal sheet</h2>
        {s.owner && s.mode !== 'on' && <Badge tone="warn">Only you see this</Badge>}
        {s.source === 'colin' && <Badge tone="info">Colin&apos;s number</Badge>}
        {s.source === 'agent' && <Badge tone="info">{(s as unknown as { agent?: { by?: string } }).agent?.by ?? 'An agent'}&apos;s number</Badge>}
        {s.kind === 'nothing_left' && <Badge tone="good">The price cannot reach them</Badge>}
        {s.kind === 'some_left' && <Badge>Something left for them</Badge>}
        {s.kind === 'a_lot' && <Badge tone="warn">They keep the difference</Badge>}
      </div>

      {s.stage !== 'ready' && (
        <div className="mt-2 rounded-md border border-amber-300 bg-amber-50 p-2 text-sm dark:bg-amber-950/30">
          {s.stage === 'needs_value' && <p><strong>No number yet.</strong> Waiting on Muse: {s.missing[0]?.what}. Call for the story and their number, and give none.</p>}
          {s.stage === 'needs_owed' && <p><strong>No number yet.</strong> Ask what is owed (step 3), then tap their answer. The number comes from it.</p>}
          {s.stage === 'colin_prices' && <p><strong>Colin prices this one.</strong> {s.why} Give no number. Use &quot;Ask Colin&quot; below if they want one now.</p>}
          {s.stage === 'no_fit' && <p><strong>No number.</strong> {s.why}</p>}
          {s.stage === 'no_number' && <p><strong>No number from us.</strong> {s.why}</p>}
          {s.stage === 'passed' && <p><strong>Colin passed.</strong> {s.why} Close it kindly.</p>}
        </div>
      )}

      <ol className="mt-3 space-y-2">
        <Step n={1} title="Their number, and where it came from">
          <Say>&quot;What do you need to get out of the place to move on?&quot; Then: &quot;How did you come up with that number?&quot; Then be quiet.</Say>
          <div className="flex flex-wrap items-center gap-2">
            <Input className="h-9 w-36" inputMode="numeric" placeholder={s.theirs.number ? usd(s.theirs.number) : 'Their number'} value={theirs} onChange={(e) => setTheirs(e.target.value)} aria-label="Their number" />
            <Button size="sm" variant="outline" disabled={busy || !num(theirs)} onClick={async () => { if (await fact('their_number', num(theirs))) setTheirs('') }}>Save</Button>
            {s.theirs.number != null && <span className="text-xs text-muted-foreground">On the card: {usd(s.theirs.number)}</span>}
          </div>
          <div className="flex flex-wrap gap-1.5" role="group" aria-label="Where their number came from">
            {SOURCES.map((x) => <button key={x} type="button" className={chip(f.their_source === x)} disabled={busy} onClick={() => fact('their_source', f.their_source === x ? null : x)}>{x}</button>)}
          </div>
          <p className="text-xs font-semibold uppercase text-muted-foreground">Who decides</p>
          <Say>&quot;Is it just you on the title, or does someone else have to say yes too?&quot;</Say>
          <div className="flex flex-wrap gap-1.5" role="group" aria-label="Who decides">
            {DECIDES.map(([id, label]) => <button key={id} type="button" className={chip(f.decides === id)} disabled={busy} onClick={() => fact('decides', f.decides === id ? null : id)}>{label}</button>)}
          </div>
          {absent && <p className="rounded border border-amber-300 bg-amber-50 p-2 text-sm dark:bg-amber-950/30"><strong>No number today.</strong> &quot;When are you both free? I&apos;ll call then.&quot; Book the call with both on the line.</p>}
        </Step>

        <Step n={2} title="The finished price, kindly">
          <Say>&quot;If it were all fixed up and ready to show, what do you think it would sell for? And what would it need to get there?&quot; Let them list it.</Say>
          {m.finished != null && (
            <Say>&quot;That matches what I&apos;m seeing. Finished, houses like it are selling around {usd(m.finished)}.{comp ? ` ${comp.address} sold for ${usd(comp.sold_price)}${month(comp.sold_date) ? ` in ${month(comp.sold_date)}` : ''}.` : ''} The figure you were given is for a finished house.&quot;</Say>
          )}
          {s.comps.length > 1 && <p className="text-xs text-muted-foreground">Other sales you can name: {s.comps.slice(1).map((c) => `${c.address}, ${usd(c.sold_price)}${month(c.sold_date) ? `, ${month(c.sold_date)}` : ''}`).join(' · ')}</p>}
          {s.rows.length > 0 && (
            <>
              <p className="text-xs font-semibold uppercase text-muted-foreground">From what they said, the inside is</p>
              <div className="flex flex-wrap gap-1.5" role="group" aria-label="The shape of the inside">
                {s.rows.map((r) => <button key={r.i} type="button" disabled={busy} className={chip(!m.needs_assumed && s.inside === r.i)} onClick={() => run('deal_sheet_inside', { p_row: r.i })}>{r.inside} · {usd(r.repairs)}</button>)}
              </div>
              {m.needs_assumed && <p className="text-xs text-muted-foreground">Not picked yet: the sheet assumes the heaviest ({m.needs_for}).</p>}
            </>
          )}
        </Step>

        <Step n={3} title="What is owed, asked first">
          <Say>&quot;If it sold for that, after everything is paid off, what would you walk away with? Is there a mortgage, taxes, anything else that comes out at closing?&quot;</Say>
          <div className="flex flex-wrap items-center gap-2">
            <Input className="h-9 w-40" inputMode="numeric" placeholder={s.theirs.owed_said ? usd(s.theirs.owed_said) : 'What they say is owed'} value={owed} onChange={(e) => setOwed(e.target.value)} aria-label="What they say is owed" />
            <Button size="sm" variant="outline" disabled={busy || !num(owed)} onClick={async () => { if (await fact('owed_said', num(owed))) setOwed('') }}>Save</Button>
            <button type="button" className={chip(f.owed_nothing === true)} disabled={busy} onClick={() => fact('owed_nothing', f.owed_nothing === true ? null : true)}>They owe nothing</button>
          </div>
          {m.open_owed.length > 0 && <p className="text-xs text-muted-foreground">Not known yet: {m.open_owed.map((o) => o.kind ?? 'a debt').join(', ')}. Their answer fills it.</p>}
        </Step>

        <Step n={4} title="What the records show, added after">
          {s.owed.length === 0 ? <p className="text-muted-foreground">Nothing in the records yet beyond what they tell you.</p> : (
            <>
              <p className="text-xs text-muted-foreground">Only after they have answered step 3, never as the reason for the call. Plainly: &quot;The records also show...&quot;</p>
              <ul className="space-y-1">
                {s.owed.map((o, i) => (
                  <li key={i} className="rounded border px-2 py-1 text-sm">
                    <span className="font-medium">{o.creditor || o.kind || 'A debt'}</span>{' '}
                    {o.amount != null ? usd(Number(o.amount)) : <span className="text-muted-foreground">amount not known: do not name a figure</span>}
                    {o.follows_house === 'yes' && <Badge className="ml-2" tone="info">paid at closing</Badge>}
                    {o.follows_house === 'no' && <Badge className="ml-2">a claim on what is left</Badge>}
                    {o.basis && <span className="block text-xs text-muted-foreground">{o.basis}</span>}
                  </li>
                ))}
              </ul>
            </>
          )}
        </Step>

        <Step n={5} title="The plain conclusion, then the way out">
          {m.finished == null || m.needs == null ? <p className="text-muted-foreground">The arithmetic needs Muse&apos;s value first.</p> : (
            <table className="w-full text-sm" aria-label="The seller's math">
              <tbody>
                <tr><td>What it sells for finished</td><td className="text-right tabular-nums">{usd(m.finished)}</td></tr>
                <tr><td>What it needs ({m.needs_for})</td><td className="text-right tabular-nums">- {usd(m.needs)}</td></tr>
                <tr><td>What selling it costs <span className="text-xs text-muted-foreground">({m.cost_words})</span></td><td className="text-right tabular-nums">- {usd(m.selling_costs)}</td></tr>
                <tr><td>Owed, paid at closing{!m.owed_known && <span className="text-xs text-amber-700"> (not confirmed)</span>}</td><td className="text-right tabular-nums">- {usd(m.to_clear)}</td></tr>
                {m.other_owed > 0 && <tr><td>Other claims on what is left</td><td className="text-right tabular-nums">- {usd(m.other_owed)}</td></tr>}
                <tr className="border-t font-semibold"><td>What they would walk away with</td><td className="text-right tabular-nums">{m.walk_away != null && m.walk_away <= 0 ? 'Nothing' : usd(m.walk_away)}</td></tr>
              </tbody>
            </table>
          )}
          {s.kind === 'nothing_left' && <Say>&quot;I&apos;ll be straight with you. If you don&apos;t want to keep the place, I don&apos;t see how selling it puts money in your pocket. If you&apos;d rather just be done with it, we&apos;ll buy it as it sits: no repairs, no showings, we clear it out, and it closes at a title company.&quot;</Say>}
          {s.kind === 'some_left' && <Say>&quot;Selling it the usual way, after the work, the agent and the months it takes, you&apos;d clear about {usd(m.walk_away)}. We can have it done in a few weeks, as it sits, with nothing for you to fix or clean out.&quot;</Say>}
          {(s.kind === 'a_lot' || s.stage === 'no_number') && (
            <>
              <Say>&quot;Honestly, an agent may do better for you than I can. Is there a number you would not go under, if it were done in a few weeks with no repairs?&quot;</Say>
              <div className="flex flex-wrap items-center gap-2">
                <Input className="h-9 w-40" inputMode="numeric" placeholder={s.theirs.floor ? usd(s.theirs.floor) : 'Their floor'} value={floor} onChange={(e) => setFloor(e.target.value)} aria-label="The number they would not go under" />
                <Button size="sm" variant="outline" disabled={busy || !num(floor)} onClick={async () => { if (await fact('floor', num(floor))) setFloor('') }}>Save</Button>
              </div>
            </>
          )}
        </Step>
      </ol>

      {s.stage === 'ready' && !absent && (
        <div className="mt-3 rounded-md border-2 border-primary p-3">
          {agreed != null ? (
            <>
              <p className="text-lg font-bold">They said yes to {usd(agreed)}.</p>
              <Say>&quot;Then let&apos;s put it in writing now. Open your email, the agreement is on its way. I&apos;ll stay on the line.&quot;</Say>
              <p className="text-sm text-muted-foreground">Send offer is below, at {usd(agreed)}. Stay on the call until it comes back signed.</p>
            </>
          ) : current != null ? (
            <>
              <p className="text-xs font-semibold uppercase text-muted-foreground">{lastSaid ? 'Next step, once' : 'Say this, once'}</p>
              <p className="text-3xl font-bold tabular-nums" aria-label="The number to say">{usd(current)}</p>
              <p className="text-sm">{s.why ? `${s.why}. ` : ''}One number, one reason, then <strong>wait. Count to five.</strong> Do not explain it, do not give a range, do not say you might go higher.</p>
              <p className="mt-2 text-xs font-semibold uppercase text-muted-foreground">What came back</p>
              <div className="mt-1 flex flex-wrap gap-1.5">
                <Button size="sm" disabled={busy} onClick={() => record('yes')}>They said yes</Button>
                {PUSHBACKS.map((p) => <button key={p.id} type="button" className={chip(open === p.id)} onClick={() => setOpen(open === p.id ? null : p.id)}>{p.they}</button>)}
              </div>
              {open && (() => {
                const p = PUSHBACKS.find((x) => x.id === open)!
                return (
                  <div className="mt-2 space-y-2 rounded border p-2">
                    <Say>{p.say}</Say>
                    {p.response === 'counter' && <Input className="h-9 w-40" inputMode="numeric" placeholder="Their number" value={counter} onChange={(e) => setCounter(e.target.value)} aria-label="The number they named" />}
                    <Textarea rows={2} placeholder="What they said, in their words" value={words} onChange={(e) => setWords(e.target.value)} aria-label="What they said" />
                    <Button size="sm" variant="outline" disabled={busy || (p.response === 'counter' && !num(counter))} onClick={() => record(p.response)}>Save what they said</Button>
                  </div>
                )
              })()}
            </>
          ) : (
            <p className="text-sm"><strong>{atLimit ? 'That was the last step.' : 'No further number.'}</strong> Anything more is Colin&apos;s: &quot;Let me get my partner on that.&quot;</p>
          )}
        </div>
      )}

      {(atLimit || s.stage === 'colin_prices' || s.stage === 'no_fit' || s.stage === 'no_number') && !s.owner && (
        <div className="mt-3 space-y-2 rounded-md border p-3">
          <p className="text-sm font-semibold">Ask Colin</p>
          {s.colin.asked_at ? <p className="text-sm text-muted-foreground">Asked: &quot;{s.colin.asked_words}&quot;. His answer comes to your phone and lands here.</p> : (
            <>
              <Textarea rows={2} placeholder="Their number, why, and when you are calling them back" value={ask} onChange={(e) => setAsk(e.target.value)} aria-label="What to ask Colin" />
              <Button size="sm" disabled={busy || !ask.trim()} onClick={async () => { if (await run('deal_sheet_ask_colin', { p_words: ask })) setAsk('') }}>Send to Colin</Button>
            </>
          )}
        </div>
      )}

      {s.said.length > 0 && (
        <ul className="mt-3 space-y-0.5 text-xs text-muted-foreground" aria-label="Numbers said">
          {s.said.map((e, i) => <li key={i}>{usd(e.number)} said{e.by ? ` by ${e.by === 'adil' ? 'Tyler' : e.by}` : ''}: {e.response.replace('_', ' ')}{e.counter ? `, they need ${usd(e.counter)}` : ''}{e.words ? `. "${e.words}"` : ''}</li>)}
        </ul>
      )}

      {s.owner && isOwner && (
        <div className="mt-3 space-y-2 rounded-md border border-dashed p-3 text-sm">
          <p className="font-semibold">Yours only</p>
          <p>The most we can pay: <strong>{usd(s.ceiling)}</strong> · the rule&apos;s opening: {usd(s.rule_opening)}{s.gap != null && <> · room under the ceiling at the number: <strong>{usd(s.gap)}</strong></>}{s.limit != null && <> · a caller&apos;s limit: {usd(s.limit)}</>}</p>
          {(s.gate?.length ?? 0) > 0 && <p className="text-amber-700">Why there is no formula number: {s.gate!.join('; ')}.</p>}
          {s.colin.asked_at && <p className="rounded bg-amber-50 p-2 dark:bg-amber-950/30"><strong>{s.caller === 'adil' ? 'Tyler' : s.caller ?? 'A caller'} asks:</strong> {s.colin.asked_words}</p>}
          <div className="flex flex-wrap items-end gap-2">
            <label className="text-xs">Your number<Input className="h-9 w-32" inputMode="numeric" placeholder={s.colin.open ? usd(s.colin.open) : 'Open at'} value={cOpen} onChange={(e) => setCOpen(e.target.value)} aria-label="Colin's number" /></label>
            <label className="text-xs">The most<Input className="h-9 w-32" inputMode="numeric" placeholder={s.colin.top ? usd(s.colin.top) : 'Top'} value={cTop} onChange={(e) => setCTop(e.target.value)} aria-label="Colin's top" /></label>
            <label className="grow text-xs">The reason the caller says<Input className="h-9" placeholder={s.colin.note ?? 'roof, furnace, taxes that come out at closing'} value={cNote} onChange={(e) => setCNote(e.target.value)} aria-label="The reason" /></label>
          </div>
          <div className="flex flex-wrap gap-2">
            <Button size="sm" disabled={busy || !num(cOpen)} onClick={async () => { if (await run('deal_sheet_colin', { p_open: num(cOpen), p_top: num(cTop), p_note: cNote || null, p_pass: false })) { setCOpen(''); setCTop(''); setCNote('') } }}>Set my number</Button>
            <Button size="sm" variant="outline" disabled={busy} onClick={() => run('deal_sheet_colin', { p_open: null, p_top: null, p_note: cNote || null, p_pass: true })}>Pass</Button>
            {(s.colin.open != null || s.colin.pass) && <Button size="sm" variant="ghost" disabled={busy} onClick={() => run('deal_sheet_colin', { p_open: null, p_top: null, p_note: null, p_pass: false })}>Back to the sheet&apos;s own number</Button>}
          </div>
          <div className="flex flex-wrap items-center gap-1.5 pt-1" role="group" aria-label="Who sees the deal sheet">
            <span className="text-xs text-muted-foreground">Who sees the deal sheet:</span>
            {([['off', 'Nobody'], ['owner', 'Only me'], ['on', 'The callers too']] as const).map(([id, label]) => (
              <button key={id} type="button" className={chip(s.mode === id)} disabled={busy} onClick={async () => {
                setBusy(true); setErr(null)
                const r = await supabase.rpc('deal_sheet_mode', { p_mode: id })
                setBusy(false)
                if (r.error) setErr(r.error.message); else void qc.invalidateQueries({ queryKey: ['deal_sheet'] })
              }}>{label}</button>
            ))}
          </div>
        </div>
      )}
      {err && <div className="mt-2"><ErrorNote error={err} /></div>}
    </section>
  )
}
