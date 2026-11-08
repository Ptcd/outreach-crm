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

type SimRun = { id: number; persona: string; name: string | null; passed: boolean; checks: { name: string; ok: boolean; detail?: string }[]; seconds: number | null; created_at: string
  transcript: { role: string; text: string }[] | null; extraction: Record<string, unknown> | null; prompt_version: string | null }

/** The simulator (2026-11-07): twenty sellers played by the model against the real assistant, each run graded by machine. */
export function AssistantSimulator() {
  const [personas, setPersonas] = useState<{ id: string; name: string }[]>([])
  const [running, setRunning] = useState<string | null>(null)
  const [progress, setProgress] = useState<string | null>(null)
  const runs = useQuery({
    queryKey: ['voice_sim_runs'],
    queryFn: async () => {
      const r = await supabase.from('voice_sim_runs').select('id, persona, name, passed, checks, seconds, created_at, transcript, extraction, prompt_version').order('created_at', { ascending: false }).limit(60)
      if (r.error) throw new Error(r.error.message)
      return (r.data ?? []) as SimRun[]
    },
  })
  useEffect(() => {
    fetch(`${import.meta.env.VITE_SUPABASE_URL}/functions/v1/voice-agent?personas=1`).then((r) => r.json()).then((j) => setPersonas(j.personas ?? [])).catch(() => setPersonas([]))
  }, [])
  const latest = new Map<string, SimRun>()
  for (const r of runs.data ?? []) if (!latest.has(r.persona)) latest.set(r.persona, r)
  const runOne = async (id: string) => {
    const r = await supabase.functions.invoke('reply-send', { body: { action: 'simulate_assistant', persona: id } })
    await runs.refetch()
    return r
  }
  const runAll = async () => {
    setRunning('all')
    for (let i = 0; i < personas.length; i++) {
      setProgress(`${i + 1} of ${personas.length}: ${personas[i].name}`)
      await runOne(personas[i].id)
    }
    setProgress(null); setRunning(null)
  }
  const passed = Array.from(latest.values()).filter((r) => r.passed).length
  return (
    <div className="space-y-3">
      <p className="text-sm text-muted-foreground">
        Twenty sellers played by the model against the real assistant, no phones: the hostile one, the estate, the one who demands a price, the one who will not give one, the wrong number, the Spanish speaker. Each run is graded: never a money figure, the lane the sheet gives, the flags, the answers captured, a clean ending. About a minute a persona.
      </p>
      <div className="flex flex-wrap items-center gap-2">
        <Button className="h-10" disabled={!!running || !personas.length} onClick={() => void runAll()}>{running === 'all' ? 'Running...' : 'Run all twenty'}</Button>
        {latest.size > 0 && <Badge tone={passed === latest.size ? 'good' : 'warn'}>{passed} of {latest.size} passing</Badge>}
        {progress && <span className="text-sm text-muted-foreground">{progress}</span>}
      </div>
      <ErrorNote error={runs.error} />
      <ul className="space-y-2">
        {personas.map((p) => {
          const r = latest.get(p.id)
          return <SimRow key={p.id} name={p.name} run={r} busy={!!running} onRun={async () => { setRunning(p.id); await runOne(p.id); setRunning(null) }} />
        })}
      </ul>
    </div>
  )
}

function SimRow({ name, run, busy, onRun }: { name: string; run?: SimRun; busy: boolean; onRun: () => Promise<unknown> }) {
  const [open, setOpen] = useState(false)
  const failed = run?.checks.filter((c) => !c.ok) ?? []
  return (
    <li className="rounded-2xl border bg-card p-3 shadow-[var(--shadow-soft)]">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div className="min-w-0">
          <p className="text-sm font-medium">{name}</p>
          {run ? <p className="text-xs text-muted-foreground">{fmtDateTime(run.created_at)} · {run.seconds ?? 0}s · prompt {run.prompt_version ?? '?'}</p> : <p className="text-xs text-muted-foreground">not run yet</p>}
        </div>
        <div className="flex items-center gap-1.5">
          {run && <Badge tone={run.passed ? 'good' : 'bad'}>{run.passed ? 'pass' : `${failed.length} failing`}</Badge>}
          <Button variant="outline" size="sm" disabled={busy} onClick={() => void onRun()}>Run</Button>
          {run && <button type="button" className="text-sm underline-offset-2 hover:underline" onClick={() => setOpen((v) => !v)}>{open ? 'Hide' : 'Details'}</button>}
        </div>
      </div>
      {run && failed.length > 0 && !open && <p className="mt-1 text-xs text-destructive">{failed.map((c) => `${c.name}${c.detail ? ` (${c.detail})` : ''}`).join(' · ')}</p>}
      {run && open && (
        <div className="mt-2 space-y-2 text-sm">
          <ul className="grid gap-0.5 sm:grid-cols-2">{run.checks.map((c, i) => <li key={i} className={c.ok ? '' : 'text-destructive'}>{c.ok ? '✓' : '✗'} {c.name}{c.detail ? <span className="text-muted-foreground"> · {c.detail}</span> : null}</li>)}</ul>
          <div className="space-y-1">{(run.transcript ?? []).map((t, i) => <p key={i} className={t.role === 'agent' ? 'text-primary' : ''}><span className="text-muted-foreground">{t.role === 'agent' ? 'assistant' : 'seller'}:</span> {t.text}</p>)}</div>
        </div>
      )}
    </li>
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
