# WPIE app (branch `wpie-live`)

The live operating layer for WPIE: Colin and Thalia work the mailed owners here.
Vite + React + TypeScript + Tailwind + shadcn-style components + supabase-js + React Query,
the same stack as the old outreach-crm app (kept at tag `pre-wpie-repurpose-2026-10-20`)
so the Vercel project settings still work.

Pages: Today (follow-ups due, new replies, follow-up debt), Pipeline (leads by stage, lane and
county), Lead (WPIE facts, phones with DNC flags, history, follow-ups, scoreboard checkpoints,
the six-item walk gate, Colin's deal box), Approvals (Colin approves or skips WPIE's planned
opener texts; sending stays in WPIE), Scoreboard (the weekly numbers from
`docs/ACQUISITION_SYSTEM_PLAYBOOK.md` section 4), Login (email magic link).

The app never computes or suggests an offer, value or price. Colin types his own offer into a
deal record; the database refuses that field from anyone else.

## Pieces

- `supabase/migrations/0001_wpie_live.sql`: tables, views, triggers, row-level security.
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
