# WPIE integration and browser-call safety — handoff for Claude

Date: 2026-10-23 UTC  
Status: implemented and verified locally; not pushed, merged, deployed, or applied to any live database

## Exact repositories and commits

### Outreach CRM / conveyor

- Repository: `https://github.com/Ptcd/outreach-crm`
- Worktree: `C:\Users\onkau\Documents\Codex\2026-10-22\task-5\outreach-crm-integration-safety`
- Branch: `codex/integration-safety-next`
- Refreshed base: `origin/wpie-live` at `0e3a20b83d1b31c3e9fa699dd65190886df1f8b6`
- Safety implementation: `7f7449babd10a3eaca35d91417c5408fdfc90353`
- Deterministic regression correction: `493edbdda73764ff71babb741156d25daecceb85`
- Frozen code HEAD before this report: `493edbdda73764ff71babb741156d25daecceb85`
- The reviewed `17f24f046d0529949b43e0a02ec2fc6fb9d28618` milestone is already an ancestor of this base. Claude's later `64f579f` and migration-`0040` commit `0e3a20b` are also preserved; nothing was cherry-picked over or duplicated.

### pm-phone / Twilio application backend

- Repository: `https://github.com/Ptcd/pm-phone`
- Worktree: `C:\Users\onkau\Documents\Codex\2026-10-22\task-5\pm-phone-integration-safety`
- Branch: `codex/wpie-call-safety-next`
- Refreshed base: `origin/main` at `d07d6375f5335cd9acbcc2690c016b3c4ce50eae`
- Safety implementation and frozen HEAD: `eeaf68d7199a261d23cddf948e6cf573244086d6`

The frozen statewide worktree/branch at `07aa1872` was not touched. No existing published history was rewritten.

## Baseline reconciliation

The current outreach base already contains every reviewed seller-to-appointment change through migration `0039`, plus Claude's shared-phone migration `0040`. Migration numbers are contiguous and collision-free; this batch adds only `0041_human_call_provider_gate.sql`.

The real backend was found at `Ptcd/pm-phone`. Its current main already validates the Twilio webhook signature, restricts caller ID to configured seller lines, and fails closed through WPIE's service-only `phone_is_blocked` RPC. That was a real improvement over the earlier audit report, but the lookup was still phone-only: `/api/twilio/voice/client` could not prove that the destination belonged to the lead whose automation was paused, that the pause was still active, or that a single provider call owned the attempt.

## What changed

### One authorization, from the card to the provider

The outreach browser now sends four custom TwiML application parameters after `begin_human_call` returns the required `{ok:true, paused:true}`:

- `To`
- `line`
- `leadId`
- `takeoverKey`

Twilio adds its own `CallSid`. The pm-phone route passes the complete tuple to WPIE's new service-role-only `claim_human_call_provider` RPC before it emits `<Dial>`.

Migration `0041` adds a small authorization-claim ledger, not a second conveyor. Under the existing lead-first lock order the RPC rechecks, at the provider boundary:

- the lead exists and is not terminal (`dnc`, `dead`, `closed_no_contact`, or `closed_won`);
- an exact human takeover is still active;
- the takeover key and normalized 10-digit destination match;
- the destination is still a phone contact on that lead;
- the current assignee still matches the immutable assignment snapshot from call start;
- the existing authoritative `phone_is_blocked` verdict is clean, including STOP, app/vendor/scrub DNC, suppression, and bad-number flags; and
- the Twilio `CallSid` has not claimed another authorization.

The first valid provider request records one claim. An exact retry with the same `CallSid` is idempotently allowed. A second `CallSid`, changed lead/key/phone, reassignment, STOP/DNC, outcome, or explicit resume is rejected. Concurrent claims serialize; a cross-lead unique-key race returns a fail-closed verdict rather than exposing a database error.

The claims table has RLS enabled and no browser policy. Both the table and RPC are unavailable to `anon` and `authenticated`; only `service_role` can execute the gate. The provider key remains header-only and is not logged or returned.

### Backend fail-closed behavior

pm-phone now calls `claim_human_call_provider`, not the earlier phone-only RPC. It refuses the call when any binding parameter or required configuration value is absent or malformed, when the RPC times out after five seconds, when HTTP/JSON/verdict handling fails, or when WPIE denies the claim. The refusal TwiML contains no database reason or key. Existing Twilio signature validation and seller caller-ID selection are unchanged.

### Test stability only

One existing reply-agent regression used database `now()` even though the assertion was about idempotency, so it failed whenever the suite ran during Central quiet hours. Its two notification claims now use the scenario's fixed Thursday-noon timestamp. No runtime behavior changed.

## Conveyor invariants preserved

- `belt_event` / `belt_enter` remains the only conveyor; `0041` only authorizes one already-paused human call.
- The worker and caller keep the established lead-first lock order. The new gate never locks or edits reply drafts, tasks, stops, messages, alerts, stages, or belt state.
- STOP/DNC and terminal cards remain final and are rechecked immediately before `<Dial>`.
- An arbitrary clean phone is insufficient: it must be the exact active destination on the exact lead.
- Existing `begin_human_call` retry, assignment-snapshot, sending-draft, resume, outcome, missed-sweep, and recovery behavior is unchanged.
- Provider retries for the same `CallSid` are harmless; a second provider call cannot reuse one browser attempt.
- Exact-date, Sunday, DST, visit ownership, appointment packet, recovery queue, hot-alert, role UI, pricing/company/cash wording, and Colin-first-person contracts are untouched and remain covered by the full app suite.
- Existing WPIE sync and conveyor contracts remain unchanged; the three compatibility suites still pass.

## Migration order, rollout, and rollback

Required staging/production order after independent review:

1. Confirm the database is already through `0040_shift_people.sql` and run the existing `0039` active-pause preflight if upgrading from an older release.
2. Apply `0041_human_call_provider_gate.sql`. It is additive: one empty claim table and one service-only RPC; it performs no lead/task/draft/belt backfill and does not clear active pauses.
3. Deploy the outreach client so new browser calls include `leadId` and `takeoverKey`. The old pm-phone backend ignores those extra parameters and retains its phone-only fail-closed check during this brief compatibility window.
4. Confirm pm-phone has the existing `WPIE_SUPABASE_URL` and service-role `WPIE_SUPABASE_KEY` configuration without printing either value.
5. Deploy pm-phone commit `eeaf68d`. Deploying this backend before steps 2–3 intentionally fails closed and would refuse browser calls; it does not create unsafe dialing.

Rollback:

1. Revert pm-phone to `d07d637` first; it restores the previous service-side phone block check.
2. Revert the outreach client parameter change if needed.
3. The `0041` table and RPC may remain inert. If removal is necessary, first ensure no browser calls are active and the backend no longer calls the RPC, then drop the function and table. No conveyor state needs reconstruction because `0041` never changes it.

## Verification evidence

All tests used synthetic/PGlite data or mocked HTTP/Twilio behavior. No credentials were read and no provider, seller, staff, or production service was contacted.

### outreach-crm

- `npm test -- --run` — **331 passed**, 42 files.
- New gate cases cover exact claim/retry, simultaneous retry, second-CallSid rejection, wrong lead/key/destination, off-card number, malformed CallSid, STOP, suppression, explicit resume, logged outcome, reassignment, cross-attempt CallSid reuse, and browser denial of the table/RPC.
- `npx tsc -b --force` — **passed**.
- `npm run build` — **passed**; only the existing Vite large-chunk advisory appeared.
- Changed non-component TypeScript tests/helpers lint — **passed**.
- Full `npm run lint` — **not green at the refreshed base**: 11 existing errors remain (8 already documented before `0040`, plus three introduced by Claude's `0040` files). Seven are the existing Fast Refresh reports in `src/lib/dialer.tsx`; the other four are `OnPhonePicker.tsx` Fast Refresh and unused test fixtures in `alertsApprovalsHandoff`, `callQueueSettings`, and `onPhone`. This batch introduced none of those locations or categories.
- `git diff --check` — **passed**.
- The known jsdom canvas warning still prints during the signing-page test; that test passes.

### pm-phone

- `npm test` — **109 passed**, 8 files.
- `npm run typecheck` — **passed**.
- `npm run build` — **passed**. The first sandboxed post-change run could not create `.next/server/app/api`; the identical elevated local rerun passed without source changes.
- `git diff --check` — **passed**.

### WPIE compatibility

- `python -m pytest -q -p no:cacheprovider tests/test_live_conveyor.py tests/test_live_sync.py tests/test_morning_belts.py` — **26 passed**.
- The first sandboxed attempt again failed only because pytest could not create Windows temporary directories (11 passed, 13 failed, 2 setup errors). The identical command outside that filesystem sandbox passed all 26 without source changes.

## Controlled smoke checklist (synthetic/test number only)

1. In staging, verify migrations through `0041` and confirm the claim table is empty.
2. Use a synthetic lead and owned test number. Start one browser call and verify one `human_call_started` event, one provider claim, and no belt text claim.
3. Replay the same signed Twilio webhook with the same `CallSid`; verify the claim is returned as a duplicate and no second row appears.
4. Try the same key with another `CallSid`; verify refusal and no `<Dial>`.
5. Authorize, then separately test STOP, a new suppression row, reassignment, explicit resume, and logged outcome before the provider webhook; every case must refuse.
6. Try a clean number from another lead and a clean number not on any card; both must refuse.
7. Temporarily point staging at an unavailable WPIE endpoint; verify the five-second fail-closed TwiML and restore configuration.
8. Confirm the displayed caller ID remains one of the owned seller lines and a forged caller-ID parameter is ignored.
9. Run one dry WPIE sync/conveyor cycle and confirm no missed stops, duplicate tasks, or claim-related worker errors.

## Remaining decisions and gates

- No live provider call was made. Signature behavior and Twilio custom-parameter delivery are covered by source review and mocked tests, but must receive the controlled staging smoke above before browser calling is enabled.
- The shared-login selector in migration `0040` changes list/settings ownership on that phone, but the current voice token and `begin_human_call` actor still derive from the authenticated shared `team_members` row (Colin). This batch did not alter that deliberate `0040` design. If per-person call attribution or per-person incoming ringing is required, it needs a separate reviewed identity contract rather than trusting local storage at the provider boundary.
- Dependency installation reported existing npm audit findings in both repositories. No automatic audit fix was run because it could change locked dependencies outside this safety batch.

## No-live-action statement

No `.env` or secret was read. No live call, SMS, email, push, seller/staff contact, database mutation, scheduler installation, credential configuration, deployment, push, merge, or PR occurred. This is a local, reviewable two-repository patch only.
