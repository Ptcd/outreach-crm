// 0247 (2026-11-16): "I'm Colin Merrill" went out in a thread that spoke as Tyler. The door's business-wording refusal
// said "write as Colin", and the one-name rule did not know "I'm X". On the real migrations.
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { PGlite } from '@electric-sql/pglite'
import { beforeAll, describe, expect, it } from 'vitest'
import { SUPABASE_STUB } from './supabaseStub'
import { BUSINESS_WORDING, replyProblem, textProblem } from '../supabase/functions/_shared/agentDoor'

const MIGRATIONS_DIR = path.resolve(__dirname, '../supabase/migrations')
const MIGRATION = readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith('.sql')).sort()
  .map((f) => readFileSync(path.join(MIGRATIONS_DIR, f), 'utf8')).join('\n')

let db: PGlite
let lead: string
const one = async <T>(sql: string, params: unknown[] = []) => (await db.query<{ r: T }>(`select ${sql} as r`, params)).rows[0].r
const speaker = (body: string) => one<string | null>(`public.text_speaker($1)`, [body])
const problem = (body: string) => one<string | null>(`public.text_rule_problem($1, $2, 0)`, [lead, body])

beforeAll(async () => {
  db = new PGlite()
  await db.exec(SUPABASE_STUB)
  await db.exec(MIGRATION)
  await db.exec(`insert into public.team_members (email, role, person, display_name) values
    ('colin@example.com', 'owner', 'colin', 'Colin'), ('thalia@example.com', 'caller', 'thalia', 'Thalia'), ('adil@example.com', 'caller', 'adil', 'Tyler')
    on conflict (email) do update set display_name = excluded.display_name`)
  lead = (await db.query<{ id: string }>(
    `insert into public.leads (wpie_owner_id, owner_name, lane, stage, property_address, municipality, locked_to, mailing_state)
     values (-7001, 'VANTEST, JASON', 'flip', 'reply_received', '991 Test St', 'CITY OF TEST', 'adil', 'WI') returning id`)).rows[0].id
  await db.query(`insert into public.messages (lead_id, direction, channel, body, status, provider_sid, to_number, sent_at, created_at)
    values ($1, 'out', 'sms', 'Hi Jason, this is Tyler. Are you the right person to ask about 991 TEST ST? Reply STOP to opt out.', 'delivered', 'SM-t1', '+14145550199', now() - interval '3 days', now() - interval '3 days')`, [lead])
}, 120_000)

describe('the refusal never says who to write as', () => {
  it('names no one, in a reply or in a queued text', () => {
    expect(BUSINESS_WORDING).not.toMatch(/colin|tyler|thalia|adil/i)
    expect(replyProblem('No company, Jason. It is just me.')).toBe(BUSINESS_WORDING)
    expect(textProblem('Hi Pat, our team buys houses. Reply STOP to opt out.')).toBe(BUSINESS_WORDING)
    expect(BUSINESS_WORDING).toMatch(/never change who is speaking/)
  })
})

describe('"I\'m X" is a name', () => {
  it('reads the speaker out of I\'m, I am and Im', async () => {
    expect(await speaker("Just me personally, Jason. I'm Colin Merrill, I buy houses around here myself.")).toBe('Colin')
    expect(await speaker('I am Thalia, I buy houses in the area.')).toBe('Thalia')
    expect(await speaker('I’m Tyler, I buy houses in the area.')).toBe('Tyler')
    expect(await speaker('Sorry, im Tyler. Just checking if you are still the owner.')).toBe('Tyler')
  })
  it('does not find one inside another word, or with no intro', async () => {
    expect(await speaker('Tell him Colin sent you.')).toBeNull()            // "him Colin" is not "im Colin"
    expect(await speaker('Is 12 Tyler St still yours?')).toBeNull()
    expect(await speaker('Thanks Tyler, talk soon.')).toBeNull()
  })
  it('refuses the second name in a thread that speaks as Tyler, however it is worded', async () => {
    expect(await one<string>(`public.card_voice($1)`, [lead])).toBe('Tyler')
    expect(await problem("Just me personally, Jason. I'm Colin Merrill, I buy houses around here myself.")).toMatch(/hears from Tyler, not Colin/)
    expect(await problem('I am Thalia, I buy houses in the area.')).toMatch(/hears from Tyler, not Thalia/)
    expect(await problem('This is Colin, following up.')).toMatch(/hears from Tyler, not Colin/)
  })
  it('lets the thread\'s own name through, and a reply with no name', async () => {
    expect(await problem("Sorry, I'm Tyler. I buy houses in the area.")).toBeNull()
    expect(await problem('Just me personally, Jason. I buy houses around here myself.')).toBeNull()
  })
})
