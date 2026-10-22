# WPIE day-in-the-life report

Tested 2026-10-22 from `codex/day-in-the-life-app`, based on refreshed `origin/wpie-live` at `bd2d8a39ae6dd02aed02e516e28170283887ea5d`.

This was the local harness walk, not the live site. The persona tests run every real migration in PGlite, exercise the real RPCs, and use jsdom tests for the screens. All phone, email, and seller activity was synthetic or mocked; nothing was sent to a seller, no production data was changed, and no signing link was sent. “Pass (harness)” therefore proves the local behavior, not production deployment or real push/email/SMS delivery.

## Day 1 — Thalia

| Step | What the manual says | What the app did | Result | Fix made or needed |
|---|---|---|---|---|
| 1 | Open Today at 9:00; see Belt health, Tasks from replies, New replies, Follow-ups due, then Follow-up debt; follow-ups default to Thalia. | The four required work sections now render in that order and the follow-up selector defaults to the signed-in person. “Your stops” had been interrupting the required order. | **Pass (harness)** | Moved “Your stops” below the required sequence and added an accessible label to the follow-up selector. |
| 2 | Save hot-ping phone/email; reload; explain phone install/permission and desktop limits. | `set_my_alerts` normalized and persisted Thalia's synthetic phone/email. Settings confirms the save. The panel had phone-centric, ambiguous desktop copy. | **Pass (harness)** | Reworded the install instruction to “three-dot menu” and explained that desktop Chrome pings require the browser to be running. |
| 3 | An interested reply should ping within two minutes by allowed channels and open the hot card/script. | A synthetic hot reply produced one staff text and one email through mocked transports, recorded the alert, and exposed the lead link/hot state through existing UI coverage. No real push, text, email, latency, or deep-link navigation was exercised. | **Partial — local paths pass** | A caller-login production smoke test with Colin's test phone is still needed before relying on delivery timing. |
| 4 | Dial, answer the script, earn “Book the visit,” book tomorrow at 2, log Interested, and cancel re-ping. | The motivated answers produced `book`; booking moved the card to `walkthrough_booked` / `visit_booked`; logging Interested marked the hot alert called and a later alert run did not re-ping. The call button/script/picker are covered in jsdom, not a real microphone call. | **Pass (harness)** | Fixed booked-walk ownership so an automatic first reminder cannot leave the card assigned to Thalia; it now belongs to Colin. |
| 5 | For “maybe, if the price is right,” get “Don't book,” then log Not now with a date two weeks out. | The verdict logic produces “Don't book,” but **Log this call** has no follow-up-date field; `log_call` assigns the generic 30-day date. The exact two-week action cannot be completed atomically as written. | **Fail — workflow gap** | Add a date picker for Not now and save that exact date with the disposition. |
| 6 | Work Calls one card at a time; see reason/context; log No answer; skip another to the end. | Existing queue tests verify `1 of N`, context, disposition completion/advance, skip-to-end, and the “skipped for now” count. | **Pass (harness)** | Also blocked the queue's Call button for vendor/scrub DNC flags, matching the lead card's safety behavior. |
| 7 | Hand a viable card to Colin once, with task, note, alert, reassignment, and removal from caller queue. | The real RPC assigned Colin, moved to Colin's call, closed caller stops, created one Colin task, wrote the note, and remained one-task-only when repeated. The stored handoff marker is rendered by the delivery worker as a notification beginning `HANDED TO YOU:` with the caller's line. | **Pass (harness)** | None. |
| 8 | Caller may approve/edit/skip a draft; guards reject price/company; mark seen and owner lookup work. | Existing inbox/guard/page tests cover caller actions, price/company refusal, seen state, and last-four lookup. | **Pass (harness)** | None. |
| 9 | Caller may approve/skip/Approve all but may not control sending or clear pause. | Existing role/UI and RLS tests keep owner controls from callers while exposing text decisions. | **Pass (harness)** | None. |
| 10 | “wrong number, STOP” suppresses every owner number, drafts nothing later, and removes every Call button. | The real migrations moved the card to DNC and suppressed both synthetic numbers. Existing reply-agent tests cover final STOP/no later draft. | **Pass (harness)** | The queue now checks `dnc_vendor` and `dnc_scrub` as well as app suppression before rendering Call. |
| 11 | Finish or re-date due work; see all replies; debt must reveal a touched card with no next date. | Due/seen controls work, but `followup_debt` explicitly filters to non-null dates already at least two days late. A touched card with no next date appears only in conveyor “cards with no stop” health, not in Follow-up debt as the manual claims. | **Fail — manual/app mismatch** | Include missing-date touched cards in the staff debt surface, or rewrite the manual to point to Belt health. |

## Day 2 — Adil

Steps 1–11 use the same caller screens and role policy as Thalia. Shared screen/RPC tests passed, but the full synthetic weekday sequence was not redundantly replayed under Adil's identity; the weekend-specific behavior was exercised as Adil.

| Step | What the manual says | What the app did | Result | Fix made or needed |
|---|---|---|---|---|
| 1 | Today uses the required order and defaults follow-ups to Adil. | The selector derives from the signed-in caller, and the fixed DOM order is role-independent. | **Pass (shared harness)** | Same Today ordering/label fix as step 1 above. |
| 2 | Adil can persist his own ping phone/email and understand notifications. | The same caller-only `set_my_alerts` RPC and Settings page apply to Adil; role policy is shared. | **Pass (shared harness)** | Same notification-copy fix as step 2 above. |
| 3 | Hot interest pings the on-duty caller and opens the hot card. | The Sunday-specific test recorded a hot reply and sent one mocked staff ping to Adil's configured synthetic number. | **Pass (harness path)** | Real delivery/deep-link/latency still needs the controlled live smoke test. |
| 4 | Work the call script and book an earned visit. | Shared caller UI, verdict, booking, logging, and re-ping tests pass. | **Pass (shared harness)** | The booked-walk Colin ownership fix is global. |
| 5 | Log Not now with the exact chosen date. | The same missing disposition date input prevents this for Adil. | **Fail — workflow gap** | Add the exact follow-up-date input/save path. |
| 6 | Work and skip the call list. | The shared caller queue tests pass. | **Pass (shared harness)** | Vendor/scrub DNC Call-button safety fix applies globally. |
| 7 | Hand to Colin with caller-specific task/note/alert. | The RPC resolves the signed-in member's display name and the repeat-safe integration path passes with a caller; the generated notification begins `HANDED TO YOU:`. | **Pass (shared harness)** | None. |
| 8 | Use caller inbox actions and guards. | Shared caller inbox/guard tests pass. | **Pass (shared harness)** | None. |
| 9 | Use text approvals without owner controls. | Shared caller role/UI/RLS tests pass. | **Pass (shared harness)** | None. |
| 10 | STOP is final and no DNC number can be dialed. | Shared real-migration STOP test and UI DNC tests pass. | **Pass (shared harness)** | Queue DNC blocking corrected. |
| 11 | End with honest follow-up debt. | Same null-date omission as Thalia: Belt health can catch it, Follow-up debt cannot. | **Fail — manual/app mismatch** | Surface null-date touched cards in debt or correct the manual. |
| 12 | Sunday plans/sends no seller text, but a hot reply still pings Adil and he may call. | At a synthetic Sunday timestamp, `claim_next_opener` returned `idle / sunday`; a hot reply still created and delivered one mocked staff ping. No seller send ran. | **Pass (harness)** | None. |
| 13 | Email/document requests appear with seller words; Email composes; Done closes. | A synthetic inbound created exactly one Adil email task even when retried, preserving the quote/address; Done closed it. Existing jsdom covers the compose control. No email was sent. | **Pass (harness)** | None. |

## Day 3 — Colin

| Step | What the manual says | What the app did | Result | Fix made or needed |
|---|---|---|---|---|
| 14 | Owner can make approval decisions, control sending/pause, edit a guarded inbox draft. | Existing owner/caller UI and RLS tests cover owner-only controls, one-left-out approvals, guarded edits, and price refusal. | **Pass (harness)** | None. No sending switch was activated outside the local database. |
| 15 | See Thalia's handoff, note, owner/stage/hot state; log two calls and book the walk. | The integration test verified the task/title/line/note/alert, logged Reached-no-decision then Interested, and booked the visit. It exposed that the automatic reminder changed “Who has it” back to Thalia. | **Pass after fix** | Added a migration invariant: every `visit_booked` lead is assigned to Colin. |
| 16 | Only Colin can save the walk gate with “numbers close”; caller view is read-only. | A caller insert was rejected by RLS; Colin saved a 12-point `walk` gate with “numbers close.” Existing page tests cover the read-only/editable presentation. | **Pass (harness)** | None. |
| 17 | Weekly Reached, confirmed, would sell, and booked counts move. | Synthetic milestones moved the weekly values to 1/1/1/1. The page previously made staff infer these from the detailed tables. | **Pass after fix** | Added a plain four-card summary labeled Reached, Confirmed owners, Would sell, and Booked calls. |
| 18 | Colin can create a signing link; seller sees terms and cannot sign until all questions are answered; do not send. | Existing contract/signing tests cover owner-only deal controls, signing-page terms, all 62 questions, and the locked Sign button. The day harness also proved callers cannot create the deal. Nothing was sent. | **Pass (harness)** | None. |

## Five changes I would make first

1. Add an exact follow-up date field to the **Not now** call disposition and persist it in the same RPC transaction.
2. Put touched cards with no next date directly in **Follow-up debt**, with a clear “missing date” label.
3. Run these three persona harnesses in CI so role, STOP, Sunday, handoff, and visit-owner regressions block releases.
4. Add a safe notification diagnostic showing the last push/text/email attempt and latency per staff member without exposing message secrets.
5. Before rollout, repeat the walk once with a caller login and Colin-owned test phone to verify real install, microphone, deep links, and delivery timing.
