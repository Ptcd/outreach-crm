// Send offer (0217) end to end on the real migrations: the standards Colin set once, who may send and at what
// price, the offer built from the card in three answers, the signing link emailed to the seller, the seller's
// signature, and the signed PDF emailed to everyone as an attachment.
// Set SEND_OFFER_OUT=<dir> to write the PDFs and the emails for a look.
import { mkdirSync, readdirSync, readFileSync, writeFileSync } from 'node:fs'
import path from 'node:path'
import { PGlite } from '@electric-sql/pglite'
import * as PDFLib from 'pdf-lib'
import { beforeAll, beforeEach, describe, expect, it } from 'vitest'
import { SUPABASE_STUB } from './supabaseStub'
import { fullRecr } from './contractPdf.test'
import { b64ToBytes, type PdfLib } from '../supabase/functions/_shared/contractPdf'
import { WB11_B64 } from '../supabase/functions/_shared/wb11Template.generated'
import {
  centralEndOfDay, muniOf, newLink, openForSigner, quickGate, quickPreview, quickSend, quickTerms, signAsSeller,
  type ContractPorts, type OfferContext, type OutMail,
} from '../supabase/functions/_shared/contracts'
import { buildMessage } from '../supabase/functions/_shared/smtp'
import type { Rpc } from '../supabase/functions/_shared/sending'

const MIGRATIONS_DIR = path.resolve(__dirname, '../supabase/migrations')
const MIGRATION = readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith('.sql')).sort()
  .map((f) => readFileSync(path.join(MIGRATIONS_DIR, f), 'utf8')).join('\n')
const LEAD = '00000000-0000-0000-0000-0000000000b1'
const T0 = new Date('2026-11-12T20:00:00Z')        // Thursday 2:00 p.m. Central
const OUT = process.env.SEND_OFFER_OUT
const keep = (name: string, bytes: Uint8Array | string) => {
  if (!OUT) return
  mkdirSync(OUT, { recursive: true })
  writeFileSync(path.join(OUT, name), bytes)
}

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
const asUser = async <T>(email: string, sql: string, params: unknown[] = []): Promise<T> => {
  await db.query(`select set_config('request.jwt.claims', $1, false)`, [JSON.stringify({ sub: '00000000-0000-0000-0000-0000000000c1', email })])
  await db.exec('set role authenticated')
  try { return (await db.query<{ r: T }>(sql, params)).rows[0].r } finally { await db.exec('reset role') }
}

const files = new Map<string, Uint8Array>()
const mails: OutMail[] = []
const pushes: { title: string }[] = []
let clock = T0
let mailDown = false
const ports = (): ContractPorts => ({
  rpc, lib: PDFLib as unknown as PdfLib, template: b64ToBytes(WB11_B64), appUrl: 'https://deals.example.com', now: () => clock,
  storage: {
    put: async (p, bytes) => { if (files.has(p)) throw new Error(`exists: ${p}`); files.set(p, bytes) },
    get: async (p) => { const b = files.get(p); if (!b) throw new Error(`missing ${p}`); return b },
    signedUrl: async (p, _s, downloadAs) => `https://storage.example.com/${p}?sig=1${downloadAs ? `&download=${encodeURIComponent(downloadAs)}` : ''}`,
  },
  notify: async (m) => { pushes.push(m) },
  mail: async (m) => { if (mailDown) throw new Error('smtp down'); mails.push(m) },
})
// Colin's number goes on the card as Colin (the deals trigger refuses anyone else)
const colinTypes = async (n: number) => {
  await db.query(`select set_config('request.jwt.claims', $1, false)`, [JSON.stringify({ sub: '00000000-0000-0000-0000-0000000000c1', email: 'colin@example.com' })])
  await db.exec(`insert into public.deals (lead_id, status, colin_offer) values ('${LEAD}', 'offer', ${n})`)
  await db.query(`select set_config('request.jwt.claims', '', false)`)
}
const ctxFor = async (email: string): Promise<OfferContext> => (await rpc('offer_context', { p_lead_id: LEAD, p_email: email })).data as OfferContext
const one = async <T>(sql: string, params: unknown[] = []) => (await db.query<T>(sql, params)).rows[0]
const tokenOf = (url: string) => url.split('/sign/')[1]
const ASK = { price: 142000, closingOn: '2026-12-12', sellers: [{ name: 'Dale Novak', email: 'dale@example.com', phone: '4145550177' }] }
const BY = { actor: 'Colin', ip: '10.0.0.1', ua: 'Colin phone' }

beforeAll(async () => {
  db = new PGlite()
  await db.exec(SUPABASE_STUB)
  await db.exec(MIGRATION)
  await db.exec(`
    insert into public.team_members (email, role, person, display_name) values
      ('colin@example.com', 'owner', 'colin', 'Colin'), ('thalia@example.com', 'caller', 'thalia', 'Thalia')
    on conflict do nothing;
    update public.offer_standards set buyer_email = 'colin@example.com', earnest_holder = 'Knight Barry Title' where id = 1;`)
})

beforeEach(async () => {
  files.clear()
  mails.length = 0
  pushes.length = 0
  clock = T0
  mailDown = false
  await db.exec(`
    truncate public.contracts, public.tasks, public.deals, public.messages, public.leads cascade;
    update public.offer_standards set signature_png = null where id = 1;
    insert into public.leads (id, wpie_owner_id, owner_name, property_address, municipality, county, stage, mailing_street, mailing_city, mailing_state, mailing_zip)
    values ('${LEAD}', 78, 'DALE NOVAK', '2847 N Burleigh St', 'VILLAGE OF SHOREWOOD', 'Milwaukee', 'colin_call', '2847 N Burleigh St', 'Shorewood', 'WI', '53211');
  `)
})

describe('the standards', () => {
  it('start as Colin said them, and only Colin changes them', async () => {
    const s = await asUser<{ ok: boolean; standards: Record<string, unknown>; can_set_price: boolean; can_send: boolean; signature_png: string | null }>(
      'colin@example.com', `select public.offer_setup($1) as r`, [LEAD])
    expect(s.standards).toMatchObject({ buyer_name: 'WeLiveWI LLC', signer_name: 'Colin Merrill', earnest_money: 500, has_signature: false })
    expect(String(s.standards.additional)).toMatch(/Buyer shall pay all closing costs/)
    expect(String(s.standards.additional)).toMatch(/as is, where is\. Seller makes no warranties as to the condition/)
    expect(String(s.standards.additional)).toMatch(/walk-through of the Property and Buyer's approval.*This contingency expires at closing\. This is Buyer's only contingency\./s)
    expect(s).toMatchObject({ can_set_price: true, can_send: true })

    const caller = await asUser<{ can_set_price: boolean; can_edit_standards: boolean; signature_png: string | null }>('thalia@example.com', `select public.offer_setup($1) as r`, [LEAD])
    expect(caller).toMatchObject({ can_set_price: false, can_edit_standards: false, signature_png: null })
    expect(await asUser('thalia@example.com', `select public.offer_standards_set('{"earnest_money":"1"}'::jsonb) as r`)).toMatchObject({ ok: false })
    expect(await asUser('colin.merrill1+muse@gmail.com', `select public.offer_standards_set('{"earnest_money":"1"}'::jsonb) as r`)).toMatchObject({ ok: false })
    expect(await asUser('colin@example.com', `select public.offer_standards_set('{"earnest_days":"3","signature_png":"nope"}'::jsonb) as r`)).toMatchObject({ ok: false })
    expect(await asUser('colin@example.com', `select public.offer_standards_set('{"earnest_days":"3"}'::jsonb) as r`)).toEqual({ ok: true })
    expect((await one<{ earnest_days: number; earnest_money: string }>(`select earnest_days, earnest_money from public.offer_standards`))).toMatchObject({ earnest_days: 3, earnest_money: '500.00' })
    await db.exec(`update public.offer_standards set earnest_days = 5 where id = 1`)
    // nobody reads the table directly: it holds the signature
    await expect(asUser('thalia@example.com', `select to_jsonb(s) as r from public.offer_standards s`)).rejects.toThrow(/permission denied/)
  })
})

describe('the offer from the card', () => {
  it('reads the municipality the way line 6 wants it', () => {
    expect(muniOf('VILLAGE OF PADDOCK LAKE')).toEqual({ type: 'Village', name: 'Paddock Lake' })
    expect(muniOf('Pewaukee (Village)')).toEqual({ type: 'Village', name: 'Pewaukee' })
    expect(muniOf('Town of Delafield')).toEqual({ type: 'Town', name: 'Delafield' })
    expect(muniOf('West Allis')).toEqual({ type: 'City', name: 'West Allis' })
  })

  it('builds the terms from three answers and holds the closing date to 2 weeks - 90 days', async () => {
    const ctx = await ctxFor('colin@example.com')
    const q = quickTerms({ standards: ctx.standards!, lead: ctx.lead! }, ASK, T0)
    expect(q.problems).toEqual([])
    expect(q.raw).toMatchObject({ buyerName: 'WeLiveWI LLC', buyerSigner: 'Colin Merrill', street: '2847 N Burleigh St', muniType: 'Village', muniName: 'Shorewood',
      county: 'Milwaukee', closing: 'December 12, 2026', bindingDeadline: 'November 17, 2026 at 11:59 p.m.', earnestMoney: 500, earnestHolder: 'Knight Barry Title',
      inspection: false, recrWithOffer: true, sellerEmail: 'dale@example.com', draftDate: 'November 12, 2026' })
    expect(q.expires.toISOString()).toBe('2026-11-18T05:59:59.000Z')      // 11:59:59 p.m. CST on the 17th
    expect(centralEndOfDay('2026-07-04').toISOString()).toBe('2026-07-05T04:59:59.000Z')   // CDT
    for (const [day, ok] of [['2026-11-25', false], ['2026-11-26', true], ['2027-02-10', true], ['2027-02-11', false], ['', false]] as const) {
      expect(quickTerms({ standards: ctx.standards!, lead: ctx.lead! }, { ...ASK, closingOn: day }, T0).problems.length === 0).toBe(ok)
    }
  })

  it('lets Colin send at any price, a caller only at his number, and Muse never', async () => {
    const colin = await ctxFor('colin@example.com')
    expect(quickGate(colin, ASK, true)).toEqual({ price: 142000, problems: [] })
    const thalia = await ctxFor('thalia@example.com')
    expect(quickGate(thalia, ASK, true).problems).toEqual(['Colin has not put his number on this card yet. Ask him for it, then send.'])
    await colinTypes(139500)
    const thalia2 = await ctxFor('thalia@example.com')
    expect(thalia2.colin_number).toBe(139500)
    expect(quickGate(thalia2, ASK, true).problems).toEqual(["The offer goes out at Colin's number: $139,500."])
    expect(quickGate(thalia2, { ...ASK, price: undefined }, true)).toEqual({ price: 139500, problems: [] })
    // the number on the package beats the one on the deal
    await db.exec(`insert into public.deal_packages (lead_id, status, our_number) values ('${LEAD}', 'number_ready', 141000)`)
    expect((await ctxFor('thalia@example.com')).colin_number).toBe(141000)
    const muse = await ctxFor('colin.merrill1+muse@gmail.com')
    expect(quickGate(muse, ASK, true).problems[0]).toMatch(/An agent does not send contracts/)
    expect(quickGate(await ctxFor('nobody@example.com'), ASK, true).problems).toEqual(['You are not on the team.'])
    // no email, a bad email, a Do Not Contact card
    expect(quickGate(colin, { ...ASK, sellers: [{ name: 'Dale Novak' }] }, true).problems).toEqual(["Add the seller's email: the offer is emailed to them."])
    expect(quickGate(colin, { ...ASK, sellers: [{ name: 'Dale Novak', email: 'dale@' }] }, true).problems).toHaveLength(1)
    await db.exec(`update public.leads set stage = 'dnc' where id = '${LEAD}'`)
    expect(quickGate(await ctxFor('colin@example.com'), ASK, true).problems).toEqual(['This card is Do Not Contact. No offer goes out.'])
  })

  it('sends: signed and dated by the buyer, the link emailed, good until the deadline, logged on the card', async () => {
    const pv = await quickPreview(ports(), await ctxFor('colin@example.com'), ASK)
    expect(pv.ok).toBe(true)
    if (pv.ok) keep('1-preview.pdf', pv.pdf)

    const r = await quickSend(ports(), await ctxFor('colin@example.com'), ASK, BY)
    if (!r.ok) throw new Error(r.reason)
    expect(r.links).toHaveLength(1)
    expect(r.links[0]).toMatchObject({ name: 'Dale Novak', emailed_to: 'dale@example.com' })
    keep('2-offer-as-sent.pdf', files.get(`${r.id}/offer.pdf`)!)
    expect(files.has(`${r.id}/buyer.png`)).toBe(false)       // no drawn signature kept: Colin's typed name signs

    expect(mails).toHaveLength(1)
    const m = mails[0]
    expect(m).toMatchObject({ to: 'dale@example.com', subject: 'Offer to purchase 2847 N Burleigh St: review and sign', fromName: 'WeLiveWI', replyTo: 'colin@example.com' })
    expect(m.text).toContain(r.links[0].url)
    expect(m.text).toMatch(/\$142,000, closing on December 12, 2026/)
    expect(m.text).toMatch(/good until November 17, 2026 at 11:59 p\.m\./)
    expect(m.html).toContain(`href="${r.links[0].url}"`)
    expect(m.attachments).toBeUndefined()
    keep('3-link-email.html', m.html)
    keep('3-link-email.eml', buildMessage({ from: 'sender@example.com', ...m }, T0))

    const c = await one<{ status: string; terms: Record<string, unknown>; buyer_name: string; buyer_signed_at: string }>(`select status, terms, buyer_name, buyer_signed_at from public.contracts`)
    expect(c).toMatchObject({ status: 'sent', buyer_name: 'WeLiveWI LLC' })
    expect(c.terms).toMatchObject({ quick: true, price: 142000, closingOn: '2026-12-12', acceptBy: '2026-11-17', recrWithOffer: true })
    const sg = await one<{ expires_at: string; emailed_to: string; emailed_at: string | null }>(`select expires_at, emailed_to, emailed_at from public.contract_signers`)
    expect(new Date(sg.expires_at).toISOString()).toBe('2026-11-18T05:59:59.000Z')
    expect(sg).toMatchObject({ emailed_to: 'dale@example.com' })
    expect(sg.emailed_at).not.toBeNull()
    const notes = (await db.query<{ body: string }>(`select body from public.messages where status = 'contract' order by sent_at, id`)).rows.map((x) => x.body)
    expect([...notes].sort()).toEqual(['Offer (WB-11 10-1-2026) sent for signature by Colin.', 'Offer emailed to dale@example.com for signature (the signing link is not kept here).'])
    expect(notes.join(' ')).not.toContain(tokenOf(r.links[0].url))     // the link itself is never stored
    expect((await db.query(`select 1 from public.contract_events where kind = 'emailed'`)).rows).toHaveLength(1)

    // one live offer per card
    const again = await quickSend(ports(), await ctxFor('colin@example.com'), ASK, BY)
    expect(again).toMatchObject({ ok: false, reason: expect.stringMatching(/already out for signature/) })

    // the deadline passes: the link stops working
    clock = new Date('2026-11-18T06:00:00Z')
    expect(await openForSigner(ports(), tokenOf(r.links[0].url))).toMatchObject({ ok: false, reason: expect.stringMatching(/expired/) })
    // a fresh link, emailed again
    const fresh = await newLink(ports(), (await one<{ id: string }>(`select id from public.contract_signers`)).id, 'Colin', true)
    expect(fresh).toMatchObject({ ok: true, emailed_to: 'dale@example.com' })
    expect(mails).toHaveLength(2)
  })

  it('uses the signature Colin drew once, on every offer after', async () => {
    const PNG = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=='
    expect(await asUser('colin@example.com', `select public.offer_standards_set($1::jsonb) as r`, [JSON.stringify({ signature_png: PNG })])).toEqual({ ok: true })
    const r = await quickSend(ports(), await ctxFor('colin@example.com'), ASK, BY)
    if (!r.ok) throw new Error(r.reason)
    expect(files.has(`${r.id}/buyer.png`)).toBe(true)
  })

  it('says so when the email does not go, and still gives the link to send by hand', async () => {
    mailDown = true
    const r = await quickSend(ports(), await ctxFor('colin@example.com'), ASK, BY)
    if (!r.ok) throw new Error(r.reason)
    expect(r.links[0].emailed_to).toBeUndefined()
    expect(r.links[0].email_error).toBe('smtp down')
    expect(r.links[0].url).toMatch(/\/sign\//)
    expect((await one<{ body: string }>(`select body from public.messages where body like 'The offer email%'`)).body).toMatch(/did not go: smtp down/)
  })

  it('a caller sends at Colin\'s number; the seller signs; everyone is emailed the signed PDF', async () => {
    await colinTypes(139500)
    const two = { closingOn: '2026-12-12', sellers: [{ name: 'Dale Novak', email: 'dale@example.com' }, { name: 'Rita Novak', email: 'rita@example.com' }] }
    const r = await quickSend(ports(), await ctxFor('thalia@example.com'), two, { actor: 'Thalia' })
    if (!r.ok) throw new Error(r.reason)
    expect((await one<{ price: number }>(`select (terms->>'price')::numeric::float8 as price from public.contracts`)).price).toBe(139500)
    expect(mails.map((m) => m.to)).toEqual(['dale@example.com', 'rita@example.com'])
    const [dale, rita] = r.links.map((l) => tokenOf(l.url))

    clock = new Date('2026-11-13T15:00:00Z')
    const v = await openForSigner(ports(), dale, '1.2.3.4', 'Dale phone')
    if (!v.ok) throw new Error(v.reason)
    expect(v.view.offer_download_url).toMatch(/download=Offer%20to%20purchase\.pdf/)
    expect(v.view.terms).toMatchObject({ buyerSigner: 'Colin Merrill', buyerPhone: '(262) 999-6513' })
    const s1 = await signAsSeller(ports(), { token: dale, consent: true, name: 'Dale R. Novak', recr: fullRecr(), ip: '1.2.3.4', ua: 'Dale phone' })
    expect(s1).toMatchObject({ ok: true, allSigned: false, copies: [] })
    mails.length = 0

    clock = new Date('2026-11-14T16:30:00Z')
    const s2 = await signAsSeller(ports(), { token: rita, consent: true, name: 'Rita Novak', ip: '5.6.7.8', ua: 'Rita laptop' })
    expect(s2).toMatchObject({ ok: true, allSigned: true, sealed: true, copies: ['dale@example.com', 'rita@example.com', 'colin@example.com'] })
    if (s2.ok) expect(s2.finalDownloadUrl).toMatch(/download=Signed%20offer\.pdf/)

    expect(mails.map((m) => m.to)).toEqual(['dale@example.com', 'rita@example.com', 'colin@example.com'])
    const signed = mails[0]
    expect(signed.subject).toBe('Signed offer: 2847 N Burleigh St')
    expect(signed.attachments).toHaveLength(1)
    expect(signed.attachments![0]).toMatchObject({ filename: 'Signed offer - 2847 N Burleigh St.pdf', contentType: 'application/pdf' })
    const final = files.get((await one<{ final_path: string }>(`select final_path from public.contracts`)).final_path)!
    expect(signed.attachments![0].bytes).toEqual(final)
    expect((await PDFLib.PDFDocument.load(final)).getPageCount()).toBeGreaterThanOrEqual(14)   // the Offer, the report, the certificate
    keep('4-signed.pdf', final)
    keep('5-signed-email.html', signed.html)

    // the attachment survives the wire format
    const eml = buildMessage({ from: 'sender@example.com', ...signed }, clock)
    keep('5-signed-email.eml', eml)
    expect(eml).toMatch(/^From: "WeLiveWI" <sender@example\.com>\r\n/)
    expect(eml).toContain('Reply-To: <colin@example.com>')
    expect(eml).toMatch(/Content-Type: multipart\/mixed; boundary="/)
    expect(eml).toContain('Content-Disposition: attachment; filename="Signed offer - 2847 N Burleigh St.pdf"')
    const b64 = eml.split('Content-Disposition: attachment; filename="Signed offer - 2847 N Burleigh St.pdf"\r\n\r\n')[1].split('\r\n--')[0].replace(/\r\n/g, '')
    expect(new Uint8Array(Buffer.from(b64, 'base64'))).toEqual(final)
    expect(eml.split('\r\n').every((l) => l.length <= 998)).toBe(true)

    expect(await one(`select status, signed_at is not null as signed from public.contracts`)).toMatchObject({ status: 'signed', signed: true })
    expect((await db.query(`select 1 from public.contract_events where kind = 'emailed' and detail->>'what' = 'signed'`)).rows).toHaveLength(3)
    expect(pushes).toHaveLength(1)
    const notes = (await db.query<{ body: string }>(`select body from public.messages where body like 'Signed offer emailed%'`)).rows
    expect(notes).toHaveLength(3)
  })
})

describe('the mail format', () => {
  it('keeps the old plain message exactly as it was', () => {
    const eml = buildMessage({ from: 'a@example.com', to: 'b@example.com', subject: 'Hi', text: 'x', html: '<p>x</p>' }, new Date('2026-11-12T00:00:00Z'), 'B')
    expect(eml).toMatch(/^From: WPIE <a@example\.com>\r\nTo: <b@example\.com>\r\nSubject: /)
    expect(eml).toContain('Content-Type: multipart/alternative; boundary="B"')
    expect(eml).not.toContain('multipart/mixed')
  })
})
