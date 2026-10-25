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

## Roles

| Key | Tools |
|---|---|
| **intake** | `add_prospects`, `find_prospects`, `prospect_counts` |
| **sender** | `texting_rules`, `sending_status`, `ready_to_text`, `queue_texts`, `todays_queue`, `withdraw_texts`, `pause_sending`, `resume_sending`, `text_results` |

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

## Code

- `supabase/functions/agent-mcp/index.ts`: transport and keys.
- `supabase/functions/_shared/agentDoor.ts`: the tools and the wording check.
- Migrations `0055_agent_door.sql` and `0056_agent_door_reads.sql`.
- Tests: `tests/agentDoor.test.ts`.
