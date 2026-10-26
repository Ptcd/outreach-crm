// The agent door (Colin 2026-10-25: "design it agent first"): the MCP tools two Muse agents (or any MCP client)
// use. The intake agent loads prospects; the sender agent writes and queues texts and watches the results. The
// agent applies the prospect rules itself. What this door refuses is only what may never go out: an opted-out or
// do-not-contact phone, a closed card, a text with a price, cash, a business name or no STOP line. Everything
// queued still passes the database's send check (switch, pause, no Sundays, window, daily cap, already texted).
// Transport: MCP over streamable HTTP, stateless JSON responses (supabase/functions/agent-mcp).
import { findPriceOrOffer } from './replyGuard.ts'

export type Role = 'intake' | 'sender'
type ToolRole = Role | 'any'
export interface Agent { id: string; name: string; role: Role }

/** Everything the tools touch, so the routing and the checks are testable without a database. */
export interface DoorDb {
  addProspect(p: Record<string, unknown>, agent: string): Promise<Record<string, unknown>>
  findProspects(f: { address?: string; phone?: string; name?: string; lead_id?: string; only_agent?: boolean; limit: number }): Promise<unknown[]>
  prospectCounts(): Promise<Record<string, unknown>>
  status(): Promise<Record<string, unknown>>
  readyToText(f: { limit: number; followups: boolean; all_sources: boolean }): Promise<unknown[]>
  queueText(t: { lead_id: string; phone: string; body: string; step: number; send_after: string | null; variant: string | null; template: string | null }, agent: string): Promise<Record<string, unknown>>
  testResults(days: number, step: number): Promise<Record<string, unknown>>
  repliesWaiting(days: number): Promise<unknown[]>
  dueToday(): Promise<unknown[]>
  markCard(m: { lead_id: string; mark: string; reason: string | null; date: string | null; phone: string | null }, agent: string): Promise<Record<string, unknown>>
  linkCards(l: { lead_id: string; other_id: string; kind: string; note: string | null }, agent: string): Promise<Record<string, unknown>>
  sendReply(t: { lead_id: string; phone: string; body: string }, agent: string): Promise<Record<string, unknown>>
  queue(date: string | null): Promise<unknown[]>
  withdraw(id: string, agent: string, reason: string): Promise<boolean>
  pause(reason: string, agent: string): Promise<Record<string, unknown>>
  resume(agent: string): Promise<Record<string, unknown>>
  results(hours: number): Promise<Record<string, unknown>>
}

export const SERVER_NAME = 'wpie'
export const PROTOCOL_VERSIONS = ['2025-06-18', '2025-03-26', '2024-11-05']

export const TEXTING_RULES = [
  'You write texts as Colin Merrill himself, first person ("I"). He is one local person who buys houses; never name a business, company, team or "investors".',
  'Never mention a price, a number of dollars, an offer, "cash" or "as-is" (carriers flag it). No $ anywhere.',
  'Every text ends with a way out that contains the word STOP, for example "Reply STOP if you\'d rather not hear from me."',
  'A first text only asks a simple question about the property (is it still yours / are you the right person to ask about <address>). No pitch until they answer.',
  'Keep it under 160 characters when you can (320 is the hard limit). No links, no emojis, no ALL CAPS.',
  'Never pressure an older or grieving owner. STOP is final: an opted-out phone can never be texted again.',
  'Follow-ups (steps 2-5) go only to people who never answered, at least 3 days apart; the sequence the team uses is days 1, 3, 10, 17, 24.',
  'Texts go out 10 AM to 7 PM in the recipient\'s time zone, never on Sunday, and share one daily limit with the laptop\'s own texts. Queue them and the server sends them in that window.',
  'Replies: you answer them now (replies_waiting, then send_reply), on the same thread. Read the whole conversation and the card first. One reply per text from them; never a first text or follow-up (queue_texts) to someone who has texted back.',
  'In a reply: never give, guess or react to a price; Colin prices every deal himself on a call. Your job is to learn why they would sell, the condition, the timing, who signs and their number, then book a call with Colin.',
  'Every morning, read due_today: dated check-backs, holds whose date arrived, booked calls and visits, and contracts out for signature. The card says why it was waiting (named_event, notes, the conversation). Act on each one and mark the card.',
  'When an A/B test is running, tag every text with its variant (and template) in queue_texts, assign cards to variants at random, and read test_results before changing anything.',
].join('\n')

const S = (description: string, extra: Record<string, unknown> = {}) => ({ type: 'string', description, ...extra })
const PHONE = { anyOf: [S('10-digit US number'), { type: 'object', properties: {
  number: S('the phone number'), type: S('mobile, landline or voip if known'), name: S('whose phone this is'),
  confidence: { type: 'number', description: '0-1 from the source, if it gives one' }, note: S('anything else') }, required: ['number'] }] }
const REASON = { type: 'object', properties: {
  kind: S('short type: tax_delinquent, foreclosure, probate, vacant, code_violation, divorce, eviction, tired_landlord, other'),
  label: S('how the team should read it on the card, e.g. "Behind on taxes 2 years"'),
  detail: S('the specifics: which years, case number, what the notice says'),
  date: S('YYYY-MM-DD the record is from'), amount: { type: 'number', description: 'dollars owed, if any' },
  source: S('where it came from: county treasurer list, court record, ...') }, required: ['kind'] }

export const TOOLS: { role: ToolRole; name: string; description: string; inputSchema: Record<string, unknown> }[] = [
  { role: 'intake', name: 'add_prospects',
    description: 'Load prospects: property address, owner name(s), phone numbers and why they are motivated. You have already applied the prospect rules; every one is accepted unless the address or owner is missing. The same address and owner merges into the existing card (new phones and reasons are added). Up to 200 per call. Returns one result per prospect: created / updated / rejected, the card id, and phones that were skipped and why.',
    inputSchema: { type: 'object', properties: { prospects: { type: 'array', maxItems: 200, items: { type: 'object', properties: {
      owner_name: S('the owner (or the person to ask for)'), owner_type: S('individual, trust, llc, estate'),
      address: S('property street address'), city: S('city / village / town'), zip: S('ZIP'), county: S('county'),
      mailing_street: S('owner mailing street'), mailing_city: S('owner mailing city'), mailing_state: S('owner mailing state (sets the texting time zone)'),
      mailing_zip: S('owner mailing ZIP'), property_type: S('house, duplex, ...'), units: { type: 'integer' },
      phones: { type: 'array', items: PHONE }, reasons: { type: 'array', items: REASON },
      source: S('where this prospect came from (defaults to muse)'), notes: S('anything the team should know') },
      required: ['owner_name', 'address'] } } }, required: ['prospects'] } },
  { role: 'intake', name: 'find_prospects',
    description: 'Look up cards by address, phone, owner name or card id: stage, phones, reasons, and whether they were texted or replied.',
    inputSchema: { type: 'object', properties: { address: S('part of the street address'), phone: S('a phone number'),
      name: S('part of the owner name'), lead_id: S('a card id'), only_agent: { type: 'boolean', description: 'only cards an agent loaded' },
      limit: { type: 'integer', maximum: 100 } } } },
  { role: 'intake', name: 'prospect_counts', description: 'How many agent-loaded cards there are, by stage and by source.',
    inputSchema: { type: 'object', properties: {} } },
  { role: 'sender', name: 'texting_rules', description: 'The rules every text must follow, and the current sending switches. Read this before writing texts.',
    inputSchema: { type: 'object', properties: {} } },
  { role: 'sender', name: 'sending_status', description: 'Is sending on or paused, the window, the daily limit and how much of it is used today, and today\'s texts by status.',
    inputSchema: { type: 'object', properties: {} } },
  { role: 'sender', name: 'ready_to_text',
    description: 'Cards waiting for a text: your own new cards, and the cards the laptop picked for a first text and handed to you (they passed the prospect rules; laptop_text is the wording the laptop would have sent, for reference). Each has a usable mobile phone and nothing queued. With followups=true, also your cards that got a text, never answered, and are due for the next step. Includes owner_type (individual, trust, llc, estate), address, phones, reasons and what was sent before.',
    inputSchema: { type: 'object', properties: { limit: { type: 'integer', maximum: 300 }, followups: { type: 'boolean' },
      all_sources: { type: 'boolean', description: 'include cards the laptop loaded (default: only agent-loaded cards)' } } } },
  { role: 'sender', name: 'queue_texts',
    description: 'Queue texts you wrote. Each: card id, phone (one on that card), the exact text, step (1 = first text, 2-5 = follow-ups) and optionally the earliest time to send. The server sends each one inside the recipient\'s window, under the daily limit. Refused texts come back with the reason. Up to 100 per call.',
    inputSchema: { type: 'object', properties: { texts: { type: 'array', maxItems: 100, items: { type: 'object', properties: {
      lead_id: S('card id'), phone: S('phone on that card'), body: S('the exact text'), step: { type: 'integer', minimum: 1, maximum: 5 },
      send_after: S('ISO time, optional'),
      variant: S('A/B test arm this text belongs to, e.g. "A" or "B" (always set it when a test is running)'),
      template: S('short name of the wording, e.g. "own_q" or "intent_q"') }, required: ['lead_id', 'phone', 'body'] } } }, required: ['texts'] } },
  { role: 'sender', name: 'test_results',
    description: 'The A/B test scoreboard: per variant, texts queued, sent, delivered, failed (and carrier-filtered 30007), real conversations (a reply that is not a STOP or a wrong number), STOPs, wrong numbers, and the reply and STOP rates on delivered texts. Default: first texts, last 14 days.',
    inputSchema: { type: 'object', properties: { days: { type: 'integer', maximum: 90 }, step: { type: 'integer', minimum: 1, maximum: 5 } } } },
  { role: 'sender', name: 'replies_waiting',
    description: 'People who texted back and have no answer from us yet, oldest first. Each comes with the whole card: property, owner, mailing address, reasons, the full conversation both ways, calls, what we already know (motivation, timeline, condition, price, who signs), the card stage and next step, whether it is hot, and how the reply agent read their text (intent, outcome, its suggested reply). Answer each with send_reply.',
    inputSchema: { type: 'object', properties: { days: { type: 'integer', maximum: 30 } } } },
  { role: 'sender', name: 'send_reply',
    description: 'Answer someone who texted us, on the same thread (same number). Sent now, unless it is quiet hours, when it goes in the morning. Refused if they opted out, if they texted again since you read the thread (read it again), or if it breaks the wording rules. A STOP line is not needed in a reply.',
    inputSchema: { type: 'object', properties: { lead_id: S('card id'), phone: S('their phone (the one that texted us)'), body: S('your reply') },
      required: ['lead_id', 'phone', 'body'] } },
  { role: 'any', name: 'due_today',
    description: 'Every card whose time has come, oldest first, each with the whole card and why it was waiting: check_back (a dated not-now, a hold, an estate or family wait whose date arrived), booked_call / booked_visit (today), call_due / text_due (a stop the team or you owes), contract_waiting (a contract sent and not signed, with who still has to sign). days_late says how overdue. Read this every morning and act on each one: a text, a mark_card, or tell Colin.',
    inputSchema: { type: 'object', properties: {} } },
  { role: 'any', name: 'mark_card',
    description: 'Mark a card the way the team does from its buttons. mark: dead (not interested), dnc (asked not to be contacted: every phone blocked for good), not_now (with date = when to check back, or reason = what has to change first), hot (wants to sell / asked for a call: Colin is pinged and the card goes to him), held (reason = the named blocker, optional date), wrong_number (phone = the number that was never them), elderly, grief, or note (reason = the note). Returns the stage and belt of the card after the mark.',
    inputSchema: { type: 'object', properties: { lead_id: S('card id'),
      mark: S('dead | dnc | not_now | hot | held | wrong_number | elderly | grief | note'),
      reason: S('why, in their words where possible; the blocker for held; the condition for not_now without a date; the note for note'),
      date: S('ISO time: the check-back date for not_now, or when a held card should be looked at again'),
      phone: S('the phone, for wrong_number or dnc') }, required: ['lead_id', 'mark'] } },
  { role: 'any', name: 'link_cards',
    description: 'Link two cards: same_person (one owner, two cards), other_property (they mentioned another place), estate_contact (the person handling an estate), shared_phone, occupant (lives there, not the owner), co_owner, related. Shown on both cards.',
    inputSchema: { type: 'object', properties: { lead_id: S('card id'), other_id: S('the other card id'),
      kind: S('same_person | other_property | estate_contact | shared_phone | occupant | co_owner | related'), note: S('what connects them') },
      required: ['lead_id', 'other_id', 'kind'] } },
  { role: 'sender', name: 'todays_queue', description: 'Every text planned for a day (default today), from you and from the laptop, with its status.',
    inputSchema: { type: 'object', properties: { date: S('YYYY-MM-DD') } } },
  { role: 'sender', name: 'withdraw_texts', description: 'Pull texts that have not gone yet.',
    inputSchema: { type: 'object', properties: { text_ids: { type: 'array', items: { type: 'string' } }, reason: S('why') }, required: ['text_ids'] } },
  { role: 'sender', name: 'pause_sending', description: 'Stop all texting now (yours and the laptop\'s) until resumed. Use it when something looks wrong: many failures, a carrier error, a wording problem.',
    inputSchema: { type: 'object', properties: { reason: S('why') }, required: ['reason'] } },
  { role: 'sender', name: 'resume_sending', description: 'Resume texting after YOUR pause. A pause Colin or the team made can only be lifted in the app.',
    inputSchema: { type: 'object', properties: {} } },
  { role: 'sender', name: 'text_results', description: 'What happened to recent texts: delivered, failed (with carrier codes), replies and STOPs, over the last N hours (default 24).',
    inputSchema: { type: 'object', properties: { hours: { type: 'integer', maximum: 168 } } } },
]

/** The wording check for a reply (no STOP line needed in the middle of a conversation). */
export function replyProblem(body: string): string | null {
  const b = (body ?? '').trim()
  if (!b) return 'empty reply'
  if (b.length > 480) return 'over 480 characters'
  if (b.includes('$')) return 'no $ or prices'
  if (findPriceOrOffer(b).length) return 'mentions a price or an offer: Colin gives numbers himself, on a call'
  if (/\bcash\b/i.test(b)) return 'no "cash" in a text'
  if (/https?:\/\/|www\./i.test(b)) return 'no links'
  if (/\b(llc|inc|company|investors?|our team)\b/i.test(b)) return 'sounds like a business: write as Colin, one person'
  return null
}

/** The wording check before a text is queued (the database checks STOP, $, length and the business name again). */
export function textProblem(body: string): string | null {
  const b = (body ?? '').trim()
  if (!b) return 'empty text'
  if (!/\bSTOP\b/.test(b)) return 'needs a STOP line (e.g. "Reply STOP if you\'d rather not hear from me.")'
  if (b.length > 320) return 'over 320 characters'
  if (b.includes('$')) return 'no $ or prices'
  if (findPriceOrOffer(b).length) return 'mentions a price or an offer'
  if (/\bcash\b/i.test(b)) return 'no "cash" in a text'
  if (/\bas[\s-]?is\b/i.test(b)) return '"as-is" is flagged by carriers'
  if (/https?:\/\/|www\./i.test(b)) return 'no links'
  if (/\b(llc|inc|company|investors?|our team)\b/i.test(b)) return 'sounds like a business: write as Colin, one person'
  return null
}

type Json = Record<string, unknown>
const ok = (id: unknown, result: unknown) => ({ jsonrpc: '2.0', id, result })
const fail = (id: unknown, code: number, message: string) => ({ jsonrpc: '2.0', id, error: { code, message } })
const textResult = (v: unknown, isError = false) => ({ content: [{ type: 'text', text: JSON.stringify(v, null, 1) }], isError })
const int = (v: unknown, d: number, max: number) => Math.max(1, Math.min(max, Number.isFinite(Number(v)) && v !== null && v !== undefined ? Math.floor(Number(v)) : d))

export async function callTool(name: string, args: Json, agent: Agent, db: DoorDb): Promise<{ value: unknown; isError?: boolean }> {
  const tool = TOOLS.find((t) => t.name === name)
  if (!tool) return { value: { error: `no tool ${name}` }, isError: true }
  if (tool.role !== 'any' && tool.role !== agent.role) return { value: { error: `the ${agent.role} key cannot use ${name}` }, isError: true }
  switch (name) {
    case 'add_prospects': {
      const list = Array.isArray(args.prospects) ? (args.prospects as Json[]).slice(0, 200) : []
      if (!list.length) return { value: { error: 'prospects is an empty list' }, isError: true }
      const results = []
      for (const p of list) results.push(await db.addProspect(p, agent.name))
      const count = (s: string) => results.filter((r) => r.status === s).length
      return { value: { created: count('created'), updated: count('updated'), rejected: count('rejected'), results } }
    }
    case 'find_prospects':
      return { value: await db.findProspects({ address: args.address as string, phone: args.phone as string, name: args.name as string,
        lead_id: args.lead_id as string, only_agent: !!args.only_agent, limit: int(args.limit, 20, 100) }) }
    case 'prospect_counts': return { value: await db.prospectCounts() }
    case 'texting_rules': return { value: { rules: TEXTING_RULES, status: await db.status() } }
    case 'sending_status': return { value: await db.status() }
    case 'ready_to_text':
      return { value: await db.readyToText({ limit: int(args.limit, 50, 300), followups: !!args.followups, all_sources: !!args.all_sources }) }
    case 'queue_texts': {
      const list = Array.isArray(args.texts) ? (args.texts as Json[]).slice(0, 100) : []
      if (!list.length) return { value: { error: 'texts is an empty list' }, isError: true }
      const results = []
      for (const t of list) {
        const body = String(t.body ?? '').replace(/\s+/g, ' ').trim()
        const why = textProblem(body)
        if (why) { results.push({ lead_id: t.lead_id, status: 'refused', reason: why }); continue }
        const r = await db.queueText({ lead_id: String(t.lead_id ?? ''), phone: String(t.phone ?? ''), body,
          step: int(t.step, 1, 5), send_after: t.send_after ? String(t.send_after) : null,
          variant: t.variant ? String(t.variant) : null, template: t.template ? String(t.template) : null }, agent.name)
        results.push({ lead_id: t.lead_id, ...r })
      }
      return { value: { queued: results.filter((r) => r.status === 'queued').length, refused: results.filter((r) => r.status !== 'queued').length, results } }
    }
    case 'due_today': return { value: await db.dueToday() }
    case 'mark_card':
      return { value: await db.markCard({ lead_id: String(args.lead_id ?? ''), mark: String(args.mark ?? ''), reason: args.reason ? String(args.reason) : null,
        date: args.date ? String(args.date) : null, phone: args.phone ? String(args.phone) : null }, agent.name) }
    case 'link_cards':
      return { value: await db.linkCards({ lead_id: String(args.lead_id ?? ''), other_id: String(args.other_id ?? ''), kind: String(args.kind ?? ''),
        note: args.note ? String(args.note) : null }, agent.name) }
    case 'replies_waiting': return { value: await db.repliesWaiting(int(args.days, 7, 30)) }
    case 'send_reply': {
      const body = String(args.body ?? '').replace(/\s+/g, ' ').trim()
      const why = replyProblem(body)
      if (why) return { value: { status: 'refused', reason: why }, isError: true }
      return { value: await db.sendReply({ lead_id: String(args.lead_id ?? ''), phone: String(args.phone ?? ''), body }, agent.name) }
    }
    case 'todays_queue': return { value: await db.queue(typeof args.date === 'string' ? args.date : null) }
    case 'withdraw_texts': {
      const ids = Array.isArray(args.text_ids) ? (args.text_ids as unknown[]).map(String).slice(0, 300) : []
      const done: string[] = []
      for (const id of ids) if (await db.withdraw(id, agent.name, String(args.reason ?? 'withdrawn by the sender agent'))) done.push(id)
      return { value: { withdrawn: done.length, not_withdrawn: ids.filter((i) => !done.includes(i)) } }
    }
    case 'pause_sending': return { value: await db.pause(String(args.reason ?? '').trim() || 'paused by the sender agent', agent.name) }
    case 'resume_sending': return { value: await db.resume(agent.name) }
    case 'text_results': return { value: await db.results(int(args.hours, 24, 168)) }
    case 'test_results': return { value: await db.testResults(int(args.days, 14, 90), int(args.step, 1, 5)) }
  }
  return { value: { error: `no tool ${name}` }, isError: true }
}

/** One JSON-RPC message; null for a notification (no reply). */
export async function handleMessage(msg: Json, agent: Agent, db: DoorDb): Promise<Json | null> {
  const id = msg.id
  const method = String(msg.method ?? '')
  if (id === undefined || id === null) return null                     // notifications/initialized and friends
  if (method === 'initialize') {
    const asked = String((msg.params as Json | undefined)?.protocolVersion ?? '')
    return ok(id, {
      protocolVersion: PROTOCOL_VERSIONS.includes(asked) ? asked : PROTOCOL_VERSIONS[0],
      capabilities: { tools: {} },
      serverInfo: { name: SERVER_NAME, version: '1.0.0' },
      instructions: agent.role === 'intake'
        ? 'You load seller prospects into the WPIE app with add_prospects. You check the prospect rules before loading; the app accepts what you send.'
        : 'You run the WPIE texting: read texting_rules first, then ready_to_text, write texts, queue_texts, and watch text_results. Pause if something looks wrong.',
    })
  }
  if (method === 'ping') return ok(id, {})
  if (method === 'tools/list') {
    return ok(id, { tools: TOOLS.filter((t) => t.role === 'any' || t.role === agent.role).map(({ name, description, inputSchema }) => ({ name, description, inputSchema })) })
  }
  if (method === 'tools/call') {
    const p = (msg.params ?? {}) as Json
    try {
      const r = await callTool(String(p.name ?? ''), (p.arguments ?? {}) as Json, agent, db)
      return ok(id, textResult(r.value, !!r.isError))
    } catch (e) {
      return ok(id, textResult({ error: e instanceof Error ? e.message : String(e) }, true))
    }
  }
  return fail(id, -32601, `method not found: ${method}`)
}

/** The key from the request: Authorization: Bearer <key>, or x-api-key. */
export function keyFrom(headers: Headers): string | null {
  const a = headers.get('authorization') ?? ''
  const m = a.match(/^Bearer\s+(\S+)$/i)
  return m ? m[1] : (headers.get('x-api-key') || null)
}
