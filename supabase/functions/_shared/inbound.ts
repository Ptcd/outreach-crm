// Twilio's incoming-message webhook for the WPIE Mail Replies messaging service
// (reply-inbound Edge Function). Fast path: check the signature, record the text (a STOP
// suppresses the phone right here, as pm-phone's inbound used to record it), answer Twilio
// with empty TwiML. Slow path, after the answer: let the reply agent decide it, and if a routine reply
// becomes due within a couple of minutes, wait for it and send it. The 1-minute reply-agent
// timer catches anything this misses; a reply can never go twice (reply_claim_send).
import { runReplyAgent, type AgentSummary, type Drafter } from './replyAgent.ts'
import type { RedteamRow } from './replyBrain.ts'
import { isOptOut, type Rpc, type SenderEnv, type TwilioPort } from './sending.ts'

export const EMPTY_TWIML = '<?xml version="1.0" encoding="UTF-8"?><Response></Response>'

export interface InboundResult {
  status: number
  body: string
  sid: string | null
}

export async function recordWebhook(opts: { rpc: Rpc; params: Record<string, string>; signatureOk: boolean; now?: () => Date }):
  Promise<InboundResult> {
  if (!opts.signatureOk) return { status: 403, body: 'forbidden', sid: null }
  const p = opts.params
  const sid = p.MessageSid || p.SmsSid || ''
  if (!sid || !p.From) return { status: 200, body: EMPTY_TWIML, sid: null }   // nothing to record; never make Twilio retry
  const r = await opts.rpc('record_inbound', {
    p_sid: sid, p_from: p.From, p_to: p.To ?? null, p_body: p.Body ?? '', p_is_opt_out: isOptOut(p.Body ?? ''),
    p_received_at: (opts.now ?? (() => new Date()))().toISOString(),
  })
  // A database error answers 500 so Twilio retries the webhook; the timer's Twilio pull is the backstop.
  if (r.error) return { status: 500, body: 'retry', sid }
  return { status: 200, body: EMPTY_TWIML, sid }
}

/** The work after Twilio has its answer. */
export async function afterWebhook(opts: {
  rpc: Rpc
  env: SenderEnv
  twilio: TwilioPort | null
  drafter: Drafter | null
  control: { reply_numbers: string[]; redteam_version: string | null; agent_last_run_at: string | null }
  redteamRows: RedteamRow[]
  now?: () => Date
  sleep?: (ms: number) => Promise<void>
  maxWaitMs?: number
}): Promise<AgentSummary[]> {
  const now = opts.now ?? (() => new Date())
  const sleep = opts.sleep ?? ((ms: number) => new Promise<void>((res) => setTimeout(res, ms)))
  const base = { ...opts, now, pull: false }
  const out = [await runReplyAgent(base)]
  const due = await opts.rpc('reply_next_due', {})
  const at = due.data ? new Date(String(due.data)).getTime() : null
  if (at != null) {
    const wait = at - now().getTime()
    if (wait <= (opts.maxWaitMs ?? 110_000)) {
      if (wait > 0) await sleep(wait + 500)
      out.push(await runReplyAgent(base))
    }
  }
  return out
}
