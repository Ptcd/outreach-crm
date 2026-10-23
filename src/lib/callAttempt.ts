/** One key per deliberate call attempt; the database uses it to make retries harmless. */
export function callAttemptKey(): string {
  return globalThis.crypto?.randomUUID?.() ?? `call_${Date.now()}_${Math.random().toString(36).slice(2)}`
}

/** A dial may start only while the database confirms the exact takeover is actively paused. */
export function humanCallAuthorized(value: unknown): value is { ok: true; paused: true } {
  return !!value && typeof value === 'object'
    && (value as { ok?: unknown }).ok === true
    && (value as { paused?: unknown }).paused === true
}
