// My cards (migration 0166; Colin 2026-11-03): every card a caller has worked, in piles: call today, booked, waiting on
// Colin, this week, talked with nothing scheduled, follow up later, tried never reached, closed. The piles are the
// database's (my_piles); a tap opens the card. Colin can look at either caller's piles.
import { useState } from 'react'
import { Link } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import { ChevronDown, ChevronRight } from 'lucide-react'
import { supabase } from '@/lib/supabaseClient'
import { useAuth } from '@/providers/AuthProvider'
import { Input } from '@/components/ui/input'
import { Badge, Empty, ErrorNote, Select } from '@/components/ui/form'
import { fmtDateTime } from '@/lib/format'
import { BELT_LABEL, type Belt } from '@/lib/belts'
import { STAGE_LABEL } from '@/lib/wpie'
import type { LeadStage } from '@/lib/types'
import { PILES, groupPiles, type Pile, type PileCard } from '@/lib/piles'
import { cn } from '@/lib/utils'

function usePiles(person: string | null) {
  return useQuery({
    queryKey: ['my_piles', person],
    queryFn: async () => {
      const r = await supabase.rpc('my_piles', person ? { p_person: person } : {})
      if (r.error) throw new Error(r.error.message)
      return r.data as { person: string; cards: PileCard[] }
    },
  })
}

export default function MyCards() {
  const { isOwner } = useAuth()
  const [person, setPerson] = useState('thalia')
  const [search, setSearch] = useState('')
  const [open, setOpen] = useState<Record<Pile, boolean>>(() => Object.fromEntries(PILES.map((p) => [p.id, p.open])) as Record<Pile, boolean>)
  const q = usePiles(isOwner ? person : null)
  const piles = groupPiles(q.data?.cards ?? [], search)
  const total = q.data?.cards.length ?? 0
  const name = (q.data?.person ?? person).replace(/^./, (ch) => ch.toUpperCase())

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-end justify-between gap-3">
        <div>
          <h1 className="text-2xl font-bold tracking-tight">{isOwner ? `${name}'s cards` : 'My cards'}</h1>
          <p className="text-sm text-muted-foreground">
            Every card {isOwner ? name : 'you'} called, talked to, or has a call on. {total} in all.
          </p>
        </div>
        {isOwner && (
          <Select value={person} onChange={(e) => setPerson(e.target.value)} aria-label="Whose cards" className="w-40">
            <option value="thalia">Thalia</option>
            <option value="adil">Adil</option>
          </Select>
        )}
      </div>
      <Input placeholder="Find a name, address or town" value={search} onChange={(e) => setSearch(e.target.value)} />

      <div className="flex flex-wrap gap-2">
        {PILES.map((p) => (
          <a key={p.id} href={`#pile-${p.id}`} onClick={() => setOpen((o) => ({ ...o, [p.id]: true }))}
            className="min-h-10 rounded-full border bg-background px-3.5 py-2 text-sm hover:bg-accent">
            {p.title} <span className="opacity-70">{piles[p.id].length}</span>
          </a>
        ))}
      </div>

      <ErrorNote error={q.error} />
      {q.isLoading && <Empty>Loading...</Empty>}

      {q.data && PILES.map((p) => {
        const rows = piles[p.id]
        const isOpen = open[p.id]
        return (
          <section key={p.id} id={`pile-${p.id}`} className="scroll-mt-20 rounded-lg border bg-card">
            <button type="button" onClick={() => setOpen((o) => ({ ...o, [p.id]: !o[p.id] }))} aria-expanded={isOpen}
              className="flex w-full items-start gap-2 px-4 py-3 text-left">
              {isOpen ? <ChevronDown className="mt-0.5 h-5 w-5 shrink-0" aria-hidden /> : <ChevronRight className="mt-0.5 h-5 w-5 shrink-0" aria-hidden />}
              <span className="flex-1">
                <span className="font-semibold">{p.title}</span>{' '}
                <Badge tone={p.id === 'call_now' && rows.length ? 'warn' : undefined}>{rows.length}</Badge>
                <span className="block text-xs text-muted-foreground">{p.hint}</span>
              </span>
            </button>
            {isOpen && (rows.length === 0
              ? <p className="border-t px-4 py-3 text-sm text-muted-foreground">Nothing here.</p>
              : <ul className="divide-y border-t">{rows.map((c) => <Row key={c.lead_id} c={c} />)}</ul>)}
          </section>
        )
      })}
    </div>
  )
}

function Row({ c }: { c: PileCard }) {
  const late = c.next_at != null && new Date(c.next_at).getTime() < Date.now()
  const status = c.belt ? (BELT_LABEL[c.belt as Belt] ?? c.belt) : (STAGE_LABEL[c.stage as LeadStage] ?? c.stage)
  return (
    <li>
      <Link to={`/lead/${c.lead_id}`} className="block px-4 py-3 hover:bg-accent">
        <div className="flex flex-wrap items-center gap-2">
          <span className="font-medium">{c.owner_name}</span>
          <Badge>{status}</Badge>
        </div>
        <div className="text-sm text-muted-foreground">
          {c.address}{c.municipality ? `, ${c.municipality}` : ''}{c.county ? ` (${c.county})` : ''}
        </div>
        {c.next_at && (
          <div className={cn('text-xs', late && 'font-medium text-rose-600')}>
            {late ? 'Was due' : 'Next'} {fmtDateTime(c.next_at)}{c.next_what ? `: ${c.next_what}` : ''}
          </div>
        )}
        {c.last_call && (
          <div className="truncate text-xs text-muted-foreground">
            Last call{c.last_call_at ? ` ${fmtDateTime(c.last_call_at)}` : ''}: {c.last_call.replace(/\s+/g, ' ')}
          </div>
        )}
      </Link>
    </li>
  )
}
