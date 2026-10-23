# WPIE seller workflow release candidate manifest

Date: 2026-10-23 UTC

Status: local candidate only. Nothing in this manifest authorizes deployment, migration, calling, messaging, or campaign activation.

## Frozen code inputs

| Component | Intended upstream base | Local review branch | Frozen code commit |
| --- | --- | --- | --- |
| outreach-crm | `origin/wpie-live` = `a708f20db4594336de3cc7dbd212f7024eb86950` | `codex/release-candidate-20261023` | `71a97f33395491bce64afa41f44a031899431f75` |
| pm-phone | `origin/main` = `cabb8ba2bb32a48e231a6d4250b4bc89459a0879` | `codex/phone-release-candidate-20261023` | `41e3ee48f89c2f55416cbab87b4f5b4558dc0f00` |
| WPIE compatibility | `origin/main` | detached, read-only fixture | `62309d4b33fe69161cc1095a8c45f50833061240` |

Both intended upstream bases already contained the previously reviewed milestones; no migration or feature commit was replayed. The frozen statewide worktree at `07aa1872` was not touched.

## Database and deploy order

Keep browser calling disabled for the entire integration window.

1. Confirm outreach-crm is already through `0038`.
2. Run the `0039_seller_shift_review_hardening.sql` preflight. It must abort atomically if any active legacy human-call pause exists. Resolve each pause operationally; do not clear or infer its actor during the migration.
3. Apply `0039`, then `0040_shift_people.sql`, additive `0041_human_call_provider_gate.sql`, and `0042_exact_date_call_gate.sql` in order. `0042` replaces only the call-authorization RPC; it has no data backfill.
4. Verify, without printing values, that pm-phone has the WPIE URL/service key and a nonempty approved seller caller-ID pool.
5. Deploy the new pm-phone backend first. Old clients omit the new binding and fail closed.
6. Deploy the new outreach client second.
7. In a production-mode staging process, run the signed-request and custom-parameter checks below.
8. Use two independent PostgreSQL sessions for the claim/STOP races below.
9. Only a separate authorization after all checks pass may enable browser calling.

Rollback with calling still disabled: roll back outreach first, then pm-phone. Leaving `0041` and `0042` inert is safe. Do not drop `0041` until the backend no longer calls it and no human call is active. Rolling pm-phone back restores the older phone-only check and is a deliberate security downgrade.

## Required configuration and identity limits

- pm-phone production mode requires a valid Twilio signature, an account SID equal to the configured parent or seller account, and a valid `client:` source.
- Seller calls require an approved seller caller-ID pool; the PM number is never a fallback.
- The provider gate requires the exact active lead, destination, takeover key, assignment snapshot, and provider CallSid, and rechecks terminal/STOP/DNC/suppression state.
- The phone persona selector chooses display/list ownership. It is not security identity. A shared Colin login authorizes the team rather than proving which person is holding the device.

## Repeatable local gates

From outreach-crm:

```text
npm run test:release-candidate
npm test -- --run
npx tsc -b --force
npm run build
npm run lint
npm run check:preview:mock
git diff --check
```

From pm-phone:

```text
npm run test:voice-client
npm test
npm run typecheck
npm run build
git diff --check
```

From current WPIE:

```text
python -m pytest -q -p no:cacheprovider tests/test_live_conveyor.py tests/test_live_sync.py tests/test_morning_belts.py
python -m pytest -q -p no:cacheprovider tests/test_single_family_plan.py
```

## Staging gates not proved locally

1. Run the same provider claim concurrently through two independent PostgreSQL sessions. Verify one stored claim, idempotent same-CallSid replay, rejection of a second CallSid, and fail-closed behavior when STOP races the claim.
2. With `NODE_ENV=production`, send a correctly signed synthetic Twilio request to the staging endpoint and verify the exact custom parameters. Tampered signature, account, source, lead, key, destination, assignment, and stale authorization must yield HTTP 403 or refusal TwiML with no `<Dial>`.
3. Exercise one synthetic lead through reply, exact-date follow-up, caller handoff, personal/app takeover, appointment packet, reschedule, STOP, and recovery. Verify no duplicate task, alert, note, claim, or queued outreach.
4. Verify the WPIE campaign inputs independently before any send. The repository statement that 200 rows were confirmed and zero unknown is documentation history, not evidence collected in this shift.

## Current local evidence

- outreach-crm: 334/334 tests, 43/43 focused RC tests, forced TypeScript build, Vite production build, mock-preview build, ESLint, and diff check passed.
- pm-phone: 115/115 tests, 17/17 focused voice-client tests, typecheck, Next production build, and diff check passed.
- WPIE at refreshed `62309d4`: 26/26 compatibility tests and 4/4 single-family classification tests passed.
- The repaired synthetic preview compiles completely. The local browser-control helper crashed twice before opening a tab, so no UI click evidence was produced.
- Genuine multi-session PostgreSQL testing was not available: this host has no `psql`, PostgreSQL server, Docker, or Podman runtime.

