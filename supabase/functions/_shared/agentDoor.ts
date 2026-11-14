// The agent door (Colin 2026-10-25: "design it agent first"): the MCP tools two Muse agents (or any MCP client)
// use. The intake agent loads prospects; the sender agent writes and queues texts and watches the results. The
// agent applies the prospect rules itself. What this door refuses is only what may never go out: an opted-out or
// do-not-contact phone, a closed card, a text with cash, a business name or no STOP line. Everything
// queued still passes the database's send check (switch, pause, no Sundays, window, daily cap, already texted).
// Transport: MCP over streamable HTTP, stateless JSON responses (supabase/functions/agent-mcp).
import { CALENDAR_TOOLS, callCalendarTool, isCalendarTool, type CalendarDoor } from './calendar.ts'

export type Role = 'intake' | 'sender' | 'records' | 'agent'
type ToolRole = Exclude<Role, 'agent'> | 'any'
/** What a key may do (Muse 2026-10-26): one key, five switches Colin flips in Settings > Agent keys. */
export type Scope = 'prospects' | 'texting' | 'calendar' | 'records' | 'marks' | 'channel'
export const SCOPES: Scope[] = ['prospects', 'texting', 'calendar', 'records', 'marks', 'channel']
/** tools: an explicit list of tool names this key may call (0214, Muse 2's seat); undefined or null = every tool in its scopes. */
export interface Agent { id: string; name: string; role: Role; scopes?: Scope[]; tools?: string[] | null }

/** The tools a key may call: its scopes, narrowed to its own list when it has one. */
export function toolAllowed(agent: Agent, tool: { name: string; role: string }): boolean {
  if (!scopesOf(agent).includes(scopeOf(tool))) return false
  return !agent.tools || agent.tools.includes(tool.name)
}

/** The old single-role keys keep exactly what their role had; a key with its own scopes has those. */
export function scopesOf(agent: Agent): Scope[] {
  if (agent.scopes) return agent.scopes
  if (agent.role === 'intake') return ['prospects', 'marks']
  if (agent.role === 'sender') return ['texting', 'calendar', 'marks']
  if (agent.role === 'records') return ['records']
  return [...SCOPES]
}

/** The scope a tool belongs to: calendar tools to calendar, cards (due_today, mark_card, link_cards) to marks. */
export function scopeOf(tool: { name: string; role: string }): Scope {
  if (isCalendarTool(tool.name)) return 'calendar'
  if (tool.role === 'channel') return 'channel'
  return tool.role === 'intake' ? 'prospects' : tool.role === 'sender' ? 'texting' : tool.role === 'records' ? 'records' : 'marks'
}

/** Everything the tools touch, so the routing and the checks are testable without a database. */
export interface DoorDb {
  /** records files (0222): a link to put a file at, mark it put, and a link to read an attachment the laptop holds */
  recordsFileUpload?(a: { request_id: string; filename: string; portal: string | null; number: string | null; note: string | null }, agent: string): Promise<Record<string, unknown>>
  recordsFileDone?(file_id: string, agent: string): Promise<Record<string, unknown>>
  recordsFileGet?(reply_id: string, name: string, agent: string): Promise<Record<string, unknown>>
  addProspect(p: Record<string, unknown>, agent: string): Promise<Record<string, unknown>>
  findProspects(f: { address?: string; phone?: string; name?: string; lead_id?: string; only_agent?: boolean; limit: number }): Promise<unknown[]>
  prospectCounts(): Promise<Record<string, unknown>>
  status(): Promise<Record<string, unknown>>
  readyToText(f: { limit: number; followups: boolean; all_sources: boolean }): Promise<unknown[]>
  queueText(t: { lead_id: string; phone: string; body: string; step: number; send_after: string | null; variant: string | null; template: string | null; slot: string | null; interest_id: string | null }, agent: string): Promise<Record<string, unknown>>
  testResults(days: number, step: number): Promise<Record<string, unknown>>
  textTemplates(): Promise<Record<string, unknown>>
  setTextTemplate(t: { variant: string; name: string | null; wording: string; note: string }, agent: string): Promise<Record<string, unknown>>
  /** Every tools/call, with its scope: ok or refused, the error, how long it took. */
  logCall?(c: { tool: string; scope: Scope | null; ok: boolean; error: string | null; ms: number }): Promise<void>
  /** A per-key, per-tool budget (0136): the reason to refuse, or null. */
  rateCheck?(tool: string): Promise<string | null>
  repliesWaiting(days: number): Promise<unknown[]>
  dueToday(): Promise<Record<string, unknown>>
  records(fn: string, args: Record<string, unknown>): Promise<unknown>
  markCard(m: { lead_id: string; mark: string; reason: string | null; date: string | null; phone: string | null }, agent: string): Promise<Record<string, unknown>>
  /** A person on a card (0084): deceased and dnc follow them onto every card, wrong_person is this card only. */
  markPerson(m: { lead_id: string; mark: string; interest_id: string | null; phone: string | null; reason: string | null }, agent: string): Promise<Record<string, unknown>>
  linkCards(l: { lead_id: string; other_id: string; kind: string; note: string | null }, agent: string): Promise<Record<string, unknown>>
  sendReply(t: { lead_id: string; phone: string; body: string }, agent: string): Promise<Record<string, unknown>>
  queue(date: string | null): Promise<unknown[]>
  withdraw(id: string, agent: string, reason: string): Promise<boolean>
  pause(reason: string, agent: string): Promise<Record<string, unknown>>
  resume(agent: string): Promise<Record<string, unknown>>
  results(hours: number): Promise<Record<string, unknown>>
  /** Colin's Google Calendar (open_slots, book_slot, cancel_booking); absent where it is not wired. */
  calendar?: CalendarDoor
}

export const SERVER_NAME = 'wpie'
export const PROTOCOL_VERSIONS = ['2025-06-18', '2025-03-26', '2024-11-05']

export const TEXTING_RULES = [
  "One name per seller, first person (\"I\"), and it follows the person across all their cards and numbers (Colin 2026-11-10): the voice the day's list gives for the card. Someone nobody has texted speaks with the caller the card belongs to (Thalia, or Tyler on Adil's cards); anyone we have texted keeps the name they saw last. The door refuses a text or a reply signed with another name. The intro (\"this is Thalia\") goes on the first text to a person and nowhere else: not on a follow-up, not on a first text to that person's next number. That person is one local buyer of houses; never name a business, company, team or \"investors\".",
  'Never say "cash" or "as-is" (carriers flag it). A dollar figure may be in a text only when Colin has OK\'d that figure for that card (Colin 2026-11-13: "Muse needs to check with me first"): the door refuses any other figure of $1,000 or more, however it is written ($85,000, 85k, 85 thousand). The figure comes from the offer path (offer_worklist), never from you: never invent, guess or round one.',
  "The offer by text (Colin 2026-11-13, on his rule of Nov 8 and 9): the offer is 65% of the after-repair value minus repairs, to the nearest $100; a counter may be taken up to 70% of the value minus repairs. Repairs are the items the seller named (offer_worklist lists each with its dollars), else $15, $30 or $60 a square foot for light, medium or heavy, from their words. The server does the arithmetic from what you record (offer_update) and puts the figure in front of Colin; you text it only after he OKs it, and every counter goes back to him before you answer it. Fewer than three sold comps, or a vague answer on the condition, is no number. A seller's number above what the house is worth fixed up is retail: no number. Colin sends the written offer from the card; you never send or promise one. Read offer_worklist at the start of every session and after replies_waiting: each row is one card with its one next step, whose step it is and when it is due. A step of yours that runs late is posted to you on the desk.",
  "A first text to a number ends with a way out that contains the word STOP, for example \"Reply STOP to opt out.\" A follow-up (steps 2-5) carries NO STOP line (Colin 2026-11-10) and the door refuses one that does; a reply never needs one. Tag each arm of a follow-up test with its own variant code so test_results can tell them apart.",
  "The day: the server builds one list a day from the whole store (7 AM Central, topped up hourly, never Sunday) and ready_to_text IS that list, in order: real need first (tier A to D, a sale date nearest first). Each row gives the phone to text and the voice to sign. The list is a floor of new people, then every follow-up that is due (2 and 3, then 4 and 5), then more new people, up to the daily cap. Write and queue it top to bottom; the_day.left_to_write says what is left. A card is on the list only if the records allow it: the door refuses a text to a card that is weak (a want, one year of tax), listed on the MLS, over the value cap, inside 14 days of a sheriff sale, thin or underwater on equity, or not judged by the laptop in the last week, and says which. Do not hold or park cards to manage the list; a card you think is wrong gets mark_card and a note.",
  'A first text only asks a simple question about the property (is it still yours / are you the right person to ask about <address>). No pitch until they answer.',
  'Keep it under 160 characters when you can (320 is the hard limit). No links, no emojis, no ALL CAPS.',
  'Never pressure an older or grieving owner. STOP is final: an opted-out phone can never be texted again.',
  'Follow-ups (steps 2-5) go only to people who never answered, at least 3 days apart; the sequence the team uses is days 1, 3, 10, 17, 24.',
  'Texts go out 10 AM to 7 PM in the recipient\'s time zone, never on Sunday, and share one daily limit with the laptop\'s own texts. Queue them and the server sends them in that window.',
  'Replies: you answer them now (replies_waiting, then send_reply), on the same thread. Read the whole conversation and the card first. One reply per text from them; never a first text or follow-up (queue_texts) to someone who has texted back.',
  'A thread a caller has taken over is theirs: send_reply is refused with the person\'s name (Thalia or Adil has this thread). Say nothing further on that phone until it is handed back; the card is still yours to read.',
  'Power hour (weekdays 4 to 6 PM Central): read replies_waiting every few minutes. A seller who asks what we would pay, or says yes to selling, stays with you by text (Colin 2026-11-13): the offer path takes them to a number with no call (offer_open, then offer_worklist). call_next is only for a seller who asks for a call ("call me", "can someone call"), with their words and the number they texted from; then you do NOT text them back, the caller phones them next, and if the call does not reach them their reply is still yours to answer. A thread a caller takes over belongs to that caller. Not interest (STOP, no, wrong number, not the owner, an older or grieving owner): handle it as usual.',
  'In a reply: the number comes first when they ask for one. The offer path gives the one next step for each such seller: one question about the condition (the big items only), the comp, the number Colin OKs, and after they answer it, who signs and the email for the papers. Before they ask, your job is to learn whether they would sell and why. A bare "yes" to "are you the owner" is an owner confirmed, not interest: ask whether they would consider selling. Book a call with Colin only when the seller asks to talk to someone.',
  "Booking: open_slots gives Colin's real open times (his calendar and his hours). Offer two or three, book_slot the one they pick with the 4 pillars, and confirm the time in your reply. Never promise a time you did not book.",
  "Phone calls: the card's call_notes say what was said on each recorded call (summary, the 4 pillars and who signs, outcome, next step, the mark the caller confirmed). Read them before you text: never ask again what they already told us on the phone, and follow the next step they agreed to.",
  'A card is one property; the people on it (people[] on every card) each have a role, a status, their own address and their own phones. Text a person (interest_id), on one of their numbers. Never text a person who is not active. One person on a card at a time: the next person gets a first text only after the one you texted is closed (deceased, dnc, wrong_person) or every first text to them bounced.',
  'Every morning, read due_today: dated check-backs, holds whose date arrived, booked calls and visits, and contracts out for signature. The card says why it was waiting (named_event, notes, the conversation). Act on each one and mark the card.',
  'The app itself texts the morning-of reminder for a booked walk-through ("Colin here. We are set to come by {street} today around {time}. Still good?"). Do not send your own reminder for a booked visit; answer their reply to it as usual.',
  'When an A/B test is running, tag every text with its variant (and template) in queue_texts, assign cards to variants at random, and read test_results before changing anything.',
].join('\n')

const S = (description: string, extra: Record<string, unknown> = {}) => ({ type: 'string', description, ...extra })
const PHONE = { anyOf: [S('10-digit US number'), { type: 'object', properties: {
  number: S('the phone number'), type: S('mobile, landline or voip if known'), name: S('whose phone this is'),
  confidence: { type: 'number', description: '0-1 from the source, if it gives one' }, note: S('anything else') }, required: ['number'] }] }
const INTEREST = { type: 'object', properties: {
  name: S('the person or entity'),
  role: S('owner_of_record | co_owner | personal_representative | special_administrator | heir | trustee | spouse | occupant | other'),
  mailing_street: S('THEIR mailing street (may differ from the property and from everyone else on the card)'), mailing_city: S('their city'),
  mailing_state: S('their state'), mailing_zip: S('their ZIP'), phones: { type: 'array', items: PHONE },
  status: S('optional: deceased | do_not_contact | not_the_contact | closed'), status_reason: S('why'), notes: S('anything about this person'),
  kind: S('optional: person | entity | household') }, required: ['name'] }
const REASON = { type: 'object', properties: {
  kind: S('short type: tax_delinquent, foreclosure, probate, vacant, code_violation, divorce, eviction, tired_landlord, other'),
  label: S('how the team should read it on the card, e.g. "Behind on taxes 2 years"'),
  detail: S('the specifics: which years, case number, what the notice says'),
  date: S('YYYY-MM-DD the record is from'), amount: { type: 'number', description: 'dollars owed, if any' },
  source: S('where it came from: county treasurer list, court record, ...') }, required: ['kind'] }

export const TOOLS: { role: ToolRole; name: string; description: string; inputSchema: Record<string, unknown> }[] = [
  { role: 'intake', name: 'add_prospects',
    description: 'Load prospects: the property, the people on it and why they are motivated. You have already applied the prospect rules; every one is accepted unless the address or a name is missing. One card per property: a prospect for an address we already have (any owner, ranges like 2825-2827 included) updates that card, adding new people, new numbers and stacking reasons. Give the people as interests[] (each with a role, THEIR address and THEIR phones); the old owner_name + phones shape still works as one owner of record. A number already on another card is attached anyway, to the person it belongs to, and comes back as also_on. Up to 200 per call. Returns one result per prospect: created / updated / already_have / rejected, the card id, each person with their interest_id and phones added, phones skipped and why, the parcel on the card, and parcel_conflict when your card already has a different one (it is kept).',
    inputSchema: { type: 'object', properties: { prospects: { type: 'array', maxItems: 200, items: { type: 'object', properties: {
      owner_name: S('the owner (or the person to ask for)'), owner_type: S('individual, trust, llc, estate'),
      address: S('property street address'), city: S('city / village / town'), zip: S('ZIP'), county: S('county'),
      parcel: S('the parcel / tax key as the county or the statewide parcel layer prints it, e.g. 0791630013000; it lands in the parcel field of the card and ties the card to the county tax and condition records. Without it a single "Parcel: X" line in notes is used'),
      mailing_street: S('owner mailing street'), mailing_city: S('owner mailing city'), mailing_state: S('owner mailing state (sets the texting time zone)'),
      mailing_zip: S('owner mailing ZIP'), property_type: S('house, duplex, ...'), units: { type: 'integer' },
      phones: { type: 'array', items: PHONE }, interests: { type: 'array', items: INTEREST, description: 'the people on this property, each with role, their address and their phones' },
      reasons: { type: 'array', items: REASON },
      source: S('where this prospect came from (defaults to muse)'), notes: S('anything the team should know'),
      wpie_owner_id: { type: 'integer', description: 'the laptop\'s owner id from phones_wanted: the card is keyed to that owner (made or updated), so the laptop texts it from the next plan' } },
      required: ['address'] } } }, required: ['prospects'] } },
  { role: 'intake', name: 'find_prospects',
    description: 'Look up cards by address, phone, a name (owner or anyone on the card) or card id: stage, the people on it (role, status, their address, their phones, their other cards), reasons, motivation (the lines the callers see: tier, tax years and dollars), equity (the grade the laptop gave and its Equity line with every input, value_on_record = equity.value_used), and whether they were texted or replied. reason_details is the record rows (prospect_reasons) and is null on cards that have none; motivation.lines is what the caller app shows under Why this card.',
    inputSchema: { type: 'object', properties: { address: S('part of the street address'), phone: S('a phone number'),
      name: S('part of the owner name'), lead_id: S('a card id'), only_agent: { type: 'boolean', description: 'only cards an agent loaded' },
      limit: { type: 'integer', maximum: 100 } } } },
  // The laptop\'s list of owners who need a phone (app 0190; Colin 2026-11-05: "automatically gives them to muse"). Every
  // night the laptop lists every owner it would text tomorrow if it had a number; Muse claims a batch, traces the owner,
  // and loads the phones with add_prospects naming wpie_owner_id. The laptop copies the phones over within ten minutes.
  { role: 'intake', name: 'phones_wanted',
    description: 'Owners the laptop would text tomorrow if it had a phone: your batch to trace, real need first (two or more years of tax behind, or a foreclosure, estate, probate, inheritance, court-debt, code or vacancy record), then the most years behind. Each comes with wpie_owner_id, the owner, mailing address, property, parcel, county, reasons, tax_years, need, why, est_value and existing_card. Claiming holds the rows for you for two days. When you find numbers, load them with add_prospects and pass wpie_owner_id on the prospect: the card is then keyed to the laptop\'s owner and the laptop texts it from the next plan. No number found: just leave the row; nothing to mark. counts_only=true returns only the counts (open, real need, yours, by county).',
    inputSchema: { type: 'object', properties: { limit: { type: 'integer', maximum: 500, description: 'owners per batch (default 100)' },
      county: S('one county'), need: S('real need | less motivated'), counts_only: { type: 'boolean' } } } },
  // The laptop's list of parcels whose equity is unknown (app 0195; Colin 2026-11-07: "figure out the equity these people
  // have before we waste time on outreach" ... "wire it up, muse can do anything on a browser"). Every night the laptop
  // lists the open cards whose equity grade is unknown or estimated; Muse claims a batch, reads the county's FREE public
  // Register of Deeds index parcel by parcel, and loads what the index shows with mortgage_add. The laptop pulls it
  // within ten minutes and the card's equity line updates on the next refresh.
  { role: 'intake', name: 'mortgages_wanted',
    description: 'Parcels whose equity the laptop cannot grade: your batch to look up in the county Register of Deeds FREE public index (index_url and index_notes say where and how; a parcel with no index_url has no free index: skip it, never pay, never log in). Real need first. Each comes with wpie_property_id, parcel (the tax key to search), address, city, county, owner_name, the grade and line the laptop holds now, need, why and card. Claiming holds the rows for you for two days. For each parcel read the index page for the parcel and report every mortgage, satisfaction / release, assignment and modification the index shows with mortgage_add: document number, recording date, lender, borrower, and the original principal ONLY when the index prints it (never from a paid copy, never estimated). Nothing recorded: mortgage_add with found=false and a note, so the laptop knows the index was searched. A disclaimer that forbids automated use, a CAPTCHA or a login is a gate: stop and say so on the desk. One parcel at a time, a few seconds apart. counts_only=true returns only the counts.',
    inputSchema: { type: 'object', properties: { limit: { type: 'integer', maximum: 200, description: 'parcels per batch (default 50)' },
      county: S('one county'), counts_only: { type: 'boolean' } } } },
  { role: 'intake', name: 'sale_add',
    description: 'Sale history you read for parcels (desk post 130): the laptop holds a last-sale date for one card in five, and tenure is the input its equity grade lacks most. Load recorded transfers only: an assessor record card, WIREX, a DOR transfer return, a deed index; never an estimate or a Zestimate (refused by word). Each sale: parcel_id (as the county prints it), county, sale_date (YYYY-MM-DD), sale_price (digits only; leave it out when the record shows no price: the date alone still gives tenure), source (what kind of record), source_url (the page or file you read, required), notes, and wpie_property_id or lead_id when you have them. Up to 200 per call. The laptop pulls them within ten minutes into sale events and the card\'s Equity line updates on the next refresh.',
    inputSchema: { type: 'object', properties: { sales: { type: 'array', maxItems: 200, items: { type: 'object', properties: {
        parcel_id: S('the tax key as the county prints it'), county: S('county name'), sale_date: S('YYYY-MM-DD'),
        sale_price: { type: 'number', description: 'digits only, only when the record prints a price' }, source: S('assessor record card | WIREX | DOR transfer return | deed index | ...'),
        source_url: S('the page or file read (required)'), notes: S('brief: deed type, grantor/grantee'), wpie_property_id: { type: 'integer' }, lead_id: S('card id, when known') },
        required: ['parcel_id', 'county', 'sale_date', 'source', 'source_url'] } } }, required: ['sales'] } },
  { role: 'intake', name: 'equity_inputs',
    description: 'The full-store equity export, one row per card (pushed nightly from the laptop): every input the equity grade used (assessed and estimated value, value used and its source, last sale date and price and where it came from, tenure start and its source, tax years and dollars, judgment, in-rem, recorded or assumed mortgage balance, debt, equity, share) with the grade, the Equity line, the basis and caveats, tier, families and reasons. Pages of up to 500 rows ordered by lead_id: pass next_after from the last page to continue. county and grade filter; counts_only=true returns the totals (cards, by grade, with a sale date, with a price, pushed_at). Where the laptop has a grade from a record (judgment, Register of Deeds) it wins; your (est) band fills only cards graded unknown or with no laptop property.',
    inputSchema: { type: 'object', properties: { after: S('next_after from the previous page'), limit: { type: 'integer', maximum: 500, description: 'rows per page (default 200)' },
      county: S('one county'), grade: S('clear | likely | thin | underwater | unknown | no laptop property'), counts_only: { type: 'boolean' } } } },
  { role: 'intake', name: 'mortgage_add',
    description: 'What the Register of Deeds index showed for one parcel from your mortgages_wanted batch. wpie_property_id (from the batch), found (true when documents are recorded against the parcel, false when the index was searched and shows nothing), documents: one per recorded document: doc_type (mortgage | satisfaction | assignment | modification | other), document_number, recorded_on (YYYY-MM-DD), amount (the original principal, digits only, only when the index prints it; otherwise leave it out), lender, borrower, satisfies_document_number (on a satisfaction: the mortgage it clears, when shown), notes, source_url (the index page you read, required), page_reference, extraction_confidence (0 to 1). notes: what you searched and saw, in a line. The laptop pulls it within ten minutes; the card\'s Equity line updates on the next refresh.',
    inputSchema: { type: 'object', properties: { wpie_property_id: { type: 'integer' }, found: { type: 'boolean' }, notes: S('what you searched and saw'),
      documents: { type: 'array', maxItems: 50, items: { type: 'object', properties: {
        doc_type: S('mortgage | satisfaction | assignment | modification | other'), document_number: S('as the index prints it'), recorded_on: S('YYYY-MM-DD'),
        amount: { type: 'number', description: 'original principal, digits only, only when the index prints it' }, lender: S('mortgagee / grantee'), borrower: S('mortgagor / grantor'),
        satisfies_document_number: S('on a satisfaction: the mortgage it clears'), notes: S('brief'), source_url: S('the index page read (required)'),
        page_reference: S('row / result number or a short quote'), extraction_confidence: { type: 'number', minimum: 0, maximum: 1 } }, required: ['doc_type', 'source_url'] } } },
      required: ['wpie_property_id'] } },
  { role: 'intake', name: 'packages_to_value', description: 'Packages a caller sent Colin that still need a value: the card (property, people, phones), the condition checklist in the words of the seller, their number and who lives there. For each, find the after-repair value from recent nearby sales and send it with set_package_value. You never set or suggest our number: Colin prices it himself.',
    inputSchema: { type: 'object', properties: { limit: { type: 'integer', maximum: 50 } } } },
  { role: 'intake', name: 'set_package_value', description: 'Write the after-repair value (ARV) for a package: the dollar value, the basis in one or two sentences (which sales, which sources, adjustments), and the comps (address, sold_price, sold_date, sqft, beds, baths, distance, url, note). Colin checks it on the card before he prices. Never a purchase number.',
    inputSchema: { type: 'object', properties: { package_id: S('the package'), arv: { type: 'number', description: 'after-repair value, dollars' },
      basis: S('how you got it'), comps: { type: 'array', items: { type: 'object' } } }, required: ['package_id', 'arv', 'basis'] } },
  { role: 'intake', name: 'handoff_deposit',
    description: 'Hand a set of verified rows to the loading agent in one deposit, with no row data on the desk. First call: title (what the rows are), instructions (how to load them, once, for the whole set) and rows[]. Each row: key (your own id for the row; the same key is the same row, so sending it again replaces it while it waits), prospect (exactly what add_prospects takes for one prospect: address, owner_name or interests[], city, county, zip, parcel, mailing, reasons[], notes, phones) and optionally caller (thalia or tyler: who a NEW card goes to) and note. Up to 250 rows a call: send the rest with the batch_id you got back. final: true on the last call makes the batch ready to load. Then post ONE line on the desk naming the batch, never the rows.',
    inputSchema: { type: 'object', properties: { batch_id: S('the batch to add to (from your first call); leave out to start a new one'), title: S('what these rows are, for a new batch'),
      instructions: S('how the loader should treat the set'), final: { type: 'boolean', description: 'true on the last call: the batch is ready to load' },
      rows: { type: 'array', maxItems: 250, items: { type: 'object', properties: { key: S('your id for the row'), prospect: { type: 'object', description: 'one prospect, as add_prospects takes it' },
        caller: S('thalia | tyler: who a new card goes to'), note: S('anything for the loader about this row') }, required: ['key', 'prospect'] } } } } },
  { role: 'intake', name: 'handoff_batches',
    description: 'The hand-off batches: with no batch_id, every open or recent batch with its counts (waiting, claimed, created, stacked, rejected). With batch_id: that batch, its instructions, its counts and why rows were rejected; rows: true adds each row with its status, its card (lead_id) and its reason (after and limit page through them, status filters, payload: true includes the prospect).',
    inputSchema: { type: 'object', properties: { batch_id: S('e.g. H-12'), rows: { type: 'boolean' }, status: S('waiting | claimed | created | stacked | rejected'),
      after: { type: 'integer', description: 'rows after this row number' }, limit: { type: 'integer' }, payload: { type: 'boolean' } } } },
  { role: 'intake', name: 'handoff_pull',
    description: 'Loader: claim the next rows of a ready batch to read them (default 50, at most 100; with no batch_id, the oldest batch with rows waiting). Returns the batch instructions and each row with its row_id and prospect. Rows you already hold come back first. A claim lapses after two hours. Then handoff_load loads them; handoff_reject refuses one. Do not call add_prospects for these rows.',
    inputSchema: { type: 'object', properties: { batch_id: S('e.g. H-12'), limit: { type: 'integer' } } } },
  { role: 'intake', name: 'handoff_load',
    description: 'Loader: load rows of a batch into WPIE. The server puts each row through the same duplicate guard as add_prospects (one card per property: an address we already have is stacked onto its card, never duplicated), gives a NEW card to the caller the row names, and writes every result back on the row by itself. With no row_ids it loads the rows you hold, or claims and loads the next ones (limit, default 50, at most 100). Returns created / stacked / rejected with the card id per row. When the last row has a result the batch is done and its report goes on the desk by itself: post nothing more about it.',
    inputSchema: { type: 'object', properties: { batch_id: S('e.g. H-12'), row_ids: { type: 'array', items: { type: 'string' }, description: 'only these rows' }, limit: { type: 'integer' } }, required: ['batch_id'] } },
  { role: 'intake', name: 'handoff_reject',
    description: 'Refuse one row of a hand-off without loading it, with the reason (the depositor reads it in handoff_batches). The depositor can use it to withdraw a row that is still waiting.',
    inputSchema: { type: 'object', properties: { row_id: S('the row'), reason: S('why') }, required: ['row_id', 'reason'] } },
  { role: 'intake', name: 'prospect_counts', description: 'How many agent-loaded cards there are, by stage and by source.',
    inputSchema: { type: 'object', properties: {} } },
  // The data pipes' verification queue (migration 0103, Muse's pipes spec 2026-10-28). Staged parcels + signals that
  // passed the gates; a lane claims, verifies and closes with an outcome code. The pipe never makes a card: a verified
  // new item is promoted through add_prospects.
  { role: 'intake', name: 'pipe_counts', description: 'The data pipes at a glance: each source (file date, rows staged), the last runs with their gate counts, the verification queue by state and kind, open owner conflicts on cards, staged signals by kind, and whether the Milwaukee map is loaded.',
    inputSchema: { type: 'object', properties: {} } },
  { role: 'intake', name: 'pipe_queue', description: 'List verification-queue items. state: open (default), claimed, held_buffer (waits for Colin\'s parcel ruling), held, verified, killed. kind: new (no card: promote through add_prospects once verified), stack (a new signal on an existing card), re_screen (a card whose owner changed in the source or disagrees with it).',
    inputSchema: { type: 'object', properties: { state: S('open | claimed | held_buffer | held | verified | killed'), county: S('county'), kind: S('new | stack | re_screen'),
      limit: { type: 'integer', maximum: 200 } } } },
  { role: 'intake', name: 'pipe_claim', description: 'Claim open items for your lane (re-screens first, then oldest). Each comes whole: the signals with source and date, the parcel facts each with source and vintage (owner, mailing, assessed value with its assessment year, type and units), every conflict, what is missing (phones, current_ownership_confirmation, unit_count_evidence, case_detail_read) and the card if it is a stack. A claim you do not close goes back to open after 24 hours. item_id claims one item (or takes back a held one).',
    inputSchema: { type: 'object', properties: { limit: { type: 'integer', maximum: 50 }, county: S('county'), kind: S('new | stack | re_screen'), item_id: S('one item') } } },
  { role: 'intake', name: 'pipe_item', description: 'Read one queue item whole, with its last parcel changes from the source.',
    inputSchema: { type: 'object', properties: { item_id: S('the item') }, required: ['item_id'] } },
  { role: 'intake', name: 'pipe_close', description: 'Close a claimed item. outcome verified: verified = {field: {value, source, date YYYY-MM-DD}} for each field you confirmed (a value field also needs basis "assessed value"; never a judgment, listing, mortgage or estimate), then promote a new one with add_prospects (pass lead_id here if you already did). outcome killed: code = not_residential | over_value_cap | owner_mismatch | sold_or_transferred | no_distress | distress_resolved | bankruptcy_active | deceased_no_representative | card_dead_or_dnc | map_excluded | listed_for_sale | duplicate | bad_data | out_of_area | other (other needs a note). outcome held: note names the blocker. outcome release: back to open. A held_buffer item takes only Colin\'s ruling: ruled_in or ruled_out, with his words in note.',
    inputSchema: { type: 'object', properties: { item_id: S('the item'), outcome: S('verified | killed | held | release | ruled_in | ruled_out'), code: S('the kill code, or a short verified code'),
      note: S('what you found; the blocker for held; Colin\'s words for a ruling'), verified: { type: 'object', description: '{field: {value, source, date, basis?}}' },
      lead_id: S('the card you promoted it to, if any') }, required: ['item_id', 'outcome'] } },
  { role: 'intake', name: 'pipe_set_map', description: 'Load the Milwaukee map as GeoJSON (Polygon, MultiPolygon, Feature or FeatureCollection; [lon, lat]). kind exclusion: inside = excluded, within buffer_m (default 275 m) of its edge = held_buffer for Colin\'s ruling. kind clear: a place the band does not reach (Riverwest: on or east of Holton St is fine). Loading the same name again replaces it. Until an exclusion map is loaded, City of Milwaukee parcels are not queued (map_not_loaded), never guessed.',
    inputSchema: { type: 'object', properties: { name: S('the area name'), kind: S('exclusion | clear'), geojson: { type: 'object' }, buffer_m: { type: 'number' }, note: S('where it came from') },
      required: ['name', 'kind', 'geojson'] } },
  { role: 'sender', name: 'texting_rules', description: 'The rules every text must follow, and the current sending switches. Read this before writing texts.',
    inputSchema: { type: 'object', properties: {} } },
  { role: 'sender', name: 'sending_status', description: 'Is sending on or paused, the window, the daily limit and how much of it is used today, and today\'s texts by status.',
    inputSchema: { type: 'object', properties: {} } },
  { role: 'sender', name: 'ready_to_text',
    description: "Today's list (the day, app 0219): the texts to write today, in order, built by the server from the whole store by the records' rules, real need first. new_cards: first texts (step 1). followups_due (with followups=true): threads that never answered and are due for their next step. next_numbers: cards where the number we texted reached someone else; each comes with the owner's next number. Every row has phone (the number to text), voice (the name to sign: one name per thread), tier and need (why this card), next_step, and the card itself (owner_type, address, people, phones, reasons, what was sent before). laptop_text is the laptop's wording when it planned the same text, for reference only. the_day says how many rows are left to write. A row leaves the list when you queue it. Before the first build of the day the same pool is shown in the same order.",
    inputSchema: { type: 'object', properties: { limit: { type: 'integer', maximum: 300 }, followups: { type: 'boolean' },
      all_sources: { type: 'boolean', description: 'no longer needed: the list is always drawn from the whole store (kept so older calls still work)' } } } },
  { role: 'sender', name: 'store_cards',
    description: 'The whole card store, a page at a time (Colin 2026-11-08: work the book like your own sales rep). Every card: id, owner and type, address, county, city, property (type, units, parcel, lane, score, laptop_card), stage and when it changed, dead_reason, card_owner (Thalia or Tyler), held (parked, resting, human takeover, elderly_or_ill, grief, caller_texting), belt and next stop, check_back_at, named date or event, say_next, reasons with details, motivation (tier, families, lines, tax years and dollars), equity (the laptop\'s grade and Equity line with every input: value and source, last sale date and price, tenure, arrears, judgment, mortgage, debt, share, estimated), people with roles and status, phones (textable, opted_out, blocked, texts sent, last sent, replies), and a cadence summary (texts sent, last out, last in, replied, call_reached, planned). Ordered by updated_at then id, up to 500 a page (default 200): pass next_after.updated_at and next_after.id back as after_updated and after_id to continue; since=<timestamp> gives only cards changed since then (the nightly delta). The first page also carries store_counts. live_only defaults true (no dead, dnc, closed). Read-only: to act, use queue_texts, mark_card, add_prospects.',
    inputSchema: { type: 'object', properties: { after_updated: S('next_after.updated_at from the previous page'), after_id: S('next_after.id from the previous page'),
      since: S('only cards updated at or after this timestamp'), limit: { type: 'integer', maximum: 500 }, county: S('one county'),
      stage: { type: 'array', items: { type: 'string' }, description: 'only these stages' }, live_only: { type: 'boolean', description: 'default true' } } } },
  { role: 'sender', name: 'store_cadence',
    description: 'Conversation and cadence state for up to 200 cards by id: each phone (textable, texts sent, last sent and its status, replies, last reply, opted_out, blocked, hold), the thread (the phone the first text ran on, texts in it, next_step and next_due_day on the 1-3-10-17-24 schedule), replied, last_inbound_at, call_reached, what is planned, and blockers (replied, call_reached, elderly_or_ill, grief, human_takeover, caller_texting, parked, resting, closed, planned_waiting), plus check_back_at, parked_why, rest_until, the belt\'s next stop, named date or event and say_next. Use it to own follow-ups: a card with next_due_day today or earlier and no blockers is due.',
    inputSchema: { type: 'object', properties: { lead_ids: { type: 'array', items: { type: 'string' }, maxItems: 200 } }, required: ['lead_ids'] } },
  { role: 'sender', name: 'queue_texts',
    description: 'Queue texts you wrote. Each: card id, the person (interest_id; without it, the phone\'s person on the card), phone (one of theirs on that card), the exact text, step (1 = first text, 2-5 = follow-ups) and optionally the earliest time to send. The server sends each one inside the recipient\'s window, under the daily limit. Refused texts come back with the reason. Up to 100 per call.',
    inputSchema: { type: 'object', properties: { texts: { type: 'array', maxItems: 100, items: { type: 'object', properties: {
      lead_id: S('card id'), phone: S('phone on that card'), body: S('the exact text'), step: { type: 'integer', minimum: 1, maximum: 5 },
      send_after: S('ISO time, optional'),
      variant: S('A/B test arm this text belongs to, e.g. "A" or "B" (always set it when a test is running)'),
      template: S('short name of the wording, e.g. "own_q" or "intent_q"'),
      slot: S('time-of-day test: am (goes from 9 AM their time) or pm (from 5 PM); leave out for follow-ups'),
      interest_id: S('the person on the card this text is for') }, required: ['lead_id', 'phone', 'body'] } } }, required: ['texts'] } },
  { role: 'sender', name: 'test_results',
    description: 'The test scoreboard: per wording variant, per time slot (am / pm), and per cell (variant/slot), with hot leads too: texts queued, sent, delivered, failed (and carrier-filtered 30007), real conversations (a reply that is not a STOP or a wrong number), STOPs, wrong numbers, and the reply and STOP rates on delivered texts. Default: first texts, last 14 days.',
    inputSchema: { type: 'object', properties: { days: { type: 'integer', maximum: 90 }, step: { type: 'integer', minimum: 1, maximum: 5 } } } },
  { role: 'sender', name: 'text_templates', description: 'The first-text wording for each variant (A own_q, B intent_q, C spare), its version and since when, and every earlier version with the dates it ran. Each first text you queue is stamped with its variant\'s current version; test_results reports by version too.',
    inputSchema: { type: 'object', properties: {} } },
  { role: 'sender', name: 'set_text_template', description: 'Change a variant\'s first-text wording: closes the current version and starts the next one now. Only when Colin has said to change it, and say so in the note. The assignment (which cards get A or B) does not change and no history is lost. The wording must keep a STOP line and no $, cash, as-is or offer.',
    inputSchema: { type: 'object', properties: { variant: S('A | B | C'), name: S('short name, e.g. own_q'), wording: S('the wording, as the brief gives it (person and trust/LLC/estate lines)'),
      note: S('why it changed, and that Colin called it') }, required: ['variant', 'wording', 'note'] } },
  { role: 'sender', name: 'replies_waiting',
    description: 'People who texted back and have no answer from us yet, oldest first. Each comes with the whole card: property, owner, mailing address, reasons, the full conversation both ways, calls, what we already know (motivation, timeline, condition, price, who signs), the card stage and next step, whether it is hot, and how the reply agent read their text (intent, outcome, its suggested reply). Answer each with send_reply.',
    inputSchema: { type: 'object', properties: { days: { type: 'integer', maximum: 30 } } } },
  { role: 'sender', name: 'call_next',
    description: 'Put someone who texted back with a bit of interest at the top of the caller\'s Power hour list, to be called next on the number they texted from. Use it in Power hour (weekdays 4 to 6 PM Central) instead of texting back. words = their reply, word for word. Refused for a dead, DNC, booked or held card, an older or grieving owner, or an opted-out phone. The answer says whether Power hour is on now.',
    inputSchema: { type: 'object', properties: { lead_id: S('card id'), phone: S('their phone (the one that texted us)'), words: S('what they texted, word for word') },
      required: ['lead_id', 'phone', 'words'] } },
  { role: 'sender', name: 'send_reply',
    description: 'Answer someone who texted us, on the same thread (same number). Sent now, unless it is quiet hours, when it goes in the morning. Refused if they opted out, if they texted again since you read the thread (read it again), if it breaks the wording rules, or if a caller (Adil, Thalia) has ever texted that card themselves: from their first text the card is theirs and the AI is off it for good (Colin, 2026-11-07); replies_waiting and queue_texts already leave those cards out. A STOP line is not needed in a reply.',
    inputSchema: { type: 'object', properties: { lead_id: S('card id'), phone: S('their phone (the one that texted us)'), body: S('your reply') },
      required: ['lead_id', 'phone', 'body'] } },
  { role: 'records', name: 'records_overview', description: 'The records-request cycle at a glance: requests by kind and status, how many are due, unhandled replies, drafts waiting, batches waiting for Colin, approved batches not sent yet.',
    inputSchema: { type: 'object', properties: {} } },
  { role: 'records', name: 'records_list', description: 'Records requests (municipal clerks, Registers of Deeds, county treasurers, clerks of court, sheriffs, police records custodians). filter: due (default: never sent, its cadence came round after an answer, or no answer in 14 days: a follow-up every 14 days without end, with why_due), for_colin (fee quotes and denials: Colin decides those, never agree to a fee), all, a status, or a kind. Each has where it goes, its categories, cadence_days, status, sent_date, last_asked, follow_up_count, records_through, next_due, notes, its drafts and replies.',
    inputSchema: { type: 'object', properties: { filter: S('due | for_colin | all | a status (draft, sent, acknowledged, replied, received, no_records, needs_payment, denied, bounced, skip) | a kind (municipal, rod, treasurer, clerk_of_court, sheriff, police)'), limit: { type: 'integer', maximum: 500 } } } },
  { role: 'records', name: 'records_set_request', description: 'Add an office to the records list, or change one (pass its request_id): kind (municipal, rod, treasurer, clerk_of_court, sheriff, police), name, county, to_email, alt_email, form_url, categories (from records_templates.categories), cadence_days (14-400, default 90: how long after an answer the next ask comes), and a note. Nothing sends: you still draft and Colin approves the batch.',
    inputSchema: { type: 'object', properties: { request_id: S('to change an existing request'), kind: S('municipal | rod | treasurer | clerk_of_court | sheriff | police'), name: S('the office, e.g. "Waukesha County Treasurer"'),
      county: S('county'), to_email: S('records email'), alt_email: S('second address'), form_url: S('online request form, if it has one'),
      categories: { type: 'array', items: { type: 'string' } }, cadence_days: { type: 'integer', minimum: 14, maximum: 400 }, note: S('why') } } },
  { role: 'records', name: 'records_templates', description: 'The request letters word for word (municipal, Register of Deeds, county treasurer, clerk of court, sheriff, police) and how to fill them, the category list, and the cadence rule. Write every first request and re-request from these. They ask for records only: never buying, cash or investors.',
    inputSchema: { type: 'object', properties: {} } },
  { role: 'records', name: 'records_replies', description: 'Replies from clerks and Registers of Deeds that came into the records mailbox, oldest first, with the body, attachments (saved on the laptop under data/records/received/) and the request they match. unhandled=true (default) shows only the ones not yet handled.',
    inputSchema: { type: 'object', properties: { unhandled: { type: 'boolean' }, limit: { type: 'integer', maximum: 200 } } } },
  { role: 'records', name: 'records_save_draft', description: 'Write a letter for a request: purpose request (first ask), re_request (the repeat once its cadence comes round), follow_up (no answer yet), or reply (answering a clerk: a fee question, a narrower scope, a corrected address). It replaces the open draft for that request. Nothing sends: drafts go into a batch for Colin.',
    inputSchema: { type: 'object', properties: { request_id: S('the request'), purpose: S('request | re_request | follow_up | reply'), to: S('email address'), cc: S('optional'),
      subject: S('subject line'), body: S('the letter'), in_reply_to: S('the Message-ID being answered, for follow_up and reply') }, required: ['request_id', 'to', 'subject', 'body'] } },
  { role: 'records', name: 'records_propose_batch', description: 'Propose drafts to send, up to 40 letters per call (the mailbox has a daily cap). Follow-ups and re-requests to an address this request already had a letter sent to go out on standing approval (the laptop sends them on its next pass, no click); first requests, replies to a clerk, and any letter that mentions money wait for Colin to approve in the app. The answer says which letters went which way, and why each waiting one waits. Send every records letter through here, never by email outside WPIE, so the record stays in one place.',
    inputSchema: { type: 'object', properties: { draft_ids: { type: 'array', items: { type: 'string' }, maxItems: 40 }, note: S('one line for Colin: what this batch is and why now') }, required: ['draft_ids'] } },
  { role: 'records', name: 'records_agent_state', description: 'The laptop records agent at a glance: whether it is on the ramp (its first 7 days and 25 sent letters; while on it you release its follow-ups), letters sent today against the 60-a-day cap, the backlog stamp and whether new first requests are open, and unread notes for it.',
    inputSchema: { type: 'object', properties: {} } },
  { role: 'records', name: 'records_release_batch', description: 'Ramp review: release (approve=true) or return (approve=false) a batch the records agent proposed. drop = draft ids to send back to the agent with your note while releasing the rest. While Colin has you in charge of the campaign (desk_inbox shows in_charge) you may release first requests too; never a letter that mentions money, a fee-route letter, a letter naming Colin, or a first DA/AG letter in a county (those stay with Colin).',
    inputSchema: { type: 'object', properties: { batch_id: S('the batch'), approve: { type: 'boolean' }, drop: { type: 'array', items: { type: 'string' } }, note: S('why, for the agent') }, required: ['batch_id', 'approve'] } },
  { role: 'records', name: 'records_post_backlog', description: 'Post the unverified-address backlog count (net-new manifest addresses not yet verified). The agent opens new first requests only under 2,000, holds steady from 2,000 to 3,000, pauses them over 3,000, and pauses them when the newest stamp is older than 8 days. Post it every night.',
    inputSchema: { type: 'object', properties: { count: { type: 'integer', minimum: 0 }, note: S('optional') }, required: ['count'] } },
  { role: 'records', name: 'records_log', description: 'The shared notes between you and the records agent (the coordination log, in WPIE): the last days of notes for you or from it. unresolved=true for open items only.',
    inputSchema: { type: 'object', properties: { days: { type: 'integer', maximum: 90 }, unresolved: { type: 'boolean' } } } },
  { role: 'records', name: 'records_log_write', description: 'Leave a note for the records agent (for=records_agent), for Colin (for=colin) or for both (for=all), optionally about one request; resolve=<id> closes a note instead.',
    inputSchema: { type: 'object', properties: { note: S('the note'), for: S('records_agent | colin | all'), request_id: S('optional'), resolve: { type: 'integer' } } } },
  { role: 'records', name: 'records_reinstate_ramp', description: 'A failed audit (a letter outside the playbook, an unstamped ask, a sheet/mailbox mismatch): put the records agent back on the ramp (on=true), or clear it after a clean sample (on=false).',
    inputSchema: { type: 'object', properties: { on: { type: 'boolean' }, reason: S('what failed, or what passed') }, required: ['on', 'reason'] } },
  { role: 'records', name: 'records_portals',
    description: "The records portals worklist (NextRequest, JustFOIA, GovQA): every portal request by office, request number and where it stands by its notices (submitted, documents released, completed, closed, invoice). A portal shows documents only to the signed-in requester, so nothing reaches the mailbox but the notice. waiting=true means documents are there and nobody has brought them in: sign in at site as the requester, download every released document, and hand each one over with records_file_upload then records_file_done. An invoice is a fee: leave it for Colin and say so with records_log_write.",
    inputSchema: { type: 'object', properties: {} } },
  { role: 'records', name: 'records_file_upload',
    description: "Hand a file to the laptop for a records request (a document you downloaded from a portal, or one a clerk gave you another way). Returns upload_url: PUT the raw file bytes to it within 2 hours, for example  curl -X PUT --data-binary @list.xlsx -H 'Content-Type: application/octet-stream' '<upload_url>'  then call records_file_done with the file_id. Give the file's own name with its extension, the portal and the request number. Up to 50 MB a file; one call per file.",
    inputSchema: { type: 'object', required: ['request_id', 'filename'], properties: { request_id: S('the request (records_portals or records_list)'),
      filename: S('the file name with its extension'), portal: S('nextrequest.com, justfoia.com, ...'), number: S('the portal request number, e.g. 26-1698'),
      note: S('what the file is, in a line') } } },
  { role: 'records', name: 'records_file_done',
    description: 'Say the file is uploaded (after the PUT to upload_url). The laptop copies it into the records inbox on its next pass, about 10 minutes, as a reply on that request; the muni intake agent reads it on its next run. Refused if the file is not there yet.',
    inputSchema: { type: 'object', required: ['file_id'], properties: { file_id: S('from records_file_upload') } } },
  { role: 'records', name: 'records_file_get',
    description: "Open an attachment on a reply (records_replies lists each reply's attachments by name). The files live on the laptop: the first call asks for it and answers status asked; the laptop sends it up on its next pass, about 10 minutes; call again and you get url, a link to download the file, good for 10 minutes. Use it when you cannot tell from the reply's words what the clerk sent (a fee letter, a list, a denial).",
    inputSchema: { type: 'object', required: ['reply_id', 'name'], properties: { reply_id: S('the reply'), name: S('the attachment name as listed') } } },
  { role: 'records', name: 'records_mark', description: 'Update a request after reading a reply or a bounce: status (acknowledged, replied, received, no_records, needs_payment, denied, bounced, skip, draft), a note, received_date, records_through (the last date the records cover: the next re-request starts the day after), next_due (received and no_records default to the cadence_days of the request), a corrected to_email, and reply_id to mark that reply handled.',
    inputSchema: { type: 'object', properties: { request_id: S('the request'), status: S('new status'), note: S('what happened'), received_date: S('YYYY-MM-DD'),
      records_through: S('date the records cover through'), next_due: S('YYYY-MM-DD'), to_email: S('corrected address'), reply_id: S('the reply this handles') }, required: ['request_id'] } },
  { role: 'any', name: 'due_today',
    description: 'Every card whose time has come, oldest first, each with the whole card and why it was waiting: check_back (a dated not-now, a hold, an estate or family wait whose date arrived), booked_call / booked_visit (today), call_due / text_due (a stop the team or you owes), contract_waiting (a contract sent and not signed, with who still has to sign). days_late says how overdue. Also `stuck`: the safety net, cards that would otherwise be lost: no_next_step (a warm card with no date), reply_unanswered (2+ hours), unlogged_call, text_stale (planned, never went), unknown_caller (a text from a phone no card has), dormant_replied (put to sleep after they replied). Read both lists every morning and act on each one: a text, a mark_card, or tell Colin. Nothing on either list may stay there two days running.',
    inputSchema: { type: 'object', properties: {} } },
  { role: 'any', name: 'call_list',
    description: 'The callers\' list for a day (default today, Central): every open call task for Thalia or Adil due that day or earlier, in the order they work it: promised callbacks, texters you sent to call_next, then the daily call list by its rank (the laptop posts it the evening before, due 7 AM), then other call stops. Each with the card, why, days_late, dials_today and the last call outcome; a task logged today shows done_at. due_today does not list these tasks: read call_list for what the callers have.',
    inputSchema: { type: 'object', properties: { date: S('YYYY-MM-DD') } } },
  { role: 'channel', name: 'desk_inbox',
    description: 'The desk channel (Colin 2026-10-29): messages between the laptop verification desk (Claude), Muse, Dots (OpenAI) and Colin. Returns in_charge (the standing grant from Colin: you make the campaign decisions for the desk as if you ran the campaign, and colin_only, what never moves to you), open_questions the desk is waiting on you to decide, and messages since since_id. Read it at the start of every session and answer every open question the same day.',
    inputSchema: { type: 'object', properties: { since_id: { type: 'integer' }, open_only: { type: 'boolean' } } } },
  { role: 'channel', name: 'desk_post',
    description: 'Post to the desk channel: kind note (information), report (finished work), or question (you need the desk or Colin to choose: options = [{id, label}], at least two). for = desk (default), colin or all. reply_to = the message you answer. Work batches, results and hand-offs to the desk go here, not in the records log.',
    inputSchema: { type: 'object', properties: { kind: S('note | report | question'), for: S('desk | colin | all'), topic: S('short subject'), body: S('the message (12,000 characters max)'),
      options: { type: 'array', items: { type: 'object', properties: { id: S('short id'), label: S('what it means') } } }, reply_to: { type: 'integer' } }, required: ['kind', 'body'] } },
  { role: 'channel', name: 'desk_decide',
    description: 'Decide a question the desk put to you (Muse while Colin has Muse in charge; Dots posts its view with desk_post instead): choice = one option id, reason = why, in a sentence or two. Your answer is the decision of record and the desk acts on it. Decide as the person running the campaign: what gets the most finished, callable cards at no cost. Anything on the colin_only list is not yours: pick the option that sends it to Colin, or post a question for colin.',
    inputSchema: { type: 'object', properties: { question_id: { type: 'integer' }, choice: S('the option id'), reason: S('why') }, required: ['question_id', 'choice', 'reason'] } },
  { role: 'any', name: 'mark_card',
    description: 'Mark a card the way the team does from its buttons. Person marks close one person, not the property: deceased (with interest_id or phone: closed on every card; if the card died only as no contact or by the death and someone live remains, it reopens), wrong_person (not connected to this property: closed on this card only), and dnc with interest_id or phone (that person is do-not-contact on every card and that number is blocked; when the person is an owner, the property closes too). When nobody live is left on a card, it holds for a re-trace. Property marks: dead (not interested), dnc with no person (the whole card: every phone blocked for good), not_now (with date = when to check back, or reason = what has to change first), hot (wants to sell / asked for a call: Colin is pinged and the card goes to him), held (reason = the named blocker, optional date), release (reason = what cleared: a held or not-now card goes back to the stage it had before the hold, and a texting thread picks up its follow-ups again), wrong_number (phone = the number that was never them), elderly, grief, note (reason = the note), or note_delete (reason = at least 8 characters of a note of yours to remove; your own notes only, and the removed text stays in the history of the card; to correct a note, note_delete then note). Returns the stage and belt of the card after the mark.',
    inputSchema: { type: 'object', properties: { lead_id: S('card id'),
      mark: S('deceased | wrong_person | dnc | dead | not_now | hot | held | release | wrong_number | elderly | grief | note | note_delete'),
      interest_id: S('the person on the card, for deceased, wrong_person and a person-level dnc'),
      reason: S('why, in their words where possible; the blocker for held; the condition for not_now without a date; what cleared for release; the note for note; words from the note to remove for note_delete'),
      date: S('ISO time: the check-back date for not_now, or when a held card should be looked at again'),
      phone: S('the phone, for wrong_number, or to say which person (deceased, wrong_person, dnc)') }, required: ['lead_id', 'mark'] } },
  // Muse does its own card work (0211; Colin 2026-11-09: "i dont want to have to approve posts ... how do we remove me in
  // the loop"): the five requests Muse used to post to the desk, each with the rule the desk applied written into the
  // database function, which says in words why it refused.
  { role: 'any', name: 'reassign_card',
    description: 'Give a card to Thalia or Tyler (person: thalia | adil; Tyler is adil in the app). The open calls and callbacks on the card go with it. A reason is required and goes on the card. Colin owns no cards and none are moved to him.',
    inputSchema: { type: 'object', properties: { lead_id: S('card id'), person: S('thalia | adil'), reason: S('why it moves') }, required: ['lead_id', 'person', 'reason'] } },
  { role: 'any', name: 'add_call_task',
    description: 'Put a card on its caller Power hour list as a call task (source power_hour). Rules in the function: a sheriff sale is callable only 14 or more days out (sale_date is refused inside the window, and the title and note carry the sale date and the last call day); the card must be live, must have a caller (its locked_to, or owner when it has none, which then locks the card), and must have a dialable phone, else the queue would never show the task; a card marked elderly, grief or taken over by a caller is refused; a card you held (belt hold_not_now) loses the hold date, because the queue hides a card until that date, while the hold and its reason stay; a date set by the seller or Colin is never overridden. One open list task per card: a second call returns the existing one. rank orders the list that day (lower first) and is written as call list (#rank) in the note; without rank the task is due now.',
    inputSchema: { type: 'object', properties: { lead_id: S('card id'), sale_date: S('YYYY-MM-DD sheriff sale date when there is one'), reason: S('why the caller should dial it'),
      rank: { type: 'integer', description: 'position in the list that day, lower first' }, owner: S('thalia | adil, only for a card that has no caller yet') }, required: ['lead_id', 'reason'] } },
  { role: 'any', name: 'close_task',
    description: 'Close a caller call task that should not be dialed (stale list task, duplicate). Allowed when the card is closed (dead, dnc, closed, under contract), when the card is one you hold (belt hold_not_now), or when it is a duplicate of another open call task for the same caller. Refused: the belt own stop (a logged call or the caller closes it), a callback the seller was promised while the card is live, and the only call task on a live unheld card (that one is the caller to close, or hold the card first). A reason is required. Never changes the card itself.',
    inputSchema: { type: 'object', properties: { task_id: S('the task (from call_list)'), reason: S('why it closes') }, required: ['task_id', 'reason'] } },
  { role: 'any', name: 'merge_people',
    description: 'Two records on one card for one person (a spelling variant, a middle name): keep one, drop the other. The stricter status wins and is never lost (deceased, do_not_contact, not_the_contact); phones and emails move to the kept record; the dropped record is removed only if it is on no other card (else refused: merge it there too, or link the cards). Pass the two interest_id values from the card people list. A reason is required.',
    inputSchema: { type: 'object', properties: { lead_id: S('card id'), keep_interest_id: S('the person record to keep'), drop_interest_id: S('the duplicate record'), reason: S('why they are one person') }, required: ['lead_id', 'keep_interest_id', 'drop_interest_id', 'reason'] } },
  { role: 'any', name: 'merge_cards',
    description: 'Two cards for one property: keep one, close the duplicate. Refused unless they share a parcel or the same address and municipality, and refused when the duplicate has a texting thread, a promised callback or a deal (then link_cards same_person and keep both). Phones, people, reasons and notes the kept card lacks move over; a do-not-contact on the duplicate makes the kept card do-not-contact too; the duplicate closes as a duplicate with its open tasks, and the two are linked. A reason is required.',
    inputSchema: { type: 'object', properties: { keep_lead_id: S('the card to keep'), drop_lead_id: S('the duplicate to close'), reason: S('why they are one property') }, required: ['keep_lead_id', 'drop_lead_id', 'reason'] } },
  // The Research Board (0213; Colin 2026-11-10 through desk posts 174/175): where every research source stands, one page
  // in WPIE that Muse and the desk both tick and Colin only reads.
  { role: 'any', name: 'research_board',
    description: 'The Research Board: the 20 source jobs in priority order with their status note and monthly ticks Nov 2026 to Oct 2027, and the 21 buy-box counties with their five legs (foreclosure_cv, probate_pr, tax, need_signal, sale_refresh). A tick means the job ran end to end that month: pull, verification, cards in WPIE. In progress is a status note, not a tick.',
    inputSchema: { type: 'object', properties: {} } },
  { role: 'any', name: 'research_board_set',
    description: 'Tick a job for a month (done true only when the cycle ran end to end that month; false to untick), add a note on that month, and/or set the job status note. job is the number (1-20) or key (foreclosure_cv, sale_refresh, post_sale_rechecks, probate_pr, tax_delinquent, evictions, bankruptcy, money_judgments, divorce_fa, guardianship_gn, water_shutoff, fire_damage, vacant_registry, code_raze, stage_d_verification, name_to_parcel, rod_mortgages, deed_pulls, phone_tracing, mls_comps). month is any date in that month.',
    inputSchema: { type: 'object', properties: { job: S('job number or key'), month: S('YYYY-MM-DD, any day of the month'), done: { type: 'boolean' }, note: S('a note on that month'), status: S('the job status note, replaces the old one') }, required: ['job'] } },
  { role: 'any', name: 'research_board_county_set',
    description: 'Tick one leg for one buy-box county (done true/false, optional note). legs: foreclosure_cv, probate_pr, tax, need_signal, sale_refresh.',
    inputSchema: { type: 'object', properties: { county: S('buy-box county name'), leg: S('foreclosure_cv | probate_pr | tax | need_signal | sale_refresh'), done: { type: 'boolean' }, note: S('optional') }, required: ['county', 'leg', 'done'] } },
  { role: 'any', name: 'link_cards',
    description: 'Link two cards: same_person (one owner, two cards), other_property (they mentioned another place), estate_contact (the person handling an estate), shared_phone, occupant (lives there, not the owner), co_owner, related. Shown on both cards.',
    inputSchema: { type: 'object', properties: { lead_id: S('card id'), other_id: S('the other card id'),
      kind: S('same_person | other_property | estate_contact | shared_phone | occupant | co_owner | related'), note: S('what connects them') },
      required: ['lead_id', 'other_id', 'kind'] } },
  { role: 'sender', name: 'offer_worklist',
    description: 'Every open offer by text, one row per card, each with its ONE next step (next.step and next.say), whose step it is (you, Colin, the seller, a caller), when it is due, whether it is late, and the gate that blocks a number. yours[] comes first: do each one. Also the call tasks past their time that nobody dialed on cards where the seller wrote back, and the rule with every repair item and its dollars. Read it at the start of every session and after replies_waiting.',
    inputSchema: { type: 'object', properties: {} } },
  { role: 'sender', name: 'offer_open',
    description: 'Put a card on the offer path: the seller asked what we would pay, or said yes to selling. A text that plainly asks for a number opens one by itself, so read offer_worklist first. Give their words. The worklist then walks it: the one condition question, the comp, Colin\'s OK, the number.',
    inputSchema: { type: 'object', properties: { lead_id: S('card id'), words: S('what the seller wrote that opens this'),
      trigger: S('asked_number | yes_to_selling | other'), phone: S('the number the thread is on') }, required: ['lead_id', 'words'] } },
  { role: 'sender', name: 'offer_update',
    description: 'Record what you learned or did on an open offer; the server recomputes the numbers and the next step and returns the row. Send any of: condition_asked (true once you texted the condition question); condition_words (their answer, in their words) together with repair_items (roof, furnace, foundation, plumbing, electrical, water, fire, kitchen, bath, floors, windows, sewer, cleanout, cosmetic) or, when they named no items, repair_level (light | medium | heavy); the comp: arv, arv_basis, comps[] and sqft of the house; what they told you: need, their_number, their_words, flexible, timeline, occupancy, signers, seller_email; their answer to our number: response (accepted | counter | no) with response_words and, for a counter, counter_number; answer (your reply to a question Colin asked on this offer). You never send a figure of ours: the rule computes it and Colin OKs it.',
    inputSchema: { type: 'object', properties: { offer_id: S('the offer (or give lead_id)'), lead_id: S('the card, when you do not have the offer id'),
      condition_asked: { type: 'boolean' }, condition_words: S('their answer on the condition, in their words'),
      repair_items: { type: 'array', items: { type: 'string' }, description: 'the big items they named' }, repair_level: S('light | medium | heavy, only when they named no items'),
      arv: { type: 'number', description: 'after-repair value, dollars' }, arv_basis: S('how you got it: which sales, which sources, adjustments'),
      comps: { type: 'array', items: { type: 'object' }, description: 'each: address, sold_price, sold_date, sqft, beds, baths, distance, url, note' },
      sqft: { type: 'integer', description: 'the house, square feet' },
      need: S('why they would sell, in their words'), their_number: { type: 'number', description: 'the figure they named, dollars' },
      their_words: S('how they said it and where the figure came from'), flexible: S('firm | flexible | unknown'), timeline: S('when they want it done'),
      occupancy: S('who lives there'), signers: S('everyone who signs'), seller_email: S('the email the papers go to'),
      response: S('accepted | counter | no: their answer to the number Colin OK\'d'), response_words: S('what they wrote'),
      counter_number: { type: 'number', description: 'their counter, dollars' }, answer: S('your answer to a question Colin asked on this offer') } } },
  { role: 'sender', name: 'offer_close',
    description: 'Close an offer with no deal. why: retail (their number is above what it is worth fixed up), no_comp_set, vague_condition, silent, declined, passed (Colin passed), records (listed, a sale inside 14 days, underwater, out of area), caller_took_it, not_selling, under_contract, or other with a note. Then give the card its disposition with mark_card.',
    inputSchema: { type: 'object', properties: { offer_id: S('the offer'), why: S('the reason code'), note: S('a few words') }, required: ['offer_id', 'why'] } },
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
TOOLS.push(...CALENDAR_TOOLS)

/** The wording check for a reply (no STOP line needed in the middle of a conversation). */
export function replyProblem(body: string): string | null {
  const b = (body ?? '').trim()
  if (!b) return 'empty reply'
  if (b.length > 480) return 'over 480 characters'
  if (/\bcash\b/i.test(b)) return 'no "cash" in a text'
  if (/https?:\/\/|www\./i.test(b)) return 'no links'
  if (/\b(llc|inc|company|investors?|our team)\b/i.test(b)) return 'sounds like a business: write as Colin, one person'
  return null
}

/** The wording check before a text is queued (the database checks STOP, length and the business name again; the price check was removed 2026-11-08). */
/** The wording check for a queued text. The STOP way out is required on a first text (step 1), where the opt-out
 * notice belongs; a follow-up (steps 2-5) may leave it out (Colin 2026-10-29: the step-2 test arm, after 10 of 11
 * traced STOPs followed a step 2 that ended "just reply STOP"). Everything else applies to every step. */
export function textProblem(body: string, step = 1): string | null {
  const b = (body ?? '').trim()
  if (!b) return 'empty text'
  if (step <= 1 && !/\bSTOP\b/.test(b)) return 'a first text needs a STOP line (e.g. "Reply STOP if you\'d rather not hear from me.")'
  if (b.length > 320) return 'over 320 characters'
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
/** What is waiting on this agent that it has not looked at (0225): its offer steps and unread desk posts, put first
 *  in the answers it reads every few minutes. Never fails the call it rides on. */
async function withAttention(db: DoorDb, agent: string, value: Record<string, unknown>): Promise<Record<string, unknown>> {
  try {
    const a = await db.records('agent_attention', { p_agent: agent })
    return a && typeof a === 'object' ? { attention: a, ...value } : value
  } catch {
    return value
  }
}

const int = (v: unknown, d: number, max: number) => Math.max(1, Math.min(max, Number.isFinite(Number(v)) && v !== null && v !== undefined ? Math.floor(Number(v)) : d))

export async function callTool(name: string, args: Json, agent: Agent, db: DoorDb): Promise<{ value: unknown; isError?: boolean }> {
  const tool = TOOLS.find((t) => t.name === name)
  if (!tool) return { value: { error: `no tool ${name}` }, isError: true }
  const scope = scopeOf(tool)
  if (!scopesOf(agent).includes(scope)) return { value: { error: `this key has no ${scope} scope, so it cannot use ${name} (Colin switches scopes in Settings > Agent keys)` }, isError: true }
  if (agent.tools && !agent.tools.includes(name)) return { value: { error: `this key is limited to: ${agent.tools.join(', ')}; ${name} is not on its list. Post to the desk and Muse handles it.` }, isError: true }
  if (isCalendarTool(name)) return callCalendarTool(name, args, agent.name, db.calendar)
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
    case 'handoff_deposit': {
      const r = await db.records('agent_handoff_deposit', { p: args, p_agent: agent.name }) as Json
      return { value: r, isError: r?.ok === false }
    }
    case 'handoff_batches': {
      const r = await db.records('agent_handoff_batches', { p: args, p_agent: agent.name }) as Json
      return { value: r, isError: !Array.isArray(r) && r?.ok === false }
    }
    case 'handoff_pull': {
      const r = await db.records('agent_handoff_pull', { p_batch: args.batch_id ? String(args.batch_id) : null, p_limit: int(args.limit, 50, 100), p_agent: agent.name }) as Json
      return { value: r, isError: r?.ok === false }
    }
    case 'handoff_load': {
      const ids = Array.isArray(args.row_ids) ? (args.row_ids as unknown[]).map(String).slice(0, 100) : null
      const r = await db.records('agent_handoff_load', { p_batch: String(args.batch_id ?? ''), p_row_ids: ids && ids.length ? ids : null,
        p_limit: int(args.limit, 50, 100), p_agent: agent.name }) as Json
      return { value: r, isError: r?.ok === false }
    }
    case 'handoff_reject': {
      const r = await db.records('agent_handoff_reject', { p_row_id: String(args.row_id ?? ''), p_reason: String(args.reason ?? ''), p_agent: agent.name }) as Json
      return { value: r, isError: r?.ok === false }
    }
    case 'prospect_counts': return { value: await db.prospectCounts() }
    case 'phones_wanted': return { value: await db.records('agent_phones_wanted', { p_agent: agent.name, p_limit: int(args.limit, 100, 500),
      p_county: args.county ? String(args.county) : null, p_need: args.need ? String(args.need) : null, p_counts_only: args.counts_only === true }) }
    case 'mortgages_wanted': return { value: await db.records('agent_mortgages_wanted', { p_agent: agent.name, p_limit: int(args.limit, 50, 200),
      p_county: args.county ? String(args.county) : null, p_counts_only: args.counts_only === true }) }
    case 'mortgage_add': {
      const r = await db.records('agent_mortgage_add', { p: { wpie_property_id: args.wpie_property_id, found: args.found, notes: args.notes,
        documents: Array.isArray(args.documents) ? (args.documents as Json[]).slice(0, 50) : [] }, p_agent: agent.name }) as Json
      return { value: r, isError: r?.ok === false }
    }
    case 'sale_add': {
      const r = await db.records('agent_sale_add', { p: { sales: Array.isArray(args.sales) ? (args.sales as Json[]).slice(0, 200) : [] }, p_agent: agent.name }) as Json
      return { value: r, isError: r?.ok === false }
    }
    case 'equity_inputs': return { value: await db.records('agent_equity_inputs', { p_after: args.after ? String(args.after) : null, p_limit: int(args.limit, 200, 500),
      p_county: args.county ? String(args.county) : null, p_grade: args.grade ? String(args.grade) : null, p_counts_only: args.counts_only === true }) }
    case 'packages_to_value': return { value: await db.records('agent_packages_to_value', { p_limit: int(args.limit, 20, 50) }) }
    case 'set_package_value': {
      const r = await db.records('package_set_value', { p_id: String(args.package_id ?? ''), p_arv: Number(args.arv), p_basis: String(args.basis ?? ''),
        p_comps: Array.isArray(args.comps) ? args.comps : [], p_agent: agent.name }) as Json
      return { value: r, isError: r?.ok === false }
    }
    case 'pipe_counts': return { value: await db.records('pipe_door_counts', {}) }
    case 'pipe_queue': return { value: await db.records('pipe_door_list', { p_state: args.state ? String(args.state) : 'open', p_county: args.county ? String(args.county) : null,
      p_kind: args.kind ? String(args.kind) : null, p_limit: int(args.limit, 50, 200) }) }
    case 'pipe_claim': return { value: await db.records('pipe_door_claim', { p_agent: agent.name, p_limit: int(args.limit, 10, 50), p_county: args.county ? String(args.county) : null,
      p_kind: args.kind ? String(args.kind) : null, p_item: args.item_id ? String(args.item_id) : null }) }
    case 'pipe_item': {
      const r = await db.records('pipe_door_item', { p_id: String(args.item_id ?? '') }) as Json
      return { value: r, isError: r?.ok === false }
    }
    case 'pipe_close': {
      const r = await db.records('pipe_door_close', { p_id: String(args.item_id ?? ''), p_agent: agent.name, p_outcome: String(args.outcome ?? ''),
        p_code: args.code ? String(args.code) : null, p_note: args.note ? String(args.note) : null,
        p_verified: args.verified && typeof args.verified === 'object' ? args.verified : null, p_lead_id: args.lead_id ? String(args.lead_id) : null }) as Json
      return { value: r, isError: r?.ok === false }
    }
    case 'pipe_set_map': {
      const r = await db.records('pipe_door_set_map', { p_agent: agent.name, p_name: String(args.name ?? ''), p_kind: String(args.kind ?? ''),
        p_geojson: args.geojson ?? null, p_buffer_m: args.buffer_m === undefined || args.buffer_m === null ? null : Number(args.buffer_m),
        p_note: args.note ? String(args.note) : null }) as Json
      return { value: r, isError: r?.ok === false }
    }
    case 'texting_rules': return { value: { rules: TEXTING_RULES, status: await db.status() } }
    case 'sending_status': return { value: await withAttention(db, agent.name, await db.status()) }
    case 'ready_to_text':
      return { value: await db.readyToText({ limit: int(args.limit, 50, 300), followups: !!args.followups, all_sources: !!args.all_sources }) }
    case 'store_cards':
      return { value: await db.records('agent_store_cards', { p_after_updated: args.after_updated ? String(args.after_updated) : null,
        p_after_id: args.after_id ? String(args.after_id) : null, p_since: args.since ? String(args.since) : null, p_limit: int(args.limit, 200, 500),
        p_county: args.county ? String(args.county) : null, p_stage: Array.isArray(args.stage) ? (args.stage as unknown[]).map(String) : null,
        p_live_only: args.live_only !== false }) }
    case 'store_cadence': {
      const ids = Array.isArray(args.lead_ids) ? (args.lead_ids as unknown[]).map(String).slice(0, 200) : []
      if (!ids.length) return { value: { error: 'lead_ids is an empty list' }, isError: true }
      return { value: await db.records('agent_store_cadence', { p_lead_ids: ids }) }
    }
    case 'queue_texts': {
      const list = Array.isArray(args.texts) ? (args.texts as Json[]).slice(0, 100) : []
      if (!list.length) return { value: { error: 'texts is an empty list' }, isError: true }
      const results = []
      for (const t of list) {
        const body = String(t.body ?? '').replace(/\s+/g, ' ').trim()
        const why = textProblem(body, int(t.step, 1, 5))
        if (why) { results.push({ lead_id: t.lead_id, status: 'refused', reason: why }); continue }
        const r = await db.queueText({ lead_id: String(t.lead_id ?? ''), phone: String(t.phone ?? ''), body,
          step: int(t.step, 1, 5), send_after: t.send_after ? String(t.send_after) : null,
          variant: t.variant ? String(t.variant) : null, template: t.template ? String(t.template) : null, slot: t.slot ? String(t.slot) : null,
          interest_id: t.interest_id ? String(t.interest_id) : null }, agent.name)
        results.push({ lead_id: t.lead_id, ...r })
      }
      return { value: { queued: results.filter((r) => r.status === 'queued').length, refused: results.filter((r) => r.status !== 'queued').length, results } }
    }
    case 'due_today': return { value: await db.dueToday() }
    case 'call_list': return { value: await db.records('agent_call_list', { p_date: args.date ? String(args.date) : null }) }
    case 'desk_inbox': return { value: await db.records('desk_read', { p_for: channelAuthor(agent), p_since: Math.max(0, Math.floor(Number(args.since_id ?? 0)) || 0), p_open_only: args.open_only === true, p_limit: 100 }) }
    case 'desk_post': return { value: await db.records('desk_post', { p_author: channelAuthor(agent), p_for: args.for ? String(args.for) : 'desk', p_kind: String(args.kind ?? 'note'),
      p_topic: args.topic ? String(args.topic) : null, p_body: String(args.body ?? ''), p_options: Array.isArray(args.options) ? args.options : null,
      p_reply_to: args.reply_to ? int(args.reply_to, 0, 2147483647) : null }) }
    case 'desk_decide': return { value: await db.records('desk_decide', { p_question_id: int(args.question_id, 0, 2147483647), p_choice: String(args.choice ?? ''),
      p_reason: String(args.reason ?? ''), p_author: channelAuthor(agent) }) }
    case 'records_overview': return { value: await db.records('records_overview', {}) }
    case 'records_templates': return { value: await db.records('records_templates', {}) }
    case 'records_list': return { value: await db.records('records_list', { p_filter: args.filter ? String(args.filter) : 'due', p_limit: int(args.limit, 100, 500) }) }
    case 'records_replies': return { value: await db.records('records_replies_list', { p_unhandled: args.unhandled !== false, p_limit: int(args.limit, 50, 200) }) }
    case 'records_save_draft': return { value: await db.records('records_save_draft', { p_request_id: String(args.request_id ?? ''), p_purpose: String(args.purpose ?? 'request'),
      p_to: String(args.to ?? ''), p_cc: args.cc ? String(args.cc) : null, p_subject: String(args.subject ?? ''), p_body: String(args.body ?? ''),
      p_in_reply_to: args.in_reply_to ? String(args.in_reply_to) : null, p_agent: agent.name }) }
    case 'records_propose_batch': return { value: await db.records('records_propose_batch', { p_draft_ids: Array.isArray(args.draft_ids) ? (args.draft_ids as unknown[]).map(String) : [],
      p_note: args.note ? String(args.note) : null, p_agent: agent.name }) }
    case 'records_agent_state': return { value: await db.records('records_agent_state', {}) }
    case 'records_release_batch': return { value: await db.records('records_muse_decide', { p_batch_id: String(args.batch_id ?? ''), p_approve: args.approve === true,
      p_drop: Array.isArray(args.drop) ? (args.drop as unknown[]).map(String) : [], p_note: args.note ? String(args.note) : null, p_agent: agent.name }) }
    case 'records_post_backlog': return { value: await db.records('records_post_backlog', { p_count: Math.max(0, Math.floor(Number(args.count ?? -1))), p_note: args.note ? String(args.note) : null, p_agent: agent.name }) }
    case 'records_log': return { value: await db.records('records_log_read', { p_for: 'muse', p_days: int(args.days, 7, 90), p_unresolved: args.unresolved === true }) }
    case 'records_log_write':
      if (args.resolve) return { value: await db.records('records_log_resolve', { p_id: int(args.resolve, 0, 2147483647), p_by: agent.name }) }
      return { value: await db.records('records_log_write', { p_author: 'muse', p_for: String(args.for ?? 'records_agent'), p_note: String(args.note ?? ''),
        p_request_id: args.request_id ? String(args.request_id) : null }) }
    case 'records_reinstate_ramp': return { value: await db.records('records_reinstate_ramp', { p_reason: String(args.reason ?? ''), p_agent: agent.name, p_on: args.on !== false }) }
    case 'records_portals': return { value: await db.records('records_portals', {}) }
    case 'records_file_upload': {
      if (!db.recordsFileUpload) return { value: { ok: false, reason: 'file hand-off is not available here' }, isError: true }
      const r = await db.recordsFileUpload({ request_id: String(args.request_id ?? ''), filename: String(args.filename ?? ''),
        portal: args.portal ? String(args.portal) : null, number: args.number ? String(args.number) : null, note: args.note ? String(args.note) : null }, agent.name)
      return { value: r, isError: (r as Json)?.ok === false }
    }
    case 'records_file_done': {
      if (!db.recordsFileDone) return { value: { ok: false, reason: 'file hand-off is not available here' }, isError: true }
      const r = await db.recordsFileDone(String(args.file_id ?? ''), agent.name)
      return { value: r, isError: (r as Json)?.ok === false }
    }
    case 'records_file_get': {
      if (!db.recordsFileGet) return { value: { ok: false, reason: 'file hand-off is not available here' }, isError: true }
      const r = await db.recordsFileGet(String(args.reply_id ?? ''), String(args.name ?? ''), agent.name)
      return { value: r, isError: (r as Json)?.ok === false }
    }
    case 'records_mark': return { value: await db.records('records_mark', { p_request_id: String(args.request_id ?? ''), p_status: args.status ? String(args.status) : null,
      p_note: args.note ? String(args.note) : null, p_received_date: args.received_date ? String(args.received_date) : null,
      p_records_through: args.records_through ? String(args.records_through) : null, p_next_due: args.next_due ? String(args.next_due) : null,
      p_to_email: args.to_email ? String(args.to_email) : null, p_reply_id: args.reply_id ? String(args.reply_id) : null, p_agent: agent.name }) }
    case 'mark_card': {
      const mark = String(args.mark ?? '')
      if (mark === 'deceased' || mark === 'wrong_person' || (mark === 'dnc' && (args.interest_id || args.phone))) {
        const r = await db.markPerson({ lead_id: String(args.lead_id ?? ''), mark, interest_id: args.interest_id ? String(args.interest_id) : null,
          phone: args.phone ? String(args.phone) : null, reason: args.reason ? String(args.reason) : null }, agent.name)
        return { value: r, isError: r.ok === false }
      }
      return { value: await db.markCard({ lead_id: String(args.lead_id ?? ''), mark: String(args.mark ?? ''), reason: args.reason ? String(args.reason) : null,
        date: args.date ? String(args.date) : null, phone: args.phone ? String(args.phone) : null }, agent.name) }
    }
    case 'reassign_card': {
      const r = await db.records('agent_reassign_card', { p_lead_id: String(args.lead_id ?? ''), p_person: String(args.person ?? ''), p_why: args.reason ? String(args.reason) : null, p_agent: agent.name }) as Json
      return { value: r, isError: r?.ok === false }
    }
    case 'add_call_task': {
      const r = await db.records('agent_add_call_task', { p_lead_id: String(args.lead_id ?? ''), p_sale_date: args.sale_date ? String(args.sale_date) : null, p_why: args.reason ? String(args.reason) : null,
        p_rank: typeof args.rank === 'number' ? Math.trunc(args.rank) : null, p_owner: args.owner ? String(args.owner) : null, p_agent: agent.name }) as Json
      return { value: r, isError: r?.ok === false }
    }
    case 'close_task': {
      const r = await db.records('agent_close_task', { p_task_id: String(args.task_id ?? ''), p_why: args.reason ? String(args.reason) : null, p_agent: agent.name }) as Json
      return { value: r, isError: r?.ok === false }
    }
    case 'merge_people': {
      const r = await db.records('agent_merge_people', { p_lead_id: String(args.lead_id ?? ''), p_keep_interest_id: String(args.keep_interest_id ?? ''), p_drop_interest_id: String(args.drop_interest_id ?? ''),
        p_why: args.reason ? String(args.reason) : null, p_agent: agent.name }) as Json
      return { value: r, isError: r?.ok === false }
    }
    case 'merge_cards': {
      const r = await db.records('agent_merge_cards', { p_keep_lead_id: String(args.keep_lead_id ?? ''), p_drop_lead_id: String(args.drop_lead_id ?? ''), p_why: args.reason ? String(args.reason) : null, p_agent: agent.name }) as Json
      return { value: r, isError: r?.ok === false }
    }
    case 'research_board': return { value: await db.records('research_board', {}) }
    case 'research_board_set': {
      const r = await db.records('agent_research_set', { p_job: String(args.job ?? ''), p_month: args.month ? String(args.month) : null,
        p_done: typeof args.done === 'boolean' ? args.done : null, p_note: args.note ? String(args.note) : null, p_status: args.status ? String(args.status) : null, p_agent: agent.name }) as Json
      return { value: r, isError: r?.ok === false }
    }
    case 'research_board_county_set': {
      const r = await db.records('agent_research_county_set', { p_county: String(args.county ?? ''), p_leg: String(args.leg ?? ''), p_done: args.done === true,
        p_note: args.note ? String(args.note) : null, p_agent: agent.name }) as Json
      return { value: r, isError: r?.ok === false }
    }
    case 'link_cards':
      return { value: await db.linkCards({ lead_id: String(args.lead_id ?? ''), other_id: String(args.other_id ?? ''), kind: String(args.kind ?? ''),
        note: args.note ? String(args.note) : null }, agent.name) }
    case 'replies_waiting': return { value: await db.repliesWaiting(int(args.days, 7, 30)) }
    case 'call_next': {
      const r = await db.records('agent_call_next', { p_lead_id: String(args.lead_id ?? ''), p_phone: String(args.phone ?? ''),
        p_words: String(args.words ?? ''), p_agent: agent.name }) as Json
      return { value: r, isError: r?.ok === false }
    }
    case 'send_reply': {
      const body = String(args.body ?? '').replace(/\s+/g, ' ').trim()
      const why = replyProblem(body)
      if (why) return { value: { status: 'refused', reason: why }, isError: true }
      // one name per thread (0219): a reply signed with another name than the thread's is refused
      const name = await db.records('text_rule_problem', { p_lead_id: String(args.lead_id ?? ''), p_body: body, p_step: 0 })
      if (typeof name === 'string' && name) return { value: { status: 'refused', reason: name }, isError: true }
      return { value: await db.sendReply({ lead_id: String(args.lead_id ?? ''), phone: String(args.phone ?? ''), body }, agent.name) }
    }
    case 'offer_worklist': return { value: await db.records('agent_offer_worklist', {}) }
    case 'offer_open': {
      const r = await db.records('agent_offer_open', { p_lead_id: String(args.lead_id ?? ''), p_trigger: String(args.trigger ?? 'yes_to_selling'),
        p_words: String(args.words ?? ''), p_phone: String(args.phone ?? ''), p_agent: agent.name }) as Json
      return { value: r, isError: r?.ok === false }
    }
    case 'offer_update': {
      const r = await db.records('agent_offer_update', { p: args, p_agent: agent.name }) as Json
      return { value: r, isError: r?.ok === false }
    }
    case 'offer_close': {
      const r = await db.records('agent_offer_close', { p_offer_id: String(args.offer_id ?? ''), p_why: String(args.why ?? ''),
        p_note: args.note ? String(args.note) : null, p_agent: agent.name }) as Json
      return { value: r, isError: r?.ok === false }
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
    case 'text_results': return { value: await withAttention(db, agent.name, await db.results(int(args.hours, 24, 168))) }
    case 'test_results': return { value: await db.testResults(int(args.days, 14, 90), int(args.step, 1, 5)) }
    case 'text_templates': return { value: await db.textTemplates() }
    case 'set_text_template': {
      const r = await db.setTextTemplate({ variant: String(args.variant ?? '').toUpperCase(), name: args.name ? String(args.name) : null,
        wording: String(args.wording ?? '').trim(), note: String(args.note ?? '').trim() }, agent.name)
      return { value: r, isError: r.ok === false }
    }
    case 'records_set_request': {
      const { request_id, kind, name: office, county, to_email, alt_email, form_url, categories, cadence_days, note } = args
      const p: Json = { request_id, kind, name: office, county, to_email, alt_email, form_url, cadence_days, note }
      if (Array.isArray(categories)) p.categories = (categories as unknown[]).map(String)
      for (const k of Object.keys(p)) if (p[k] === undefined || p[k] === null) delete p[k]
      return { value: await db.records('records_set_request', { p, p_agent: agent.name }) }
    }
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
      instructions: agent.role === 'agent'
        ? `One key for WPIE, with these scopes switched on: ${scopesOf(agent).join(', ')}. Every call is logged and every tool has a per-minute budget per key (find_prospects 30, ready_to_text 10; queue_texts, send_reply, mark_card, call_next have none): over it you are refused, and three times over it in five minutes locks that tool for five minutes. Pace and batch lookups; the same database sends the texts. Read desk_inbox at the start of every session: the desk and Colin talk to you there. Phones: phones_wanted is the laptop\'s list of owners who need a number; trace a batch each night and load what you find with add_prospects naming wpie_owner_id. Equity: mortgages_wanted is the laptop's list of parcels whose equity it cannot grade; read the county's free Register of Deeds index for a batch each night and load what it shows with mortgage_add. Texting: read texting_rules first. Records: a batch sends only after a review. Cards: read due_today every morning.`
        : agent.role === 'records'
        ? 'You run the public-records-request cycle: read records_overview, records_replies and records_list(due); mark what came back; draft letters from records_templates; propose batches. Colin approves every batch before anything sends.'
        : agent.role === 'intake'
        ? 'You load seller prospects into the WPIE app with add_prospects. You check the prospect rules before loading; the app accepts what you send.'
        : 'You run the WPIE texting: read texting_rules first, then ready_to_text, write texts, queue_texts, and watch text_results. Pause if something looks wrong.',
    })
  }
  if (method === 'ping') return ok(id, {})
  if (method === 'tools/list') {
    return ok(id, { tools: TOOLS.filter((t) => toolAllowed(agent, t)).map(({ name, description, inputSchema }) => ({ name, description, inputSchema })) })
  }
  if (method === 'tools/call') {
    const p = (msg.params ?? {}) as Json
    const tool = String(p.name ?? '')
    const known = TOOLS.find((t) => t.name === tool)
    const started = Date.now()
    const log = async (okay: boolean, value: unknown) => {
      if (!db.logCall) return
      const err = okay ? null : String((value as Json | null)?.error ?? (value as Json | null)?.reason ?? 'refused')
      try { await db.logCall({ tool, scope: known ? scopeOf(known) : null, ok: okay, error: err, ms: Date.now() - started }) } catch { /* the log never blocks a call */ }
    }
    try {
      const over = db.rateCheck && known ? await db.rateCheck(tool).catch(() => null) : null   // a failed check never blocks a call
      if (over) { const value = { error: over }; await log(false, value); return ok(id, textResult(value, true)) }
      const r = await callTool(tool, (p.arguments ?? {}) as Json, agent, db)
      await log(!r.isError, r.value)
      return ok(id, textResult(r.value, !!r.isError))
    } catch (e) {
      const value = { error: e instanceof Error ? e.message : String(e) }
      await log(false, value)
      return ok(id, textResult(value, true))
    }
  }
  return fail(id, -32601, `method not found: ${method}`)
}

/** Who a key speaks as on the desk channel: a key named for Dots (OpenAI) is Dots; every other key is Muse. */
export function channelAuthor(agent: Agent): 'dots' | 'muse' | 'muse 2' {
  if (/\bdots?\b|openai/i.test(agent.name)) return 'dots'
  return /\bmuse\s*2\b/i.test(agent.name) ? 'muse 2' : 'muse'
}

/** A key in the URL, for MCP clients that cannot send a header (ChatGPT connectors): .../agent-mcp/k/<key> or ?key=<key>. */
export function keyFromUrl(url: string): string | null {
  try {
    const u = new URL(url)
    const m = u.pathname.match(/\/k\/(wpie_[a-z]+_[0-9a-f]{64})\/?$/)
    return m ? m[1] : (u.searchParams.get('key')?.match(/^wpie_[a-z]+_[0-9a-f]{64}$/)?.[0] ?? null)
  } catch { return null }
}

/** The key from the request: Authorization: Bearer <key>, or x-api-key. */
export function keyFrom(headers: Headers): string | null {
  const a = headers.get('authorization') ?? ''
  const m = a.match(/^Bearer\s+(\S+)$/i)
  return m ? m[1] : (headers.get('x-api-key') || null)
}
