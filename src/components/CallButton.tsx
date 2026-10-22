// "Call" on a lead card or a thread: places the call in the browser (lib/dialer). Disabled while a call is
// up, and never shown for a number the card flags (bad, do-not-contact, STOP, DNC list).
import { Button } from '@/components/ui/button'
import { callLabel, useDialer } from '@/lib/dialer'

export function CallButton(props: {
  to: string | null | undefined
  name?: string | null
  address?: string | null
  leadId: string | null
  contactId?: string | null
  blocked?: boolean
  size?: 'sm' | 'default'
  className?: string
}) {
  const { active, start, supported } = useDialer()
  const to = (props.to ?? '').trim()
  if (!to || props.blocked) return null
  const busy = !!active && (active.status === 'connecting' || active.status === 'ringing' || active.status === 'in_call')
  const title = !supported ? 'This browser cannot place calls; open the app in Chrome or Safari.' : undefined
  return (
    <Button size={props.size ?? 'sm'} className={props.className} disabled={busy || !supported} title={title}
      onClick={() => void start({ to, label: callLabel(props.name, props.address), leadId: props.leadId, contactId: props.contactId ?? null })}>
      Call
    </Button>
  )
}
