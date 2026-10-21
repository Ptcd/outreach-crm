// Send contract end to end on the real migrations (PGlite, calls made as service_role like the
// Edge Functions): Colin signs and sends -> two sellers open, agree, one fills the condition
// report, both sign -> sealed PDF stored, deal "Signed: to title", lead under contract, task for
// today, Colin notified. Plus the refusals: bad / replaced / expired links, no consent, an
// incomplete report, signing twice, a withdrawn offer, and an audit log nobody can edit.
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { PGlite } from '@electric-sql/pglite'
import * as PDFLib from 'pdf-lib'
import { beforeAll, beforeEach, describe, expect, it } from 'vitest'
import { SUPABASE_STUB } from './supabaseStub'
import { TERMS, fullRecr } from './contractPdf.test'
import { b64ToBytes, sha256Hex, type PdfLib } from '../supabase/functions/_shared/contractPdf'
import { WB11_B64 } from '../supabase/functions/_shared/wb11Template.generated'
import {
  checkTerms, newLink, openForSigner, previewOffer, seal, sendOffer, signAsSeller, type ContractPorts,
} from '../supabase/functions/_shared/contracts'
import type { Rpc } from '../supabase/functions/_shared/sending'

const MIGRATIONS_DIR = path.resolve(__dirname, '../supabase/migrations')
const MIGRATION = readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith('.sql')).sort()
  .map((f) => readFileSync(path.join(MIGRATIONS_DIR, f), 'utf8')).join('\n')
const LEAD = '00000000-0000-0000-0000-0000000000a1'
const T0 = new Date('2026-10-21T19:00:00Z')
const PNG = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=='

let db: PGlite
const rpc: Rpc = async (fn, args) => {
  const names = Object.keys(args)
  try {
    await db.exec('set role service_role')
    const r = await db.query<{ r: unknown }>(`select public.${fn}(${names.map((n, i) => `${n} => $${i + 1}`).join(', ')}) as r`,
      names.map((n) => { const v = args[n]; return v !== null && typeof v === 'object' ? JSON.stringify(v) : v }))
    return { data: r.rows[0]?.r ?? null, error: null }
  } catch (e) {
    return { data: null, error: { message: String(e) } }
  } finally {
    await db.exec('reset role')
  }
}

const files = new Map<string, Uint8Array>()
const pushes: { title: string; body: string; url: string }[] = []
let clock = T0
const ports = (): ContractPorts => ({
  rpc, lib: PDFLib as unknown as PdfLib, template: b64ToBytes(WB11_B64), appUrl: 'https://deals.example.com', now: () => clock,
  storage: {
    put: async (p, bytes) => { if (files.has(p)) throw new Error(`exists: ${p}`); files.set(p, bytes) },
    get: async (p) => { const b = files.get(p); if (!b) throw new Error(`missing ${p}`); return b },
    signedUrl: async (p) => `https://storage.example.com/${p}?sig=1`,
  },
  notify: async (m) => { pushes.push(m) },
})
const tokenOf = (url: string) => url.split('/sign/')[1]
const terms = TERMS as unknown as Record<string, unknown>

async function send(sellers = [{ name: 'Dale Novak', email: 'dale@example.com' }, { name: 'Rita Novak' }], includeRecr = true) {
  const r = await sendOffer(ports(), { leadId: LEAD, terms, includeRecr, sellers, buyerSignature: PNG, actor: 'Colin', ip: '10.0.0.1', ua: 'Colin phone' })
  if (!r.ok) throw new Error(r.reason)
  return r
}
const one = async <T>(sql: string, params: unknown[] = []) => (await db.query<T>(sql, params)).rows[0]

beforeAll(async () => {
  db = new PGlite()
  await db.exec(SUPABASE_STUB)
  await db.exec(MIGRATION)
})

beforeEach(async () => {
  files.clear()
  pushes.length = 0
  clock = T0
  await db.exec(`
    truncate public.contracts, public.tasks, public.deals, public.messages, public.leads cascade;
    insert into public.leads (id, wpie_owner_id, owner_name, property_address, stage) values ('${LEAD}', 77, 'DALE NOVAK', '2847 N Burleigh St', 'colin_call');
  `)
})

describe('send contract', () => {
  it('previews with a watermark and refuses missing terms', async () => {
    const p = await previewOffer(ports(), terms)
    expect(p.ok).toBe(true)
    const bad = checkTerms({ ...terms, price: '', closing: '', earnestHolder: '' })
    expect(bad.problems).toEqual(['Add the price.', 'Add the closing date.', 'Earnest money must be a number below the price.',
      'Say who holds the earnest money (the title company).'])
    const r = await sendOffer(ports(), { leadId: LEAD, terms, includeRecr: true, sellers: [], actor: 'Colin' })
    expect(r).toMatchObject({ ok: false, reason: expect.stringMatching(/one or two sellers/) })
  })

  it('runs the whole flow and seals one PDF', async () => {
    const sent = await send()
    expect(sent.links.map((l) => l.name)).toEqual(['Dale Novak', 'Rita Novak'])
    expect(sent.links[0].url).toMatch(/^https:\/\/deals\.example\.com\/sign\/[A-Za-z0-9_-]{43}$/)
    expect(files.has(`${sent.id}/offer.pdf`)).toBe(true)
    expect(files.has(`${sent.id}/buyer.png`)).toBe(true)
    const c0 = await one<{ status: string; offer_sha256: string }>(`select status, offer_sha256 from public.contracts`)
    expect(c0.status).toBe('sent')
    expect(c0.offer_sha256).toBe(await sha256Hex(files.get(`${sent.id}/offer.pdf`)!))
    expect((await one<{ n: number }>(`select count(*)::int n from public.contract_signers where token_hash like '%${tokenOf(sent.links[0].url)}%'`)).n).toBe(0)
    expect((await one<{ status: string }>(`select status::text from public.deals`)).status).toBe('offer')

    const [dale, rita] = sent.links.map((l) => tokenOf(l.url))
    clock = new Date('2026-10-22T20:10:00Z')
    const o = await openForSigner(ports(), dale, '5.6.7.8', 'Android Chrome')
    if (!o.ok) throw new Error(o.reason)
    expect(o.view).toMatchObject({ status: 'sent', include_recr: true, recr: null, buyer_name: 'Colin Merrill',
      signer: { name: 'Dale Novak', position: 1, signed_at: null }, others: [{ name: 'Rita Novak', signed: false }] })
    expect(o.view.terms.price).toBe(182500)
    expect(o.view.offer_url).toMatch(/offer\.pdf/)
    expect(JSON.stringify(o.view)).not.toMatch(/token_hash|offer_path/)

    expect(await signAsSeller(ports(), { token: dale, consent: false, name: 'Dale Novak', recr: fullRecr() }))
      .toMatchObject({ ok: false, reason: expect.stringMatching(/agree to sign electronically/) })
    expect(await signAsSeller(ports(), { token: dale, consent: true, name: 'Dale Novak', recr: { ...fullRecr(['B1']), explain: {} } }))
      .toMatchObject({ ok: false, reason: 'Explain each "yes" in section B (B1).' })
    expect(await signAsSeller(ports(), { token: dale, consent: true, name: 'Dale Novak', recr: null }))
      .toMatchObject({ ok: false, reason: 'Fill in the condition report first.' })

    const s1 = await signAsSeller(ports(), { token: dale, consent: true, name: 'Dale A. Novak', signature: PNG, recr: fullRecr(['B1']),
      ip: '5.6.7.8', ua: 'Android Chrome' })
    expect(s1).toMatchObject({ ok: true, allSigned: false, sealed: false })
    expect(await signAsSeller(ports(), { token: dale, consent: true, name: 'Dale Novak' })).toMatchObject({ ok: false, reason: 'You already signed.' })

    // Rita sees Dale's report already filled and signs with a typed signature.
    const o2 = await openForSigner(ports(), rita, '9.9.9.9', 'iPhone Safari')
    if (!o2.ok) throw new Error(o2.reason)
    expect(o2.view.recr?.answers.B1).toBe('yes')
    expect(o2.view.others).toEqual([{ name: 'Dale Novak', signed: true }])
    clock = new Date('2026-10-22T20:30:00Z')
    const s2 = await signAsSeller(ports(), { token: rita, consent: true, name: 'Rita Novak', ip: '9.9.9.9', ua: 'iPhone Safari' })
    expect(s2).toMatchObject({ ok: true, allSigned: true, sealed: true })
    if (!s2.ok) return
    expect(s2.finalUrl).toMatch(/signed-[0-9a-f]{12}\.pdf/)

    const c = await one<{ status: string; final_path: string; final_sha256: string; signed_at: string }>(
      `select status, final_path, final_sha256, signed_at::text from public.contracts`)
    expect(c.status).toBe('signed')
    const final = files.get(c.final_path)!
    expect(c.final_sha256).toBe(await sha256Hex(final))
    const pages = (await PDFLib.PDFDocument.load(final)).getPageCount()
    expect(pages).toBeGreaterThanOrEqual(11 + 5 + 1)
    expect((await one<{ status: string; contract_date: string }>(`select status::text, contract_date::text from public.deals`)))
      .toEqual({ status: 'signed_to_title', contract_date: '2026-10-22' })
    expect((await one<{ stage: string }>(`select stage::text from public.leads`)).stage).toBe('under_contract')
    const task = await one<{ title: string; owner: string; source: string; done_at: null }>(`select title, owner::text, source, done_at from public.tasks`)
    expect(task).toEqual({ title: 'Contract + deposit to title today: 2847 N Burleigh St', owner: 'colin', source: 'contract', done_at: null })
    expect(pushes).toEqual([{ title: 'Contract signed: 2847 N Burleigh St', tag: expect.any(String),
      body: 'Every seller signed. Contract + earnest money to Knight Barry Title, Milwaukee today.', url: `https://deals.example.com/lead/${LEAD}` }])
    const kinds = (await db.query<{ kind: string }>(`select kind from public.contract_events order by at, id`)).rows.map((r) => r.kind)
    expect(kinds).toEqual(['buyer_signed', 'created', 'created', 'opened', 'consented', 'recr', 'signed', 'opened', 'consented', 'signed', 'sealed'])
    const notes = (await db.query<{ body: string }>(`select body from public.messages order by sent_at`)).rows.map((r) => r.body)
    expect(notes[0]).toBe('Offer (WB-11 10-1-2026) sent for signature by Colin.')
    expect(notes[1]).toMatch(/^Offer signed by every seller\. Sealed PDF SHA-256 [0-9a-f]{64}\.$/)

    // Sealing again is a no-op; the signed link still opens and offers the signed copy.
    expect(await seal(ports(), sent.id)).toEqual({ ok: true, path: c.final_path })
    const after = await openForSigner(ports(), dale)
    expect(after.ok && after.view.final_url).toMatch(/signed-/)
    expect(pushes).toHaveLength(1)
  })

  it('keeps the audit log append-only, even for the service role', async () => {
    await send()
    await db.exec('set role service_role')
    await expect(db.exec(`update public.contract_events set actor = 'x'`)).rejects.toThrow(/append-only/)
    await expect(db.exec(`delete from public.contract_events`)).rejects.toThrow(/append-only/)
    await db.exec('reset role')
  })

  it('refuses bad, replaced and expired links, and a withdrawn offer', async () => {
    const sent = await send([{ name: 'Dale Novak' }], false)
    const dale = tokenOf(sent.links[0].url)
    expect(await openForSigner(ports(), 'nope')).toMatchObject({ ok: false, reason: expect.stringMatching(/not valid/) })
    expect(await openForSigner(ports(), 'A'.repeat(43))).toMatchObject({ ok: false, reason: expect.stringMatching(/not valid/) })

    const signer = await one<{ id: string }>(`select id from public.contract_signers`)
    const fresh = await newLink(ports(), signer.id, 'Colin')
    if (!fresh.ok) throw new Error(fresh.reason)
    expect(await openForSigner(ports(), dale)).toMatchObject({ ok: false })
    const freshToken = tokenOf(fresh.url)
    expect((await openForSigner(ports(), freshToken)).ok).toBe(true)

    clock = new Date(T0.getTime() + 15 * 86_400_000)
    expect(await openForSigner(ports(), freshToken)).toMatchObject({ ok: false, reason: expect.stringMatching(/expired/) })
    clock = T0

    expect((await rpc('contract_void', { p_id: sent.id, p_reason: 'seller sold to someone else', p_actor: 'Colin' })).data).toEqual({ ok: true })
    expect(await openForSigner(ports(), freshToken)).toMatchObject({ ok: false, reason: 'Colin withdrew this offer.' })
    expect(await signAsSeller(ports(), { token: freshToken, consent: true, name: 'Dale' })).toMatchObject({ ok: false })
  })

  it('signs without a condition report when Colin marked the seller exempt', async () => {
    const sent = await send([{ name: 'Estate of J Novak, Rita Novak PR' }], false)
    const r = await signAsSeller(ports(), { token: tokenOf(sent.links[0].url), consent: true, name: 'Rita Novak, Personal Representative' })
    expect(r).toMatchObject({ ok: true, allSigned: true, sealed: true })
    const pages = (await PDFLib.PDFDocument.load(files.get((await one<{ final_path: string }>(`select final_path from public.contracts`)).final_path)!)).getPageCount()
    expect(pages).toBe(12)   // the Offer + the certificate, no condition report
  })

  it('lets the team read contracts but not the link hashes, and nobody else write', async () => {
    await send()
    await db.exec(`insert into public.team_members (email, role, person, display_name) values ('adil@example.com', 'owner', 'adil', 'Adil') on conflict do nothing`)
    await db.query(`select set_config('request.jwt.claims', $1, false)`, [JSON.stringify({ sub: '00000000-0000-0000-0000-0000000000ad', email: 'adil@example.com' })])
    await db.exec('set role authenticated')
    try {
      expect((await db.query(`select id, status from public.contracts`)).rows).toHaveLength(1)
      expect((await db.query(`select name, signed_at from public.contract_signers`)).rows).toHaveLength(2)
      await expect(db.query(`select token_hash from public.contract_signers`)).rejects.toThrow(/permission denied/)
      await expect(db.query(`update public.contracts set status = 'signed'`)).rejects.toThrow(/permission denied/)
      await expect(db.query(`select public.contract_sign('x', 'y', null, null, null, null)`)).rejects.toThrow(/permission denied/)
    } finally {
      await db.exec('reset role')
    }
  })
})
