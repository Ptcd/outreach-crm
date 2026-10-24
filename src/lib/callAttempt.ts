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

/** A paused attempt keeps its recovery button even if the card is later moved to a future date. */
export function personalCallControlHidden(blocked: boolean | undefined, activeKey: string | null | undefined,
  notBefore: string | null | undefined, nowMs = Date.now()): boolean {
  return !!blocked || (!activeKey && outboundCallWaits(notBefore, nowMs))
}

/** Custom TwiML-App parameters that bind the provider webhook to this exact database pause. */
export function humanCallProviderParams(to: string, line: string, leadId: string, takeoverKey: string) {
  return { To: to, line, leadId, takeoverKey }
}

type ThreadRow = { direction: string; channel: string; from_number: string | null; to_number: string | null; sent_at: string }
const last10 = (n: string | null | undefined) => (n ?? '').replace(/[^0-9]/g, '').slice(-10)

/** The number to call from (Colin 2026-10-24: "it should call from the same number"): our side of the latest text
 *  with this phone, so the seller sees the number that texted them. Else the latest number we texted the card from,
 *  else the fallback. pm-phone still refuses any number outside the seller pool. */
export function callerLineFor(to: string, rows: ThreadRow[], fallback: string): string {
  const sms = rows.filter((r) => r.channel === 'sms').sort((a, b) => b.sent_at.localeCompare(a.sent_at))
  const ours = (r: ThreadRow) => (r.direction === 'out' ? r.from_number : r.to_number)
  const hit = sms.find((r) => last10(r.direction === 'out' ? r.to_number : r.from_number) === last10(to) && last10(ours(r)).length === 10)
    ?? sms.find((r) => r.direction === 'out' && last10(r.from_number).length === 10)
  return hit ? `+1${last10(ours(hit))}` : fallback
}
