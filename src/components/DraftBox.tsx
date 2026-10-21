import { useState } from 'react'
import { Button } from '@/components/ui/button'
import { Badge, ErrorNote, Textarea } from '@/components/ui/form'
import { api, useWrite } from '@/lib/queries'
import { fmtDateTime, fmtPhone } from '@/lib/format'
import { DRAFT_LABEL, DRAFT_OPEN, intentText } from '@/lib/inbox'
import { useAuth } from '@/providers/AuthProvider'
import type { ReplyDraft } from '@/lib/types'

const KIND_LABEL: Record<ReplyDraft['kind'], string> = {
  removal: 'Removal - phone blocked',
  routine: 'Routine - Sam can answer',
  candidate: 'Real reply - needs you',
}

// One text from a seller and Sam's answer. Approve sends Colin's final wording (he can edit);
// nothing here sends without his tap, except routine lines when he has turned those on.
export function DraftBox({ d, showFrom = false }: { d: ReplyDraft; showFrom?: boolean }) {
  const { isOwner } = useAuth()
  const [text, setText] = useState(d.body ?? '')
  const [result, setResult] = useState<string | null>(null)
  const keys = [['inbox'], ['reply_drafts'], ['reply_waiting']]
  const act = useWrite(({ action, body }: { action: 'approve' | 'skip'; body?: string }) =>
    api.replyAction(d.id, action, body).then((r) => {
      if (!r.error) setResult(action === 'skip' ? 'Skipped.' : outcomeText((r as { data?: { outcome: string; reason?: string } }).data))
      return r
    }), keys)
  const open = DRAFT_OPEN.includes(d.status)
  const tone = d.status === 'awaiting_approval' ? 'warn' : d.status === 'sent' ? 'good'
    : d.status === 'failed' || d.status === 'uncertain' ? 'bad' : 'muted'

  return (
    <div className="mt-3 rounded-md border border-amber-200 bg-amber-50/60 p-2 text-sm">
      <div className="flex flex-wrap items-center gap-1.5">
        <Badge tone={d.kind === 'candidate' ? 'warn' : d.kind === 'removal' ? 'bad' : 'info'}>{KIND_LABEL[d.kind]}</Badge>
        <Badge tone={tone}>{DRAFT_LABEL[d.status]}</Badge>
        {d.intent && <span className="text-xs text-muted-foreground">Sam read it as: {intentText(d.intent)}</span>}
      </div>
      {showFrom && (
        <p className="mt-1 text-xs text-muted-foreground">From {fmtPhone(d.phone10)} to {fmtPhone(d.our_number)} - {fmtDateTime(d.inbound_at)}</p>
      )}
      {showFrom && d.inbound_body && <p className="mt-1 whitespace-pre-wrap rounded bg-muted p-2">{d.inbound_body}</p>}
      {d.status === 'sent' && d.sent_body && <p className="mt-1 whitespace-pre-wrap">Sent: {d.sent_body}</p>}
      {d.status === 'queued' && d.send_after && <p className="mt-1 text-xs">Goes out {fmtDateTime(d.send_after)} (quiet hours).</p>}
      {open && isOwner && (
        <div className="mt-2 space-y-2">
          <label className="block text-xs font-medium text-muted-foreground">
            {d.body ? (d.kind === 'candidate' ? "Sam's draft - edit if you like" : 'Fixed reply') : 'No draft - write the reply'}
            <Textarea value={text} onChange={(e) => setText(e.target.value)} rows={3} className="mt-1" />
          </label>
          <div className="flex flex-wrap gap-2">
            <Button disabled={act.isPending || !text.trim()} onClick={() => act.mutate({ action: 'approve', body: text })}>
              Approve &amp; send
            </Button>
            <Button variant="outline" disabled={act.isPending} onClick={() => act.mutate({ action: 'skip' })}>Skip</Button>
          </div>
        </div>
      )}
      {result && <p className="mt-1 text-xs font-medium">{result}</p>}
      <ErrorNote error={act.error} />
    </div>
  )
}

function outcomeText(d?: { outcome: string; reason?: string }): string {
  if (!d) return ''
  if (d.outcome === 'sent') return 'Sent.'
  if (d.outcome === 'dry_sent') return 'Approved. Live sending is off, so it was recorded as "would send".'
  if (d.outcome === 'queued') return `Approved. ${d.reason ?? 'It goes out in the morning.'}`
  return d.reason ?? d.outcome
}
