// A call the phone network refused, in plain words (Thalia 2026-10-28: "ConnectionError (31005): Error sent from
// gateway in HANGUP ... is this normal or a system issue?").
import { describe, expect, it } from 'vitest'
import { likelyDisconnected, plainCallError } from '../src/lib/dialer'

describe('call errors', () => {
  it('31005 and its cousins read as a likely disconnected number', () => {
    const raw = 'ConnectionError (31005): Error sent from gateway in HANGUP'
    expect(likelyDisconnected(raw)).toBe(true)
    expect(plainCallError(raw)).toMatch(/usually a disconnected number/)
    expect(likelyDisconnected('Allow the microphone to call from here.')).toBe(false)
    expect(plainCallError('Allow the microphone to call from here.')).toBe('Allow the microphone to call from here.')
  })
})
