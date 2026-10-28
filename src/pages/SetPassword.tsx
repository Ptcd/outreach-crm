import { useState } from 'react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { useAuth } from '@/providers/AuthProvider'

const MIN_PASSWORD = 6   // the same as every team code (2026-10-28)

// Shown when the app is opened from the "set the app password" email.
export default function SetPassword() {
  const { setPassword } = useAuth()
  const [a, setA] = useState('')
  const [b, setB] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  const submit = async (e: React.FormEvent) => {
    e.preventDefault()
    if (a.length < MIN_PASSWORD) return setError(`Use at least ${MIN_PASSWORD} characters.`)
    if (a !== b) return setError('The two codes do not match.')
    setBusy(true)
    const { error } = await setPassword(a)
    setBusy(false)
    if (error) setError(error)
  }

  return (
    <div className="flex min-h-screen items-center justify-center bg-muted/40 px-4">
      <form onSubmit={submit} className="w-full max-w-sm space-y-3 rounded-lg border bg-card p-6 shadow-sm">
        <h1 className="text-2xl font-bold tracking-tight">Set Colin&apos;s code</h1>
        <p className="text-sm text-muted-foreground">
          The code Colin signs in with. Thalia and Adil have their own (Settings). At least {MIN_PASSWORD} characters.
        </p>
        <label className="block text-sm font-medium">
          New code
          <Input type="password" autoComplete="new-password" value={a} onChange={(e) => setA(e.target.value)} className="mt-1" />
        </label>
        <label className="block text-sm font-medium">
          Same again
          <Input type="password" autoComplete="new-password" value={b} onChange={(e) => setB(e.target.value)} className="mt-1" />
        </label>
        {error && <p className="text-sm text-red-700">{error}</p>}
        <Button type="submit" className="w-full" disabled={busy}>{busy ? 'Saving...' : 'Save code'}</Button>
      </form>
    </div>
  )
}
