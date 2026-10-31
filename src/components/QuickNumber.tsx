import { useEffect, useState } from 'react'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { api, useOfferSettings } from '@/lib/queries'
import { supabase } from '@/lib/supabaseClient'
import { cn } from '@/lib/utils'

// The quick number on the Power hour card (migration 0154; Colin 2026-10-31: "this needs to be something done quickly
// during power hour", "also needs to factor in repairs", "less questions = more likely to get to the point of an offer").
// Four taps set the repair lines (roof, furnace/AC, kitchen and baths, anything big); anything not tapped counts as
// needing work, so the number is there with no taps at all. The figure is the database's (offer_shoot), never the
// caller's; she says it once, as rough, and logs what they said back. Hidden while the anchor is off in Settings; in
// "only when they won't say a number" mode it stays folded until she opens it.

type Line = { item: string; amount: number; why: string }
type Shot = {
  ok: boolean; reason?: string; walk_first?: boolean; number?: number; say?: string; value?: number; value_basis?: string; size_known?: boolean; sqft_basis?: string
  repairs?: number; lines?: Line[]; pct?: number; off?: number; mao?: number; asked?: number
}
const QUESTIONS: { key: string; ask: string; options: [string, string][] }[] = [
  { key: 'quick_roof', ask: 'Roof', options: [['new', 'Done in last 15 yrs'], ['old', 'Older / not sure']] },
  { key: 'quick_hvac', ask: 'Furnace & AC', options: [['new', 'Newer'], ['old', 'Original / not sure']] },
  { key: 'quick_kb', ask: 'Kitchen & baths', options: [['updated', 'Updated'], ['original', 'Original']] },
  { key: 'quick_big', ask: 'Water, foundation, fire?', options: [['no', 'No'], ['yes', 'Yes']] },
]
// the house's size sets the value (sold comps' price per sq ft x the size, 0158): asked only when the county has no size
const BEDS: [string, string][] = [['1', '1 bed'], ['2', '2 beds'], ['3', '3 beds'], ['4', '4+ beds']]
const REACTIONS: [string, string][] = [['gave_number', 'Said a number'], ['open', 'Open to it'], ['no', 'No / hung up'], ['later', 'Later']]
const dollars = (n: number) => '$' + Math.round(n).toLocaleString('en-US')

export function QuickNumber({ leadId }: { leadId: string }) {
  const settings = useOfferSettings()
  const mode = settings.data?.mode ?? 'off'
  const qc = useQueryClient()
  const [open, setOpen] = useState(false)
  const [picked, setPicked] = useState<Record<string, string>>({})
  // what was already tapped on this card (another call, or before a refresh)
  const saved = useQuery({
    queryKey: ['quick_answers', leadId],
    queryFn: async () => {
      const r = await supabase.from('leads').select('call_facts').eq('id', leadId).maybeSingle()
      return ((r.data as { call_facts?: Record<string, { value?: { choices?: string[] } }> } | null)?.call_facts) ?? {}
    },
    enabled: mode !== 'off',
  })
  useEffect(() => {
    if (!saved.data) return
    setPicked(Object.fromEntries(QUESTIONS.map((q) => [q.key, saved.data[q.key]?.value?.choices?.[0] ?? '']).filter(([, v]) => v)))
  }, [saved.data, leadId])
  const [said, setSaid] = useState<string | null>(null)
  const [reaction, setReaction] = useState('')
  const [counter, setCounter] = useState('')
  const [err, setErr] = useState<string | null>(null)
  const show = mode === 'live' || open
  const shot = useQuery({
    queryKey: ['quick_number', leadId, JSON.stringify(picked)],
    queryFn: async () => { const r = await api.offerShoot(leadId); if (r.error) throw r.error; return r.data as Shot },
    enabled: mode !== 'off' && show,
    placeholderData: (prev) => prev,      // the last number stays up while a tap is worked out: no flicker mid-call
  })
  const d = shot.data
  if (mode === 'off') return null
  if (!show) return (
    <Button variant="outline" className="h-11 w-full" onClick={() => setOpen(true)}>Won&apos;t name a number, or leaving? Quick number</Button>
  )
  const tap = async (key: string, v: string) => {
    setErr(null)
    const next = picked[key] === v ? '' : v
    setPicked((p) => ({ ...p, [key]: next }))
    const r = await api.callAnswer(leadId, key, next ? { choices: [next] } : null)
    const d = r.data as { ok?: boolean; reason?: string } | null
    if (r.error || !d?.ok) setErr(r.error?.message ?? d?.reason ?? 'not saved')
    void qc.invalidateQueries({ queryKey: ['quick_number', leadId] })
  }
  const logSaid = async () => {
    if (!d?.ok || d.number == null || !reaction) return
    setErr(null)
    const c = reaction === 'gave_number' ? Number(counter.replace(/[^0-9.]/g, '')) : null
    const r = await api.offerSaid(leadId, d.number, reaction, c, null)
    const res = r.data as { ok?: boolean; reason?: string } | null
    if (r.error || !res?.ok) { setErr(r.error?.message ?? res?.reason ?? 'not saved'); return }
    setSaid(`Said ${dollars(d.number)}; they: ${REACTIONS.find(([k]) => k === reaction)?.[1]}${c ? ` ${dollars(c)}` : ''}`)
  }
  return (
    <section aria-label="Quick number" className="space-y-2 rounded-lg border-2 border-amber-400 p-3">
      <div className="flex items-center justify-between gap-2">
        <p className="font-semibold">Quick number</p>
        <p className="text-xs text-muted-foreground">Tap what they say. Not asked counts as needing work.</p>
      </div>
      <div className="grid gap-2 sm:grid-cols-2">
        {QUESTIONS.map((q) => (
          <div key={q.key} className="space-y-1">
            <p className="text-xs font-medium text-muted-foreground">{q.ask}</p>
            <div className="grid grid-cols-2 gap-1">
              {q.options.map(([v, label]) => {
                const on = picked[q.key] === v
                return (
                  <button key={v} type="button" aria-pressed={on} onClick={() => void tap(q.key, v)}
                    className={cn('min-h-11 rounded-md border px-2 text-sm font-medium', on ? 'border-primary bg-primary text-primary-foreground' : 'bg-background')}>
                    {label}
                  </button>
                )
              })}
            </div>
          </div>
        ))}
      </div>
      {(d?.size_known === false || !!picked.quick_beds) && (
        <div className="space-y-1">
          <p className="text-xs font-medium text-muted-foreground">How many bedrooms? (sets the size, so the value)</p>
          <div className="grid grid-cols-4 gap-1">
            {BEDS.map(([v, label]) => {
              const on = picked.quick_beds === v
              return (
                <button key={v} type="button" aria-pressed={on} onClick={() => void tap('quick_beds', v)}
                  className={cn('min-h-11 rounded-md border px-2 text-sm font-medium', on ? 'border-primary bg-primary text-primary-foreground' : 'bg-background')}>
                  {label}
                </button>
              )
            })}
          </div>
        </div>
      )}
      {shot.isLoading && !shot.data && <p className="text-sm text-muted-foreground">Working it out...</p>}
      {d && !d.ok && (
        <p className={cn('rounded-md p-2 text-sm', d.walk_first ? 'bg-red-50 font-medium text-red-800 dark:bg-red-950/30 dark:text-red-200' : 'bg-muted')}>
          {d.walk_first ? 'No number: Colin walks this one first. "My partner would want to see it before saying a number. When could he come by?"' : `No number to say: ${d.reason}`}
        </p>
      )}
      {d?.ok && (
        <div className="space-y-2">
          <div className="flex flex-wrap items-baseline justify-between gap-2">
            <p className="text-3xl font-bold text-amber-800 dark:text-amber-300">{dollars(d.number ?? 0)}</p>
            <p className="text-xs text-muted-foreground">
              {dollars(d.value ?? 0)} value · {dollars(d.repairs ?? 0)} repairs
            </p>
          </div>
          <p className="rounded-md bg-amber-50 p-2 text-base leading-snug dark:bg-amber-950/30">&ldquo;{d.say}&rdquo;</p>
          <details className="text-xs text-muted-foreground">
            <summary className="cursor-pointer">The repairs</summary>
            <ul className="mt-1 space-y-0.5">
              {(d.lines ?? []).map((l) => <li key={l.item}>{l.item}: {dollars(l.amount)} <span className="opacity-80">({l.why})</span></li>)}
            </ul>
            <p className="mt-1">{d.value_basis}</p>
          </details>
          {said ? <p className="text-sm font-medium text-emerald-700">{said}</p> : (
            <div className="flex flex-wrap items-center gap-2">
              {REACTIONS.map(([k, label]) => (
                <button key={k} type="button" aria-pressed={reaction === k} onClick={() => setReaction(k)}
                  className={cn('min-h-10 rounded-md border px-2 text-sm', reaction === k ? 'border-primary bg-primary text-primary-foreground' : 'bg-background')}>{label}</button>
              ))}
              {reaction === 'gave_number' && <Input className="h-10 w-36" inputMode="decimal" placeholder="Their number ($)" value={counter} onChange={(e) => setCounter(e.target.value)} />}
              <Button size="sm" disabled={!reaction || (reaction === 'gave_number' && !counter.trim())} onClick={() => void logSaid()}>I said it</Button>
            </div>
          )}
        </div>
      )}
      {err && <p className="text-sm text-red-700">{err}</p>}
    </section>
  )
}
