// Test the inbound assistant (Colin 2026-11-07: "give me a button to test you with Muse in the WPIE settings"). The
// buttons place a call from this browser's own softphone straight to the assistant (no phone number, no rings), so the
// laptop's speaker and microphone are the call and Muse, in voice mode on Colin's phone, plays the seller. Nothing touches a card: the call is marked test, and the transcript and
// what the assistant extracted appear below when it ends. Owner only (the function refuses anyone else).
import { useEffect, useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { Button } from '@/components/ui/button'
import { Badge, Empty, ErrorNote } from '@/components/ui/form'
import { supabase } from '@/lib/supabaseClient'
import { useDialer } from '@/lib/dialer'
import { fmtDateTime, fmtPhone } from '@/lib/format'

type TestCall = { call_sid: string; from10: string | null; started_at: string; ended_at: string | null; seconds: number | null
  transcript: { role: string; text: string }[] | null; extraction: Record<string, unknown> | null; outcome: string; events: { at: number; type: string; detail?: string }[] | null }

export function AssistantTest() {
  const dialer = useDialer()
  const [watch, setWatch] = useState(false)
  const [note, setNote] = useState<string | null>(null)
  const calls = useQuery({
    queryKey: ['assistant_test_calls'],
    refetchInterval: watch ? 8_000 : false,
    queryFn: async () => {
      const r = await supabase.from('voice_calls').select('call_sid, from10, started_at, ended_at, seconds, transcript, extraction, outcome, events')
        .eq('outcome', 'test').order('started_at', { ascending: false }).limit(5)
      if (r.error) throw new Error(r.error.message)
      return (r.data ?? []) as TestCall[]
    },
  })
  useEffect(() => { if (!watch) return; const t = setTimeout(() => setWatch(false), 6 * 60_000); return () => clearTimeout(t) }, [watch])
  const busy = !!dialer.active && ['connecting', 'ringing', 'in_call'].includes(dialer.active.status)
  const run = async (mode: 'known' | 'unknown') => {
    setNote('Connecting. When the assistant greets, hold the phone with Muse in voice mode up to this speaker and let Muse answer. Hang up from the call bar when done; the transcript shows here.')
    setWatch(true)
    await dialer.testAssistant(mode)
  }
  return (
    <div className="space-y-3">
      <p className="text-sm text-muted-foreground">
        Runs right here in the browser: this device's speaker and microphone are the call. Tap a button, then put your phone with Muse in voice mode next to it and let Muse play the seller. Nothing touches a card; the call is a test and lands below when it ends.
      </p>
      {!dialer.supported && <ErrorNote error={new Error('This browser cannot place calls (no microphone access or WebRTC). Open the app in Chrome on the laptop.')} />}
      <div className="flex flex-wrap items-center gap-2">
        <Button className="h-10" disabled={busy || !dialer.supported} onClick={() => void run('known')}>{busy ? 'On the call...' : 'Start as a known seller'}</Button>
        <Button variant="outline" className="h-10" disabled={busy || !dialer.supported} onClick={() => void run('unknown')}>{busy ? 'On the call...' : 'Start as an unknown number'}</Button>
        {busy && <Button variant="outline" className="h-10" onClick={() => dialer.hangUp()}>Hang up</Button>}
      </div>
      <p className="text-xs text-muted-foreground">Known seller: the assistant believes the card is Pat Tester at 123 Test St, West Bend, and says the address. Unknown number: it asks for the house, the town and a name.</p>
      {note && <p className="text-sm">{note}</p>}
      {dialer.active?.error && <ErrorNote error={new Error(dialer.active.error)} />}
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
  const [events, setEvents] = useState(false)
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
      <div className="mt-2 flex gap-3">
        <button type="button" className="text-sm underline-offset-2 hover:underline" onClick={() => setOpen((v) => !v)}>{open ? 'Hide the transcript' : `Transcript (${c.transcript?.length ?? 0} turns)`}</button>
        <button type="button" className="text-sm underline-offset-2 hover:underline" onClick={() => setEvents((v) => !v)}>{events ? 'Hide what happened' : `What happened (${c.events?.length ?? 0} events)`}</button>
      </div>
      {open && (
        <div className="mt-2 space-y-1 text-sm">
          {(c.transcript ?? []).map((t, i) => (
            <p key={i} className={t.role === 'agent' ? 'text-primary' : ''}><span className="text-muted-foreground">{t.role === 'agent' ? 'assistant' : 'seller'}:</span> {t.text}</p>
          ))}
        </div>
      )}
      {events && (
        <div className="mt-2 max-h-72 space-y-0.5 overflow-y-auto font-mono text-[11px]">
          {(c.events ?? []).map((e, i) => (
            <p key={i}><span className="text-muted-foreground">{(e.at / 1000).toFixed(1)}s</span> {e.type}{e.detail ? `: ${e.detail}` : ''}</p>
          ))}
          {!c.events?.length && <p className="text-muted-foreground">No events recorded (the call predates the log).</p>}
        </div>
      )}
    </div>
  )
}
