/** One key per deliberate call attempt; the database uses it to make retries harmless. */
export function callAttemptKey(): string {
  return globalThis.crypto?.randomUUID?.() ?? `call_${Date.now()}_${Math.random().toString(36).slice(2)}`
}
