// "Call coming in": a seller is calling a seller line and the app is open (Colin 2026-10-22: "if a lead
// calls in should the app ring or have a call coming in thing and then show the property card stuff").
// Shows the number, the owner and property the call desk matched (phone_lookup), and Accept / Decline.
// Accept runs the call in the in-call bar and opens the lead card with the call script; Decline leaves
// Colin's cell ringing as before. Nothing here while no call is ringing (and never outside DialerProvider).
// Rung in while she is on a call (2026-10-28): Accept says it ends the call she is on; a seller calling us comes first.
import { useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { PhoneIncoming } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { inboundLabel, pickInbound, useDialer } from '@/lib/dialer'
import { fmtPhone } from '@/lib/format'

export function IncomingCallBar() {
  const { incoming, active, accept, decline } = useDialer()
  const nav = useNavigate()
  const [busy, setBusy] = useState(false)
  if (!incoming) return null
  const m = incoming.matches
  const pick = pickInbound(m)
  const extra = m && m.length > 1 ? m.length - 1 : 0
  const who = m === null ? 'Looking them up...'
    : pick ? inboundLabel(incoming.from, m)
    : incoming.lookupError ? `Could not look them up: ${incoming.lookupError}`
    : 'Not in the list - a new caller'

  const onCall = incoming.busy && !!active && ['connecting', 'ringing', 'in_call'].includes(active.status)
  const take = async () => {
    setBusy(true)
    const r = await accept()
    setBusy(false)
    if (r?.leadId) nav(`/lead/${r.leadId}?call=1&phone=${r.phone}`)
  }

  return (
    <div role="alert" aria-live="assertive"
      className="pt-safe fixed inset-x-0 top-0 z-50 border-b-4 border-emerald-500 bg-emerald-50 shadow-lg">
      <div className="mx-auto flex max-w-5xl items-center gap-3 px-4 py-3">
        <PhoneIncoming className="h-7 w-7 shrink-0 animate-pulse text-emerald-700" aria-hidden />
        <div className="min-w-0 flex-1">
          <p className="text-xs font-semibold uppercase tracking-wide text-emerald-800">
            Call coming in{incoming.line ? ` on ${fmtPhone(incoming.line)}` : ''}{onCall ? ' while you are on a call: take it' : ''}
          </p>
          <p className="truncate text-lg font-semibold">{pick ? who : fmtPhone(incoming.from) || 'Withheld number'}</p>
          <p className="truncate text-sm text-muted-foreground">
            {pick ? fmtPhone(incoming.from) : who}
            {extra ? ` - ${extra} more lead${extra > 1 ? 's' : ''} with this number` : ''}
            {pick?.blocked ? ' - marked do not contact' : ''}
          </p>
        </div>
        <Button className="h-12 px-5 bg-emerald-600 text-white hover:bg-emerald-700" disabled={busy} onClick={() => void take()}>{onCall ? 'Hang up and answer' : 'Accept'}</Button>
        <Button className="h-12" variant="outline" disabled={busy} onClick={decline}>{onCall ? 'Let it go to Colin' : 'Decline'}</Button>
      </div>
    </div>
  )
}
