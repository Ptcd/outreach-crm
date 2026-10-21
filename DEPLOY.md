# Deploying the WPIE app

Everything below needs one of Colin's accounts. Steps marked **[Colin signs in]** need
Colin's own login; Claude cannot do them, and never types or reads a key.

## Status, 2026-10-21

- Code: branch `wpie-live` on GitHub (Ptcd/outreach-crm). Not merged to `main`.
- Supabase project `jyfetargyaaxcqmxdgft` exists. Migrations 0001 and 0002 were applied (per the
  2026-10-20 commit; not re-checked, the CLI is signed out); **0003 (app sending) is not yet**.
- **The app is not on the internet yet. Why (checked from Colin's PC with the Vercel CLI):**
  1. The Vercel project `outreach-crm` (team "Colin's projects") has not built anything since
     2025-09-01. The pushes to `wpie-live` on 2026-10-20/21 made no deployment at all, so the
     project is no longer connected to the GitHub repo (or Vercel's GitHub app lost access to it).
  2. Its `VITE_SUPABASE_URL` / `VITE_SUPABASE_ANON_KEY` were created 416 days ago, i.e. they point
     at the OLD CRM's Supabase project, not `jyfetargyaaxcqmxdgft`. (Inferred from the date; the
     values were not read.)
  3. The production branch is `main`, which is still the old CRM.
- The Supabase CLI on Colin's PC is signed out ("Invalid access token"), so Claude cannot deploy the
  Edge Functions or apply migration 0003 until Colin signs it in once (step A3 below).

## Fast path: get the app live (about 10 minutes of clicks)

**A1. Reconnect Vercel to GitHub  [Colin signs in: vercel.com]**
vercel.com > team "Colin's projects" > project `outreach-crm` > Settings > Git.
If no repository is shown, click **Connect Git Repository** > GitHub > `Ptcd/outreach-crm`.
If GitHub asks to give Vercel access to that repo, allow it (only that repo is fine).

**A2. Point the project at the new Supabase  [Colin signs in: supabase.com]**
Easiest (no copy-paste): supabase.com > project `jyfetargyaaxcqmxdgft` > Project Settings >
Integrations > **Vercel** > Connect > pick the Vercel project `outreach-crm`. This adds
`NEXT_PUBLIC_SUPABASE_URL` / `NEXT_PUBLIC_SUPABASE_ANON_KEY`, which the app reads first.
Then in Vercel > `outreach-crm` > Settings > Environment Variables, **delete** the two old
`VITE_SUPABASE_*` variables and `SMARTLEAD_API_KEY` (old CRM leftovers).

**A3. Let Claude deploy the database part  [Colin clicks one browser sign-in]**
In a terminal on the PC run `supabase login` and approve it in the browser that opens.
Then Claude can run, with your OK: `supabase link --project-ref jyfetargyaaxcqmxdgft`,
`supabase db push` (applies 0003) and
`supabase functions deploy send-openers opener-status --project-ref jyfetargyaaxcqmxdgft`.
None of these sends a text: the sending switch starts OFF and no Twilio key is set.
(Without the CLI: SQL Editor > paste `supabase/migrations/0003_app_sending.sql` > Run.)

**A4. Build it**
Vercel > `outreach-crm` > Deployments > **Redeploy** the newest `wpie-live` preview, or ask Claude
to push any small commit to `wpie-live`. Open the preview link it gives you.

**A5. Sign-in links  [Colin signs in: supabase.com]**
Authentication > URL Configuration: add the preview address (and later the production one) to
Redirect URLs, and set it as Site URL once it is the real address. Step 3 and 4 below are still true.

**A6. Make it the real address (when the preview looks right)**
Either merge `wpie-live` into `main` (replaces the old CRM; it is kept at tag
`pre-wpie-repurpose-2026-10-20`), or Vercel > Settings > Git > Production Branch = `wpie-live`.

## The address: deals.junkcarsmequon.com (Colin, 2026-10-21)

Checked 2026-10-21: junkcarsmequon.com's DNS is at **Hostinger** (nameservers `ns1/ns2.dns-parking.com`),
not Vercel. The apex points at Vercel (`76.76.21.21`) and `www` is a CNAME to `cname.vercel-dns.com`, both
for pm-phone. In Vercel the domain belongs to the team that holds pm-phone (`team-0257d0aa`), while this
app's project `outreach-crm` is in **"Colin's projects"**, so Vercel will ask for one extra TXT record to
prove the subdomain is yours. Nothing was added yet: the project's production deployment is still the
2025 CRM, so adding the name before A1 and A6 would put the old CRM on it.

After A1 and A6 (the WPIE app is the project's production deployment):

**D1. Vercel  [Colin signs in: vercel.com]** team "Colin's projects" > `outreach-crm` > Settings > Domains >
Add > `deals.junkcarsmequon.com` > Add. Vercel shows the DNS records it wants: a **CNAME** for `deals` and,
because the domain lives in the other team, a **TXT** record named `_vercel`. Leave that page open.

**D2. Hostinger  [Colin signs in: hpanel.hostinger.com]** Domains > junkcarsmequon.com > DNS / Nameservers >
DNS records. Add:
- Type **CNAME**, Name `deals`, Target `cname.vercel-dns.com`, TTL default.
- Type **TXT**, Name `_vercel`, Value exactly as Vercel shows it (starts `vc-domain-verify=`).
Do not touch the existing `@` A record or `www` CNAME: those are pm-phone.

**D3.** Back in Vercel, the domain turns "Valid Configuration" within a few minutes and Vercel issues the
certificate by itself.

**D4. Supabase  [Colin signs in: supabase.com]** Authentication > URL Configuration:
Site URL `https://deals.junkcarsmequon.com`; Redirect URLs add `https://deals.junkcarsmequon.com/**`.
(The password-setting email sends people back to that address.)

## The app password (Colin, 2026-10-21: "an app password not users")

The login screen asks for one password and nothing else. Under the hood it signs into ONE Supabase
account (Colin's, owner role), so the database's access rules keep working. The password lives only in
Supabase Auth: it is not in this repo, not in Vercel and not in the page. Anyone with the password acts as
Colin (owner): they can approve texts and turn sending on. Separate roles for Thalia can come back later.

**P1. Which account  [Colin signs in: vercel.com]** `outreach-crm` > Settings > Environment Variables > Add
`VITE_WPIE_APP_EMAIL` = the email of Colin's Supabase login for this app (the one in `team_members` with
role `owner`), for Production and Preview. Redeploy. This is not a secret; it keeps the email out of the
public repo.

**P2. Set the password, typed only by Colin.** Either:
- In the app: tap **Set or reset the app password** on the login screen. A link goes to that email; open it
  on the same device; the app shows **Set the app password** (12+ characters, twice). Done; or
- Supabase > Authentication > Users: if the account is not there yet, **Add user > Create new user** with
  that email, type the password, tick **Auto Confirm User**. If it is there, its menu > **Send password
  recovery**, then as above.
Supabase's built-in mailer only sends a few emails an hour and only to the project team's own addresses,
which is fine for this one account.

**P3.** Supabase > Authentication > Sign In / Providers > Email: keep it on (it covers passwords); keep
"Allow new users to sign up" **off**.

## the reply agent (deployed 2026-10-21, everything off)

Migrations 0004 and 0005 are applied and the reply-agent / reply-send functions are deployed. What is
left, in order (Claude never sees a key; each script shows only "set" / "saved"):

1. **Server settings  [Colin runs, about 1 minute]** in a PowerShell window in `C:\Users\onkau\claude\real estate`:
   `powershell -ExecutionPolicy Bypass -File tools\set_supabase_secrets.ps1`
   It copies the Twilio subaccount SID/token, messaging service and sender number already saved on the
   PC into Supabase, and asks once (hidden) for an Anthropic API key for drafted replies. It never sets
   `TWILIO_LIVE_SENDING`. From then on the reply agent reads every reply each minute and drafts; nothing is sent.
2. **Laptop -> app sync  [Colin runs, about 2 minutes]**
   `powershell -ExecutionPolicy Bypass -File tools\set_supabase_db_url.ps1`
   (paste the Session pooler string from Supabase > Connect, then the database password, hidden).
   The 10-minute live cycle then puts each day's planned texts into the app and pulls results back.
3. **Check** the Approve page: "Red-team test: 440/440 passed - the reply agent last checked <time>".
4. **Optional:** Approve page > "Turn routine replies on" (the reply agent answers the routine ones himself).
5. **Go live, only on Colin's word:** add the function secret `TWILIO_LIVE_SENDING` = `1`, approve the
   day's texts, "Turn sending on". To stop: turn sending off, or delete that secret.

## Instant replies: the webhook (deployed 2026-10-21, not pointed at yet)

`reply-inbound` is Twilio's "A message comes in" webhook for the WPIE Mail Replies messaging service:

    https://jyfetargyaaxcqmxdgft.supabase.co/functions/v1/reply-inbound   (HTTP POST)

- Refuses any request without a valid X-Twilio-Signature (the subaccount's auth token).
- Records the text and, for a STOP or any removal wording, blocks the phone before answering Twilio
  (what pm-phone's inbound did for these numbers). Answers with empty TwiML: Twilio sends nothing and
  nothing is relayed to Colin's phone or email.
- After answering: The reply agent decides the text (a draft for Colin, or a routine line), and a routine reply goes
  after a natural 45-90 s pause (`campaign_control.auto_reply_delay_min/max`), never in quiet hours (then
  08:00 plus the pause). Colin's approvals go when he taps (or at 08:00).
- The 1-minute reply-agent timer stays as the catch-up; a reply can never go twice.
- Twilio's own STOP handling (Advanced Opt-Out on the messaging service) keeps working as before.

Order (each needs Colin's OK):
1. Twilio settings on the functions (`tools\set_supabase_secrets.ps1`, or the hidden-prompt pattern).
   **Do this first**: without TWILIO_AUTH_TOKEN the webhook refuses every request and texts would only
   arrive through the timer's Twilio pull, which also needs those settings.
2. Twilio console > switch to the WPIE Mail Replies subaccount > Messaging > Services > WPIE Mail Replies
   (MGd94f196186140435f7889071eb014882) > Integration > Incoming Messages: "Send a webhook", Request URL
   the address above, HTTP POST > Save. That moves these texts off pm-phone.
3. Send a test text from your own phone to (262) 999-6513: it appears in the Inbox within seconds.

## Sending from the app (WPIE docs/APP_SENDING.md)

Three locks, all OFF until Colin says go:

1. **Function secret `TWILIO_LIVE_SENDING`** (Supabase > Edge Functions > Secrets). Unset = every run is a
   test run: all checks happen, "would send" is recorded, Twilio's send is never called.
2. **The Sending switch** on the Approve page (Colin only).
3. **Each day's texts approved** on the Approve page (Approve all / Approve all except / Withdraw).

Setup, in order, once A3 is done:

- **S1. Timer** (after the functions are deployed): SQL Editor > paste `supabase/setup/send_openers_cron.sql`
  > Run. It runs `send-openers` every 5 minutes; with the locks off that is a test run.
- **S2. Twilio settings  [Colin pastes; Claude never sees them]** Supabase > Edge Functions > Secrets > Add:
  `TWILIO_ACCOUNT_SID` and `TWILIO_AUTH_TOKEN` of the **WPIE Mail Replies** subaccount (Twilio console >
  that subaccount > Account Info), `CAMPAIGN_MESSAGING_SERVICE_SID` (its Messaging Service, starts MG),
  `CAMPAIGN_FROM_NUMBER` = `+12629996513`. With these set but lock 1 still off, runs also read new replies
  and STOPs from Twilio (read only).
- **S3. Shadow day**: leave lock 1 off for a day and compare the Approve page's "would send" / skip reasons
  with the laptop's dry run.
- **S4. Go live, only on Colin's word**: add secret `TWILIO_LIVE_SENDING` = `1`; Approve page > approve the
  day > Turn sending on. To stop at any moment: Turn sending off (or delete that secret).

On the laptop, `python -m wpie.live.sync pull` copies every app send into the campaign ledger, and
`python -m wpie.campaign send --live` refuses any day the app has sent on or while the app switch is on.

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

1. Email: on. Sign-in is one shared app password (see "The app password" above).
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
   Thalia's. (Superseded 2026-10-21: everyone now signs in with the one app password, which
   uses Colin's account; see "The app password".)

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

- The Inbox's suggested replies come from WPIE's scripted reply agent (pushed by the sync); pm-phone's
  Claude-written suggestions still arrive by text, not in the app. Nothing in the app sends a reply.
- The sync runs every 10 minutes from the laptop's "WPIE live cycle" task once `SUPABASE_DB_URL` is set (step 6).
- Inbound replies reach the app through the campaign ledger (`import-replies` + `sync`) and, once the
  Twilio settings are in the function secrets (S2), straight from Twilio every 5 minutes (Inbox marks
  those "new" until WPIE records them).
- Scoreboard number 12 (profit per 1,000 owners) is not computed; the app never computes money figures.
- The buyers table exists (cash-buyer list stub) but has no screen yet.
