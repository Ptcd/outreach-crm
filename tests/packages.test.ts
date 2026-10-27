// The package (Colin 2026-10-27; migration 0085), on the real migrations: Thalia sends it after a first call, Colin
// gets one email with everything, Muse adds the value, Colin sets the number, Thalia delivers exactly that number on
// the callback, a yes goes to the walk, and the funnel counts it by list.
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { PGlite } from '@electric-sql/pglite'
import { beforeAll, describe, expect, it } from 'vitest'
import { SUPABASE_STUB } from './supabaseStub'
import { packageEmail, type PackageRow } from '../supabase/functions/_shared/packages'
import { handleMessage, type DoorDb } from '../supabase/functions/_shared/agentDoor'

const MIGRATIONS_DIR = path.resolve(__dirname, '../supabase/migrations')
const MIGRATION = readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith('.sql')).sort()
  .map((f) => readFileSync(path.join(MIGRATIONS_DIR, f), 'utf8')).join('\n')
const COLIN = { sub: '00000000-0000-0000-0000-00000000000c', email: 'colin@example.com' }
const THALIA = { sub: '00000000-0000-0000-0000-0000000000a1', email: 'thalia@example.com' }
let db: PGlite
const r = async (sql: string, params: unknown[] = []) => (await db.query<{ r: Record<string, unknown> }>(`select ${sql} as r`, params)).rows[0].r
const as = async <T>(who: { sub: string; email: string }, fn: () => Promise<T>) => {
  await db.query(`select set_config('request.jwt.claims', $1, false)`, [JSON.stringify(who)])
  await db.exec('set role authenticated')
  try { return await fn() } finally { await db.exec('reset role'); await db.query(`select set_config('request.jwt.claims', '', false)`) }
}

beforeAll(async () => {
  db = new PGlite()
  await db.exec(SUPABASE_STUB)
  await db.exec(MIGRATION)
  await db.exec(`insert into public.team_members (email, role, person, display_name) values
    ('colin@example.com', 'owner', 'colin', 'Colin'), ('thalia@example.com', 'caller', 'thalia', 'Thalia')`)
})

describe('the package', () => {
  it('send, email, value, price, callback, walk; the funnel counts it', async () => {
    const lead = (await r(`public.agent_add_prospect($1::jsonb, 'Muse intake')`, [JSON.stringify({ owner_name: 'PAT PACKAGE', owner_type: 'individual',
      address: '21 Package Test St', city: 'Waukesha', phones: [{ number: '4145562101', name: 'PAT PACKAGE' }] })])).lead_id as string
    const pkg = { lead_id: lead, need: 'Moving to Arizona for work in January', timeline: 'Phoenix, by January 15',
      their_number: '180', their_basis: 'what she owes plus moving money', owed: 'about 120 on the mortgage, current', on_title: 'Pat and her ex-husband Lee',
      occupancy: 'Pat lives there', motivation: 'Job transfer, has to be out by mid-January', hot: true,
      condition: { roof: '22 years old, leaks over the kitchen', yard: 'big oak over the garage, fence falling down' } }
    // validation: a callback time is required unless the walk was booked
    expect(await as(THALIA, () => r(`public.package_submit($1::jsonb)`, [JSON.stringify(pkg)]))).toMatchObject({ ok: false, reason: expect.stringContaining('callback') })
    const sent = await as(THALIA, () => r(`public.package_submit($1::jsonb)`, [JSON.stringify({ ...pkg, callback_at: '2026-10-28T19:00:00Z' })]))
    expect(sent).toMatchObject({ ok: true })
    const id = sent.package_id as string
    expect(await as(THALIA, () => r(`public.package_submit($1::jsonb)`, [JSON.stringify({ ...pkg, callback_at: '2026-10-28T19:00:00Z' })])))
      .toMatchObject({ ok: false, reason: expect.stringContaining('open package') })
    expect((await db.query(`select kind, owner::text, due_at from public.tasks where lead_id = $1`, [lead])).rows)
      .toEqual([{ kind: 'callback', owner: 'thalia', due_at: new Date('2026-10-28T19:00:00Z') }])
    // the email: claimed once, with everything in it
    const mail = (await r(`public.package_mail_claim(5)`)) as unknown as PackageRow[]
    expect(mail).toHaveLength(1)
    expect((await r(`public.package_mail_claim(5)`)) as unknown as unknown[]).toEqual([])
    const e = packageEmail(mail[0], 'https://app.example.com')
    expect(e.subject).toBe('HOT Package: PAT PACKAGE, 21 Package Test St')
    for (const words of ['Moving to Arizona', 'what she owes plus moving money', 'Pat and her ex-husband Lee', '22 years old, leaks over the kitchen',
      'big oak over the garage', 'Yard and outside', `https://app.example.com/lead/${lead}#package`]) expect(e.text).toContain(words)
    expect(e.html).toContain('Price it on the card')
    // Muse adds the value; only Colin sets the number
    expect(await r(`public.package_set_value($1, 0, 'x', null, 'Muse')`, [id])).toMatchObject({ ok: false })
    expect(await r(`public.package_set_value($1, 265000, '3 sales within half a mile, last 6 months', $2::jsonb, 'Muse')`,
      [id, JSON.stringify([{ address: '30 Near St', sold_price: 270000, sold_date: '2026-08-01', sqft: 1400 }])])).toMatchObject({ ok: true, status: 'waiting_number' })
    await expect(as(THALIA, () => r(`public.package_price($1, 150000, null, 'A')`, [id]))).rejects.toThrow(/only Colin/)
    expect(await as(COLIN, () => r(`public.package_price($1, 150000, 'roof and the oak', 'A')`, [id]))).toMatchObject({ ok: true })
    expect((await r(`public.package_ready_claim()`)) as unknown as unknown[]).toHaveLength(1)
    expect((await r(`public.package_ready_claim()`)) as unknown as unknown[]).toEqual([])
    // the callback: only Colin's number
    expect(await as(THALIA, () => r(`public.package_delivered($1, 160000, 'yes', null, null)`, [id])))
      .toMatchObject({ ok: false, reason: expect.stringContaining('150000') })
    expect(await as(THALIA, () => r(`public.package_delivered($1, 150000, 'close', null, 'wants Lee there')`, [id])))
      .toMatchObject({ ok: true, status: 'agreed' })
    expect((await db.query(`select count(*)::int n from public.tasks where lead_id = $1 and done_at is null`, [lead])).rows[0]).toEqual({ n: 0 })
    // the walk booked on the card closes the package
    await db.query(`update public.leads set stage = 'walkthrough_booked' where id = $1`, [lead])
    expect((await db.query(`select status from public.deal_packages where id = $1`, [id])).rows[0]).toEqual({ status: 'walk_booked' })
    const f = (await as(COLIN, () => r(`public.deals_funnel(4)`))) as unknown as { source: string; packages: number; priced: number; agreed: number; walks: number; grades: { A: number } }[]
    expect(f.find((x) => x.source === 'cold_list' && x.packages === 1)).toMatchObject({ priced: 1, agreed: 1, walks: 1, grades: { A: 1 } })
  })

  it('a counter goes back to Colin; Colin late on the same day shows on Today', async () => {
    const lead = (await r(`public.agent_add_prospect($1::jsonb, 'Muse intake')`, [JSON.stringify({ owner_name: 'CODY COUNTER', owner_type: 'individual',
      address: '22 Package Test St', phones: ['4145562201'] })])).lead_id as string
    const id = (await as(THALIA, () => r(`public.package_submit($1::jsonb)`, [JSON.stringify({ lead_id: lead, need: 'landlord, done with tenants',
      walk_booked_on_call: false, callback_at: '2026-10-29T19:00:00Z' })]))).package_id as string
    await db.query(`update public.deal_packages set created_at = now() - interval '2 days' where id = $1`, [id])
    const open = (await as(COLIN, () => r(`public.packages_open()`))) as unknown as { package: { id: string }; late: string | null }[]
    expect(open.find((x) => x.package.id === id)?.late).toBe('Colin: price it today')
    await as(COLIN, () => r(`public.package_price($1, 90000, null, 'B')`, [id]))
    expect(await as(THALIA, () => r(`public.package_delivered($1, 90000, 'counter', 110000, 'needs 110')`, [id]))).toMatchObject({ ok: true, status: 'counter' })
    expect(await as(COLIN, () => r(`public.package_price($1, 98000, 'met him partway', 'B')`, [id]))).toMatchObject({ ok: true })
    expect((await db.query(`select status, our_number::int from public.deal_packages where id = $1`, [id])).rows[0]).toEqual({ status: 'number_ready', our_number: 98000 })
  })

  it('the door: Muse lists packages to value and writes the value, never a number', async () => {
    const calls: [string, Record<string, unknown>][] = []
    const db2 = { records: async (fn: string, args: Record<string, unknown>) => { calls.push([fn, args]); return { ok: true } } } as unknown as DoorDb
    const muse = { id: 'k', name: 'Muse', role: 'agent' as const }
    await handleMessage({ jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: 'packages_to_value', arguments: {} } }, muse, db2)
    await handleMessage({ jsonrpc: '2.0', id: 2, method: 'tools/call', params: { name: 'set_package_value', arguments: { package_id: 'P1', arv: 265000, basis: '3 sales', comps: [] } } }, muse, db2)
    expect(calls).toEqual([['agent_packages_to_value', { p_limit: 20 }],
      ['package_set_value', { p_id: 'P1', p_arv: 265000, p_basis: '3 sales', p_comps: [], p_agent: 'Muse' }]])
  })
})
