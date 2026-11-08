// Test the inbound assistant (Colin 2026-11-07: "give me a button to test you with Muse in the WPIE settings"). The
// button has Twilio call the number typed here and put the assistant on the line at once, no rings. Hold the phone to
// Muse's speaker and let Muse play the seller. Nothing touches a card: the call is marked test, and the transcript and
// what the assistant extracted appear below when it ends. Owner only (the function refuses anyone else).
import { useEffect, useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Badge, Empty, ErrorNote } from '@/components/ui/form'
import { supabase } from '@/lib/supabaseClient'
import { fmtDateTime, fmtPhone } from '@/lib/format'

type TestCall = { call_sid: string; from10: string | null; started_at: string; ended_at: string | null; seconds: number | null
  transcript: { role: string; text: string }[] | null; extraction: Record<string, unknown> | null; outcome: string }

const KEY = 'wpie.assistant_test_phone'

export function AssistantTest() {
  const [phone, setPhone] = useState(() => { try { return localStorage.getItem(KEY) ?? '' } catch { return '' } })
  const [busy, setBusy] = useState<'known' | 'unknown' | null>(null)
  const [msg, setMsg] = useState<string | null>(null)
  const [err, setErr] = useState<string | null>(null)
  const [watch, setWatch] = useState(false)
  const calls = useQuery({
    queryKey: ['assistant_test_calls'],
    refetchInterval: watch ? 8_000 : false,
    queryFn: async () => {
      const r = await supabase.from('voice_calls').select('call_sid, from10, started_at, ended_at, seconds, transcript, extraction, outcome')
        .eq('outcome', 'test').order('started_at', { ascending: false }).limit(5)
      if (r.error) throw new Error(r.error.message)
      return (r.data ?? []) as TestCall[]
    },
  })
  useEffect(() => { if (!watch) return; const t = setTimeout(() => setWatch(false), 6 * 60_000); return () => clearTimeout(t) }, [watch])

  const call = async (mode: 'known' | 'unknown') => {
    setBusy(mode); setMsg(null); setErr(null)
    try { localStorage.setItem(KEY, phone) } catch { /* fine */ }
    const r = await supabase.functions.invoke('reply-send', { body: { action: 'test_assistant', to: phone, mode } })
    const d = (r.data ?? {}) as { outcome?: string; reason?: string; to?: string }
    if (r.error || d.outcome !== 'calling') setErr(r.error?.message ?? d.reason ?? 'not placed')
    else { setMsg(`Calling ${fmtPhone(d.to ?? phone)}. Answer, then hold the phone to Muse's speaker. The transcript shows here when the call ends.`); setWatch(true) }
    setBusy(null)
  }

  return (
    <div className="space-y-3">
      <p className="text-sm text-muted-foreground">
        The assistant calls the number below and comes on the line at once, no rings. Let Muse play the seller through the speaker. Nothing touches a card; the call is a test and lands here.
      </p>
      <div className="flex flex-wrap items-end gap-2">
        <label className="text-sm font-medium">Call this phone
          <Input className="mt-1 h-10 w-44" inputMode="tel" placeholder="(414) 555-0100" value={phone} onChange={(e) => setPhone(e.target.value)} />
        </label>
        <Button className="h-10" disabled={!!busy || phone.replace(/\D/g, '').length < 10} onClick={() => call('known')}>{busy === 'known' ? 'Calling...' : 'Call me as a known seller'}</Button>
        <Button variant="outline" className="h-10" disabled={!!busy || phone.replace(/\D/g, '').length < 10} onClick={() => call('unknown')}>{busy === 'unknown' ? 'Calling...' : 'Call me as an unknown number'}</Button>
      </div>
      <p className="text-xs text-muted-foreground">Known seller: the assistant believes the card is Pat Tester at 123 Test St, West Bend, and says the address. Unknown number: it asks for the house, the town and a name.</p>
      {msg && <p className="text-sm">{msg}</p>}
      {err && <ErrorNote error={new Error(err)} />}
      <div className="space-y-2">
        <p className="text-sm font-semibold">Recent test calls</p>
        <ErrorNote error={calls.error} />
        {calls.data && calls.data.length === 0 && <Empty>No test calls yet.</Empty>}
        {(calls.data ?? []).map((c) => <TestCallCard key={c.call_sid} c={c} />)}
      </div>
    </div>
  )
}

function TestCallCard({ c }: { c: TestCall }) {
  const [open, setOpen] = useState(false)
  const x = c.extraction ?? {}
  const show = (k: string) => { const v = x[k]; return v === null || v === undefined || v === '' ? null : String(v) }
  return (
    <div className="rounded-2xl border bg-card p-3 shadow-[var(--shadow-soft)]">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <p className="text-sm font-medium">{fmtDateTime(c.started_at)} · {c.from10 ? fmtPhone(c.from10) : 'test'} · {c.seconds ?? 0}s</p>
        <div className="flex gap-1.5">
          {show('lane') && <Badge tone="info">lane {show('lane')}</Badge>}
          {x.stop === true && <Badge tone="bad">stop</Badge>}
          {x.wrong_person === true && <Badge tone="warn">wrong person</Badge>}
          {!c.extraction && <Badge tone="muted">nothing extracted</Badge>}
        </div>
      </div>
      {c.extraction && (
        <ul className="mt-2 grid gap-1 text-sm sm:grid-cols-2">
          {[['Who', 'caller_name'], ['House', 'property_address'], ['Town', 'municipality'], ['Why', 'why'], ['Condition', 'condition'], ['Who is there', 'who_there'], ['Timeline', 'timeline'],
            ['On the title', 'who_signs'], ['Their number', 'their_number'], ['Callback', 'callback_window'], ['Notes', 'notes']].map(([label, k]) => show(k) ? (
            <li key={k}><span className="text-muted-foreground">{label}:</span> {show(k)}</li>) : null)}
        </ul>
      )}
      <button type="button" className="mt-2 text-sm underline-offset-2 hover:underline" onClick={() => setOpen((v) => !v)}>{open ? 'Hide the transcript' : `Transcript (${c.transcript?.length ?? 0} turns)`}</button>
      {open && (
        <div className="mt-2 space-y-1 text-sm">
          {(c.transcript ?? []).map((t, i) => (
            <p key={i} className={t.role === 'agent' ? 'text-primary' : ''}><span className="text-muted-foreground">{t.role === 'agent' ? 'assistant' : 'seller'}:</span> {t.text}</p>
          ))}
        </div>
      )}
    </div>
  )
}
