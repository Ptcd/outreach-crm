# WPIE seller workflow release candidate - handoff for Claude

Date: 2026-10-23 UTC

Status: code frozen and verified locally; not pushed, merged, deployed, migrated, or activated

## Outcome

This shift produced a cohesive local release candidate from the already reviewed seller-to-appointment and provider-call safety work. The refreshed outreach and pm-phone upstream tips already contained all prior milestones, so this work added tests and endpoint hardening without replaying migrations or building a parallel conveyor.

Frozen code commits:

- outreach-crm `codex/release-candidate-20261023`: `5a949da334e46f7509628fc50a9da79b90024b40`, based directly on `origin/wpie-live` `a708f20db4594336de3cc7dbd212f7024eb86950`. Its logical commits are `f3ba5e8` (RC journey/lint gate), `71a97f3` (exact-date call hold and preview repair), and `5a949da` (app/personal boundary matrix and paused-call recovery).
- pm-phone `codex/phone-release-candidate-20261023`: `41e3ee48f89c2f55416cbab87b4f5b4558dc0f00`, based directly on `origin/main` `cabb8ba2bb32a48e231a6d4250b4bc89459a0879`.
- WPIE compatibility was rerun in a detached read-only worktree at refreshed `origin/main` `62309d4b33fe69161cc1095a8c45f50833061240`.

The exact migration/deploy/rollback sequence and copyable commands are in `RELEASE_CANDIDATE_2026-10-23.md` beside this report.

## What this shift added

### End-to-end seller journey gate

`tests/releaseCandidateJourney.test.ts` drives one synthetic seller through the existing system:

- inbound interest enters the existing `yes_unbooked` belt;
- Thalia records an exact Not-now date, corrects it, and leaves exactly one queued action owned by Colin, never before the named day;
- Thalia starts and safely retries a personal-phone authorization, then explicitly resumes when the call did not happen;
- Adil starts the app call, and the provider gate claims and idempotently replays the exact CallSid;
- Adil logs interest; Thalia records motivation, timing, signer, condition, and asking price;
- the repeat-safe handoff creates one Colin visit task and Colin books the visit;
- the appointment packet preserves recorded actor provenance and visibly leaves unanswered facts unknown; and
- STOP before a provider claim denies it; STOP after an already allowed claim invalidates replay and new authorization, removes open work, and refuses a new personal-phone authorization. An already returned provider verdict cannot be revoked, which is why the real STOP/claim race remains a staging gate.

The focused gate also includes the existing Thalia, Adil, Colin, handoff, exact-date, takeover, provider-gate, incoming-call, and call-queue suites. It is exposed as `npm run test:release-candidate`.

### Actual pm-phone endpoint coverage and hardening

The new test calls the real Next route `POST /api/twilio/voice/client` in `NODE_ENV=production` using synthetic requests and locally generated Twilio signatures. It proves:

- a correctly signed request carries the normalized destination, lead ID, takeover key, and CallSid into the WPIE provider-claim contract and emits `<Dial>` only after an allowed verdict; the requested line is checked locally against the approved seller caller-ID pool;
- a tampered signature is rejected with HTTP 403 before WPIE is called;
- a foreign account SID and a non-Voice-SDK/PSTN `From` are rejected with HTTP 403;
- an empty seller caller-ID pool produces refusal TwiML and never falls back to the PM number;
- a stale key or wrong destination produces refusal TwiML with no `<Dial>`; and
- exact same-CallSid replay remains idempotently dialable while a new or changed authorization is still governed by the database gate.

The route now explicitly requires an account SID equal to the configured parent or seller account and a bounded `client:` source identity in addition to the existing production signature check. `npm run test:voice-client` runs this route suite with the lower-level dial contract.

### Exact-date outbound-call gate

Independent review found that the previous journey could open a human call before the seller's future Not-now date. Additive migration `0042_exact_date_call_gate.sql` replaces only `begin_human_call` and rejects both app and personal outbound authorization while a `not_now_dated` card's recipient-local due instant is still future. It compares against database `now()` so an authenticated caller cannot bypass the hold by supplying a future `p_now`. Incoming seller calls remain answerable.

Lead, Calls, and Inbox views hide new outbound controls until the due instant, while keeping the recovery control visible for an already-paused attempt. The RPC remains authoritative. Tests prove future-date rejection for both app and personal sources even with a forged future `p_now`, no takeover mutation, acceptance after the fixture advances due, continued valid retry behavior, and successful resume after a paused card is rescheduled into a future hold.

### Clean repository gates

The 11 pre-existing outreach lint errors were small mixed-export/unused-test-fixture problems. Targeted explanations and fixture cleanup make the full repository lint pass without moving runtime logic or changing the conveyor.

## Conveyor and safety invariants preserved

- `belt_event` and `belt_enter` remain the only conveyor. No second scheduler, task stream, or follow-up engine was added.
- Migration order is `0039` zero-active-pause preflight, `0040` shared-phone people, additive `0041` provider claim gate, then additive function replacement `0042` for the exact-date call hold.
- Exact-date Not-now work never runs before the named date, is reassigned to Colin, and rescheduling leaves one current task rather than parallel old/new work.
- Missing-date and conversation-recovery paths remain visible; terminal, STOP, DNC, suppressed, and bad-number records do not re-enter outreach.
- Personal-phone and app calls both require an active paused authorization. A refusal means no dialing. Valid active retries remain idempotent; resume, outcome, reassignment, wrong destination, or STOP invalidates old authority.
- Provider claims retain the established lead-first lock order and do not edit belts, tasks, drafts, messages, or alerts.
- Handoff remains repeat-safe while genuinely corrected same-time handoffs keep distinct alerts.
- Visit ownership stays with Colin; appointment packets report recorded provenance and use explicit unknowns instead of guesses.
- Thalia and Adil share the current caller list. Sunday seller-text restrictions, role controls, Colin-first-person wording, and pricing/company/cash guards are unchanged.
- The PM number cannot become seller caller ID when the seller pool is missing.

## Manual and current-WPIE reconciliation

Current WPIE `origin/main` contains the October 22 operator-manual changes: the shared Thalia/Adil list, Colin-owned exact-date callbacks, required personal-phone authorization, and the rule that a refusal means do not dial. The RC journey directly tests those data-plane cases.

Commit `62309d4` calls the refusal gate “live.” That is a documentation statement, not deployment evidence. This shift did not inspect credentials, query production, or deploy anything, so the actual live version remains unverified.

Current WPIE also contains `9cd7dd2`, which treats a one-unit record with conflicting duplex/other-residential land use as unknown. Its four classification tests pass. The commit message reports a 200-confirmed/zero-unknown October 23 plan, but this shift deliberately did not inspect or send campaign files; that count remains unverified operational context.

## Verification evidence

All data was synthetic/PGlite or mocked HTTP. No provider request or external message was sent.

### outreach-crm

- `npm run test:release-candidate`: 44 passed in 8 files.
- `npm test -- --run`: 335 passed in 43 files.
- `npx tsc -b --force`: passed.
- `npm run build`: passed; only the existing Vite large-chunk advisory appeared.
- `npm run lint`: passed.
- `npm run check:preview:mock`: passed after adding the conveyor/Today mocks missing from the preview harness; only the existing Vite large-chunk advisory appeared.
- `git diff --check`: passed.
- The known jsdom canvas warning still prints during the signing-page test; that test passes.

### pm-phone

- `npm run test:voice-client`: 17 passed in 2 files.
- `npm test`: 115 passed in 9 files.
- `npm run typecheck`: passed.
- `npm run build`: passed.
- One final sandboxed rerun could not create `.next/server/app/api/twilio/voice`; the unchanged elevated local rerun passed. This was a filesystem-sandbox failure, not a compile failure.
- `git diff --check`: passed.

### WPIE

- At refreshed `62309d4`, live conveyor/sync/morning-belt compatibility: 26 passed.
- `tests/test_single_family_plan.py`: 4 passed.

### Not completed and why

- Real separate-session PostgreSQL contention: not run. This host has no `psql`, PostgreSQL server, Docker, or Podman. PGlite uses one local handle and is not represented as proof of server concurrency. Run the exact races in staging before enablement.
- Local synthetic browser clicks: not run. The browser-control runtime crashed twice before creating a tab; no click had an uncertain outcome. The repaired synthetic preview now compiles, and component/UI flows remain in the passing test suites, but interactive clicking is still a staging smoke item.
- Live state and provider delivery: not checked by design. Production credentials and calls were outside authorization.

The smallest remaining environment actions are bounded: provide an existing disposable PostgreSQL 15+ test database to a runner that can open two genuinely independent sessions, then run only the documented migration fixtures and claim/STOP/lock races; and restart the browser-control runtime, open the existing synthetic preview on loopback, and execute the documented click checklist without a real login. If no disposable PostgreSQL runtime already exists, installation or startup needs separate approval. No service installation, database startup, credential change, or browser-security change was attempted in this shift.

The useful release-candidate work reached those environment gates early; this records completion against the eight-hour allocation, not eight hours of elapsed execution.

## Claude review and rollout instructions

1. Review both frozen code commits and `RELEASE_CANDIDATE_2026-10-23.md`; do not cherry-pick older milestones separately because they are already ancestors of the bases.
2. Keep browser calling disabled. Apply migrations only in the documented order, with the `0039` zero-active-pause preflight.
3. Deploy pm-phone before outreach. Roll back outreach before pm-phone.
4. Require a production-mode staging signature/custom-parameter smoke and the real two-session PostgreSQL race before any enablement decision.
5. Verify staging config exists and the approved seller pool is nonempty without printing secrets.
6. Treat the phone persona as display/list state, not individual security identity; the shared Colin row authorizes the team.
7. Re-verify current campaign inputs independently. Repository documentation does not authorize or prove a send.

## No-live-action statement

No `.env` or secret was read. No live call, SMS, email, push, seller/staff contact, campaign send, database migration, production mutation, scheduler installation, credential/configuration change, deployment, push, merge, or PR occurred. The statewide branch frozen at `07aa1872` was not touched.
