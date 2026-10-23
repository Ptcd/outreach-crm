// Who is on this phone (2026-10-22 evening). Everyone signs in with the one app password, and that account
// is Colin's, so the app asks each phone once who is working it and remembers the answer on that phone.
// It decides whose list the Calls page and Today show and whose alerts Settings edits. A caller with a
// login of their own is always themself.
import { useEffect, useState } from 'react'
import type { Person } from './types'

export type OnPhone = Person
export type TaskOwner = Person | 'callers' | 'all'
const KEY = 'wpie.on_phone'
const EVENT = 'wpie-on-phone'

const valid = (v: unknown): v is OnPhone => v === 'thalia' || v === 'adil' || v === 'colin'

export function readOnPhone(): OnPhone | null {
  try {
    const v = globalThis.localStorage?.getItem(KEY)
    return valid(v) ? v : null
  } catch {
    return null
  }
}

export function writeOnPhone(p: OnPhone) {
  try { globalThis.localStorage?.setItem(KEY, p) } catch { /* private window: this visit only */ }
  memory = p
  globalThis.dispatchEvent?.(new Event(EVENT))
}

let memory: OnPhone | null = null

/** The person this phone is working as: a caller login is that caller; the shared login is whoever picked. */
export function workerFor(member: { role?: string | null; person?: string | null } | null | undefined, picked: OnPhone | null): OnPhone | null {
  if (member?.role === 'caller' && valid(member.person)) return member.person
  return picked
}

/** Whose tasks a worker sees: Colin his own; Thalia and Adil the callers' list, since the call list and the
 *  conveyor's caller stops are written in Thalia's name and Adil covers them at the weekend. A phone that has
 *  not answered yet shows the login's own list, as before the picker (the question sits on top). */
export function ownerFilterFor(worker: OnPhone | null, login?: string | null): TaskOwner {
  const who = worker ?? (valid(login) ? login : null)
  return who === 'colin' ? 'colin' : 'callers'
}

export function useOnPhone(): [OnPhone | null, (p: OnPhone) => void] {
  const [v, setV] = useState<OnPhone | null>(() => readOnPhone() ?? memory)
  useEffect(() => {
    const on = () => setV(readOnPhone() ?? memory)
    globalThis.addEventListener?.(EVENT, on)
    globalThis.addEventListener?.('storage', on)
    return () => {
      globalThis.removeEventListener?.(EVENT, on)
      globalThis.removeEventListener?.('storage', on)
    }
  }, [])
  return [v, writeOnPhone]
}
