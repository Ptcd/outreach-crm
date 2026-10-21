import { useState } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Select, Textarea } from '@/components/ui/form'
import { api } from '@/lib/queries'
import { EMAIL_TEMPLATES } from '@/lib/wpie'

function firstName(owner: string | null | undefined): string {
  const w = (owner ?? '').trim().split(/\s+/)[0] ?? ''
  if (!w || /LLC|INC|TRUST|ESTATE|CORP/i.test(owner ?? '')) return 'there'
  return w.charAt(0).toUpperCase() + w.slice(1).toLowerCase()
}

// "Send email": pick a template, edit, tap Send. Sent from the Gmail sender, logged on the lead.
// Nothing here is written or sent by AI.
export function EmailComposer({ leadId, taskId, to: initialTo, ownerName, address, onDone }: {
  leadId: string | null
  taskId?: string | null
  to?: string | null
  ownerName?: string | null
  address?: string | null
  onDone?: () => void
}) {
  const qc = useQueryClient()
  const fill = (s: string) => s.replace(/\{first\}/g, firstName(ownerName)).replace(/\{address\}/g, address || 'your property')
  const [tpl, setTpl] = useState(EMAIL_TEMPLATES[0].id)
  const t = EMAIL_TEMPLATES.find((x) => x.id === tpl) ?? EMAIL_TEMPLATES[0]
  const [to, setTo] = useState(initialTo ?? '')
  const [subject, setSubject] = useState(fill(t.subject))
  const [body, setBody] = useState(fill(t.body))
  const [busy, setBusy] = useState(false)
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null)

  const pick = (id: string) => {
    const n = EMAIL_TEMPLATES.find((x) => x.id === id) ?? EMAIL_TEMPLATES[0]
    setTpl(id)
    setSubject(fill(n.subject))
    setBody(fill(n.body))
  }
  const send = async () => {
    setBusy(true)
    setMsg(null)
    const r = await api.sendEmail({ lead_id: leadId, task_id: taskId ?? null, to, subject, body })
    setBusy(false)
    if (r.error) setMsg({ ok: false, text: r.error.message })
    else {
      setMsg({ ok: true, text: `Sent to ${to}.` })
      void qc.invalidateQueries({ queryKey: ['tasks'] })
      void qc.invalidateQueries({ queryKey: ['lead'] })
      void qc.invalidateQueries({ queryKey: ['reply_waiting'] })
      onDone?.()
    }
  }

  return (
    <div className="mt-2 space-y-2 rounded-lg border p-3">
      <label className="block text-sm font-medium">Template
        <Select value={tpl} onChange={(e) => pick(e.target.value)} className="mt-1">
          {EMAIL_TEMPLATES.map((x) => <option key={x.id} value={x.id}>{x.label}</option>)}
        </Select>
      </label>
      <label className="block text-sm font-medium">To
        <Input type="email" inputMode="email" value={to} onChange={(e) => setTo(e.target.value)} placeholder="their@email.com" className="mt-1" />
      </label>
      <label className="block text-sm font-medium">Subject
        <Input value={subject} onChange={(e) => setSubject(e.target.value)} className="mt-1" />
      </label>
      <label className="block text-sm font-medium">Email
        <Textarea value={body} onChange={(e) => setBody(e.target.value)} rows={7} className="mt-1" />
      </label>
      <Button className="h-12 w-full sm:w-auto" disabled={busy || !to.trim()} onClick={() => void send()}>
        {busy ? 'Sending...' : 'Send email'}
      </Button>
      {msg && <p className={msg.ok ? 'text-sm font-medium text-emerald-700' : 'text-sm font-medium text-red-700'}>{msg.text}</p>}
    </div>
  )
}
