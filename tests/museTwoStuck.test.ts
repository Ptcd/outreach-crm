// 0298 (Colin 2026-11-22: "2100 illinois st merge cards. Fix stuff for muse 2, read posts and the room"). A load for
// a house we had made a second card because the ZIP differed; the merge then listed the same people twice and brought
// the owner who died back as living; and phones_wanted handed back owners already traced with nothing found.
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { PGlite } from '@electric-sql/pglite'
import { beforeAll, describe, expect, it } from 'vitest'
import { SUPABASE_STUB } from './supabaseStub'
import { callTool, type Agent, type DoorDb } from '../supabase/functions/_shared/agentDoor'

const MIGRATIONS_DIR = path.resolve(__dirname, '../supabase/migrations')
const MIGRATION = readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith('.sql')).sort()
  .map((f) => readFileSync(path.join(MIGRATIONS_DIR, f), 'utf8')).join('\n')

let db: PGlite
type Json = Record<string, any>
const records = async (fn: string, args: Record<string, unknown>) => {
  const keys = Object.keys(args)
  await db.exec('set role service_role')
  try {
    return (await db.query<{ r: unknown }>(`select public.${fn}(${keys.map((k, i) => `${k} => $${i + 1}`).join(', ')}) as r`,
      keys.map((k) => typeof args[k] === 'object' && args[k] !== null ? JSON.stringify(args[k]) : args[k]))).rows[0].r
  } finally { await db.exec('reset role') }
}
const add = async (p: Json) => await records('agent_add_prospect', { p, p_agent: 'Muse 2' }) as Json
const muse2: Agent = { id: 'k2', name: 'Muse 2', role: 'agent', scopes: ['prospects', 'marks', 'channel'], tools: null }
const people = async (lead: string) => (await db.query<Json>(`select p.name, i.role, i.status, p.status as person_status,
    (select count(*)::int from public.contacts c where c.lead_id = i.lead_id and c.person_id = p.id) as phones
    from public.interests i join public.people p on p.id = i.person_id where i.lead_id = $1 order by p.name`, [lead])).rows

beforeAll(async () => {
  db = new PGlite()
  await db.exec(SUPABASE_STUB)
  await db.exec(MIGRATION)
}, 180_000)

describe('what Muse 2 was stuck on', () => {
  let first = ''
  it('a load for a house we have updates that card even when the ZIP differs, in the same town', async () => {
    const a = await add({ owner_name: 'Lisa F. Rawley', address: '2100 ILLINOIS ST', city: 'RACINE', county: 'Racine', zip: '53403', phones: ['2625550111'],
      reasons: [{ kind: 'probate', label: 'Probate' }] })
    expect(a.status).toBe('created')
    first = a.lead_id
    const b = await add({ owner_name: 'Lisa F. Rawley', address: '2100 Illinois St', city: 'Racine', county: 'Racine', zip: '53405',
      interests: [{ name: 'Sharon K. Rawley', role: 'heir', phones: ['2625550122'] }] })
    expect(b).toMatchObject({ status: 'updated', lead_id: first })
    // the same street in another town is still another house
    const c = await add({ owner_name: 'Other Owner', address: '2100 Illinois St', city: 'Kenosha', county: 'Kenosha', zip: '53140', phones: ['2625550133'] })
    expect(c.status).toBe('created')
    expect(c.lead_id).not.toBe(first)
    for (const [x, k] of [['CITY OF RACINE', 'racine'], ['Racine (City)', 'racine'], ['Town of Mt. Pleasant', 'mtpleasant'], [null, '']] as const)
      expect((await db.query<{ k: string }>(`select public.muni_key($1) as k`, [x])).rows[0].k).toBe(k)
  })

  it('a merge folds the same-named people into one, keeps their phones, and never undoes a death', async () => {
    await records('agent_mark_person', { p_lead_id: first, p_mark: 'deceased', p_interest_id: null, p_phone: '2625550111', p_reason: 'obituary', p_agent: 'desk' })
    // a second card for the same house, as the old ZIP rule made it: the owner as living, the heir again with another number
    const dup = await add({ owner_name: 'Lisa F. Rawley', address: '2100 Illinois Ct', city: 'Racine', county: 'Racine', zip: '53405',
      interests: [{ name: 'Lisa F. Rawley', role: 'owner_of_record' }, { name: 'Sharon K. Rawley', role: 'heir', phones: ['2625550144'] },
        { name: 'William Klee', role: 'heir', phones: ['2625550155'] }] })
    expect(dup.status).toBe('created')
    await db.query(`update public.leads set property_address = '2100 Illinois St' where id = $1`, [dup.lead_id])
    const m = await records('agent_merge_cards', { p_keep_lead_id: first, p_drop_lead_id: dup.lead_id, p_why: 'one house, loaded twice', p_agent: 'desk' }) as Json
    expect(m).toMatchObject({ ok: true, people_folded: 2 })
    const after = await people(first)
    expect(after.map((p) => p.name)).toEqual(['Lisa F. Rawley', 'Sharon K. Rawley', 'William Klee'])          // each once
    expect(after.find((p) => p.name === 'Lisa F. Rawley')).toMatchObject({ person_status: 'deceased' })
    expect(after.find((p) => p.name === 'Sharon K. Rawley')!.phones).toBe(2)                                  // both numbers, one person
    expect(after.find((p) => p.name === 'William Klee')!.phones).toBe(1)
    expect((await db.query<{ stage: string }>(`select stage::text from public.leads where id = $1`, [dup.lead_id])).rows[0].stage).toBe('dead')
    const note = (await db.query<{ body: string }>(`select body from public.messages where lead_id = $1 and channel = 'note' and body like 'Duplicate card merged in%'`, [first])).rows[0].body
    expect(note).toMatch(/^Duplicate card merged in \(Desk\)/)
  })

  it('an owner traced with no number found is marked, and the next batch does not hand them back', async () => {
    await db.exec(`insert into public.phones_wanted (wpie_owner_id, owner_name, property_address, municipality, county, lane, need, tax_years, listed_on) values
      (801, 'NO NUMBER ONE', '1 A ST', 'Racine', 'Racine', 'flip', 'real need', 3, current_date),
      (802, 'NO NUMBER TWO', '2 A ST', 'Racine', 'Racine', 'flip', 'real need', 2, current_date),
      (803, 'STILL OPEN', '3 A ST', 'Racine', 'Racine', 'flip', 'real need', 1, current_date)`)
    const call = async (args: Json) => (await callTool('phones_wanted', args, muse2, { records } as unknown as DoorDb)) as { value: any; isError?: boolean }
    expect((await call({ limit: 10 })).value.owners.map((o: Json) => o.wpie_owner_id)).toEqual([801, 802, 803])
    const marked = (await call({ no_number: [801, 802, 999], note: 'FastPeopleSearch, no profile' })).value
    expect(marked).toMatchObject({ ok: true, marked: 2, sent: 3 })
    const next = (await call({ limit: 10 })).value
    expect(next.owners.map((o: Json) => o.wpie_owner_id)).toEqual([803])                                      // was 801, 802, 803 again
    expect(next.counts).toMatchObject({ tried_no_number: 2 })
    expect((await call({ no_number: [] })).isError).toBe(true)
    // after 30 days they are open again: another source may have them
    await db.exec(`update public.phones_wanted set tried_at = now() - interval '31 days' where wpie_owner_id = 801`)
    expect((await call({ limit: 10 })).value.owners.map((o: Json) => o.wpie_owner_id)).toEqual([801, 803])
  })
})
