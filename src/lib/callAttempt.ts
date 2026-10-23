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

/** UI clarity only; begin_human_call remains the authoritative exact-date gate. */
export function outboundCallWaits(notBefore: string | null | undefined, nowMs = Date.now()): boolean {
  if (!notBefore) return false
  const at = new Date(notBefore).getTime()
  return Number.isFinite(at) && at > nowMs
}

/** Custom TwiML-App parameters that bind the provider webhook to this exact database pause. */
export function humanCallProviderParams(to: string, line: string, leadId: string, takeoverKey: string) {
  return { To: to, line, leadId, takeoverKey }
}
