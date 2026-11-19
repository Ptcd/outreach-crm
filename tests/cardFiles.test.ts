// 0256 (Muse, desk 311, 2026-11-19, from Colin: "Muse must be able to read ALL files stored in WPIE, not just card
// fields"). The agent door's card_files: every contract on a card whole (terms, added provisions word for word, the
// seller's yes answers, who signed), the same in plain sentences, and a short-lived link to the PDF. No storage path
// leaves the server, a caller login cannot call the database function, and the tool changes nothing.
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { PGlite } from '@electric-sql/pglite'
import { beforeAll, describe, expect, it } from 'vitest'
import { SUPABASE_STUB } from './supabaseStub'
import { callTool, TOOLS, type Agent, type DoorDb } from '../supabase/functions/_shared/agentDoor'
import { contractPlainWords, shapeCardFiles } from '../supabase/functions/_shared/cardFiles'

const MIGRATIONS_DIR = path.resolve(__dirname, '../supabase/migrations')
const MIGRATION = readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith('.sql')).sort()
  .map((f) => readFileSync(path.join(MIGRATIONS_DIR, f), 'utf8')).join('\n')

let db: PGlite
type Json = Record<string, any>
const LEAD = '00000000-0000-0000-0000-00000000f001'
const BARE = '00000000-0000-0000-0000-00000000f002'
const SIGNED = '2026-11-18T22:51:14Z'
const ADDED = '1. CLOSING COSTS. Buyer shall pay all closing costs of this transaction. 3. WALK-THROUGH CONTINGENCY. This is Buyer\'s only contingency.'
const TERMS = { street: '991 TEST ST', muniType: 'City', muniName: 'Green Bay', county: 'Brown', buyerName: 'WeLiveWI LLC', buyerSigner: 'Colin Merrill',
  buyerSignerTitle: 'Authorized Representative', price: 60000, closing: 'December 18, 2026', closingOn: '2026-12-18', earnestMoney: 500, earnestDays: 5,
  earnestHolder: 'the title company selected by Buyer', proofOfFundsDays: 7, inspection: false, bindingDeadline: 'November 23, 2026 at 11:59 p.m.', additional: ADDED }
let contractId = ''
const files = async (lead: string | null, contract: string | null = null) => {
  await db.exec('set role service_role')
  try { return (await db.query<{ r: Json }>(`select public.agent_card_files($1, $2) as r`, [lead, contract])).rows[0].r } finally { await db.exec('reset role') }
}
const link = async (p: string) => `https://files.example/${encodeURIComponent(p)}?token=t`

beforeAll(async () => {
  db = new PGlite()
  await db.exec(SUPABASE_STUB)
  await db.exec(MIGRATION)
  await db.exec(`
    insert into public.team_members (email, role, person, display_name) values
      ('colin@example.com', 'owner', 'colin', 'Colin'), ('adil@example.com', 'caller', 'adil', 'Tyler')
    on conflict (email) do update set role = excluded.role, person = excluded.person, display_name = excluded.display_name;
    insert into public.leads (id, wpie_owner_id, owner_name, lane, stage, property_address, municipality, county, mailing_state, locked_to, assigned_to) values
      ('${LEAD}', 9201, 'JASON TESTESTATE', 'flip', 'colin_call', '991 TEST ST', 'CITY OF GREEN BAY', 'Brown', 'WI', 'adil', 'adil'),
      ('${BARE}', 9202, 'NO PAPER YET', 'flip', 'colin_call', '2 BARE ST', 'CITY OF TEST', 'Brown', 'WI', 'adil', 'adil');`)
  contractId = (await db.query<{ id: string }>(
    `insert into public.contracts (lead_id, form, status, terms, buyer_name, buyer_signed_at, offer_path, offer_sha256, include_recr, recr)
     values ($1, 'WB-11 10-1-2026', 'sent', $2, 'WeLiveWI LLC', $3, 'c1/offer.pdf', 'aa11', true, $4) returning id::text`,
    [LEAD, JSON.stringify(TERMS), SIGNED, JSON.stringify({ answers: { B1: 'no', B2: 'yes' }, explain: { B12: 'Roof leaked in 2024, patched.' }, years: { G6: '20' } })])).rows[0].id
  await db.query(`insert into public.contract_signers (contract_id, position, name, email, token_hash, expires_at)
                  values ($1, 1, 'Jason Testestate', 'seller@example.com', 'h1', $2::timestamptz + interval '5 days')`, [contractId, SIGNED])
}, 180_000)

describe('card_files: an agent reads the documents on a card', () => {
  it('an offer out for signature: the terms whole, in plain words, and a link to the offer as sent', async () => {
    const raw = await files(LEAD)
    expect(raw.ok).toBe(true)
    expect(raw.files).toHaveLength(1)
    expect(raw.files[0].terms.additional).toBe(ADDED)
    const out = await shapeCardFiles(raw, link) as Json
    const f = out.files[0]
    expect(f.status).toBe('sent')
    expect(f.pdf).toMatchObject({ which: 'offer_as_sent', url: 'https://files.example/c1%2Foffer.pdf?token=t', expires_in_seconds: 600, sha256: 'aa11' })
    expect(f.in_plain_words).toEqual(expect.arrayContaining([
      'Offer to purchase 991 TEST ST, City of Green Bay, Brown County, Wisconsin. Form WB-11 10-1-2026.',
      'Status: sent, not signed by every seller (waiting on Jason Testestate). Not a contract yet.',
      'Buyer: WeLiveWI LLC, signed by Colin Merrill (Authorized Representative).',
      'Price: $60,000.', 'Closing: December 18, 2026.',
      'Earnest money: $500, due within 5 days of acceptance, held by the title company selected by Buyer.',
      'Title company: none is named in the contract. The buyer picks it.',
      'Proof of funds: the buyer gives it within 7 days of acceptance.', 'Inspection contingency: none.',
      `Added provisions, word for word (they override the printed form where they say so): ${ADDED}`,
    ]))
    // the seller's yes answers come with their question and the section's explanation
    expect(f.condition_report.yes).toHaveLength(1)
    expect(f.condition_report.yes[0]).toMatchObject({ id: 'B2', explanation: 'Roof leaked in 2024, patched.' })
    expect(f.condition_report.yes[0].question.length).toBeGreaterThan(10)
    // no storage path leaves the server, in any field
    expect(JSON.stringify(out)).not.toMatch(/offer_path|final_path|c1\/offer\.pdf/)
  })

  it('once signed: the signed PDF is the one linked, with the deal and its title company', async () => {
    await db.query(`update public.contract_signers set signed_at = $2, signed_name = 'Jason Testestate' where contract_id = $1`, [contractId, SIGNED])
    await db.exec('set role service_role')
    try { await db.query(`select public.contract_sealed($1, 'c1/signed.pdf', 'bb22', $2)`, [contractId, SIGNED]) } finally { await db.exec('reset role') }
    await db.query(`update public.deals set title_company = 'Knight Barry Title', title_phone = '9205550100' where lead_id = $1`, [LEAD])
    const out = await shapeCardFiles(await files(null, contractId), link) as Json   // by the contract's id alone
    expect(out.lead_id).toBe(LEAD)
    expect(out.stage).toBe('under_contract')
    expect(out.deal).toMatchObject({ status: 'signed_to_title', price: 60000, closing_on: '2026-12-18', title_company: 'Knight Barry Title' })
    const f = out.files[0]
    expect(f.pdf).toMatchObject({ which: 'signed', url: 'https://files.example/c1%2Fsigned.pdf?token=t', sha256: 'bb22' })
    expect(f.in_plain_words[1]).toBe('Status: signed by every seller on November 18, 2026. This is a binding contract.')
    expect(f.in_plain_words).toContain('Seller: Jason Testestate (signed November 18, 2026).')
    // a link that cannot be made is said, and the terms are still there
    const dark = await shapeCardFiles(await files(LEAD), async () => null) as Json
    expect(dark.files[0].pdf).toMatchObject({ url: null, expires_in_seconds: null })
    expect(dark.files[0].terms.price).toBe(60000)
  })

  it('a card with no contract says so; a wrong id is refused; a term the contract does not state is not invented', async () => {
    const none = await shapeCardFiles(await files(BARE), link) as Json
    expect(none).toMatchObject({ ok: true, files: [], none: 'No contract has been made on this card. WPIE stores no other file on a card today.' })
    expect(await shapeCardFiles(await files('00000000-0000-0000-0000-0000000000ff'), link)).toEqual({ ok: false, reason: 'no such card' })
    expect(await shapeCardFiles(await files(null, '00000000-0000-0000-0000-0000000000ff'), link)).toEqual({ ok: false, reason: 'no such contract' })
    const lines = contractPlainWords({ form: 'WB-11 10-1-2026', status: 'sent', terms: { street: '5 X ST', price: 100000, earnestHolder: 'Knight Barry Title, Milwaukee', inspection: true, inspectionDays: 10 }, sellers: [] })
    expect(lines).toContain('Title company named in the contract: Knight Barry Title, Milwaukee.')
    expect(lines).toContain('Inspection contingency: yes, 10 days.')
    expect(lines).toContain('Added provisions: none. The printed form decides who pays which closing cost.')
    expect(lines.some((l) => l.startsWith('Closing') || l.startsWith('Earnest') || l.startsWith('Proof'))).toBe(false)
  })

  it('is read only and the door\'s alone: a login cannot call it, and the tool takes a card or a contract id', async () => {
    await db.query(`select set_config('request.jwt.claims', $1, false)`, [JSON.stringify({ email: 'adil@example.com' })])
    await db.exec('set role authenticated')
    try { await expect(db.query(`select public.agent_card_files($1)`, [LEAD])).rejects.toThrow(/permission denied/) }
    finally { await db.exec('reset role'); await db.query(`select set_config('request.jwt.claims', '', false)`) }

    const tool = TOOLS.find((t) => t.name === 'card_files')!
    expect(tool.role).toBe('any')
    const muse: Agent = { id: 'k1', name: 'Muse', role: 'agent', scopes: ['marks'], tools: null }
    const asked: unknown[] = []
    const door = { cardFiles: async (a: unknown) => { asked.push(a); return { ok: true, files: [] } } } as unknown as DoorDb
    expect((await callTool('card_files', { contract_id: contractId }, muse, door)).isError).toBeFalsy()
    expect(asked).toEqual([{ lead_id: null, contract_id: contractId }])
    expect((await callTool('card_files', {}, muse, door)).isError).toBe(true)
    expect((await callTool('card_files', { lead_id: "x'; drop table leads" }, muse, door)).isError).toBe(true)
    expect(asked).toHaveLength(1)
  })
})
