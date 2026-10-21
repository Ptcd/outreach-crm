// Sam's drafted reply for a real conversation (Colin approves every one before it goes).
// Same prompt and guard pm-phone uses (both generated from WPIE): REPLY_SYSTEM_PROMPT,
// then guardDraft strips price/offer language (replaced by the deflection), the business
// name, "postcard" and markdown, and caps the length. Returns null when there is nothing
// safe to suggest; Colin then writes the reply himself.
import { REPLY_SYSTEM_PROMPT } from './replyPrompt.generated.ts'
import { guardDraft, parseModelMessage, shouldDraft } from './replyGuard.ts'
import type { DraftInput, Drafter } from './replyAgent.ts'

/** The facts the model reports alongside its message (WPIE prompt's JSON 'facts'), empty ones dropped. */
export function parseModelFacts(raw: string): Record<string, unknown> | null {
  const text = (raw ?? '').trim().replace(/^```(?:json)?\s*|\s*```$/g, '')
  const start = text.indexOf('{')
  const end = text.lastIndexOf('}')
  if (start < 0 || end <= start) return null
  try {
    const f = JSON.parse(text.slice(start, end + 1))?.facts
    if (!f || typeof f !== 'object') return null
    const kept = Object.fromEntries(Object.entries(f as Record<string, unknown>).filter(([, v]) =>
      v !== '' && v !== null && v !== undefined && v !== false && !(Array.isArray(v) && v.length === 0)))
    return Object.keys(kept).length ? kept : null
  } catch {
    return null
  }
}

type ChatMessage = { role: 'user' | 'assistant'; content: string }

export function buildMessages(x: DraftInput): ChatMessage[] {
  const out: ChatMessage[] = []
  const turns = [...x.history.map((h) => ({ role: (h.who === 'them' ? 'user' : 'assistant') as ChatMessage['role'], content: h.body.trim() })),
    { role: 'user' as const, content: x.inbound.trim() }]
  for (const m of turns) {
    const last = out[out.length - 1]
    if (last && last.role === m.role) last.content += '\n' + m.content
    else out.push({ ...m })
  }
  if (out[0]?.role !== 'user') out.unshift({ role: 'user', content: '(conversation start)' })
  return out
}

export function conversationContext(x: DraftInput): string {
  return [
    '# This conversation',
    'Channel: sms',
    x.ownerName ? `Owner on record: ${x.ownerName}` : 'We could not match this number to an owner on record.',
    x.propertyAddress ? `Property the text was about: ${x.propertyAddress}` : 'Find out which property they mean before anything else.',
    'The assistant turns above were sent by Colin or for him (the first is usually his own opening text).',
    'Never mention a postcard or a business. Never give or hint at a price, value or offer.',
    'Your message is a draft Colin reads in the WPIE app and approves or edits before it is sent.',
  ].join('\n')
}

export function claudeDrafter(opts: { apiKey: string; model?: string; effort?: string; companyName?: string;
  fetchFn: typeof fetch; timeoutMs?: number }): Drafter {
  return async (x) => {
    if (!shouldDraft(x.inbound)) return null
    const ctrl = new AbortController()
    const timer = setTimeout(() => ctrl.abort(), opts.timeoutMs ?? 20_000)
    try {
      const res = await opts.fetchFn('https://api.anthropic.com/v1/messages', {
        method: 'POST',
        signal: ctrl.signal,
        headers: { 'content-type': 'application/json', 'x-api-key': opts.apiKey, 'anthropic-version': '2023-06-01' },
        body: JSON.stringify({
          model: opts.model || 'claude-sonnet-5-5',
          max_tokens: 600,
          system: [
            { type: 'text', text: REPLY_SYSTEM_PROMPT, cache_control: { type: 'ephemeral' } },
            { type: 'text', text: conversationContext(x) },
          ],
          messages: buildMessages(x),
          ...(opts.effort ? { output_config: { effort: opts.effort } } : {}),
        }),
      })
      if (!res.ok) return null
      const data = await res.json()
      if (data?.stop_reason === 'refusal' || data?.stop_reason === 'max_tokens') return null
      const text = Array.isArray(data?.content)
        ? data.content.filter((b: { type?: string }) => b?.type === 'text').map((b: { text?: string }) => b.text ?? '').join('') : ''
      const message = text ? parseModelMessage(text) : null
      if (!message) return null
      const guarded = guardDraft(message, { companyName: opts.companyName || 'Merrill Holdings' }).text
      return guarded ? { message: guarded, facts: parseModelFacts(text) } : null
    } catch {
      return null
    } finally {
      clearTimeout(timer)
    }
  }
}
