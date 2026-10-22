import { useState } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { Button } from '@/components/ui/button'
import { api, useHotAlerts } from '@/lib/queries'
import { fmtDateTime } from '@/lib/format'

const mins = (a: string, b: string | Date) => Math.max(0, Math.round((new Date(b).getTime() - new Date(a).getTime()) / 60_000))
const dur = (m: number) => (m < 60 ? `${m} min` : `${Math.floor(m / 60)} h ${m % 60} min`)

// A seller replied with interest: when it came in, whether Colin was texted, and speed to lead
// (reply -> first call, stamped by "Log this call" or the button here).
export function HotBanner({ leadId }: { leadId: string }) {
  const q = useHotAlerts(leadId)
  const qc = useQueryClient()
  const [busy, setBusy] = useState(false)
  const latest = q.data?.[0]
  if (!latest) return null
  const called = latest.called_at
  const mark = async () => {
    setBusy(true)
    await api.markCalled(leadId)
    setBusy(false)
    void qc.invalidateQueries({ queryKey: ['hot_alerts', leadId] })
  }
  return (
    <section className={called ? 'rounded-lg border border-emerald-300 bg-emerald-50 p-3' : 'rounded-lg border-2 border-red-400 bg-red-50 p-3'}>
      <p className="font-semibold">{latest.is_test ? 'TEST ' : ''}Hot reply {fmtDateTime(latest.created_at)}</p>
      <p className="mt-1 text-base">&ldquo;{latest.body}&rdquo;</p>
      {called ? (
        <p className="mt-1 text-sm font-medium text-emerald-800">Called {dur(mins(latest.created_at, called))} after the reply (speed to lead).</p>
      ) : (
        <div className="mt-2 flex flex-wrap items-center gap-2">
          <p className="text-sm font-medium text-red-800">Not called yet: {dur(mins(latest.created_at, new Date()))} since the reply.
            {latest.alert1_at ? ' Colin was texted.' : ''}{latest.alert2_at ? ' Reminder sent.' : ''}</p>
          <Button className="h-11" disabled={busy} onClick={() => void mark()}>I called them</Button>
        </div>
      )}
    </section>
  )
}
