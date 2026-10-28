// Sign-in codes (Colin 2026-10-28: "a different password/key per person"). Colin sets Thalia's and Adil's here (the
// team-codes function makes their own accounts); anyone changes their own. The code goes straight to the sign-in
// service; nothing here keeps or shows it.
import { useState } from 'react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { supabase } from '@/lib/supabaseClient'
import { SIGN_IN_PEOPLE, teamCodeProblem } from '@/lib/teamCodes'
import { useAuth } from '@/providers/AuthProvider'

/** Colin only: set or reset Thalia's or Adil's code. */
export function TeamCodes() {
  const [codes, setCodes] = useState<Record<string, string>>({})
  const [msg, setMsg] = useState<Record<string, { ok: boolean; text: string }>>({})
  const [busy, setBusy] = useState<string | null>(null)
  const set = async (person: string) => {
    const code = codes[person] ?? ''
    const why = teamCodeProblem(code)
    if (why) { setMsg((m) => ({ ...m, [person]: { ok: false, text: why } })); return }
    setBusy(person)
    const r = await supabase.functions.invoke('team-codes', { body: { person, code } })
    setBusy(null)
    const d = r.data as { ok?: boolean; reason?: string } | null
    if (r.error || !d?.ok) { setMsg((m) => ({ ...m, [person]: { ok: false, text: d?.reason ?? r.error?.message ?? 'Not set' } })); return }
    setCodes((c) => ({ ...c, [person]: '' }))
    setMsg((m) => ({ ...m, [person]: { ok: true, text: 'Set. Tell them the code; they tap their name on the sign-in screen and type it once.' } }))
  }
  return (
    <div className="space-y-3 text-sm">
      <p className="text-muted-foreground">Each person signs in with their own code, so every call, package and callback is theirs. Their browser stays signed in after the first time.</p>
      {SIGN_IN_PEOPLE.filter((p) => p.person !== 'colin').map((p) => (
        <div key={p.person} className="space-y-1">
          <div className="grid gap-2 sm:grid-cols-[6rem_1fr_auto] sm:items-center">
            <span className="font-medium">{p.name}</span>
            <Input type="password" autoComplete="new-password" placeholder="New code (6+ characters)" className="h-11"
              value={codes[p.person] ?? ''} onChange={(e) => setCodes((c) => ({ ...c, [p.person]: e.target.value }))} aria-label={`${p.name}'s new code`} />
            <Button className="h-11" disabled={busy === p.person || !(codes[p.person] ?? '')} onClick={() => void set(p.person)}>
              {busy === p.person ? 'Setting...' : `Set ${p.name}'s code`}</Button>
          </div>
          {msg[p.person] && <p className={msg[p.person].ok ? 'text-emerald-700' : 'text-red-700'}>{msg[p.person].text}</p>}
        </div>
      ))}
    </div>
  )
}

/** Everyone: change the code you sign in with. */
export function MyCode() {
  const { setPassword, member } = useAuth()
  const [code, setCode] = useState('')
  const [again, setAgain] = useState('')
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null)
  const [busy, setBusy] = useState(false)
  const save = async () => {
    const why = teamCodeProblem(code)
    if (why) { setMsg({ ok: false, text: why }); return }
    if (code !== again) { setMsg({ ok: false, text: 'The two codes are not the same.' }); return }
    setBusy(true)
    const r = await setPassword(code)
    setBusy(false)
    if (r.error) { setMsg({ ok: false, text: r.error }); return }
    setCode(''); setAgain('')
    setMsg({ ok: true, text: 'Changed. Use the new code next time you sign in.' })
  }
  return (
    <div className="space-y-2 text-sm">
      <p className="text-muted-foreground">The code {member?.display_name ?? 'you'} sign{member?.display_name ? 's' : ''} in with.{member?.role === 'owner' ? ' This one is shared by every phone on your account.' : ''}</p>
      <div className="grid gap-2 sm:grid-cols-[1fr_1fr_auto]">
        <Input type="password" autoComplete="new-password" placeholder="New code (6+ characters)" className="h-11" value={code} onChange={(e) => setCode(e.target.value)} aria-label="New code" />
        <Input type="password" autoComplete="new-password" placeholder="Same code again" className="h-11" value={again} onChange={(e) => setAgain(e.target.value)} aria-label="New code again" />
        <Button className="h-11" disabled={busy || !code} onClick={() => void save()}>{busy ? 'Saving...' : 'Change my code'}</Button>
      </div>
      {msg && <p className={msg.ok ? 'text-emerald-700' : 'text-red-700'}>{msg.text}</p>}
    </div>
  )
}
