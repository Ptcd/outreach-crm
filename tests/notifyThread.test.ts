// The "needs you" email's thread shows each text once (Martin 2026-10-22: the pitch appeared twice,
// once as the sent reply and once as the same reply logged in messages; synced inbound copies too).
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { PGlite } from '@electric-sql/pglite'
import { describe, expect, it } from 'vitest'
import { SUPABASE_STUB } from './supabaseStub'

const MIGRATION = readdirSync(path.resolve(__dirname, '../supabase/migrations')).filter((f) => f.endsWith('.sql')).sort()
  .map((f) => readFileSync(path.resolve(__dirname, '../supabase/migrations', f), 'utf8')).join('\n')
const LEAD = '00000000-0000-0000-0000-0000000000a1'
const PITCH = 'Thanks for getting back to me. I buy a few houses a year around here myself, as-is and on your timeline. Would you ever consider selling that one? No pressure either way.'

describe('needs-you email thread', () => {
  it('shows the opener, their yes, the pitch and their answer once each', async () => {
    const db = new PGlite()
    await db.exec(SUPABASE_STUB)
    await db.exec(MIGRATION)
    await db.exec(`
      insert into public.leads (id, wpie_owner_id, owner_name, property_address, stage) values ('${LEAD}', 9, 'MARTIN X', '2469 S HOWELL AV', 'reply_received');
      insert into public.messages (lead_id, direction, channel, body, provider_sid, is_opener, sent_at, source_key) values
        ('${LEAD}', 'out', 'sms', 'Hi Martin, Colin from Mequon. Is the building on S Howell Av still yours?', 'SMopen', true, '2026-10-22T19:50:00Z', 'ledger:9:1:opener'),
        ('${LEAD}', 'in', 'sms', 'Yes', 'SMyes', false, '2026-10-22T19:56:48Z', 'twilio:SMyes'),
        ('${LEAD}', 'out', 'sms', '${PITCH.replace(/'/g, "''")}', 'SMpitch', false, '2026-10-22T19:57:40Z', 'reply:p1');
      insert into public.twilio_inbound (sid, from10, to_number, body, lead_id, received_at, processed_at) values
        ('SMyes', '4144063758', '+12624180202', 'Yes', '${LEAD}', '2026-10-22T19:56:48Z', '2026-10-22T19:56:49Z'),
        ('SMno', '4144063758', '+12624180202', 'If you are looking to overpay', '${LEAD}', '2026-10-22T20:00:11Z', '2026-10-22T20:00:12Z');
      insert into public.reply_drafts (inbound_sid, phone10, our_number, lead_id, inbound_body, inbound_at, intent, kind, outcome, body,
        draft_source, status, provider_sid, sent_body, sent_at) values
        ('SMyes', '4144063758', '+12624180202', '${LEAD}', 'Yes', '2026-10-22T19:56:48Z', 'interested', 'routine', 'open', '${PITCH.replace(/'/g, "''")}',
         'fixed_line', 'sent', 'SMpitch', '${PITCH.replace(/'/g, "''")}', '2026-10-22T19:57:40Z'),
        ('SMno', '4144063758', '+12624180202', '${LEAD}', 'If you are looking to overpay', '2026-10-22T20:00:11Z', 'not_interested', 'candidate', 'open', null,
         'none', 'awaiting_approval', null, null, null);
    `)
    const r = await db.query<{ r: { thread: { who: string; body: string }[] }[] }>(`select public.notify_claim('first', '2026-10-22T20:01:00Z') as r`)
    const thread = r.rows[0].r[0].thread.map((l) => `${l.who}: ${l.body.slice(0, 20)}`)
    expect(thread).toEqual(['us: Hi Martin, Colin fro', 'them: Yes', 'us: Thanks for getting b', 'them: If you are looking t'])
  })
})
