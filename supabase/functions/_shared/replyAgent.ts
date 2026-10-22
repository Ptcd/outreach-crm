// The reply-agent loop behind the reply-agent Edge Function (cron, every minute). No Deno
// globals: tests/replyAgent.test.ts runs it against the real migrations on PGlite with a
// fake Twilio and a fake drafter. Whether a reply MAY go is decided in Postgres
// (reply_claim_send, migration 0004); what the reply agent says is decided by replyBrain.decide and,
// for a real conversation, by the drafter (Claude) whose text only Colin can approve.
import { PITCH_ASKED, endsInterest, firstNameOf, isHotReply } from './hotLeads.ts'
import { reactionKind, reactionMeaning } from './replyGuard.ts'
import { decide, rulesVersion, scoreRedteam, type RedteamRow, type ReplyContext } from './replyBrain.ts'
import { classifyFailure, isOptOut, type Rpc, type SenderEnv, type TwilioPort } from './sending.ts'
import { guardDraft } from './replyGuard.ts'
import { workNeeded } from './needsWork.ts'

export interface DraftInput {
  inbound: string
  history: { who: 'us' | 'them'; body: string }[]
  ownerName: string | null
  propertyAddress: string | null
}
/** The draft text, or text plus the facts the model read from the thread (reason, clock, ...). */
export type Drafted = string | { message: string; facts?: Record<string, unknown> | null }
export type Drafter = (x: DraftInput) => Promise<Drafted | null>

export interface ClaimedInbound {
  sid: string
  from10: string
  to_number: string | null
  body: string | null
  received_at: string
  lead_id: string | null
  owner_name: string | null
  property_address: string | null
  prior_inbound: string[]
  last_agent_text: string | null
  history: { who: 'us' | 'them'; body: string | null }[]
  is_test?: boolean
}

export interface AgentSummary {
  mode: 'live' | 'dry'
  rules_version: string
  redteam: string | null
  inbound_new: number
  inbound_errors: string[]
  decided: { removal: number; routine: number; candidate: number; drafted: number }
  tasks: number
  hot: number
  sent: number
  dry_sent: number
  queued: number
  failed: number
  uncertain: number
  refused: string[]
}

/** Send one claimed reply through Twilio and record the result (never retried). */
export async function sendClaimed(rpc: Rpc, twilio: TwilioPort, claim: { id: string; to: string; from: string | null; body: string },
  now: () => Date): Promise<'sent' | 'failed' | 'uncertain'> {
  let res
  try {
    res = await twilio.send(claim.to, claim.body, claim.from)
  } catch (e) {
    res = { ok: false as const, httpStatus: null, code: null, message: String(e).slice(0, 300) }
  }
  const status = res.ok ? 'sent' : classifyFailure(res)
  await rpc('reply_record_result', {
    p_id: claim.id, p_status: status, p_sid: res.ok ? res.sid : null, p_error_code: res.ok ? null : res.code,
    p_reason: res.ok ? null : `${res.httpStatus ?? 'no answer'} ${res.code ?? ''} ${res.message}`.trim().slice(0, 300),
    p_now: now().toISOString(),
  })
  return status
}

export async function runReplyAgent(opts: {
  rpc: Rpc
  env: SenderEnv
  twilio: TwilioPort | null
  drafter: Drafter | null
  control: { reply_numbers: string[]; redteam_version: string | null; agent_last_run_at: string | null; test_opener?: string | null }
  redteamRows: RedteamRow[]
  now?: () => Date
  batch?: number
  pull?: boolean            // read new texts from Twilio first (the timer); the webhook already recorded its text
}): Promise<AgentSummary> {
  const now = opts.now ?? (() => new Date())
  const live = opts.env.live && opts.twilio != null
  const version = rulesVersion()
  const s: AgentSummary = { mode: live ? 'live' : 'dry', rules_version: version, redteam: null, inbound_new: 0, inbound_errors: [],
    decided: { removal: 0, routine: 0, candidate: 0, drafted: 0 }, tasks: 0, hot: 0, sent: 0, dry_sent: 0, queued: 0, failed: 0, uncertain: 0, refused: [] }

  // 0. Score the rules this build runs, once per version (the routine switch depends on it).
  if (opts.control.redteam_version !== version) {
    const r = scoreRedteam(opts.redteamRows)
    await opts.rpc('record_redteam', { p_version: version, p_passed: r.passed, p_total: r.total, p_ok: r.ok,
      p_detail: { handled_automatically: r.handled_automatically, to_colin: r.to_colin, missed_removals: r.missed_removals,
        failures: r.failures.slice(0, 40) }, p_now: now().toISOString() })
    s.redteam = `${r.passed}/${r.total}${r.ok ? ' passed' : ' FAILED'}`
  }

  // 1. New inbound texts to every reply number, straight from Twilio.
  if (opts.twilio && opts.pull !== false) {
    const since = opts.control.agent_last_run_at
      ? new Date(new Date(opts.control.agent_last_run_at).getTime() - 3600_000) : new Date(now().getTime() - 3 * 86400_000)
    for (const num of opts.control.reply_numbers) {
      try {
        for (const m of await opts.twilio.inboundSince(since, num)) {
          const r = await opts.rpc('record_inbound', { p_sid: m.sid, p_from: m.from, p_to: m.to, p_body: m.body,
            p_is_opt_out: isOptOut(m.body), p_received_at: m.dateSent })
          if (r.error) throw new Error(r.error.message)
          s.inbound_new += 1
        }
      } catch (e) {
        s.inbound_errors.push(`${num}: ${String(e instanceof Error ? e.message : e).slice(0, 200)}`)
      }
    }
  }

  // 2. Decide each new text: removal / routine line / a draft for Colin.
  // A text claimed by a run that died before deciding it (e.g. during a deploy) is put back first.
  const rq = await opts.rpc('reply_requeue_lost', { p_now: now().toISOString() })
  if (rq.error) s.inbound_errors.push(`requeue: ${rq.error.message.slice(0, 160)}`)
  const c = await opts.rpc('reply_claim_inbound', { p_limit: opts.batch ?? 10 })
  if (c.error) throw new Error(c.error.message)
  for (const t of (c.data as ClaimedInbound[]) ?? []) {
    // Colin's test phone plays a real owner: give it the opening text that owner was sent.
    const opener = t.is_test ? opts.control.test_opener?.trim() || null : null
    if (opener) {
      t.last_agent_text = t.last_agent_text ?? opener
      if (!(t.history ?? []).some((h) => h.who === 'us')) t.history = [{ who: 'us', body: opener }, ...(t.history ?? [])]
    }
    // A phone reaction is read for what it means (yes / no thanks), not the quote of our text it carries.
    const react = reactionKind(t.body ?? '')
    const ctx: ReplyContext = { inbound: (react ? reactionMeaning(react) : null) ?? t.body ?? '', priorInbound: (t.prior_inbound ?? []).filter(Boolean),
      lastAgentText: t.last_agent_text, propertyAddress: t.property_address, ownerName: t.owner_name,
      ourTurns: Math.max(0, (t.history ?? []).filter((h) => h.who === 'us').length - 1) }
    let d = decide(ctx)
    // A held phone (reply_holds) gets nothing on its own: Colin answers. A removal stays final.
    const held = (await opts.rpc('reply_is_held', { p_phone10: t.from10 })).data === true
    if (held && d.kind === 'routine') d = { ...d, kind: 'candidate', reply: null, outcome: 'open', facts: undefined, note: `held for Colin: ${d.note}` }
    let body = d.reply
    let source = d.reply ? 'fixed_line' : 'none'
    let facts: Record<string, unknown> | null = d.facts ?? null
    if (d.kind === 'candidate' && opts.drafter) {
      try {
        const got = await opts.drafter({ inbound: ctx.inbound, ownerName: t.owner_name, propertyAddress: t.property_address,
          history: (t.history ?? []).filter((h) => h.body).map((h) => ({ who: h.who, body: h.body as string })) })
        body = typeof got === 'string' ? got : got?.message ?? null
        facts = typeof got === 'object' && got ? got.facts ?? null : null
        if (body) { source = 'claude'; s.decided.drafted += 1 }
      } catch {
        body = null     // no draft: Colin writes this one himself
      }
    }
    s.decided[d.kind] += 1
    const r = await opts.rpc('reply_record_decision', { p_sid: t.sid, p_intent: d.intent, p_kind: d.kind, p_removal: d.removal,
      p_outcome: d.outcome, p_body: body, p_draft_source: source, p_note: d.note, p_rules_version: version,
      p_now: now().toISOString() })
    if (r.error) throw new Error(r.error.message)
    if (facts && Object.keys(facts).length) await opts.rpc('reply_set_facts', { p_sid: t.sid, p_facts: facts })
    // A real condition behind a no: a quiet follow-up task in 30 days (no email, no ping).
    if (d.facts?.nurture) {
      await opts.rpc('reply_nurture', { p_sid: t.sid, p_quote: ctx.inbound,
        p_due: new Date(now().getTime() + 30 * 86_400_000).toISOString(), p_now: now().toISOString() })
    }
    // A reply that shows interest or asks about selling: Colin's cell gets a text (hotLeads.ts).
    if (endsInterest({ intent: d.intent, removal: d.removal, outcome: d.outcome })) {
      await opts.rpc('hot_resolve', { p_phone10: t.from10, p_lead_id: t.lead_id, p_reason: `later reply: ${d.intent}`,
        p_now: now().toISOString() })
    }
    const afterPitch = PITCH_ASKED.test(ctx.lastAgentText ?? '')
    if ((held && !d.removal) || isHotReply({ intent: d.intent, text: ctx.inbound, removal: d.removal, afterPitch })) {
      const h = await opts.rpc('hot_record', { p_sid: t.sid, p_lead_id: t.lead_id, p_phone10: t.from10,
        p_first_name: firstNameOf(t.owner_name), p_address: t.property_address, p_body: ctx.inbound,
        p_is_test: t.is_test === true, p_now: now().toISOString() })
      if (!h.error) s.hot += 1
    }
    // Work no text can do (an email, paperwork, records, another person, a visit): a Task for a person.
    const work = d.removal ? null : workNeeded(ctx.inbound)
    if (work) {
      const k = await opts.rpc('reply_create_task', { p_sid: t.sid, p_kind: work.kind, p_title: work.title,
        p_quote: ctx.inbound, p_email: work.email, p_now: now().toISOString() })
      if (!k.error) s.tasks += 1
    }
  }

  // 3. Replies whose time has come: routine (switch on) and approvals held overnight.
  const due = await opts.rpc('reply_due', { p_limit: 20, p_now: now().toISOString() })
  if (due.error) throw new Error(due.error.message)
  for (const id of (due.data as string[]) ?? []) {
    let r = await opts.rpc('reply_claim_held', { p_id: id, p_dry: !live, p_now: now().toISOString() })
    let j = r.data as { outcome: string; reason?: string; id?: string; to?: string; from?: string | null; body?: string }
    if (j?.outcome === 'refused' && j.reason === 'not a held approval') {
      r = await opts.rpc('reply_claim_send', { p_id: id, p_mode: 'auto', p_body: null, p_actor: 'auto-reply', p_dry: !live,
        p_now: now().toISOString() })
      j = r.data as typeof j
    }
    if (!j) continue
    if (j.outcome === 'send' && live && opts.twilio) {
      const st = await sendClaimed(opts.rpc, opts.twilio, { id: j.id!, to: j.to!, from: j.from ?? null, body: j.body! }, now)
      s[st] += 1
    } else if (j.outcome === 'dry_sent') s.dry_sent += 1
    else if (j.outcome === 'queued') s.queued += 1
    else if (j.outcome === 'refused') s.refused.push(j.reason ?? '')
  }
  return s
}

/** Colin's Approve (with his final wording). Refuses a price, an offer or the business name
 *  rather than changing his words; the database refuses stale, sent or opted-out replies. */
export async function approveReply(opts: { rpc: Rpc; env: SenderEnv; twilio: TwilioPort | null; id: string; text: string;
  actor: string; now?: () => Date; companyName?: string }): Promise<{ outcome: string; reason?: string }> {
  const now = opts.now ?? (() => new Date())
  const text = (opts.text ?? '').replace(/\s+/g, ' ').trim()
  const g = guardDraft(text, { companyName: opts.companyName || 'Merrill Holdings', maxChars: 480 })
  const blocked = g.violations.filter((v) => v === 'price_or_offer' || v === 'names_company' || v === 'mentions_postcard')
  if (blocked.length) {
    const what = blocked.map((b) => b.replace(/_/g, ' ')).join(', ')
    return { outcome: 'refused', reason: 'not sent: the text has ' + what + (g.blocked.length ? ' (' + g.blocked.join(', ') + ')' : '') }
  }
  const live = opts.env.live && opts.twilio != null
  const r = await opts.rpc('reply_claim_send', { p_id: opts.id, p_mode: 'approve', p_body: text, p_actor: opts.actor, p_dry: !live,
    p_now: now().toISOString() })
  if (r.error) return { outcome: 'refused', reason: r.error.message }
  const j = r.data as { outcome: string; reason?: string; id?: string; to?: string; from?: string | null; body?: string }
  if (j.outcome !== 'send') return j
  const st = await sendClaimed(opts.rpc, opts.twilio!, { id: j.id!, to: j.to!, from: j.from ?? null, body: j.body! }, now)
  return { outcome: st }
}
