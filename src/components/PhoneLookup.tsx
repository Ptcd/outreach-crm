import { useState } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Badge } from '@/components/ui/form'
import { api, usePhoneLookup } from '@/lib/queries'
import { fmtPhone } from '@/lib/format'
import { STAGE_LABEL } from '@/lib/wpie'

// "Who's calling?": type the last 4 digits (or more) of the caller's number, tap the owner, the lead
// card opens with the call script. An unknown number gets a "New caller" card.
export function PhoneLookup() {
  const [digits, setDigits] = useState('')
  const [name, setName] = useState('')
  const [msg, setMsg] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const nav = useNavigate()
  const d = digits.replace(/\D/g, '')
  const q = usePhoneLookup(d)
  const rows = q.data ?? []

  const newCaller = async () => {
    setBusy(true)
    setMsg(null)
    const r = await api.newCaller(d, name.trim() || undefined)
    setBusy(false)
    const out = r.data as { ok: boolean; lead_id?: string; reason?: string } | null
    if (r.error || !out?.ok || !out.lead_id) { setMsg(r.error?.message ?? out?.reason ?? 'Could not make the card.'); return }
    nav(`/lead/${out.lead_id}?call=1&phone=${d}`)
  }

  return (
    <section className="rounded-lg border-2 border-primary/30 bg-card p-3">
      <label className="block text-sm font-semibold" htmlFor="phone-lookup">Someone calling? Type the last 4 digits of their number</label>
      <Input id="phone-lookup" inputMode="numeric" autoComplete="off" placeholder="e.g. 6435" value={digits}
        onChange={(e) => setDigits(e.target.value)} className="mt-1 h-12 text-lg tracking-widest" />
      {d.length >= 3 && (
        <div className="mt-2">
          {q.isLoading && <p className="text-sm text-muted-foreground">Looking...</p>}
          {q.error && <p className="text-sm text-red-700">Could not look that up: {q.error.message}</p>}
          {rows.length > 1 && <p className="mb-1 text-sm font-medium">{rows.length >= 50 ? '50+' : rows.length} owners have a number ending in {d}. Ask their name or street:</p>}
          <ul className="space-y-2">
            {rows.map((r) => (
              <li key={r.lead_id}>
                <Link to={`/lead/${r.lead_id}?call=1&phone=${r.phone}`}
                  className="block min-h-11 rounded-md border bg-background p-2 active:bg-muted">
                  <span className="flex flex-wrap items-center gap-1.5">
                    <span className="font-semibold">{r.owner_name}</span>
                    <Badge tone={r.stage === 'dnc' ? 'bad' : 'muted'}>{STAGE_LABEL[r.stage] ?? r.stage}</Badge>
                    {r.lane && <Badge tone="info">{r.lane === 'hold' ? 'Hold' : 'Flip'}</Badge>}
                    {r.blocked && r.stage !== 'dnc' && <Badge tone="bad">Do not contact</Badge>}
                  </span>
                  <span className="block text-sm text-muted-foreground">
                    {[r.property_address, r.municipality].filter(Boolean).join(', ') || 'No property on file'} - {fmtPhone(r.phone)}
                    {r.person_name && r.person_name.toUpperCase() !== r.owner_name.toUpperCase() ? ` (${r.person_name})` : ''}
                  </span>
                </Link>
              </li>
            ))}
          </ul>
          {q.isFetched && rows.length === 0 && (
            <div className="space-y-2 rounded-md bg-muted p-2">
              <p className="text-sm">No owner has a number ending in {d}.</p>
              {d.length >= 10 ? (
                <>
                  <Input placeholder="Their name (optional)" value={name} onChange={(e) => setName(e.target.value)} className="h-11" />
                  <Button className="h-11 w-full" disabled={busy} onClick={() => void newCaller()}>New caller: make a card for {fmtPhone(d)}</Button>
                </>
              ) : (
                <p className="text-sm text-muted-foreground">Type the full 10-digit number to make a new caller card.</p>
              )}
            </div>
          )}
          {msg && <p className="mt-1 text-sm text-red-700">{msg}</p>}
        </div>
      )}
    </section>
  )
}
