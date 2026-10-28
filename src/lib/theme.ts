// Light or dark (Colin 2026-10-28: "can you make a dark mode"). A choice per browser, Light by default: it never follows
// the phone's own setting, which is what made text unreadable on 2026-10-21. The class goes on <html> before the first
// paint (main.tsx), so the page never flashes the other way.
import { useEffect, useState } from 'react'

export type Theme = 'light' | 'dark'
const KEY = 'wpie.theme'
const EVENT = 'wpie-theme'

export function getTheme(): Theme {
  try { return globalThis.localStorage?.getItem(KEY) === 'dark' ? 'dark' : 'light' } catch { return 'light' }
}

export function applyTheme(t: Theme) {
  const root = globalThis.document?.documentElement
  if (!root) return
  root.classList.toggle('dark', t === 'dark')
  root.style.colorScheme = t
  globalThis.document?.querySelector('meta[name="theme-color"]')?.setAttribute('content', t === 'dark' ? '#0b1020' : '#f5f6fb')
}

export function setTheme(t: Theme) {
  try { globalThis.localStorage?.setItem(KEY, t) } catch { /* private window: this visit only */ }
  applyTheme(t)
  globalThis.dispatchEvent?.(new Event(EVENT))
}

export function useTheme(): [Theme, (t: Theme) => void] {
  const [t, setT] = useState<Theme>(getTheme)
  useEffect(() => {
    const on = () => setT(getTheme())
    globalThis.addEventListener?.(EVENT, on)
    globalThis.addEventListener?.('storage', on)
    return () => { globalThis.removeEventListener?.(EVENT, on); globalThis.removeEventListener?.('storage', on) }
  }, [])
  return [t, setTheme]
}
