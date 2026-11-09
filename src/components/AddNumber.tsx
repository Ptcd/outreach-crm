import { useState } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { api } from '@/lib/queries'
import { fmtPhone } from '@/lib/format'

// A number the seller gives on a call (Adil 2026-11-08: "when they're dialing they can add another phone number to the
// card easily that's a good contact number for the person and a spot for their name"). Before this it went into the
// remark ("Interested 9209053042 Adam's phone number", Hayes Street 10/29), where nothing could dial or text it.
// Saved through contact_add (0172), the card page's own door: ten digits, never a duplicate, the name as whose it is, a
// note that it was given on a call. Then one tap makes it the number the big Dial button calls next.
export function AddNumber({ leadId, live, onAdded }: { leadId: string; live?: boolean; onAdded?: (phone10: string, name: string | null) => void }) {
  const qc = useQueryClient()
  const [open, setOpen] = useState(false)
  const [value, setValue] = useState('')
  const [who, setWho] = useState('')
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState<string | null>(null)
  const [saved, setSaved] = useState<{ phone10: string; name: string | null } | null>(null)
  const digits = value.replace(/\D/g, '').replace(/^1(?=\d{10}$)/, '')
  const ok = /^\d{10}$/.test(digits)

  const save = async () => {
    if (!ok || busy) return
    setBusy(true); setErr(null)
    const r = await api.contactAdd(leadId, 'phone', digits, who.trim() || null, 'given on a call')
    setBusy(false)
    const d = r.data as { ok?: boolean; reason?: string } | null
    if (r.error || d?.ok === false) { setErr(r.error?.message ?? d?.reason ?? 'Not saved'); return }
    setSaved({ phone10: digits, name: who.trim() || null })
    setValue(''); setWho(''); setOpen(false)
    for (const k of [['lead', leadId], ['power_dial'], ['card_brief', leadId]]) void qc.invalidateQueries({ queryKey: k })
  }

  if (saved) {
    return (
      <div className="flex flex-wrap items-center gap-2 rounded-md border border-emerald-300 bg-emerald-50 p-2 text-sm dark:bg-emerald-950/30">
        <span className="flex-1">Added {fmtPhone(saved.phone10)}{saved.name ? ` (${saved.name})` : ''} to the card.</span>
        {onAdded && <Button size="sm" onClick={() => { onAdded(saved.phone10, saved.name); setSaved(null) }}>{live ? 'Dial it after this call' : 'Dial it next'}</Button>}
        <Button size="sm" variant="ghost" onClick={() => setSaved(null)}>OK</Button>
      </div>
    )
  }
  if (!open) {
    return <button type="button" className="text-left text-xs text-muted-foreground underline underline-offset-2" onClick={() => setOpen(true)}>Add a number they gave you</button>
  }
  return (
    <div className="space-y-1 rounded-md border bg-muted/40 p-2">
      <div className="flex flex-wrap items-center gap-2">
        <Input type="tel" inputMode="tel" autoFocus value={value} onChange={(e) => setValue(e.target.value)} placeholder="(920) 555-0100" aria-label="The number they gave" className="h-10 w-40"
          onKeyDown={(e) => { if (e.key === 'Enter') void save() }} />
        <Input value={who} onChange={(e) => setWho(e.target.value)} placeholder="Whose it is (name)" aria-label="Whose number it is" className="h-10 w-44"
          onKeyDown={(e) => { if (e.key === 'Enter') void save() }} />
        <Button className="h-10" disabled={!ok || busy} onClick={() => void save()}>Save to card</Button>
        <Button className="h-10" variant="ghost" onClick={() => { setOpen(false); setErr(null) }}>Cancel</Button>
      </div>
      <p className="text-xs text-muted-foreground">Their cell, a son or daughter, the person who handles the house: the number and whose it is. It goes on the card with your name and today.</p>
      {err && <p className="text-sm text-red-700">{err}</p>}
    </div>
  )
}
