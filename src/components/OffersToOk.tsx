// Offers by text waiting for Colin (Colin 2026-11-13: "Muse needs to check with me first"). Muse does the comp and the
// one condition question; the server works the number by the rule (65% of the value fixed up, minus repairs; the most
// at 70%) and puts it here. Nothing with a dollar figure leaves until Colin OKs that figure; a counter comes back
// here too. A seller's yes shows here as "send the written offer", which is Colin's from the card.
import { useState } from 'react'
import { Link } from 'react-router-dom'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Badge, Empty, ErrorNote, Section } from '@/components/ui/form'
import { supabase } from '@/lib/supabaseClient'
import { fmtDateTime } from '@/lib/format'

type Comp = { address?: string; sold_price?: number | string; sold_date?: string; sqft?: number | string; distance?: string | number; note?: string; url?: string }
type Offer = {
  offer_id: string; lead_id: string; owner_name: string | null; address: string | null; city: string | null; county: string | null
  opened_at: string; opened_by: string; their_words_that_opened_it: string | null
  next: { step: string; who: string | null; due_at: string | null; late: boolean; gate: string | null; say: string }
  seller: { need: string | null; their_number: number | null; their_words: string | null; flexible: string; timeline: string | null; signers: string | null
    seller_email: string | null; occupancy: string | null; condition_words: string | null; repair_items: string[]; repair_level: string | null }
  comp: { arv: number | null; basis: string | null; sold_comps: number; sqft: number | null }
  numbers: { repairs: number | null; repairs_basis: string | null; offer: number | null; most: number | null; wholesale: number | null
    asked_of_colin: number | null; ok_number: number | null }
  answer: { response: string | null; words: string | null; counter: number | null; accepted: number | null }
  comps: Comp[]; ask_kind: string | null; ask_note: string | null
  records: { tier: string | null; why: string | null; equity: string | null; equity_line: string | null } | null
}

const usd = (n: number | string | null | undefined) => (n === null || n === undefined || n === '' ? '?' : `$${Math.round(Number(n)).toLocaleString('en-US')}`)
const STEP: Record<string, string> = {
  ask_condition: 'Muse asks about the condition', comp: 'Muse comps it', wait_condition: 'waiting on the seller (condition)', read_condition: 'Muse reads the condition',
  retail: 'retail: Muse closes it', stop: 'the records say no: Muse closes it', passed: 'you passed: Muse closes it', answer_colin: 'Muse answers your question',
  ask_colin: 'coming to you', send_number: 'Muse texts the number', wait_reply: 'waiting on the seller (the number)', read_reply: 'Muse reads their answer',
  signing_details: 'Muse asks who signs', signing: 'out for signature', caller_has_it: 'a caller has the thread', close: 'Muse closes it',
}

export function OffersToOk() {
  const qc = useQueryClient()
  const q = useQuery({ queryKey: ['text_offers'], refetchInterval: 60_000, queryFn: async () => {
    const r = await supabase.rpc('text_offers_for_colin')
    if (r.error) throw new Error(r.error.message)
    return (r.data ?? []) as Offer[]
  } })
  const all = q.data ?? []
  const mine = all.filter((o) => o.next.who === 'colin')
  const rest = all.filter((o) => o.next.who !== 'colin')
  const done = () => void qc.invalidateQueries({ queryKey: ['text_offers'] })
  return (
    <Section title={`Offers by text${q.data ? ` (${mine.length} for you, ${rest.length} moving)` : ''}`}>
      <p className="mb-3 text-sm text-muted-foreground">
        A seller asked for a number. Muse comps it and asks about the condition; the number is 65% of the value fixed up, minus repairs. No figure is texted until you OK it here.
      </p>
      <ErrorNote error={q.error} />
      {q.data && mine.length === 0 && <Empty>Nothing waiting for you.</Empty>}
      <div className="space-y-4">
        {mine.map((o) => (o.next.step === 'written_offer' ? <YesCard key={o.offer_id} o={o} /> : <AskCard key={o.offer_id} o={o} onDone={done} />))}
      </div>
      {rest.length > 0 && (
        <ul className="mt-4 divide-y text-sm">
          {rest.map((o) => (
            <li key={o.offer_id} className="flex flex-wrap items-center gap-x-2 gap-y-1 py-2">
              <Link to={`/lead/${o.lead_id}`} className="font-medium underline">{o.address ?? 'a card'}</Link>
              <span className="text-muted-foreground">{STEP[o.next.step] ?? o.next.step}</span>
              {o.next.due_at && o.next.who === 'muse' && <span className="text-xs text-muted-foreground">by {fmtDateTime(o.next.due_at)}</span>}
              {o.next.late && <Badge tone="bad">late</Badge>}
              {o.numbers.ok_number !== null && <Badge tone="good">you OK&apos;d {usd(o.numbers.ok_number)}</Badge>}
            </li>
          ))}
        </ul>
      )}
    </Section>
  )
}

function Line({ k, children }: { k: string; children: React.ReactNode }) {
  return <p className="text-sm"><span className="text-muted-foreground">{k}: </span>{children}</p>
}

function AskCard({ o, onDone }: { o: Offer; onDone: () => void }) {
  const [num, setNum] = useState(String(o.numbers.asked_of_colin ?? ''))
  const [note, setNote] = useState('')
  const [showComps, setShowComps] = useState(false)
  const [busy, setBusy] = useState(false)
  const [msg, setMsg] = useState<string | null>(null)
  const say = async (what: 'ok' | 'pass' | 'ask') => {
    setBusy(true); setMsg(null)
    const n = Number(String(num).replace(/[^0-9.]/g, ''))
    const r = await supabase.rpc('text_offer_decide', { p_id: o.offer_id, p_say: what, p_number: what === 'ok' ? n : null, p_note: note.trim() || null })
    setBusy(false)
    if (r.error) { setMsg(r.error.message); return }
    const d = r.data as { ok: boolean; reason?: string }
    if (!d.ok) { setMsg(d.reason ?? 'not saved'); return }
    onDone()
  }
  const kind = o.ask_kind === 'counter' ? 'Their counter' : o.ask_kind === 'their_number' ? 'Their own number (under the rule)' : 'First number'
  return (
    <div className="rounded-xl border border-amber-300 bg-amber-50/60 p-3 dark:bg-amber-950/20">
      <div className="flex flex-wrap items-center gap-2">
        <Badge tone="warn">{kind}</Badge>
        <Link to={`/lead/${o.lead_id}`} className="text-sm font-semibold underline">{o.address ?? 'a card'}{o.city ? `, ${o.city}` : ''}</Link>
        <span className="text-xs text-muted-foreground">{o.owner_name}</span>
        {o.next.late && <Badge tone="bad">waiting since {fmtDateTime(o.next.due_at)}</Badge>}
      </div>
      <div className="mt-2 space-y-1">
        {o.their_words_that_opened_it && <Line k="They wrote">&ldquo;{o.their_words_that_opened_it}&rdquo;</Line>}
        {o.ask_note && <Line k="Note">{o.ask_note}</Line>}
        <Line k="Worth fixed up">{usd(o.comp.arv)} from {o.comp.sold_comps} sold comps{o.comp.sqft ? `, ${o.comp.sqft.toLocaleString('en-US')} sq ft` : ''}. {o.comp.basis}{' '}
          {o.comps.length > 0 && <button type="button" className="underline" onClick={() => setShowComps(!showComps)}>{showComps ? 'hide comps' : 'see comps'}</button>}</Line>
        {showComps && (
          <ul className="rounded-lg bg-background p-2 text-xs">
            {o.comps.map((c, i) => <li key={i}>{c.address} · {usd(c.sold_price)} · {c.sold_date}{c.sqft ? ` · ${c.sqft} sq ft` : ''}{c.distance ? ` · ${c.distance}` : ''}{c.note ? ` · ${c.note}` : ''}</li>)}
          </ul>
        )}
        <Line k="Condition, their words">{o.seller.condition_words ? <>&ldquo;{o.seller.condition_words}&rdquo;</> : '(none)'}</Line>
        <Line k="Repairs">{usd(o.numbers.repairs)} ({o.numbers.repairs_basis})</Line>
        <Line k="The rule">offer {usd(o.numbers.offer)}, the most {usd(o.numbers.most)}, a wholesale buyer about {usd(o.numbers.wholesale)}</Line>
        {(o.seller.their_number !== null || o.seller.their_words) && <Line k="Their number">{o.seller.their_number !== null ? usd(o.seller.their_number) : ''} {o.seller.their_words ? `"${o.seller.their_words}"` : ''} ({o.seller.flexible})</Line>}
        {o.seller.need && <Line k="Why they would sell">{o.seller.need}</Line>}
        {o.records && (o.records.why || o.records.equity_line) && <Line k="Records">{[o.records.tier ? `tier ${o.records.tier}` : null, o.records.why, o.records.equity_line].filter(Boolean).join(' · ')}</Line>}
        {o.numbers.ok_number !== null && <Line k="You OK'd before">{usd(o.numbers.ok_number)}</Line>}
      </div>
      <div className="mt-3 flex flex-wrap items-end gap-2">
        <label className="text-sm font-medium">Number to text
          <Input inputMode="numeric" value={num} onChange={(e) => setNum(e.target.value)} className="mt-1 w-36" />
        </label>
        <label className="min-w-0 flex-1 text-sm font-medium">Note (needed to pass or to ask)
          <Input value={note} onChange={(e) => setNote(e.target.value)} placeholder="a few words for Muse" className="mt-1" />
        </label>
      </div>
      <div className="mt-3 flex flex-wrap items-center gap-2">
        <Button className="h-12 sm:h-10" disabled={busy || !Number(String(num).replace(/[^0-9.]/g, ''))} onClick={() => void say('ok')}>OK, text {usd(String(num).replace(/[^0-9.]/g, ''))}</Button>
        <Button className="h-12 sm:h-10" variant="outline" disabled={busy} onClick={() => void say('pass')}>Pass</Button>
        <Button className="h-12 sm:h-10" variant="outline" disabled={busy} onClick={() => void say('ask')}>Ask Muse</Button>
        {msg && <span className="text-sm text-red-600">{msg}</span>}
      </div>
    </div>
  )
}

function YesCard({ o }: { o: Offer }) {
  return (
    <div className="rounded-xl border border-emerald-300 bg-emerald-50/60 p-3 dark:bg-emerald-950/20">
      <div className="flex flex-wrap items-center gap-2">
        <Badge tone="good">They said yes to {usd(o.answer.accepted)}</Badge>
        <span className="text-sm font-semibold">{o.address ?? 'a card'}{o.city ? `, ${o.city}` : ''}</span>
        <span className="text-xs text-muted-foreground">{o.owner_name}</span>
      </div>
      <div className="mt-2 space-y-1">
        {o.answer.words && <Line k="They wrote">&ldquo;{o.answer.words}&rdquo;</Line>}
        <Line k="Who signs">{o.seller.signers}</Line>
        <Line k="Email for the papers">{o.seller.seller_email}</Line>
        {o.seller.timeline && <Line k="Timing">{o.seller.timeline}</Line>}
      </div>
      <p className="mt-3 text-sm"><Link to={`/lead/${o.lead_id}`} className="font-medium underline">Open the card and Send offer</Link>. Muse never sends the written offer.</p>
    </div>
  )
}
