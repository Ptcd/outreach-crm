// Reading the voicemails (Colin 2026-10-28: "not have her calling people that called in pissed or are not real leads";
// migration 0118). Every voicemail on our seller line gets a verdict in the reply agent's minute run: the rule words
// first (a stop, or the wrong person, the same words the database blocks on), then Claude for the rest. Power hour and
// Today's Missed calls box call back only seller and unclear; stop and wrong_person block that number; upset and
// not_seller go to Colin instead of the team.
import { saysWrongPerson } from './replyBrain.ts'
import type { Rpc } from './sending.ts'

export type Verdict = 'seller' | 'unclear' | 'stop' | 'wrong_person' | 'upset' | 'not_seller'
export const VERDICTS: Verdict[] = ['seller', 'unclear', 'stop', 'wrong_person', 'upset', 'not_seller']

// the database's voicemail_asks_to_stop (0089), word for word
const ASKS_TO_STOP = /(erase|remove|delete|take|lose|drop) (my|this|the) (phone |cell )?(number|#)|(take|get) (me|my number|this number) off|off (of )?your (list|system|database|records)|stop (calling|texting|contacting|messaging)|(do not|don't|dont|quit|never|no more) (call|text|contact|bother)|leave me alone/i

/** The rule floor: a clear stop or a clear wrong person, or null for Claude to read. */
export function voicemailRule(words: string): Verdict | null {
  const w = (words ?? '').replace(/’/g, "'")
  if (!w.trim()) return null
  const stop = ASKS_TO_STOP.test(w)
  if (saysWrongPerson(w)) return 'wrong_person'
  return stop ? 'stop' : null
}

export const VOICEMAIL_MODEL = 'claude-haiku-5-5'

const SYSTEM = [
  'You read a voicemail left on the phone line of a small local home buyer. We texted or wrote to the owner of a property; this person called back and left a message.',
  'Decide whether our caller should call them back, as one verdict:',
  '- seller: they want to talk about the property or about selling, or they are returning our message and sound open, curious or neutral (questions like "why do you want my property?" or "call me back" count).',
  '- unclear: the words are garbled or say too little to tell (only a name or a number). These get a call back.',
  '- stop: they ask us to stop calling or texting, or to remove their number.',
  '- wrong_person: they say they are not the owner, or the person we want is not at this number.',
  '- upset: they are angry, hostile, accusing, threatening or complaining about being contacted, without clearly asking to stop.',
  '- not_seller: not an owner talking about their property: a real estate agent, wholesaler or investor pitching us, a vendor or marketer, a robocall or spam, a government or records office, a tenant, or a business that called the wrong number.',
  'When in doubt between seller and unclear, say unclear. Say upset only when the message is clearly hostile; a skeptical but polite question is seller.',
  'Answer with JSON only: {"verdict": one of the six words, "reason": at most 20 plain words saying why}.',
].join('\n')

const SCHEMA = {
  type: 'object', additionalProperties: false, required: ['verdict', 'reason'],
  properties: { verdict: { type: 'string', enum: VERDICTS }, reason: { type: 'string' } },
}

/** Claude's verdict on one voicemail. Throws with a reason, never with the words. */
export async function readVoicemail(v: { words: string; owner_name?: string | null; property_address?: string | null }, opts: {
  apiKey: string; fetchFn: typeof fetch; model?: string; timeoutMs?: number
}): Promise<{ verdict: Verdict; reason: string }> {
  const ctrl = new AbortController()
  const timer = setTimeout(() => ctrl.abort(), opts.timeoutMs ?? 30_000)
  try {
    const res = await opts.fetchFn('https://api.anthropic.com/v1/messages', {
      method: 'POST', signal: ctrl.signal,
      headers: { 'content-type': 'application/json', 'x-api-key': opts.apiKey, 'anthropic-version': '2023-06-01',
        'anthropic-beta': 'server-side-fallback-2026-07-01' },
      body: JSON.stringify({
        model: opts.model || VOICEMAIL_MODEL, max_tokens: 400, fallbacks: 'default', system: SYSTEM,
        messages: [{ role: 'user', content: `The property: ${v.property_address ?? 'unknown'} (owner of record: ${v.owner_name ?? 'unknown'}).\n\nThe voicemail, as transcribed:\n"""${v.words}"""` }],
        output_config: { format: { type: 'json_schema', schema: SCHEMA } },
      }),
    })
    if (!res.ok) throw new Error(`Claude answered ${res.status}`)
    const data = await res.json() as { stop_reason?: string; content?: { type?: string; text?: string }[] }
    if (data.stop_reason === 'refusal') throw new Error('Claude declined')
    const text = (data.content ?? []).filter((b) => b.type === 'text').map((b) => b.text ?? '').join('')
    const parsed = JSON.parse(text) as { verdict?: string; reason?: string }
    if (!VERDICTS.includes(parsed.verdict as Verdict)) throw new Error('no verdict')
    return { verdict: parsed.verdict as Verdict, reason: String(parsed.reason ?? '').slice(0, 200) }
  } catch (e) {
    if (ctrl.signal.aborted) throw new Error('Claude did not answer in time')
    throw e
  } finally {
    clearTimeout(timer)
  }
}

export type VoicemailSummary = { read: number; by_rule: number; by_claude: number; failed: number; verdicts: Record<string, number> }

/** The minute run: up to five voicemails. Without a key only the rule words decide; the rest wait (and come up for a
 *  call back after 10 minutes, as before). */
export async function runVoicemailRead(rpc: Rpc, opts: { apiKey: string; fetchFn: typeof fetch; model?: string }): Promise<VoicemailSummary> {
  const s: VoicemailSummary = { read: 0, by_rule: 0, by_claude: 0, failed: 0, verdicts: {} }
  const r = await rpc('voicemail_to_read', { p_limit: 5 })
  for (const v of ((r.data as { call_sid: string; words: string; owner_name: string | null; property_address: string | null }[] | null) ?? [])) {
    let verdict: Verdict | null = voicemailRule(v.words)
    let reason = verdict === 'stop' ? 'asked us to stop or to remove the number' : verdict === 'wrong_person' ? 'says the owner is not at this number' : ''
    let by: 'rule' | 'claude' = 'rule'
    if (!verdict && opts.apiKey) {
      try {
        const c = await readVoicemail(v, opts)
        verdict = c.verdict; reason = c.reason; by = 'claude'
      } catch {
        s.failed++
      }
    }
    if (!verdict) continue
    const w = await rpc('voicemail_set_verdict', { p_call_sid: v.call_sid, p_verdict: verdict, p_reason: reason, p_by: by })
    if (w.error) { s.failed++; continue }
    s.read++
    if (by === 'rule') s.by_rule++; else s.by_claude++
    s.verdicts[verdict] = (s.verdicts[verdict] ?? 0) + 1
  }
  return s
}
