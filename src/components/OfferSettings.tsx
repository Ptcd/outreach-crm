import { useEffect, useState } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Select } from '@/components/ui/form'
import { api, useOfferSettings, type OfferSettings as Rules } from '@/lib/queries'

// The exit anchor's rules (migration 0149). Colin 2026-10-30: a seller who will not name a number, or is leaving,
// hears one low, non-firm figure so they say their own (Adil: "we're just asking questions ... then saying we'll
// call you back"). Off until Colin turns it on here. The figure is Rick's arithmetic: value minus repairs, times the
// band's percentage, then the anchor sits under that.
const MODE: { id: Rules['mode']; label: string; hint: string }[] = [
  { id: 'off', label: 'Off', hint: 'No number on the phone, ever. Colin gives his at the house.' },
  { id: 'exit_only', label: 'Only when they will not say a number, or are leaving', hint: 'The anchor card opens under "Their number" once the seller has refused or is going.' },
  { id: 'live', label: 'Every call', hint: 'The anchor card is open on every call script.' },
]

export function OfferSettings() {
  const q = useOfferSettings()
  const qc = useQueryClient()
  const [f, setF] = useState<Record<string, string>>({})
  const [bands, setBands] = useState<{ upto: string; pct: string }[]>([])
  const [msg, setMsg] = useState<string | null>(null)
  useEffect(() => {
    if (!q.data) return
    const d = q.data
    setF({ mode: d.mode, repair_light: String(d.repair_light), repair_medium: String(d.repair_medium), repair_heavy: String(d.repair_heavy),
      lao_discount: String(Math.round(d.lao_discount * 100)), default_sqft: String(d.default_sqft), min_number: String(d.min_number), round_to: String(d.round_to) })
    setBands((d.bands ?? []).map((b) => ({ upto: b.upto == null ? '' : String(b.upto), pct: String(Math.round(b.pct * 100)) })))
  }, [q.data])
  if (q.isLoading) return <p className="text-sm text-muted-foreground">Loading…</p>
  if (!q.data) return <p className="text-sm text-muted-foreground">The app has no offer rules yet (migration 0149).</p>
  const set = (k: string) => (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement>) => setF((x) => ({ ...x, [k]: e.target.value }))
  const num = (k: string) => { const v = Number(f[k]); return Number.isFinite(v) ? v : null }
  const save = async () => {
    setMsg(null)
    const p: Record<string, unknown> = { mode: f.mode, repair_light: num('repair_light'), repair_medium: num('repair_medium'), repair_heavy: num('repair_heavy'),
      lao_discount: num('lao_discount') == null ? null : (num('lao_discount') as number) / 100, default_sqft: num('default_sqft'), min_number: num('min_number'), round_to: num('round_to'),
      bands: bands.filter((b) => b.pct.trim()).map((b) => ({ upto: b.upto.trim() ? Number(b.upto) : null, pct: Number(b.pct) / 100 })) }
    const r = await api.offerSettingsSet(p)
    const d = r.data as { ok?: boolean; reason?: string } | null
    if (r.error || d?.ok === false) { setMsg(r.error?.message ?? d?.reason ?? 'not saved'); return }
    setMsg('Saved.')
    void qc.invalidateQueries({ queryKey: ['offer_settings'] })
  }
  const mode = MODE.find((m) => m.id === f.mode) ?? MODE[0]
  return (
    <div className="space-y-3 text-sm">
      <label className="block font-medium">When a caller may say a number
        <Select className="mt-1" value={f.mode ?? 'off'} onChange={set('mode')}>
          {MODE.map((m) => <option key={m.id} value={m.id}>{m.label}</option>)}
        </Select>
      </label>
      <p className="text-muted-foreground">{mode.hint} The figure is never the caller&apos;s guess: it is the county&apos;s value and what the seller said about the place, through the math below. Firm numbers still come from you at the house.</p>
      <div className="grid gap-2 sm:grid-cols-3">
        <label className="block">Repairs, cosmetic ($ per sq ft)<Input className="mt-1" inputMode="decimal" value={f.repair_light ?? ''} onChange={set('repair_light')} /></label>
        <label className="block">Repairs, mechanicals / kitchen ($ per sq ft)<Input className="mt-1" inputMode="decimal" value={f.repair_medium ?? ''} onChange={set('repair_medium')} /></label>
        <label className="block">Repairs, roof / structure / damage ($ per sq ft)<Input className="mt-1" inputMode="decimal" value={f.repair_heavy ?? ''} onChange={set('repair_heavy')} /></label>
      </div>
      <div>
        <p className="font-medium">Percent of value minus repairs, by value</p>
        <p className="text-xs text-muted-foreground">Rick: 70% under $120K; 75 to 80% above. The last row (no &quot;up to&quot;) covers everything higher.</p>
        <div className="mt-1 space-y-1">
          {bands.map((b, i) => (
            <div key={i} className="grid grid-cols-[1fr_1fr_auto] items-center gap-2">
              <Input placeholder="Up to ($), blank = and above" inputMode="decimal" value={b.upto} onChange={(e) => setBands((x) => x.map((y, j) => j === i ? { ...y, upto: e.target.value } : y))} />
              <Input placeholder="%" inputMode="decimal" value={b.pct} onChange={(e) => setBands((x) => x.map((y, j) => j === i ? { ...y, pct: e.target.value } : y))} />
              <Button variant="ghost" size="sm" onClick={() => setBands((x) => x.filter((_, j) => j !== i))}>Remove</Button>
            </div>
          ))}
          <Button variant="outline" size="sm" onClick={() => setBands((x) => [...x, { upto: '', pct: '' }])}>Add a band</Button>
        </div>
      </div>
      <div className="grid gap-2 sm:grid-cols-4">
        <label className="block">Anchor under that (%)<Input className="mt-1" inputMode="decimal" value={f.lao_discount ?? ''} onChange={set('lao_discount')} /></label>
        <label className="block">Size when unknown (sq ft)<Input className="mt-1" inputMode="decimal" value={f.default_sqft ?? ''} onChange={set('default_sqft')} /></label>
        <label className="block">Too thin to say, under ($)<Input className="mt-1" inputMode="decimal" value={f.min_number ?? ''} onChange={set('min_number')} /></label>
        <label className="block">Round down to ($)<Input className="mt-1" inputMode="decimal" value={f.round_to ?? ''} onChange={set('round_to')} /></label>
      </div>
      <div className="flex items-center gap-2">
        <Button onClick={() => void save()}>Save the offer rules</Button>
        {msg && <span className={msg === 'Saved.' ? 'text-emerald-700' : 'text-red-600'}>{msg}</span>}
      </div>
    </div>
  )
}
