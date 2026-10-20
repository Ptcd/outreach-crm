import { useState } from 'react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { useAuth } from '@/providers/AuthProvider'

export default function Login() {
  const { sendMagicLink } = useAuth()
  const [email, setEmail] = useState('')
  const [sent, setSent] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  const submit = async (e: React.FormEvent) => {
    e.preventDefault()
    setBusy(true)
    setError(null)
    const { error } = await sendMagicLink(email)
    setBusy(false)
    if (error) setError(error)
    else setSent(true)
  }

  return (
    <div className="flex min-h-screen items-center justify-center bg-muted/40 px-4">
      <div className="w-full max-w-sm rounded-lg border bg-card p-6 shadow-sm">
        <h1 className="mb-1 text-xl font-semibold">WPIE</h1>
        <p className="mb-4 text-sm text-muted-foreground">Sign in with your email. We send you a link; no password.</p>
        {sent ? (
          <p className="rounded bg-emerald-50 p-3 text-sm text-emerald-900">
            Check your email for the sign-in link. Open it on this device.
          </p>
        ) : (
          <form onSubmit={submit} className="space-y-3">
            <label className="block text-sm font-medium">
              Email
              <Input
                type="email"
                required
                autoComplete="email"
                value={email}
                onChange={(e) => setEmail(e.target.value)}
                className="mt-1"
              />
            </label>
            {error && <p className="text-sm text-red-700">{error}</p>}
            <Button type="submit" className="w-full" disabled={busy}>
              {busy ? 'Sending...' : 'Email me a sign-in link'}
            </Button>
          </form>
        )}
      </div>
    </div>
  )
}
