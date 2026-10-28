// team-codes: a sign-in code per person (Colin 2026-10-28: "a different password/key per person ... then when they
// log in once their browser can stay logged in"). Colin, signed in as the owner, sets Thalia's or Adil's code from
// Settings; this makes (or updates) their own app account and their team row, so every call, package and callback
// is theirs. The code is never stored here, logged or sent back: it goes straight to Supabase Auth as the password.
// Each person's account is <person>@team.junkcarsmequon.com, never emailed.
import { createClient } from 'npm:@supabase/supabase-js@2.56.1'
import { TEAM_PEOPLE, teamEmail, teamCodeProblem } from '../_shared/teamCodes.ts'

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS })
  const json = (body: unknown, status = 200) => Response.json(body, { status, headers: CORS })
  const url = Deno.env.get('SUPABASE_URL') ?? ''
  const asUser = createClient(url, Deno.env.get('SUPABASE_ANON_KEY') ?? '', {
    global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } }, auth: { persistSession: false } })
  const owner = await asUser.rpc('is_owner')
  if (owner.error || owner.data !== true) return json({ ok: false, reason: 'Only Colin sets team codes.' }, 403)

  const body = await req.json().catch(() => ({})) as { person?: string; code?: string }
  const person = String(body.person ?? '')
  const code = String(body.code ?? '')
  if (!TEAM_PEOPLE.some((p) => p.person === person)) return json({ ok: false, reason: 'person is thalia or adil' }, 400)
  const why = teamCodeProblem(code)
  if (why) return json({ ok: false, reason: why }, 400)

  const admin = createClient(url, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '', { auth: { persistSession: false } })
  const email = teamEmail(person)
  const made = await admin.auth.admin.createUser({ email, password: code, email_confirm: true })
  if (made.error) {
    // already there: find the account and set the new code
    let id: string | null = null
    for (let page = 1; page <= 10 && !id; page++) {
      const r = await admin.auth.admin.listUsers({ page, perPage: 200 })
      if (r.error) return json({ ok: false, reason: 'Could not look up the account.' }, 500)
      id = r.data.users.find((u) => (u.email ?? '').toLowerCase() === email)?.id ?? null
      if (r.data.users.length < 200) break
    }
    if (!id) return json({ ok: false, reason: 'Could not make the account.' }, 500)
    const up = await admin.auth.admin.updateUserById(id, { password: code })
    if (up.error) return json({ ok: false, reason: up.error.message.includes('password') ? up.error.message : 'Could not set the code.' }, 400)
  }
  const display = TEAM_PEOPLE.find((p) => p.person === person)!.name
  const row = await admin.from('team_members').upsert({ email, role: 'caller', person, display_name: display }, { onConflict: 'email' })
  if (row.error) return json({ ok: false, reason: row.error.message }, 500)
  return json({ ok: true, person, signs_in_as: display })
})
