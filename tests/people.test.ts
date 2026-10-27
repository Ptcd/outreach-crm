// One property card, many interests (Muse's spec for Colin, 2026-10-27), step 1 on the real migrations: every card has
// its owner of record, every phone belongs to the person it names, and one person is one record across cards only when
// the name matches AND a phone or the mailing address does. The six cases from the spec are the tests.
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { PGlite } from '@electric-sql/pglite'
import { beforeAll, describe, expect, it } from 'vitest'
import { SUPABASE_STUB } from './supabaseStub'

const MIGRATIONS_DIR = path.resolve(__dirname, '../supabase/migrations')
const MIGRATION = readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith('.sql')).sort()
  .map((f) => readFileSync(path.join(MIGRATIONS_DIR, f), 'utf8')).join('\n')
let db: PGlite
const rows = async <T = Record<string, unknown>>(sql: string, params: unknown[] = []) => (await db.query<T>(sql, params)).rows
const add = async (p: Record<string, unknown>) =>
  ((await rows<{ r: { lead_id: string } }>(`select public.agent_add_prospect($1::jsonb, 'Muse intake') as r`, [JSON.stringify(p)]))[0].r).lead_id
const phone = (lead: string, num: string, name: string) =>
  db.query(`insert into public.contacts (lead_id, kind, value, value_normalized, person_name, line_type, source)
            values ($1, 'phone', $2, $2, $3, 'mobile', 'test')`, [lead, num, name])
const interests = (lead: string) => rows<{ name: string; role: string; kind: string; phones: string[] | null }>(
  `select p.name, i.role, p.kind, (select array_agg(c.value_normalized order by c.value_normalized) from public.contacts c where c.person_id = p.id and c.lead_id = i.lead_id) phones
     from public.interests i join public.people p on p.id = i.person_id where i.lead_id = $1 order by i.role, p.name`, [lead])

beforeAll(async () => {
  db = new PGlite()
  await db.exec(SUPABASE_STUB)
  await db.exec(MIGRATION)
})

describe('people and interests', () => {
  it('Orlich: the estate contact is her own person on the property card, with her own phones, not the dead owner', async () => {
    const card = await add({ owner_name: 'SAM L ORLICH', owner_type: 'individual', address: '1 Test Alabama Av', city: 'Milwaukee',
      mailing_street: '1 Test Alabama Av', mailing_city: 'Milwaukee', mailing_zip: '53207',
      phones: [{ number: '4145551001', name: 'SAM ORLICH' }, { number: '4145551002', name: 'Eva Orlich' }, { number: '4145551003', name: 'Eva Orlich' }] })
    expect(await interests(card)).toEqual([
      { name: 'Eva Orlich', role: 'other', kind: 'person', phones: ['4145551002', '4145551003'] },
      { name: 'SAM L ORLICH', role: 'owner_of_record', kind: 'person', phones: ['4145551001'] },
    ])
  })

  it('Kurth: a couple, each spouse a co-owner with their own phones; a shared line shows under both', async () => {
    const card = await add({ owner_name: 'CRAIG & KATHLEEN KURTH', owner_type: 'couple', address: '2 Test 63rd St', city: 'Milwaukee' })
    await phone(card, '4145552001', 'CRAIG KURTH')
    await phone(card, '4145552002', 'KATHLEEN KURTH')
    await phone(card, '4145552009', 'CRAIG KURTH')
    await phone(card, '4145552009', 'KATHLEEN KURTH')
    expect(await interests(card)).toEqual([
      { name: 'CRAIG KURTH', role: 'co_owner', kind: 'person', phones: ['4145552001', '4145552009'] },
      { name: 'KATHLEEN KURTH', role: 'co_owner', kind: 'person', phones: ['4145552002', '4145552009'] },
      { name: 'CRAIG & KATHLEEN KURTH', role: 'owner_of_record', kind: 'household', phones: null },
    ])
  })

  it('Morrell: the owner\'s mailing address is the person\'s, separate from the property', async () => {
    const card = await add({ owner_name: 'HEATHER MORRELL', owner_type: 'individual', address: '3 Test Oakdale Dr', city: 'New Berlin',
      mailing_street: '8 Test 36th St', mailing_city: 'Franklin', mailing_state: 'WI', mailing_zip: '53132', phones: ['4145553001'] })
    expect(await rows(`select p.mailing_city, l.property_address from public.interests i join public.people p on p.id = i.person_id
                         join public.leads l on l.id = i.lead_id where i.lead_id = $1`, [card]))
      .toEqual([{ mailing_city: 'Franklin', property_address: '3 Test Oakdale Dr' }])
  })

  it('Baxter: the same person on two property cards is one person, and his phones are his on both', async () => {
    const owner = { owner_name: 'JOHN E BAXTER', owner_type: 'individual', city: 'Milwaukee', mailing_street: '9 Test 24th St', mailing_zip: '53204' }
    const a = await add({ ...owner, address: '4 Test 24th St', phones: [{ number: '4145554001', name: 'JOHN BAXTER' }] })
    const b = await add({ ...owner, address: '5 Test 24th St' })
    const people = await rows<{ person_id: string }>(`select distinct person_id from public.interests where lead_id in ($1, $2) and role = 'owner_of_record'`, [a, b])
    expect(people).toHaveLength(1)
    expect(await rows(`select phone10, on_cards from public.person_phones where person_id = $1`, [people[0].person_id]))
      .toEqual([{ phone10: '4145554001', on_cards: [a] }])
  })

  it('the same name is not the same person without a shared phone or address', async () => {
    const a = await add({ owner_name: 'JOHN SMITH', owner_type: 'individual', address: '6 Test St', mailing_street: '6 Test St', mailing_zip: '53202', phones: ['4145556001'] })
    const b = await add({ owner_name: 'JOHN SMITH', owner_type: 'individual', address: '7 Test St', mailing_street: '7 Test St', mailing_zip: '53215', phones: ['4145556002'] })
    expect(await rows(`select count(distinct person_id)::int n from public.interests where lead_id in ($1, $2)`, [a, b])).toEqual([{ n: 2 }])
    // but the same name and a shared phone is
    const c = await add({ owner_name: 'Ann Lee', owner_type: 'individual', address: '8 Test St', phones: [{ number: '4145558001', name: 'Ann Lee' }] })
    const d = await add({ owner_name: 'ANN M LEE TRUST', owner_type: 'trust', address: '9 Test St' })
    await phone(d, '4145558001', 'ANN LEE')
    const ann = await rows<{ role: string; same: boolean }>(`select i.role, i.person_id = (select person_id from public.interests where lead_id = $1 and role = 'owner_of_record') same
                         from public.interests i where i.lead_id = $2 and i.role <> 'owner_of_record'`, [c, d])
    expect(ann).toEqual([{ role: 'trustee', same: true }])
  })

  it('probate: the estate is the owner of record; a personal representative with a different name is their own person', async () => {
    const card = await add({ owner_name: 'ESTATE OF ROSE TESTER', owner_type: 'estate', address: '10 Test St', city: 'Waukesha' })
    await phone(card, '6305551010', 'MARK ATTORNEY')
    expect(await interests(card)).toEqual([
      { name: 'MARK ATTORNEY', role: 'other', kind: 'person', phones: ['6305551010'] },
      { name: 'ESTATE OF ROSE TESTER', role: 'owner_of_record', kind: 'entity', phones: null },
    ])
  })

  // ---------------------------------------------------------------- step 2: the door (0083)
  const r1 = async (sql: string, params: unknown[] = []) => (await rows<{ r: Record<string, unknown> }>(`select ${sql} as r`, params))[0].r
  const OPENER = "Hi Eva, Colin Merrill here. Are you the right person to ask about 11 Estate Av? Reply STOP if you'd rather not hear from me."
  const tue = '2026-10-27T20:00:00Z'

  it('import with interests: the owner, a personal representative at her own address, her phones; a range address is the same card', async () => {
    const res = await r1(`public.agent_add_prospect($1::jsonb, 'Muse intake')`, [JSON.stringify({ address: '11 Estate Av', city: 'Milwaukee',
      owner_name: 'SAMUEL TESTMAN', owner_type: 'individual',
      interests: [{ name: 'SAMUEL TESTMAN', role: 'owner_of_record', status: 'deceased', mailing_street: '11 Estate Av', mailing_zip: '53207' },
                  { name: 'Eve Testman', role: 'personal_representative', mailing_street: '5 Chase Test Ave', mailing_city: 'Milwaukee', mailing_zip: '53207',
                    phones: [{ number: '4145561101', type: 'mobile' }, { number: '4145561102', type: 'landline' }] }] })])
    expect(res).toMatchObject({ status: 'created', phones_added: ['4145561101', '4145561102'] })
    const card = res.lead_id as string
    const ppl = (await r1(`public.card_interests($1)`, [card])) as unknown as { name: string; role: string; status: string; mailing: { street?: string }; phones: { phone: string; textable: boolean }[] | null }[]
    expect(ppl.map((x) => [x.name, x.role, x.status])).toEqual([['Eve Testman', 'personal_representative', 'active'], ['SAMUEL TESTMAN', 'owner_of_record', 'deceased']])
    expect(ppl[0].mailing.street).toBe('5 Chase Test Ave')
    expect(ppl[0].phones!.map((x) => [x.phone, x.textable])).toEqual([['4145561101', true], ['4145561102', false]])
    // 11-13 Estate Av is the same property: the second import adds an heir, no second card
    const again = await r1(`public.agent_add_prospect($1::jsonb, 'Muse intake')`, [JSON.stringify({ address: '11 13 Estate Av',
      interests: [{ name: 'Ned Testman', role: 'heir', phones: ['4145561103'] }] })])
    expect(again).toMatchObject({ status: 'updated', lead_id: card })
    expect(((await r1(`public.card_interests($1)`, [card])) as unknown as unknown[]).length).toBe(3)
  })

  it('the Orlich rule: a card that died as no contact reopens when the owner is marked deceased and a live person remains', async () => {
    const card = await add({ owner_name: 'OTTO ORLTEST', owner_type: 'individual', address: '12 Alabama Test Av',
      phones: [{ number: '4145561201', name: 'OTTO ORLTEST' }, { number: '4145561202', name: 'Ava Orltest' }] })
    await db.query(`update public.leads set stage = 'dead', dead_reason = 'no_contact' where id = $1`, [card])
    const otto = (await rows<{ id: string }>(`select i.id from public.interests i where i.lead_id = $1 and i.role = 'owner_of_record'`, [card]))[0].id
    const m = await r1(`public.agent_mark_person($1, 'deceased', $2, null, 'died 2026', 'Muse')`, [card, otto])
    expect(m).toMatchObject({ ok: true, person: 'OTTO ORLTEST', cards: [{ lead_id: card, result: 'reopened' }] })
    expect((await rows(`select stage::text, dead_reason from public.leads where id = $1`, [card]))[0]).toEqual({ stage: 'opener_queued', dead_reason: null })
    // his number is never texted again, on any card; hers is
    expect(await r1(`public.agent_queue_text($1, '4145561201', $2, 1, null, 'Muse', $3::timestamptz)`, [card, OPENER, tue]))
      .toMatchObject({ status: 'refused', reason: expect.stringContaining('marked deceased') })
    const q = await r1(`public.agent_queue_text($1, '4145561202', $2, 1, null, 'Muse', $3::timestamptz)`, [card, OPENER, tue])
    expect(q).toMatchObject({ status: 'queued', person: 'Ava Orltest' })
    expect((await rows(`select i.role from public.planned_openers p join public.interests i on i.id = p.interest_id where p.id = $1`, [q.text_id]))[0]).toEqual({ role: 'other' })
    await db.query(`update public.planned_openers set send_status = 'withdrawn' where id = $1`, [q.text_id])
  })

  it('DNC is a person: a special administrator who says stop is closed on every card, the estate card stays open for the PR', async () => {
    const a = await r1(`public.agent_add_prospect($1::jsonb, 'Muse intake')`, [JSON.stringify({ address: '14 Admin Test St', owner_name: 'ESTATE OF ALMA TEST', owner_type: 'estate',
      interests: [{ name: 'Carl Counsel', role: 'special_administrator', phones: ['6305561401'] }, { name: 'Pia Test', role: 'personal_representative', phones: ['4145561402'] }] })])
    const b = await r1(`public.agent_add_prospect($1::jsonb, 'Muse intake')`, [JSON.stringify({ address: '15 Other Test St', owner_name: 'ESTATE OF BO TEST', owner_type: 'estate',
      interests: [{ name: 'Carl Counsel', role: 'special_administrator', phones: ['6305561401'] }] })])
    const carl = (await rows<{ n: number }>(`select count(distinct person_id)::int n from public.interests i join public.people p on p.id = i.person_id where p.name = 'Carl Counsel'`))[0]
    expect(carl).toEqual({ n: 1 })                                         // one Carl across both estates (name + shared phone)
    const m = await r1(`public.agent_mark_person($1, 'dnc', null, '6305561401', 'DO NOT TEXT ME AGAIN', 'Muse')`, [a.lead_id])
    expect(m).toMatchObject({ ok: true, person: 'Carl Counsel' })
    expect((await rows(`select stage::text from public.leads where id = $1`, [a.lead_id]))[0]).toEqual({ stage: 'opener_queued' })   // Pia is live
    expect((await rows(`select stage::text from public.leads where id = $1`, [b.lead_id]))[0]).toEqual({ stage: 'data_fix' })       // nobody live left: re-trace
    expect(await r1(`public.agent_queue_text($1, '6305561401', $2, 1, null, 'Muse', $3::timestamptz)`, [b.lead_id, OPENER, tue])).toMatchObject({ status: 'refused' })
  })

  it('an owner who says stop still closes the property; the wrong person closes only themselves', async () => {
    const card = await add({ owner_name: 'DORA DNCTEST', owner_type: 'individual', address: '16 Stop Test St',
      phones: [{ number: '4145561601', name: 'DORA DNCTEST' }, { number: '4145561602', name: 'Rel Ative' }, { number: '4145561603', name: 'Wes Wrong' }] })
    expect(await r1(`public.agent_mark_person($1, 'wrong_person', null, '4145561603', 'not related', 'Muse')`, [card])).toMatchObject({ ok: true })
    expect((await rows(`select stage::text from public.leads where id = $1`, [card]))[0]).toEqual({ stage: 'opener_queued' })
    expect(await r1(`public.agent_queue_text($1, '4145561603', $2, 1, null, 'Muse', $3::timestamptz)`, [card, OPENER, tue]))
      .toMatchObject({ status: 'refused', reason: expect.stringContaining('closed') })
    await r1(`public.agent_mark_person($1, 'dnc', null, '4145561601', 'stop texting me', 'Muse')`, [card])
    expect((await rows(`select stage::text from public.leads where id = $1`, [card]))[0]).toEqual({ stage: 'dnc' })
  })

  it('a text names its person; a number shared by one person on two cards passes the send check', async () => {
    const owner = { owner_name: 'TOM TWOCARDS', owner_type: 'individual', city: 'Milwaukee', mailing_street: '17 Home Test St', mailing_zip: '53204' }
    const a = await add({ ...owner, address: '17 One Test St', phones: [{ number: '4145561701', name: 'TOM TWOCARDS', type: 'mobile' }] })
    const b = await add({ ...owner, address: '18 Two Test St', phones: [{ number: '4145561701', name: 'TOM TWOCARDS', type: 'mobile' }] })
    const iv = (await rows<{ id: string }>(`select id from public.interests where lead_id = $1 and role = 'owner_of_record'`, [b]))[0].id
    expect(await r1(`public.agent_queue_text($1, '4145561701', $2, 1, null, 'Muse', $3::timestamptz, null, null, null, $4)`, [a, OPENER, tue, iv]))
      .toMatchObject({ status: 'refused', reason: expect.stringContaining('no such person on this card') })
    await db.exec(`update public.planned_openers set send_status = 'withdrawn' where send_status in ('planned', 'would_send')`)
    const q = await r1(`public.agent_queue_text($1, '4145561701', $2, 1, null, 'Muse', $3::timestamptz, null, null, null, $4)`, [b, OPENER, tue, iv])
    expect(q).toMatchObject({ status: 'queued', interest_id: iv, person: 'TOM TWOCARDS' })
    const claim = await r1(`public.claim_next_opener(true, $1::timestamptz)`, [tue])
    expect(claim).toMatchObject({ outcome: 'would_send', opener: { id: q.text_id } })
  })
})
