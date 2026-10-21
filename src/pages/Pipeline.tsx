import { useMemo, useState } from 'react'
import { Link, useSearchParams } from 'react-router-dom'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Badge, Empty, ErrorNote, Select } from '@/components/ui/form'
import { PAGE_SIZE, useLeads, usePipelineCounts, type LeadFilter } from '@/lib/queries'
import { STAGES, STAGE_LABEL, WORKING_STAGES } from '@/lib/wpie'
import { fmtDateTime } from '@/lib/format'
import type { LeadStage } from '@/lib/types'
import { cn } from '@/lib/utils'

export default function Pipeline() {
  const [params, setParams] = useSearchParams()
  const filter: LeadFilter = {
    stage: (params.get('stage') as LeadFilter['stage']) || 'working',
    lane: (params.get('lane') as LeadFilter['lane']) || 'all',
    county: params.get('county') || 'all',
    search: params.get('q') || '',
    page: Number(params.get('page') || 0),
  }
  const [search, setSearch] = useState(filter.search)
  const set = (patch: Partial<Record<'stage' | 'lane' | 'county' | 'q' | 'page', string>>) => {
    const next = new URLSearchParams(params)
    for (const [k, v] of Object.entries(patch)) {
      if (!v || v === 'all' || (k === 'page' && v === '0')) next.delete(k)
      else next.set(k, v)
    }
    if (!('page' in patch)) next.delete('page')
    setParams(next, { replace: true })
  }

  const counts = usePipelineCounts()
  const leads = useLeads(filter, WORKING_STAGES)

  // stage counts under the current lane / county filter
  const { byStage, counties } = useMemo(() => {
    const byStage = new Map<LeadStage, number>()
    const counties = new Set<string>()
    for (const r of counts.data ?? []) {
      if (r.county) counties.add(r.county)
      if (filter.lane !== 'all' && r.lane !== filter.lane) continue
      if (filter.county !== 'all' && r.county !== filter.county) continue
      byStage.set(r.stage, (byStage.get(r.stage) ?? 0) + r.n)
    }
    return { byStage, counties: [...counties].sort() }
  }, [counts.data, filter.lane, filter.county])
  const working = WORKING_STAGES.reduce((s, id) => s + (byStage.get(id) ?? 0), 0)
  const all = [...byStage.values()].reduce((a, b) => a + b, 0)

  const chip = (id: string, label: string, n: number) => (
    <button
      key={id}
      onClick={() => set({ stage: id })}
      className={cn(
        'min-h-11 rounded-full border px-4 py-2 text-sm',
        filter.stage === id ? 'border-primary bg-primary text-primary-foreground' : 'bg-background hover:bg-accent',
      )}
    >
      {label} <span className="opacity-70">{n}</span>
    </button>
  )

  const pages = Math.max(1, Math.ceil((leads.data?.count ?? 0) / PAGE_SIZE))

  return (
    <div className="space-y-4">
      <h1 className="text-xl font-semibold">Pipeline</h1>

      <div className="grid grid-cols-2 gap-2 sm:grid-cols-4">
        <Select value={filter.lane} onChange={(e) => set({ lane: e.target.value })} aria-label="Lane">
          <option value="all">Both lanes</option>
          <option value="hold">Hold (keep)</option>
          <option value="flip">Flip (resell)</option>
        </Select>
        <Select value={filter.county} onChange={(e) => set({ county: e.target.value })} aria-label="County">
          <option value="all">All counties</option>
          {counties.map((c) => (
            <option key={c} value={c}>
              {c}
            </option>
          ))}
        </Select>
        <form
          className="col-span-2 flex gap-2"
          onSubmit={(e) => {
            e.preventDefault()
            set({ q: search })
          }}
        >
          <Input placeholder="Name or address" value={search} onChange={(e) => setSearch(e.target.value)} />
          <Button type="submit" variant="outline">
            Find
          </Button>
        </form>
      </div>

      <div className="flex flex-wrap gap-2">
        {chip('working', 'Being worked', working)}
        {STAGES.map((s) => chip(s.id, s.label, byStage.get(s.id) ?? 0))}
        {chip('all', 'Everyone', all)}
      </div>

      <ErrorNote error={leads.error ?? counts.error} />
      {leads.isLoading && <Empty>Loading...</Empty>}
      {leads.data && leads.data.rows.length === 0 && <Empty>No leads here.</Empty>}

      <ul className="divide-y rounded-lg border bg-card">
        {leads.data?.rows.map((l) => (
          <li key={l.id}>
            <Link to={`/lead/${l.id}`} className="block px-4 py-3 hover:bg-accent">
              <div className="flex flex-wrap items-center gap-2">
                <span className="font-medium">{l.owner_name}</span>
                <Badge>{STAGE_LABEL[l.stage]}</Badge>
                {l.lane && <Badge tone="info">{l.lane === 'hold' ? 'Hold' : 'Flip'}</Badge>}
              </div>
              <div className="text-sm text-muted-foreground">
                {l.property_address}
                {l.municipality ? `, ${l.municipality}` : ''} {l.county ? `(${l.county})` : ''}
              </div>
              {l.next_action_at && (
                <div className="text-xs">
                  Next: {l.next_action || 'action'} {fmtDateTime(l.next_action_at)}
                </div>
              )}
            </Link>
          </li>
        ))}
      </ul>

      {pages > 1 && (
        <div className="flex items-center justify-between text-sm">
          <Button variant="outline" size="sm" disabled={filter.page === 0} onClick={() => set({ page: String(filter.page - 1) })}>
            Previous
          </Button>
          <span>
            Page {filter.page + 1} of {pages} ({leads.data?.count} leads)
          </span>
          <Button variant="outline" size="sm" disabled={filter.page + 1 >= pages} onClick={() => set({ page: String(filter.page + 1) })}>
            Next
          </Button>
        </div>
      )}
    </div>
  )
}
