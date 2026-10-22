// Settings: where each team member sets the phone and email their hot pings go to, and turns on push
// notifications on this phone (Colin 2026-10-22: "Make a spot in settings to add emails for hot pings").
import { useEffect, useState } from 'react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { ErrorNote, Section } from '@/components/ui/form'
import { NotifyPanel } from '@/components/NotifyPanel'
import { myAlerts, setMyAlerts } from '@/lib/apiExtra'
import { useAuth } from '@/providers/AuthProvider'

export default function Settings() {
  const { member, isOwner } = useAuth()
  const [phone, setPhone] = useState('')
  const [email, setEmail] = useState('')
  const [loaded, setLoaded] = useState(false)
  const [busy, setBusy] = useState(false)
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null)
  const [err, setErr] = useState<Error | null>(null)

  useEffect(() => {
    if (!member?.email) return
    let on = true
    myAlerts(member.email).then((a) => {
      if (!on) return
      setPhone(a.alert_phone ?? '')
      setEmail(a.alert_email ?? '')
      setLoaded(true)
    }).catch((e) => on && setErr(e instanceof Error ? e : new Error(String(e))))
    return () => { on = false }
  }, [member?.email])

  const save = async () => {
    setBusy(true)
    setMsg(null)
    try {
      const r = await setMyAlerts(phone, email)
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
      <h1 className="text-xl font-semibold">Settings</h1>
      <Section title={`Your alerts${member ? ` (${member.display_name})` : ''}`}>
        <p className="mb-3 text-sm text-muted-foreground">
          A hot reply pings you three ways at the same moment: a notification on this phone (turn it on below), a text to the number here,
          and an email to the address here. Set the email and the number you actually look at during your shift.
        </p>
        <ErrorNote error={err} />
        <div className="grid gap-3 sm:grid-cols-2">
          <label className="text-sm font-medium">
            Email for hot pings
            <Input type="email" inputMode="email" placeholder="you@example.com" className="mt-1 h-11" value={email}
              onChange={(e) => setEmail(e.target.value)} disabled={!loaded && !err} />
          </label>
          <label className="text-sm font-medium">
            Phone for text pings
            <Input type="tel" inputMode="tel" placeholder="(414) 555-0100" className="mt-1 h-11" value={phone}
              onChange={(e) => setPhone(e.target.value)} disabled={!loaded && !err} />
            <span className="mt-1 block text-xs font-normal text-muted-foreground">
              Texts go out from the office line, which only sends to numbers Colin has put on its list: tell him when you set or change this.
            </span>
          </label>
        </div>
        <div className="mt-3 flex items-center gap-3">
          <Button className="h-11" disabled={busy || (!loaded && !err)} onClick={() => void save()}>{busy ? 'Saving...' : 'Save'}</Button>
          {msg && <p className={msg.ok ? 'text-sm font-medium text-emerald-700' : 'text-sm text-red-700'}>{msg.text}</p>}
        </div>
        {isOwner && <p className="mt-3 text-xs text-muted-foreground">Colin: your cell gets every alert regardless; the email here adds an email copy.</p>}
      </Section>
      <Section title="Notifications on this phone">
        <NotifyPanel />
      </Section>
    </div>
  )
}
