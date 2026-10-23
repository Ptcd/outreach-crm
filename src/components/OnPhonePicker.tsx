// "Who's on this phone?" Asked once per phone on the shared login; shown in the header after that.
import { Button } from '@/components/ui/button'
import { Select } from '@/components/ui/form'
import { useAuth } from '@/providers/AuthProvider'
import { useOnPhone, workerFor, type OnPhone } from '@/lib/onPhone'

const WHO: { id: OnPhone; label: string }[] = [
  { id: 'thalia', label: 'Thalia' },
  { id: 'adil', label: 'Adil' },
  { id: 'colin', label: 'Colin' },
]

/** Colin's own controls (the sending switch, the visit override, his score, contracts, deals) show only when
 *  this phone is Colin's: on the shared login everyone is the owner account, so the phone's answer decides.
 *  A phone that has not answered yet is treated as Colin's, as before the picker. */
export function useColinHere(): boolean {
  const { isOwner } = useAuth()
  const [picked] = useOnPhone()
  return isOwner && (picked === 'colin' || picked === null)
}

/** The compact switch in the header. Hidden for a caller who has a login of their own. */
export function OnPhoneSwitch() {
  const { member } = useAuth()
  const [picked, pick] = useOnPhone()
  if (member?.role === 'caller') return null
  return (
    <Select aria-label="Who's on this phone" className="h-9 w-24 text-sm" value={picked ?? ''}
      onChange={(e) => e.target.value && pick(e.target.value as OnPhone)}>
      <option value="" disabled>Who?</option>
      {WHO.map((w) => <option key={w.id} value={w.id}>{w.label}</option>)}
    </Select>
  )
}

/** The one-time question at the top of Today, Calls and Settings until this phone has an answer. */
export function OnPhonePrompt() {
  const { member } = useAuth()
  const [picked, pick] = useOnPhone()
  if (workerFor(member, picked)) return null
  return (
    <div className="rounded-lg border-2 border-primary/50 bg-card p-3" data-testid="on-phone-prompt">
      <p className="font-medium">Who's on this phone?</p>
      <p className="text-sm text-muted-foreground">Pick once. The app remembers it on this phone and shows your list; change it any time at the top.</p>
      <div className="mt-2 grid grid-cols-3 gap-2">
        {WHO.map((w) => <Button key={w.id} className="h-12" variant="outline" onClick={() => pick(w.id)}>{w.label}</Button>)}
      </div>
    </div>
  )
}
