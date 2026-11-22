import { useState } from 'react'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { Button } from '@/components/ui/button'
import { Badge, ErrorNote, Section } from '@/components/ui/form'
import { supabase } from '@/lib/supabaseClient'
import { cn } from '@/lib/utils'

// Before you call (0267; Colin 2026-11-20: "figure out the story of what's going on with the house ahead of time and
// then make a detailed script like I got for the Jason call where I got a contract"). Muse writes it: what is going
// on, what is owed and which of it has to be paid at closing, what is not known yet, and the words for the call.
// The card's caller and Colin read it here. A yes asks for one by itself; anyone on the card can ask for one.

type Owed = { kind: string; creditor: string | null; amount: number | null; basis: string; follows_house: 'yes' | 'no' | 'unknown'; note: string | null }
type Brief = { status: 'none' | 'wanted' | 'ready'; due_at?: string | null; late?: boolean; wanted_by?: string | null
  story?: string | null; owed?: Owed[]; owed_line?: string | null; to_clear?: number | null; owed_total?: number | null
  unknowns?: string[]; script?: string | null; sources?: string | null; written_by?: string | null; written_at?: string | null
  angles?: { angle: string; why: string }[]; situation?: string | null; claimed_by?: string | null }
const usd = (n: number | null | undefined) => (n == null ? 'amount not known' : Number(n).toLocaleString('en-US', { style: 'currency', currency: 'USD', maximumFractionDigits: 0 }))
const clock = (iso: string | null | undefined) => (iso ? new Date(iso).toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit' }) : '')
const KIND: Record<string, string> = { mortgage: 'Mortgage', tax: 'Unpaid tax', judgment: 'Judgment', lien: 'Lien', estate_claim: 'Claim on the estate', utility: 'Utility', hoa: 'Association', other: 'Other' }
const FOLLOWS: Record<string, { text: string; tone: string }> = {
  yes: { text: 'paid at closing', tone: 'text-rose-700 dark:text-rose-300' },
  no: { text: 'does not follow the house', tone: 'text-muted-foreground' },
  unknown: { text: 'not settled yet', tone: 'text-amber-700 dark:text-amber-300' },
}

export function CallBrief({ leadId }: { leadId: string }) {
  const qc = useQueryClient()
  const q = useQuery({ queryKey: ['call_brief', leadId], refetchInterval: 60_000, queryFn: async () => {
    const r = await supabase.rpc('call_brief', { p_lead_id: leadId })
    if (r.error) throw r.error
    return (r.data ?? { status: 'none' }) as Brief
  } })
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState<string | null>(null)
  const [open, setOpen] = useState(true)
  const b = q.data
  const ask = async () => {
    setBusy(true); setErr(null)
    // 0281: comps, angles and a number, whichever agent (Muse or Grok) takes it first
    const r = await supabase.rpc('card_work_ask', { p_lead_id: leadId })
    setBusy(false)
    if (r.error) { setErr(r.error.message); return }
    await qc.invalidateQueries({ queryKey: ['call_brief', leadId] })
    await qc.invalidateQueries({ queryKey: ['deal_sheet', leadId] })
  }
  if (q.isLoading || !b) return q.error ? <ErrorNote error={q.error} /> : null
  if (!['none', 'wanted', 'ready'].includes(b.status)) return null   // an answer this page does not know: show nothing rather than half a brief
  if (b.status === 'none') {
    return (
      <div className="flex flex-wrap items-center gap-2 rounded-2xl border border-dashed border-border/70 px-4 py-3 text-sm">
        <span className="text-muted-foreground">No story or script for this call yet.</span>
        <Button size="sm" variant="outline" disabled={busy} onClick={ask}>Get comps, angles and a script</Button>
        {err && <span className="text-red-700">{err}</span>}
      </div>
    )
  }
  if (b.status === 'wanted') {
    return (
      <Section title="Before you call" right={<Badge tone={b.late ? 'warn' : 'info'}>{b.late ? 'Late' : `By ${clock(b.due_at)}`}</Badge>}>
        <p className="text-sm">
          {b.late ? `${b.claimed_by ?? 'Nobody'} has not written it yet.` : `${b.claimed_by ? `${b.claimed_by} is` : 'Muse or Grok will be'} working up the comps, the angles and a script, on the card by ${clock(b.due_at)}.`}{' '}
          If you call first: ask what is owed on the house and to whom, and who has to sign.
        </p>
      </Section>
    )
  }
  const owed = b.owed ?? []
  return (
    <Section title="Before you call" right={<button type="button" className="text-xs font-medium underline" onClick={() => setOpen(!open)}>{open ? 'Hide the script' : 'Show the script'}</button>}>
      {b.situation && <p className="mb-2 rounded-md bg-muted/60 p-2 text-sm font-semibold">{b.situation}</p>}
      {b.story && <p className="whitespace-pre-wrap text-sm">{b.story}</p>}
      {(b.angles ?? []).length > 0 && (
        <div className="mt-3">
          <p className="text-xs font-semibold uppercase tracking-wide text-emerald-700 dark:text-emerald-300">Angles: what we can give besides money</p>
          <ol className="mt-1 list-decimal space-y-1 pl-5 text-sm">
            {(b.angles ?? []).map((a, i) => <li key={i}><span className="font-medium">{a.angle}</span><span className="text-muted-foreground"> · {a.why}</span></li>)}
          </ol>
        </div>
      )}
      {owed.length > 0 && (
        <div className="mt-3">
          <p className="text-xs font-semibold uppercase tracking-wide text-muted-foreground">What is owed</p>
          <ul className="mt-1 divide-y text-sm">
            {owed.map((o, i) => (
              <li key={i} className="flex flex-wrap items-baseline gap-x-2 py-1">
                <span className="font-medium">{KIND[o.kind] ?? o.kind}{o.creditor ? `, ${o.creditor}` : ''}</span>
                <span className="font-semibold">{usd(o.amount)}</span>
                <span className={cn('text-xs', FOLLOWS[o.follows_house]?.tone)}>{FOLLOWS[o.follows_house]?.text}</span>
                <span className="text-xs text-muted-foreground">({o.basis})</span>
                {o.note && <span className="basis-full text-xs text-muted-foreground">{o.note}</span>}
              </li>
            ))}
          </ul>
          <p className="mt-2 rounded-md bg-muted/60 p-2 text-sm font-semibold">
            Has to be paid at closing: {b.to_clear != null ? usd(b.to_clear) : 'nothing found that follows the house'}
            {b.owed_total != null && b.owed_total !== b.to_clear ? <span className="font-normal text-muted-foreground"> · everything owed, {usd(b.owed_total)}</span> : null}
          </p>
        </div>
      )}
      {(b.unknowns ?? []).length > 0 && (
        <div className="mt-3">
          <p className="text-xs font-semibold uppercase tracking-wide text-amber-700 dark:text-amber-300">Find out on the call</p>
          <ul className="mt-1 list-disc pl-5 text-sm">{(b.unknowns ?? []).map((u, i) => <li key={i}>{u}</li>)}</ul>
        </div>
      )}
      {open && b.script && (
        <div className="mt-3">
          <p className="text-xs font-semibold uppercase tracking-wide text-muted-foreground">The script</p>
          <div className="mt-1 max-h-[70vh] overflow-auto rounded-md border bg-background p-3 text-sm leading-relaxed">
            {b.script.split('\n').map((line, i) => {
              const head = line.match(/^\s*\*\*(.+?)\*\*\s*$/)
              if (head) return <p key={i} className="mt-3 text-sm font-bold first:mt-0">{head[1]}</p>
              return line.trim() === '' ? <div key={i} className="h-2" /> : <p key={i} className="whitespace-pre-wrap">{line}</p>
            })}
          </div>
        </div>
      )}
      <p className="mt-2 text-xs text-muted-foreground">
        {b.written_by ? `Written by ${b.written_by}` : 'Written'}{b.written_at ? `, ${new Date(b.written_at).toLocaleString('en-US', { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' })}` : ''}.
        {b.sources ? ` Read from: ${b.sources}` : ''}
        <button type="button" className="ml-2 underline" disabled={busy} onClick={ask}>Ask for a fresh one</button>
      </p>
      {err && <p className="text-sm text-red-700">{err}</p>}
    </Section>
  )
}
