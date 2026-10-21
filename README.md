# WPIE app (branch `wpie-live`)

The live operating layer for WPIE: Colin and Thalia work the mailed owners here.
Vite + React + TypeScript + Tailwind + shadcn-style components + supabase-js + React Query,
the same stack as the old outreach-crm app (kept at tag `pre-wpie-repurpose-2026-10-20`)
so the Vercel project settings still work.

Pages: Today (follow-ups due, new replies, follow-up debt), Inbox (every seller text as a card:
what was sent, replies, the reply AI's read and suggested reply, one-tap Book Colin's call / Not
interested; chips Needs me / AI handling / Booked / No reply yet / Dead), Pipeline (leads by stage, lane and
county), Lead (WPIE facts, phones with DNC flags, history, follow-ups, scoreboard checkpoints,
the six-item walk gate, Colin's deal box), Approve (Colin approves the day's planned texts, all
at once or all except a few, withdraws what is unsent, and turns server sending on or off), Scoreboard (the weekly numbers from
`docs/ACQUISITION_SYSTEM_PLAYBOOK.md` section 4), Login (email magic link).

The app never computes or suggests an offer, value or price. Colin types his own offer into a
deal record; the database refuses that field from anyone else.

## Pieces

- `supabase/migrations/0001_wpie_live.sql`: tables, views, triggers, row-level security.
- `supabase/migrations/0003_app_sending.sql`: sending from the server; every send-time check is in
  `claim_next_opener`. `supabase/functions/send-openers` + `opener-status` (Edge Functions),
  `supabase/setup/send_openers_cron.sql` (the 5-minute timer). See WPIE `docs/APP_SENDING.md`.
- WPIE side (other repo): `python -m wpie.live.sync push|pull` in `C:\Users\onkau\claude\real estate`.
- `DEPLOY.md`: the remaining steps that need Colin's Supabase and Vercel accounts.

## Commands

```
npm install
npm run dev        # needs VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY (see .env.example)
npm run build      # type-check + production build
npm test           # schema tests on an in-memory Postgres (PGlite) + component tests
npm run db:local   # throwaway local Postgres with the migration, for testing the WPIE sync
```
