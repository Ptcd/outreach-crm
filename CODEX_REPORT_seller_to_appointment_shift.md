# Seller-to-appointment shift — handoff for Claude

Date: 2026-10-23 UTC  
Status: implemented and tested locally; not pushed, merged, deployed, or applied to a live database

## Exact source and deliverable

- Repository: `https://github.com/Ptcd/outreach-crm`
- Isolated worktree: `C:\Users\onkau\Documents\Codex\2026-10-22\task-5\outreach-crm-seller-appointment`
- Branch: `codex/seller-appointment-shift`
- Base: `origin/wpie-live` at `0e2df5217b03bde38c1dcfce525f4fbe79105691`
- Baseline regression commit: `4a2b43335f1894441ed58d6d9cc08e9dac23d65c`
- Implementation commit: `0841d39994b5c90157ddfa802912f4cb3526079a`
- Operator-manual reconciliation commit: `bf9b1e9546a625d5b302c49c9131df9d0c743fe5`
- Prior reviewed audit milestone: `40105ed9fb01b37797ede365534d5e19243d102a`
- Previous audit report: `CODEX_REPORT_day_in_the_life.md` (Library identity `libfile_9b6dab843d4081919dab90ee8f1bfcb6`)
- WPIE compatibility reference: `origin/main` at `536606b78a1a8d160e9d0c3715aadce2672f39b6`
- Frozen statewide branch/worktree `07aa1872` was not touched.

## What changed

### 1. Exact follow-up dates

The existing migration `0035_not_now_date.sql` already stores a seller-named date before the belt routes the call. This shift preserves it and removes the UI's misleading automatic 30-day date choice:

- “Not now” starts with no date preselected.
- The caller must choose either a specific date or an event/condition with a written note.
- A specific calendar date is stored at noon Milwaukee time, independent of the device time zone.
- DST regressions cover both CST and CDT.
- An event-only answer still has the existing 30-day internal review reminder, but the UI labels that as a review reminder rather than a date the seller gave.
- Migration `0038_not_now_manual_alignment.sql` reconciles the implementation with WPIE operator-manual commit `536606b78a1a8d160e9d0c3715aadce2672f39b6`: an exact-date card now has no seller contact before that day. The first stop is Colin's call on or after the named instant, followed by one seven-day retry.
- The migration supersedes a queued or approval-waiting legacy pre-date draft, closes its task, and remaps active old steps (`1/2 -> 1`, `3 -> 2`). It refuses to run while a matching draft is `sending`, because an uncertain provider outcome must be reconciled first.
- Rescheduling updates the same stable belt task to the new date; the old due time is not left open.

### 2. No forgotten conversations

Migration `0037_seller_appointment_shift.sql` adds `seller_recovery_queue`, which lists:

- a human call whose outcome still needs logging;
- a touched live lead with no next action;
- a live belt card with no next stop; and
- an overdue live stop.

Every row has `recovery_owner`. Explicit assignments win; Colin keeps owner/visit work; otherwise weekdays route to Thalia and weekends to Adil in `America/Chicago`. Terminal, resting, fully suppressed, and untouched cold-text inventory stay out.

The Today page renders missing work directly under Follow-up debt in a distinct "Missing date / next stop" subsection with a `missing date` tag and responsible person. Pending call outcomes and overdue belt stops remain in the adjacent Conversation recovery subsection.

### 3. Human takeover without a second conveyor

Both the browser Call button and the new “Calling on personal phone” button use the same RPC, `begin_human_call`.

The RPC:

- requires a signed-in team member;
- requires the destination to be a phone on that lead card;
- calls the existing service-role-only `phone_is_blocked` check;
- rejects terminal/DNC cards;
- marks the current belt as paused in place rather than creating another state machine;
- suppresses queued belt drafts while remembering their exact prior statuses;
- marks hot alerts called;
- uses a client attempt key for retry and concurrent-click idempotency; and
- refuses to overlap a provider-uncertain text already marked `sending`.

`resume_human_call` is the explicit “call did not happen” path. It restores the exact held draft status and leaves the belt step/time untouched. A saved call outcome clears the pause only after the ordinary `belt_on_message` trigger routes that outcome to the next existing stop. STOP or another terminal transition clears the marker and remains final.

The conveyor worker now calls `belt_claim_text_guarded`. The due-text scan, guarded claim, and missed-stop sweep all leave an active human takeover alone. An uncertain browser SDK error stays paused for recovery; it is not automatically resumed.

### 4. Appointment packet

A booked visit now shows one deterministic Appointment packet on the lead card:

- property and property type/units;
- seller/owner and speaking identity;
- reason for selling;
- condition/work;
- seller's number;
- timing/move plan;
- decision-makers/signers;
- occupancy/access;
- appointment time;
- booking-gate result and hard stops; and
- a generated unresolved list.

The packet only reads persisted WPIE, call-script, reply, and gate facts. Missing fields display `Unknown — ask and record`; no fact, price, condition, signer, or visit time is inferred.

## Database migration and contracts

Apply migrations in numeric order. `0037` depends on `0035` (dated `log_call`) and `0036` (`phone_is_blocked`). `0038` then changes only the existing `not_now_dated` belt cadence and performs its targeted active-card reconciliation. `0037` adds nullable lead columns:

- `human_takeover_at`
- `human_takeover_by`
- `human_takeover_phone`
- `human_takeover_key`
- `human_takeover_drafts`

New/replaced database interfaces:

- `begin_human_call(uuid, text, text, text, timestamptz)` — authenticated
- `resume_human_call(uuid, text, timestamptz)` — authenticated
- `seller_recovery_owner(...)`
- `seller_recovery_queue` — authenticated read
- `belt_claim_text_guarded(uuid, boolean, boolean, timestamptz)` — service role
- `belt_due_texts(...)` — replaced to exclude active human takeover
- `belt_sweep_missed(...)` — replaced to exclude active human takeover
- message/lead triggers clear a takeover after a logged outcome or terminal transition

`0037` has no data backfill: existing rows receive null takeover fields, and the recovery view derives existing debt immediately. `0038` has a deliberately bounded backfill for active `not_now_dated` cards only: it supersedes unsent legacy pre-date drafts, closes their tasks, remaps their old step number, and schedules the replacement call. It does not rewrite stages, assignees, WPIE identifiers, terminal cards, or any other belt.

The Edge worker contract changes from `belt_claim_text` to `belt_claim_text_guarded`. Deploy both database migrations before the updated conveyor function. Deploying the worker first would make claims fail because the RPC would not exist; it would fail closed (no belt text), but the conveyor would be unhealthy.

Rollback considerations:

1. First return the conveyor worker to `belt_claim_text`.
2. Resolve or explicitly resume every row with `human_takeover_at is not null`; do not silently discard uncertain call state.
3. If rolling back `0038`, resolve every exact-date task/draft first. Restoring the retired four-day-early text would contradict the current operator manual, so prefer a forward repair or a call-only cadence.
4. Remove the `0037` view, RPCs, and triggers if rollback is still required.
5. The additive nullable columns may safely remain. Dropping them is optional and should happen only after step 2.

## Conveyor invariants preserved

- One belt engine remains authoritative (`belt_event`/`belt_enter`); there is no parallel scheduler.
- An exact Not-now date creates no seller contact before the named day; rescheduling leaves one call task at the replacement date and cancels the old queued touch.
- STOP/DNC is final. No resumed call, inbound interest, or recovery row moves a DNC card.
- Suppressed/bad/DNC phones are rejected by the app authorization RPC and excluded from callable recovery.
- A booked visit remains Colin-owned, including reassignment attempts.
- Exact retries and concurrent duplicate taps create one takeover event; a different attempt cannot begin until the active one is resolved.
- Rescheduling leaves one open belt task at the corrected time.
- A paused card cannot be claimed for text or swept as missed.
- A failed-to-start call can resume the exact prior stop and approval draft.
- Sunday seller sends still slide to Monday; Sunday staff alerts remain allowed.
- Colin-first-person wording, STOP lines, price/offer/company/postcard guards, elderly/grief protections, role permissions, and legitimate resume behavior remain unchanged.
- Existing WPIE contracts (`belt_mirror_cold`, `belt_wpie_event`, `cards_no_stop`, lifecycle pull, call-outcome pull) are unchanged.

## Verification

All tests used synthetic/PGlite data and mocked providers. No live call, text, email, database write, credential read, or schedule change occurred.

- `npm test` - **307 passed**, 38 test files.
  - Includes baseline matrix, no-early-contact exact date, CST/CDT boundaries, legacy queued-text migration, reschedule replacement, duplicate/concurrent takeover, interrupted resume, in-flight-text refusal, missed-call sweep, STOP/DNC, suppression, weekend ownership, Thalia -> Adil -> Colin simulated shift, and appointment unknowns.
  - jsdom prints its known `HTMLCanvasElement.getContext` warning in the signing-page test; the test passes.
- `npx tsc -b --force` — **passed**.
- `npm run build` — **passed**; Vite emitted only the existing large-chunk advisory.
- Changed-file ESLint command - **passed** for the changed files outside `src/lib/dialer.tsx`; that file remains covered by the full lint result below because of its pre-existing file-wide fast-refresh findings.
- `npm run lint` — **not green at baseline**: 8 pre-existing errors remain (7 `react-refresh/only-export-components` reports in `src/lib/dialer.tsx`, 1 unused `COLIN` fixture in `tests/alertsApprovalsHandoff.test.ts`). This shift added no new lint category/error.
- WPIE `python -m pytest -q -p no:cacheprovider tests/test_live_conveyor.py tests/test_live_sync.py tests/test_morning_belts.py` — **26 passed**.
- `git diff --check` — **passed**.

## Unresolved blocker: provider-side DNC enforcement

This branch improves app-side authorization, but it must not be described as security at the actual calling backend.

The app's Twilio token still carries a generic outgoing application grant. The code comments identify the production TwiML target as `pm-phone /api/twilio/voice/client`, but that source is not present in any accessible local repository. A fresh fetch of the only local phone-capable repository (`Ptcd/google-maps-data-dashboard`, `origin/main` `2a4192493cb6a19620ee3d99f3e4077cd3527b41`) found `/api/twilio/voice`, not the named `/client` route, and no WPIE `phone_is_blocked` call. It appears to be a different/general SDR backend, so modifying it would be unsafe and out of scope.

Before browser calling is considered fail-closed, the actual TwiML application backend must:

1. normalize `To` to exactly ten US digits;
2. call WPIE's service-role `phone_is_blocked` immediately before emitting `<Dial>`;
3. refuse invalid, lookup-error, suppressed, DNC, and bad-number results;
4. validate the Twilio webhook signature and restrict caller IDs to the seller-number pool; and
5. add backend tests proving an arbitrary `To` cannot bypass those checks.

That needs the exact `pm-phone` repository/deployment mapping and secrets/configuration authority. None was available or accessed here.

## Controlled staging smoke checklist (no sellers)

1. Snapshot current migration version and counts for live belts, open belt tasks, `cards_no_stop`, and suppressed phones.
2. Apply `0037` in a non-production/staging database; confirm it performs no backfill writes to existing belt/task rows.
3. Before `0038`, confirm there are no `sending` belt drafts on `not_now_dated`; reconcile any uncertain provider outcome. Apply `0038`, then verify every active dated card has no queued pre-date draft and exactly one correct call stop on or after its named date.
4. Deploy the updated conveyor function after both migrations and run it dry; verify heartbeat/canary and zero RPC errors.
5. Use a synthetic lead/test phone: tap browser Call twice concurrently; confirm one `human_call_started` event and no text claim.
6. Repeat with "Calling on personal phone"; confirm the same pause and a Conversation recovery row.
7. With an approval draft waiting, pause and choose "call did not happen"; confirm the same draft status and belt stop return.
8. Simulate an uncertain SDK failure; confirm the card remains paused until explicit resume or a logged outcome.
9. Log no-answer, interested, exact-date not-now, and reached-no-decision outcomes; confirm one correct next stop each. Reschedule the dated outcome and confirm the old stop/draft stays closed.
10. Send a synthetic STOP during a pause; confirm DNC, zero open outreach, and no recovery row.
11. Reschedule a callback and visit; confirm one open task and Colin ownership for the visit.
12. Open the appointment packet and confirm unknown source fields remain visibly unknown.
13. Verify WPIE dry push/pull and belt health queries remain compatible.
14. Separately prove provider-side DNC rejection at the real `pm-phone` TwiML endpoint before enabling browser calling.

## Release decision

The local branch is ready for independent code review. Do not deploy or enable browser calling yet: provider-side DNC enforcement at the named TwiML backend remains unverified and unresolved. No push, PR, merge, deployment, production mutation, schedule installation, or live contact was performed.
