// "Call" on a lead card or a thread: places the call in the browser (lib/dialer). Disabled while a call is
// up, and never shown for a number the card flags (bad, do-not-contact, STOP, DNC list).
import { Button } from '@/components/ui/button'
import { callLabel, useDialer } from '@/lib/dialer'
import { callAttemptKey, humanCallAuthorized, outboundCallWaits, personalCallControlHidden } from '@/lib/callAttempt'
import { api } from '@/lib/queries'
import { useQueryClient } from '@tanstack/react-query'
import { useState } from 'react'

export function CallButton(props: {
  to: string | null | undefined
  name?: string | null
  address?: string | null
  leadId: string | null
  contactId?: string | null
  blocked?: boolean
  notBefore?: string | null
  size?: 'sm' | 'default'
  className?: string
}) {
  const { active, start, supported } = useDialer()
  const to = (props.to ?? '').trim()
  if (!to || props.blocked || outboundCallWaits(props.notBefore)) return null
  const busy = !!active && (active.status === 'connecting' || active.status === 'ringing' || active.status === 'in_call')
  const title = !supported ? 'This browser cannot place calls; open the app in Chrome or Safari.' : undefined
  return (
    <Button size={props.size ?? 'sm'} className={props.className} disabled={busy || !supported} title={title}
      onClick={() => void start({ to, label: callLabel(props.name, props.address), leadId: props.leadId, contactId: props.contactId ?? null })}>
      Call
    </Button>
  )
}

/** Explicit takeover for a call placed outside the browser. It uses the same database door as Call. */
export function PersonalCallButton(props: {
  to: string
  leadId: string
  blocked?: boolean
  notBefore?: string | null
  activeKey?: string | null
  size?: 'sm' | 'default'
}) {
  const qc = useQueryClient()
  const [busy, setBusy] = useState(false)
  const [message, setMessage] = useState<string | null>(null)
  // A new outbound start waits for the seller's date. An already-active attempt must
  // keep its recovery control visible so the caller can resume automation safely.
  if (personalCallControlHidden(props.blocked, props.activeKey, props.notBefore)) return null
  const refresh = async () => {
    await Promise.all([
      qc.invalidateQueries({ queryKey: ['lead', props.leadId] }),
      qc.invalidateQueries({ queryKey: ['seller_recovery_queue'] }),
      qc.invalidateQueries({ queryKey: ['cards_no_stop'] }),
    ])
  }
  const begin = async () => {
    setBusy(true); setMessage(null)
    const r = await api.beginHumanCall(props.leadId, props.to, 'personal', callAttemptKey())
    const d = r.data as { ok?: boolean; paused?: boolean; reason?: string } | null
    setBusy(false)
    if (r.error || !humanCallAuthorized(d)) { setMessage(r.error?.message ?? d?.reason ?? 'Call not paused'); return }
    setMessage('Automated follow-ups paused. Log the call outcome when you finish.')
    await refresh()
  }
  const resume = async () => {
    if (!props.activeKey) return
    setBusy(true); setMessage(null)
    const r = await api.resumeHumanCall(props.leadId, props.activeKey)
    const d = r.data as { ok?: boolean; reason?: string } | null
    setBusy(false)
    if (r.error || !d?.ok) { setMessage(r.error?.message ?? d?.reason ?? 'Could not resume'); return }
    setMessage('The original follow-up is active again.')
    await refresh()
  }
  return (
    <span className="inline-flex flex-col items-start gap-1">
      <Button size={props.size ?? 'sm'} variant="outline" disabled={busy}
        onClick={() => void (props.activeKey ? resume() : begin())}>
        {busy ? 'Saving...' : props.activeKey ? 'Call did not happen — resume' : 'Calling on personal phone'}
      </Button>
      {message && <span className="max-w-64 text-xs text-muted-foreground">{message}</span>}
    </span>
  )
}
