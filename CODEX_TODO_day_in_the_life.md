# Codex to-do: a day in the life of Thalia, Adil and Colin in the WPIE app

Colin, 2026-10-22: "pretend you're them and go through a mini day in the life of Thalia or Adil operating, and then me." Your job is to walk the app the way they will, step by step, and report what works, what doesn't, and what you fixed. You are a tester playing three people, not a feature builder: fix small things in place (a missing label, a dead button, a wrong default), and list anything bigger in the report instead of building it.

## Where things are

- App: this repo (`outreach-crm`, branch `wpie-live`). React + Vite in `src/`, Supabase migrations in `supabase/migrations/`, edge functions in `supabase/functions/`. Live at https://deals.junkcarsmequon.com. Supabase project `jyfetargyaaxcqmxdgft`.
- The manual the staff follow: `C:\Users\onkau\claude\real estate\docs\OPERATORS_MANUAL.md` (sections 3 "Your shift, in order", 4 "The call", 7 "What to do when", 8 "Hand to Colin"). Walk the app against that text: every sentence in section 3 should be doable in the app exactly as written. Where it is not, that is a finding.
- Checks before any push: `npx tsc --noEmit -p tsconfig.json`, `npx vitest run`, `npx vite build`. Tests run the real migrations on PGlite; see `tests/replyAgent.test.ts` for the harness and `tests/alertsApprovalsHandoff.test.ts` for a short one.
- Rules that never bend (do not "fix" these): no price, range or value anywhere a seller could see it; no company name or "cash" in seller texts; every text reads as Colin in the first person; STOP is final; nothing is sent to a real seller during your walk. Never read `.env` files or print secrets.

## How to run it

Preferred: locally against the live project, signed in as a caller. Ask Colin for a caller login (a `team_members` row with role `caller`, e.g. Thalia's, or a test caller he creates) and for Approve's **test phone** to be set to a number he owns, so the texts you approve go to him and nobody else. `npm install`, `npm run dev`, open the app, sign in. If you cannot get a login, do the whole walk on the test harness instead: a vitest file per persona that drives the real RPCs on PGlite (`tests/alertsApprovalsHandoff.test.ts` shows the shape) plus the jsdom page tests (`tests/pages.test.tsx`, `tests/callQueueSettings.test.tsx`) for the screens, and say in the report that it was the harness, not the live app.

## Day 1: Thalia (Monday to Friday, 9 am to 5 pm Central)

Play each step, in order. For each: what the manual says, what the app actually did, pass or fail, and the fix if you made one.

1. **9:00, open the app.** Today loads. Sections in this order: Belt health (may be missing: the conveyor is being built in parallel, ignore it), Tasks from replies, New replies, Follow-ups due, Follow-up debt. The dropdown under Follow-ups due defaults to me (Thalia), not "Everyone".
2. **Settings.** The gear in the header opens Settings. I set my email and my phone for hot pings, press Save, see a confirmation, reload, and both are still there. Notifications on this phone: the panel explains install and the Allow button; on a desktop browser it says what it can and cannot do.
3. **A hot reply arrives.** Simulate one: as Colin (or via the test phone) make a seller reply that shows interest (e.g. "yes, would sell, what would you pay?"). Within two minutes I should get a push (if allowed), a text (if my phone is on the office line's allow-list; Colin controls that), and an email at the address from step 2. The link opens the lead card with the call script open and the number ready. The HotBanner on the card says it is hot and shows "I called them".
4. **The call.** On the card: press the Call button next to the number (the dialer needs a microphone; on the harness, check that the button exists and is not blocked). The script shows Pick up with, What we already know (our text, their reply), the questions with one-tap answers. Tap answers for a motivated seller (moving, within 30 days, just them, number rests on the payoff, open to hearing under it, lives there, roof is old). The box "The card says" must turn green "Book the visit" and the close must show the booking lines and the Walk-through picker. Set a Walk-through for tomorrow 2 pm. The card's stage becomes Walk-through booked. Log the call: Interested. Confirm the hot banner's "called" state cleared the 15-minute re-ping (no second text).
5. **A not-so-hot one.** Second reply: "maybe, if the price is right". Tap answers: only for the right price, no date. The box must turn red "Don't book" and the close must show the not-ready lines. Log: Not now with a date two weeks out. The card moves to Follow up later with that date.
6. **The call list.** Open Calls (bottom nav). It should say "1 of N" and show one card: who, where, why this call (the list reason in plain words), their texts if any, the numbers to dial, the script, Log this call, Skip for now, Hand to Colin. Log "No answer" on the first: the task is done and the next card appears. Skip the second: it goes to the end and the count says "skipped for now". If the list is empty on the live project, insert two `tasks` rows (kind `call`, owner `thalia`, due today, source `call_list`) for two leads and use those.
7. **Hand to Colin.** On a card that is clearly viable, press Hand to Colin, type one line, Send. Check: the lead is assigned to Colin, stage Colin's call; a task for Colin exists with the title "From Thalia: worth a look" and my line; a note sits in the thread history; a hot alert row exists whose text starts "HANDED TO YOU"; the call left my queue.
8. **Inbox.** A draft waiting for approval ("Reply needs you"): as a caller I can Approve (with an edit) or Skip; the approve is refused if I put a price or the business name in it. Mark seen on a new reply. "Someone calling?" with the last 4 digits finds the owner.
9. **Approve.** As a caller I can approve or skip each planned text and Approve all; the sending switch and Clear pause are NOT mine (they must be disabled or absent for a caller).
10. **STOP and wrong number.** A reply "wrong number, STOP": the number is suppressed, the card goes to DNC, nothing is drafted; a later "thanks, you too" produces nothing (no draft, no email). On the card, every Call button for that owner is gone or blocked.
11. **End of shift.** Follow-ups due in my name are all done or re-dated; New replies all seen; the debt list is honest (a card I touched with no next date should appear there, or the manual's claim is wrong: say which).

## Day 2: Adil (Saturday and Sunday, 8 am to 8 pm Central)

Same as Thalia's steps 1 to 11, signed in as Adil (role caller, person adil), on a Saturday date if you can set the clock in the harness. Plus:

12. **Sunday.** No texts are planned or sent on Sunday (the plan skips Sunday; the reply agent's auto replies respect quiet hours). A hot reply on Sunday still pings him and he can still call.
13. **Tasks from replies.** A seller asks for an email or a document: the task shows under Tasks from replies with the seller's words; the Email button composes to them; Done closes it.

## Day 3: Colin (owner)

14. **Morning.** Approve: the day's texts, Approve all with one left out; the sending switch and the pause are his. Inbox: a draft the agent would not send alone; approve it with an edit; the price guard refuses a number.
15. **The hand-off.** His Today shows the task "From Thalia: worth a look" under Follow-ups due with her line; the card opens with Who has it = Colin, stage Colin's call, the note in the history, and the hot banner. He logs the call "Reached, no decision", then "Interested", then books a Walk-through.
16. **The walk gate.** On the card, "Book the visit?" shows the verdict; under it "Colin's score" lets only him save a gate score with "numbers close"; a caller sees it read-only.
17. **Scoreboard.** Reached, confirmed, would sell, booked for the week reflect what the three of you did today (at least the counts moved).
18. **The deal.** Contract box (Colin only): a new signing link renders; the seller page shows terms and locks Sign until every question is answered. Do not send anything.

## Report

One Markdown file, `CODEX_REPORT_day_in_the_life.md` in this repo, with a table per day: step, what the manual says, what the app did, pass/fail, fix made or needed. Then: the five things you would change first, in one line each. Commit your fixes on `wpie-live` (pull first; the conveyor build commits on the same branch, so pull before every commit and never force-push), with `Co-Authored-By: Codex <noreply@openai.com>` or your usual trailer, and push. Nothing goes to a real seller.
