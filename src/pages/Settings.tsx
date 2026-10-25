// Settings: where each person sets the phone and email their hot pings go to, and turns on push
// notifications on this phone (Colin 2026-10-22: "Make a spot in settings to add emails for hot pings").
// On the shared login the person is whoever this phone is set to (migration 0040), so Thalia's email never
// lands on Colin's row.
import { useEffect, useState } from 'react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { ErrorNote, Section } from '@/components/ui/form'
import { NotifyPanel } from '@/components/NotifyPanel'
import { personAlerts, setPersonAlerts } from '@/lib/apiExtra'
import { OnPhonePrompt, useColinHere } from '@/components/OnPhonePicker'
import { AgentKeys } from '@/components/AgentKeys'
import { useOnPhone, workerFor } from '@/lib/onPhone'
import { personLabel } from '@/lib/wpie'
import { useAuth } from '@/providers/AuthProvider'

export default function Settings() {
  const { member } = useAuth()
  const [picked] = useOnPhone()
  const who = workerFor(member, picked)
  const colinHere = useColinHere()
  const [phone, setPhone] = useState('')
  const [email, setEmail] = useState('')
  const [loaded, setLoaded] = useState(false)
  const [busy, setBusy] = useState(false)
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null)
  const [err, setErr] = useState<Error | null>(null)

  useEffect(() => {
    if (!who) return
    let on = true
    setLoaded(false)
    setMsg(null)
    personAlerts(who).then((a) => {
      if (!on) return
      setPhone(a.alert_phone ?? '')
      setEmail(a.alert_email ?? '')
      setLoaded(true)
    }).catch((e) => on && setErr(e instanceof Error ? e : new Error(String(e))))
    return () => { on = false }
  }, [who])

  const save = async () => {
    setBusy(true)
    setMsg(null)
    try {
      if (!who) return
      const r = await setPersonAlerts(who, phone, email)
      setMsg(r.ok ? { ok: true, text: 'Saved. Hot pings now go to ' + [r.phone ? 'that phone' : '', r.email ? 'that email' : ''].filter(Boolean).join(' and ') + (r.phone || r.email ? '.' : 'nothing but this app.') }
        : { ok: false, text: r.reason ?? 'Not saved' })
    } catch (e) {
      setMsg({ ok: false, text: e instanceof Error ? e.message : String(e) })
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="space-y-4">
      <h1 className="text-2xl font-bold tracking-tight">Settings</h1>
      <OnPhonePrompt />
      <Section title={`Your alerts${who ? ` (${personLabel(who)})` : ''}`}>
        <p className="mb-3 text-sm text-muted-foreground">
          A hot reply pings you three ways at the same moment: a notification on this phone (turn it on below), a text to the number here,
          and an email to the address here. Set the email and the number you actually look at during your shift.
        </p>
        <ErrorNote error={err} />
        <div className="grid gap-3 sm:grid-cols-2">
          <label className="text-sm font-medium">
            Email for hot pings
            <Input type="email" inputMode="email" placeholder="you@example.com" className="mt-1 h-11" value={email}
              onChange={(e) => setEmail(e.target.value)} disabled={!who || (!loaded && !err)} />
          </label>
          <label className="text-sm font-medium">
            Phone for text pings
            <Input type="tel" inputMode="tel" placeholder="(414) 555-0100" className="mt-1 h-11" value={phone}
              onChange={(e) => setPhone(e.target.value)} disabled={!who || (!loaded && !err)} />
            <span className="mt-1 block text-xs font-normal text-muted-foreground">
              Texts go out from the office line, which only sends to numbers Colin has put on its list: tell him when you set or change this.
            </span>
          </label>
        </div>
        <div className="mt-3 flex items-center gap-3">
          <Button className="h-11" disabled={busy || !who || (!loaded && !err)} onClick={() => void save()}>{busy ? 'Saving...' : 'Save'}</Button>
          {msg && <p className={msg.ok ? 'text-sm font-medium text-emerald-700' : 'text-sm text-red-700'}>{msg.text}</p>}
        </div>
        {who === 'colin' && <p className="mt-3 text-xs text-muted-foreground">Colin: your cell gets every alert regardless; the email here adds an email copy.</p>}
      </Section>
      <Section title="Notifications on this phone">
        <NotifyPanel />
      </Section>
      {colinHere && (
        <Section title="Agent keys (Muse)">
          <AgentKeys />
        </Section>
      )}
    </div>
  )
}
