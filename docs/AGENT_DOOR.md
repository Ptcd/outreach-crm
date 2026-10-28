# The agent door (MCP)

WPIE's app is agent first (Colin, 2026-10-25). Agents such as Muse, or any MCP client, connect to one MCP server:

```
https://jyfetargyaaxcqmxdgft.supabase.co/functions/v1/agent-mcp
```

The transport is streamable HTTP. It is stateless: JSON-RPC goes in by POST and JSON comes back, with no event stream.

Each agent sends its own key as `Authorization: Bearer <key>` (or `x-api-key: <key>`). Colin makes the keys in the app, under **Settings > Agent keys**:

- A key is shown once.
- Only its hash is stored.
- **Turn off** stops that agent at once.

## Scopes: one key (migration 0078)

One key does everything Colin switches on for it. Each scope is a switch on the key in **Settings > Agent keys**. Turn one off and the door refuses that part at once, and drops it from `tools/list`. Every `tools/call` is logged in `agent_calls`: key, tool, scope, ok or refused, the error, and how long it took. The key list shows calls and refusals for the last 24 hours.

| Scope | Tools |
|---|---|
| **prospects** | `add_prospects`, `find_prospects`, `prospect_counts`, `packages_to_value`, `set_package_value`, and the pipes' verification queue: `pipe_counts`, `pipe_queue`, `pipe_claim`, `pipe_item`, `pipe_close`, `pipe_set_map` (docs/PIPES.md) |
| **texting** | `texting_rules`, `sending_status`, `ready_to_text`, `queue_texts`, `test_results`, `text_templates`, `set_text_template`, `replies_waiting`, `send_reply`, `todays_queue`, `withdraw_texts`, `pause_sending`, `resume_sending`, `text_results` |
| **calendar** | `open_slots`, `book_slot`, `cancel_booking` |
| **records** | `records_overview`, `records_list`, `records_set_request`, `records_templates`, `records_replies`, `records_save_draft`, `records_propose_batch`, `records_mark` |
| **marks** | `due_today`, `mark_card`, `link_cards` |

The older single-role keys still work, with exactly what their role had: intake = prospects + marks, sender = texting + calendar + marks, records = records. Colin turns them off once the one key is live.

No guardrail moved with the scopes. The wording check, the daily cap and window, slot and variant assignment, and Colin's approval of every records batch all stay where they were.

## Versioned first-text wording (texting scope)

Each variant (A = `own_q`, B = `intent_q`, C = spare) has a template with versions in `text_templates`. `text_templates` shows the current wording of each, and every earlier version with the dates it ran. `set_text_template` closes the current version and opens the next, but only when Colin has called the change. It needs a note, a STOP line, and no $, cash, as-is or offer.

Every agent first text is stamped with its variant's version when it is queued (`planned_openers.template_version`). `test_results` adds `versions`: the same scores per variant version, with `ran_from` and `ran_to`. The assignment does not change: the variant still comes from the last character of the card id. No history is lost.

## Intake: `add_prospects`

The intake agent applies the prospect rules itself, so the door accepts every prospect that has an address and an owner. A prospect with the same address and owner merges into the existing card, which picks up the new phones and reasons. Up to 200 per call.

```json
{ "prospects": [ {
  "owner_name": "Pat Sample", "address": "12 Maple St", "city": "Waukesha", "zip": "53186", "county": "Waukesha",
  "mailing_state": "WI",
  "phones": [ { "number": "414-555-0142", "type": "mobile", "name": "Pat Sample" } ],
  "reasons": [ { "kind": "tax_delinquent", "label": "Behind on taxes 2 years", "detail": "2024 and 2025",
                 "amount": 6100, "date": "2026-01-31", "source": "Waukesha County treasurer" } ],
  "source": "muse", "notes": "anything the team should know" } ] }
```

Each card it makes:

- gets a negative owner number (the laptop's cards are positive);
- starts at stage `opener_queued`;
- shows its reasons on the card.

## Sender: writing and queueing texts

Read `texting_rules` first. Then:

1. Get the cards from `ready_to_text` (pass `followups: true` for the follow-ups that are due).
2. Write each text and send them with `queue_texts`.
3. Watch `text_results`.

```json
{ "texts": [ { "lead_id": "<card id>", "phone": "4145550142", "step": 1,
  "body": "Hi Pat, Colin Merrill here. Are you still the owner of 12 Maple St? Reply STOP if you'd rather not hear from me." } ] }
```

**What the door refuses:**

- a text with no STOP line;
- a text with `$`, a price or an offer;
- "cash" or "as-is";
- a link;
- business words;
- more than 320 characters;
- a phone that opted out, is do-not-contact or a landline;
- a card that is closed;
- a person who already texted back;
- a second text waiting for the same step.

**What the send check still enforces on every queued text** (`claim_next_opener`, the same check the laptop's texts pass):

- the sending switch and any pause;
- no Sundays;
- 10 AM to 7 PM in the recipient's time zone;
- one daily limit shared with the laptop;
- not already texted, not replied, not suppressed;
- a STOP on any of the card's phones blocks the whole card.

A text queued outside the window goes at the start of the next allowed window.

**Pausing:** `pause_sending` stops all texting. The agent can lift only its own pause; a pause Colin or the team made is lifted in the app.

## Booking Colin's calls (sender key)

Colin's Google Calendar is behind the booking. He connects it once in **Settings > Calendar** (Google's own consent page; the refresh token is sealed on the server and never reaches the browser) and sets the hours he takes calls and visits, the slot lengths, the gap between them, the notice and how far ahead people can book.

- `open_slots` `{kind: call|visit, after?, limit?}`: his next open times, Central time. Busy events on the calendars he picked, other bookings and other agents' live holds are already taken out. `suggest` is two or three spread out to offer.
- `book_slot` `{lead_id, start, kind?, phone?, pillars: {why, condition, timeline, their_number, who_signs}, note?}`: a hold on the slot (one lock for every booking, so two agents can't take it), Google free/busy checked again, then the event (seller, phone, address, pillars, link to the card) and the card moves with `belt_event 'next_step'`, the same move as the app's booking: `call_booked` / `visit_booked`, `named_date` at the slot. A card with a booking is moved to the new time and the old event comes off. Refused, with `alternatives`, when the time was taken; refused for a closed, do-not-contact, older/ill or grieving card.
- `cancel_booking` `{lead_id, reason?}`: the event comes off and the card goes back to `yes_unbooked` (a person calls to set a new time).

Colin's own edits flow back every 10 minutes (pg_cron `wpie-calendar-sync`): an event he moves moves the card's `named_date`; an event he deletes cancels the booking and puts the card on `yes_unbooked`.

Code: `supabase/functions/_shared/calendar.ts` (slots, sealing, Google, the flows, the tools), `supabase/functions/calendar` (consent, Settings actions, sync), migration `0074_calendar.sql`, tests `tests/calendar.test.ts`. Secret `CALENDAR_TOKEN_KEY` seals the tokens.

## Code

- `supabase/functions/agent-mcp/index.ts`: transport and keys.
- `supabase/functions/_shared/agentDoor.ts`: the tools and the wording check.
- Migrations `0055_agent_door.sql` and `0056_agent_door_reads.sql`.
- Tests: `tests/agentDoor.test.ts`.

## Marking and linking cards (both keys)

`mark_card` moves a card the way the team's own buttons do. `mark` is one of:

- `dead`: not interested.
- `dnc`: asked not to be contacted. Every phone on the card is blocked for good.
- `not_now`: with `date` (when to check back) or `reason` (what has to change first).
- `hot`: wants to sell or asked for a call. Colin is pinged and the card goes to him.
- `held`: `reason` is the named blocker; `date` is optional.
- `wrong_number`: `phone` is the number that was never them.
- `elderly`, `grief`: the card is flagged and every pending text is cancelled.
- `note`: `reason` is the note.

`link_cards` connects two cards: `same_person`, `other_property`, `estate_contact`, `shared_phone`, `occupant`, `co_owner` or `related`, with a note. Links show on both cards under `links`; a phone that is also on another card shows under `phones[].also_on`.

## What is due (both keys)

`due_today` lists every card whose time has come, oldest first, each with the whole card and `why` it was waiting:

- `check_back`: a dated not-now, a hold, or an estate, family or elderly wait whose date arrived.
- `booked_call` / `booked_visit`: today.
- `call_due` / `text_due`: a stop the team or the agent owes.
- `contract_waiting`: a contract sent and not signed, with who still has to sign.

`days_late` says how overdue it is. The card carries `check_back_at`, `named_date`, `named_event`, `notes`, the conversation and `contracts`, so the agent sees why it was waiting before it acts.

## Records requests (records key)

The public-records letters to municipal clerks and county Registers of Deeds run through the app (migration 0072).

Six kinds of office: municipal clerks, Registers of Deeds, county treasurers, clerks of circuit court, sheriffs, and police records custodians (0078). Each request has its own `categories` (from `records_templates.categories`) and `cadence_days` (default 90). `records_set_request` adds an office or changes one.

1. The agent reads `records_overview`, `records_replies` (clerks' answers, copied in from the records mailbox by the laptop) and `records_list`. A request is due when it was never sent, or when an answer (received or no records) is `cadence_days` old. It is also due when there has been no answer for 14 days since `last_asked`: a polite follow-up every 14 days, without end, counted in `follow_up_count`.
   Fee quotes (`needs_payment`) and denials go to Colin. `records_list('for_colin')` lists them, and they show on his Approve page. The agent never agrees to a fee.
2. It marks what came back (`records_mark`).
3. It writes letters from `records_templates` (`records_save_draft`) and proposes them in batches of up to 40 (`records_propose_batch`).

**Nothing sends until Colin approves the batch** on the Approve page. The laptop (`tools/records_bridge.py`, in the live cycle every 10 minutes) then sends only the approved letters from the records mailbox, 30 to 60 seconds apart, and writes back the Message-ID. A refusal stops the pass.
