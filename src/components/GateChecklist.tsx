import { useState } from 'react'
import { Button } from '@/components/ui/button'
import { Badge, Select, Textarea } from '@/components/ui/form'
import { DECISION_LABEL, GATE_ITEMS, HARD_STOPS, gateSuggestion, gateTotal, noWalkRoute, STAGE_LABEL, type GateScores } from '@/lib/wpie'
import type { GateDecision, GateScore } from '@/lib/types'
import { fmtDateTime } from '@/lib/format'
import { cn } from '@/lib/utils'

export interface GateSave {
  scores: GateScores
  hard_stops: string[]
  decision: GateDecision
  note: string | null
}

const EMPTY: GateScores = {
  reason_and_clock: 0, decision_makers: 0, number_and_anchor: 0, flexibility: 0, condition: 0, numbers_close: 0,
}

function fromRow(row: GateScore | null): GateScores {
  if (!row) return { ...EMPTY }
  return {
    reason_and_clock: row.reason_and_clock, decision_makers: row.decision_makers, number_and_anchor: row.number_and_anchor,
    flexibility: row.flexibility, condition: row.condition, numbers_close: row.numbers_close,
  }
}

/** The six-item walk / don't-walk gate. Colin scores it after his call; others read it. */
export function GateChecklist({
  latest, canEdit, onSave, saving,
}: {
  latest: GateScore | null
  canEdit: boolean
  onSave?: (v: GateSave) => Promise<void> | void
  saving?: boolean
}) {
  const [scores, setScores] = useState<GateScores>(() => fromRow(latest))
  const [stops, setStops] = useState<string[]>(() => latest?.hard_stops ?? [])
  const [decision, setDecision] = useState<GateDecision | ''>('')
  const [note, setNote] = useState('')

  const total = gateTotal(scores)
  const suggested = gateSuggestion(scores, stops)
  const chosen = decision || suggested

  return (
    <div className="space-y-4">
      {latest && (
        <p className="text-sm text-muted-foreground">
          Last scored {fmtDateTime(latest.at)}
          {latest.decided_by_name ? ` by ${latest.decided_by_name}` : ''}: {latest.total}/12, decision{' '}
          <strong>{DECISION_LABEL[latest.decision]}</strong>
          {latest.note ? ` - ${latest.note}` : ''}
        </p>
      )}
      <ol className="space-y-3">
        {GATE_ITEMS.map((item, i) => (
          <li key={item.id} className="rounded-md border p-3">
            <div className="mb-2 font-medium">
              {i + 1}. {item.label}
            </div>
            <div role="radiogroup" aria-label={item.label} className="grid gap-2 sm:grid-cols-3">
              {[0, 1, 2].map((v) => (
                <label
                  key={v}
                  className={cn(
                    'flex cursor-pointer items-start gap-2 rounded border p-2 text-sm',
                    scores[item.id] === v ? 'border-primary bg-primary/5' : 'border-input',
                    !canEdit && 'cursor-default',
                  )}
                >
                  <input
                    type="radio"
                    name={item.id}
                    value={v}
                    className="mt-1"
                    checked={scores[item.id] === v}
                    disabled={!canEdit}
                    onChange={() => setScores((s) => ({ ...s, [item.id]: v }))}
                  />
                  <span>
                    <strong>{v}</strong> - {item.scale[v]}
                  </span>
                </label>
              ))}
            </div>
          </li>
        ))}
      </ol>

      <fieldset className="rounded-md border p-3">
        <legend className="px-1 font-medium">Hard stops (any one means don't walk)</legend>
        <div className="space-y-2">
          {HARD_STOPS.map((h) => (
            <label key={h.id} className="flex items-start gap-2 text-sm">
              <input
                type="checkbox"
                className="mt-1"
                checked={stops.includes(h.id)}
                disabled={!canEdit}
                onChange={(e) => setStops((s) => (e.target.checked ? [...s, h.id] : s.filter((x) => x !== h.id)))}
              />
              {h.label}
            </label>
          ))}
        </div>
      </fieldset>

      <div className="flex flex-wrap items-center gap-2 text-sm" data-testid="gate-summary">
        <span>
          Total <strong>{total}</strong>/12
        </span>
        <span>The written rule says:</span>
        <Badge tone={suggested === 'walk' ? 'good' : suggested === 'one_more_call' ? 'warn' : 'bad'}>{DECISION_LABEL[suggested]}</Badge>
        {suggested === 'no_walk' && <span className="text-muted-foreground">(then: {STAGE_LABEL[noWalkRoute(scores)]})</span>}
      </div>

      {canEdit && (
        <div className="space-y-2">
          <label className="block text-sm font-medium">
            Your decision
            <Select value={chosen} onChange={(e) => setDecision(e.target.value as GateDecision)} className="mt-1">
              <option value="walk">{DECISION_LABEL.walk}</option>
              <option value="one_more_call">{DECISION_LABEL.one_more_call}</option>
              <option value="no_walk">{DECISION_LABEL.no_walk}</option>
            </Select>
          </label>
          <Textarea placeholder="Why (optional)" value={note} onChange={(e) => setNote(e.target.value)} />
          <Button
            disabled={saving}
            onClick={() => onSave?.({ scores, hard_stops: stops, decision: chosen, note: note.trim() || null })}
          >
            {saving ? 'Saving...' : 'Save gate score'}
          </Button>
        </div>
      )}
      {!canEdit && <p className="text-sm text-muted-foreground">Colin scores the gate after his call.</p>}
    </div>
  )
}
