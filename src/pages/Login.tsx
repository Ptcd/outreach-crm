import { useState } from 'react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { useAuth } from '@/providers/AuthProvider'

// One shared app password (Colin, 2026-10-21). No emails or user names to type.
export default function Login() {
  const { signInWithPassword, sendPasswordLink } = useAuth()
  const [password, setPw] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [linkSent, setLinkSent] = useState(false)

  const submit = async (e: React.FormEvent) => {
    e.preventDefault()
    setBusy(true)
    setError(null)
    const { error } = await signInWithPassword(password)
    setBusy(false)
    if (error) setError(error)
  }

  const [asking, setAsking] = useState(false)
  const forgot = async () => {
    setAsking(false)
    setBusy(true)
    const { error } = await sendPasswordLink()
    setBusy(false)
    if (error) setError(error)
    else setLinkSent(true)
  }

  return (
    <div className="flex min-h-screen items-center justify-center bg-muted/40 px-4">
      <div className="w-full max-w-sm rounded-lg border bg-card p-6 shadow-sm">
        <h1 className="mb-4 text-xl font-semibold">WPIE</h1>
        <form onSubmit={submit} className="space-y-3">
          <label className="block text-sm font-medium">
            App password
            <Input type="password" required autoComplete="current-password" className="mt-1 h-12 text-lg" value={password}
              onChange={(e) => setPw(e.target.value)} />
          </label>
          {error && <p className="text-sm text-red-700">{error}</p>}
          <Button type="submit" className="h-12 w-full text-base" disabled={busy || !password}>
            {busy ? 'Signing in...' : 'Sign in'}
          </Button>
        </form>
        {linkSent ? (
          <p className="mt-4 rounded bg-emerald-50 p-3 text-sm text-emerald-900">
            A link went to Colin&apos;s email. Open it, then choose the new password.
          </p>
        ) : (
          asking ? (
            <div className="mt-4 rounded-lg border border-amber-300 bg-amber-50 p-3 text-sm dark:border-amber-800 dark:bg-amber-950">
              <p>Email Colin a link to set a new app password?</p>
              <div className="mt-2 grid grid-cols-2 gap-2">
                <Button className="h-12" onClick={() => void forgot()} disabled={busy}>Yes, email it</Button>
                <Button className="h-12" variant="outline" onClick={() => setAsking(false)}>Cancel</Button>
              </div>
            </div>
          ) : (
            <button type="button" className="mt-4 min-h-11 text-sm text-muted-foreground underline" onClick={() => setAsking(true)} disabled={busy}>
              Set or reset the app password
            </button>
          )
        )}
      </div>
    </div>
  )
}
