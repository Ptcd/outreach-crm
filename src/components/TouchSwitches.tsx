import { Button } from '@/components/ui/button'
import { Badge, Empty, ErrorNote, Section } from '@/components/ui/form'
import { ConfirmButton } from '@/components/ui/confirm'
import { api, useTouchTemplates, useWrite } from '@/lib/queries'
import { fmtDateTime } from '@/lib/format'

/** The belts' texts, each behind its own switch (Colin only). Off: the stop becomes a draft for his tap. */
export function TouchSwitches({ canDecide }: { canDecide: boolean }) {
  const q = useTouchTemplates()
  const set = useWrite(({ key, on }: { key: string; on: boolean }) => api.setTouchTemplate(key, on), [['touch_templates']])
  return (
    <Section title="Follow-up texts the belts send">
      <p className="mb-2 text-sm text-muted-foreground">
        Each text is Colin in the first person: the street, a time or the thing they named, and the STOP line. Every switch starts off:
        with a switch off, that stop lands on Approve for your tap instead of going on its own (a morning-of reminder is skipped, so a booked
        call or visit never waits on a tap). Drafts marked &quot;always a draft&quot; wait for your tap whatever the switch says.
      </p>
      <ErrorNote error={q.error ?? set.error} />
      {q.data?.length === 0 && <Empty>No templates (migration 0029 not applied).</Empty>}
      <ul className="divide-y">
        {q.data?.map((t) => (
          <li key={t.key} className="py-3">
            <div className="flex flex-wrap items-center justify-between gap-2">
              <p className="font-medium">{t.label}</p>
              <div className="flex items-center gap-2">
                {!t.auto && <Badge>always a draft</Badge>}
                <Badge tone={t.enabled ? 'good' : 'muted'}>{t.enabled ? 'On' : 'Off'}</Badge>
              </div>
            </div>
            <p className="mt-1 rounded bg-muted p-2 text-sm">{t.wording}</p>
            {t.changed_at && <p className="text-xs text-muted-foreground">{t.enabled ? 'On' : 'Off'} since {fmtDateTime(t.changed_at)}{t.changed_by ? ` (${t.changed_by})` : ''}</p>}
            {canDecide && t.auto && (
              t.enabled
                ? <Button variant="outline" className="mt-2 h-11" disabled={set.isPending} onClick={() => set.mutate({ key: t.key, on: false })}>Turn off</Button>
                : <ConfirmButton className="mt-2 h-11" disabled={set.isPending} question={`Send "${t.label}" on its own, with this wording, when its stop comes?`} yes="Yes, turn on"
                    onConfirm={() => set.mutate({ key: t.key, on: true })}>Turn on</ConfirmButton>
            )}
          </li>
        ))}
      </ul>
    </Section>
  )
}
