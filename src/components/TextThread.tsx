import { useEffect, useMemo, useRef, useState } from 'react'
import { Button } from '@/components/ui/button'
import { ErrorNote, Textarea } from '@/components/ui/form'
import { api, useWrite } from '@/lib/queries'
import { fmtDateTime, fmtPhone } from '@/lib/format'
import { textThreadOf } from '@/lib/textThread'
import { cn } from '@/lib/utils'
import type { Contact, Message, TwilioInbound } from '@/lib/types'

// The card's texts as a phone's message log (Colin 2026-10-24): theirs on the left, ours on the right, oldest at the
// top and the newest at the bottom, with the box to text them right under it (Adil: "unable to figure out where to
// send the text from"). A typed text goes from the number that texted them, through the same checks as an approved
// reply: no price or business name, nobody who opted out, held until morning in quiet hours.
export function TextThread({ leadId, phone, messages, inbound, closed }: {
  leadId: string; phone: Contact | null; messages: Message[]; inbound: TwilioInbound[]; closed: boolean
}) {
  const items = useMemo(() => textThreadOf(messages, inbound), [messages, inbound])
  const box = useRef<HTMLDivElement>(null)
  const [text, setText] = useState('')
  const [result, setResult] = useState<string | null>(null)
  useEffect(() => { if (box.current) box.current.scrollTop = box.current.scrollHeight }, [items.length])
  const send = useWrite((body: string) => api.sendCardText(leadId, phone!.value, body).then((r) => {
    if (!r.error) {
      const d = (r as { data?: { outcome: string; reason?: string } }).data
      setResult(d?.outcome === 'sent' ? 'Sent.' : d?.outcome === 'queued' ? `Held for the morning: ${d.reason ?? 'quiet hours'}.`
        : d?.outcome === 'dry_sent' ? 'Live sending is off, so it was only recorded.' : (d?.reason ?? d?.outcome ?? ''))
      setText('')
    }
    return r
  }), [['lead', leadId], ['inbox'], ['reply_drafts']])

  return (
    <section id="texts" className="scroll-mt-16 rounded-lg border bg-card">
      <h2 className="border-b px-3 py-2 text-sm font-semibold">Texts{phone ? ` with ${fmtPhone(phone.value)}` : ''}</h2>
      <div ref={box} className="max-h-[60vh] space-y-2 overflow-y-auto p-3" aria-label="Text messages, newest at the bottom">
        {items.length === 0 && <p className="text-sm text-muted-foreground">No texts yet.</p>}
        {items.map((t) => (
          <div key={t.key} className={cn('flex flex-col', t.mine ? 'items-end' : 'items-start')}>
            <p className={cn('max-w-[85%] whitespace-pre-wrap rounded-2xl px-3 py-2 text-sm',
              t.mine ? 'rounded-br-sm bg-blue-600 text-white' : 'rounded-bl-sm bg-muted text-foreground')}>{t.body || '(empty)'}</p>
            <span className="mt-0.5 px-1 text-[11px] text-muted-foreground">
              {fmtDateTime(t.at)}{!t.mine && phone && t.phone10 !== phone.value.replace(/\D/g, '').slice(-10) ? ` - from ${fmtPhone(t.phone10)}` : ''}
            </span>
          </div>
        ))}
      </div>
      {closed ? <p className="border-t px-3 py-2 text-sm text-muted-foreground">This card is closed: no texts.</p>
        : !phone ? <p className="border-t px-3 py-2 text-sm text-muted-foreground">No phone to text on this card.</p> : (
        <div className="space-y-2 border-t p-3">
          <Textarea value={text} onChange={(e) => { setText(e.target.value); setResult(null) }} rows={2}
            placeholder={`Text ${fmtPhone(phone.value)}`} aria-label="Your text" />
          <div className="flex items-center gap-2">
            <Button className="h-11 px-6" disabled={!text.trim() || send.isPending} onClick={() => send.mutate(text.trim())}>
              {send.isPending ? 'Sending...' : 'Send text'}
            </Button>
            {result && <span className="text-sm">{result}</span>}
          </div>
          {send.error && <ErrorNote error={send.error} />}
        </div>
      )}
    </section>
  )
}
