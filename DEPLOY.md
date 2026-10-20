# Deploying the WPIE app

Everything below needs one of Colin's accounts. Nothing here has been done yet:
the code is on the local branch `wpie-live` and has not been pushed. Steps marked
**[Colin signs in]** need Colin's own login; Claude cannot do them.

Keys, in one line each:

- **anon key**: public by design, goes on Vercel. Row-level security protects the data.
- **service_role key**: never goes on Vercel or in the app. Not needed at all.
- **database password / SUPABASE_DB_URL**: only on Colin's PC, for the WPIE sync. Never in a file in either repo.

---

## 1. Create the Supabase project  **[Colin signs in: supabase.com]**

1. supabase.com > New project. Name: `wpie-live`. Region: US East (or Central).
   Pick a strong database password and save it in Bitwarden (step 6 uses it).
2. Use a **new** project. If the old outreach-crm app had a Supabase project, leave it alone;
   this schema does not need any of its tables.

## 2. Run the migration  **[Colin signs in: supabase.com]**

1. In the new project: SQL Editor > New query.
2. Paste the whole of `supabase/migrations/0001_wpie_live.sql` and press Run.
   It should finish with "Success. No rows returned".
   (Alternative if you use the Supabase CLI: `supabase link` then `supabase db push`.)

## 3. Sign-in settings  **[Colin signs in: supabase.com]**

Authentication > Sign In / Providers:

1. Email: on. Magic link is the sign-in method; there are no passwords.
2. Turn **off** "Allow new users to sign up". Only people you invite can get in.

Authentication > URL Configuration:

3. Site URL: the Vercel address of outreach-crm (for example `https://outreach-crm.vercel.app`, or your custom domain).
4. Redirect URLs: add that same address, plus `http://localhost:5173` for local testing.

## 4. Add the team  **[Colin signs in: supabase.com]**

1. Table Editor > `team_members` > Insert row, twice:

   | email (lower case) | role | person | display_name |
   |---|---|---|---|
   | Colin's email | owner | colin | Colin |
   | Thalia's email | caller | thalia | Thalia |

2. Authentication > Users > Add user > "Send invitation", once for Colin's email and once for
   Thalia's. Each person clicks the link in the invite email once; after that they sign in from
   the app's login page with "Email me a sign-in link".

What each role can do (enforced in the database, not just the screens):

- **owner (Colin)**: everything, including the gate score, the deal box (your own offer
  number, typed by you), approving or skipping planned texts, and editing the team list.
- **caller (Thalia)**: work leads (stage, next action, who has it, notes), log calls and notes,
  mark phones bad or do-not-contact, follow-ups, buyers. Reads the gate. Cannot see deals,
  approve texts, or change WPIE's facts.
- Anyone else who somehow signs in sees nothing.

## 5. Point the Vercel project at Supabase  **[Colin signs in: vercel.com]**

1. In Supabase: Project Settings > API. Copy the **Project URL** and the **anon public** key.
2. In Vercel: project `outreach-crm` > Settings > Environment Variables. Add, for Production and Preview:
   - `VITE_SUPABASE_URL` = the Project URL
   - `VITE_SUPABASE_ANON_KEY` = the anon public key
3. Build settings stay as they are (framework Vite, `npm run build`, output `dist`).
4. Get the code to Vercel: push the `wpie-live` branch to GitHub (Ptcd/outreach-crm). Vercel builds
   a preview from it. When the preview looks right, merging `wpie-live` into `main` replaces the old
   CRM on the production address. (The old code is kept at tag `pre-wpie-repurpose-2026-10-20`.)
   Pushing and merging are your call; Claude has not done either.

## 6. Connect WPIE's sync on your PC  **[Colin types the password himself]**

1. In Supabase: the Connect button > "Session pooler" connection string (works on home internet without IPv6).
   It looks like `postgresql://postgres.<ref>:[YOUR-PASSWORD]@aws-0-us-east-1.pooler.supabase.com:5432/postgres`.
2. Put your database password in it, then set it for your Windows user (PowerShell, one time):

   ```powershell
   [Environment]::SetEnvironmentVariable("SUPABASE_DB_URL", "<the connection string>", "User")
   ```

   Open a new terminal afterwards. Do not put it in any `.env` file in either repo.
3. Install the database driver once: `pip install "psycopg[binary]>=3.1"`.

## 7. First sync  (no sign-in needed once step 6 is done)

From `C:\Users\onkau\claude\real estate`:

```
python -m wpie.live.sync push --dry-run   # counts only, touches nothing
python -m wpie.live.sync push             # loads the 5,000 mailed owners, their phones, texts and planned openers
python -m wpie.live.sync pull             # writes data/live/lifecycle.json and data/live/opener_decisions.json
```

Run `push` after every `python -m wpie.campaign plan` / `send` / `sync`, and `pull` before the next
`plan`, so the campaign skips owners the app marked dead, DNC, replied or mail-only, and phones
marked bad or do-not-contact.

## 8. Invite Thalia to start

Send Thalia the app address. She signs in with the email from step 4.

---

## Known gaps in v1

- **Approve / Skip is recorded but not yet enforced by WPIE's sender.** `pull` writes the decisions to
  `data/live/opener_decisions.json`; `wpie/campaign/send.py` does not read that file yet. Until it does,
  only send what you approved by hand.
- Nothing runs the sync on a schedule; run `push` / `pull` yourself (or ask Claude to set one up).
- Inbound replies reach the app only through the campaign ledger (the `mark` / `import-replies` /
  `sync` commands). Texts that only landed on your phone through pm-phone are not in the app until recorded.
- Scoreboard number 12 (profit per 1,000 owners) is not computed; the app never computes money figures.
- The buyers table exists (cash-buyer list stub) but has no screen yet.
