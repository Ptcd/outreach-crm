// The contract PDFs: the official WB-11 filled from Colin's terms, the condition report, the
// certificate, and the sealed merge. Set CONTRACT_PDF_OUT=<dir> to write the samples for a look.
import { mkdirSync, writeFileSync } from 'node:fs'
import path from 'node:path'
import * as PDFLib from 'pdf-lib'
import { describe, expect, it } from 'vitest'
import {
  b64ToBytes, dollarsInWords, fillWb11, mergePdfs, pngFromDataUrl, renderCertificate, renderRecr, safeText, sha256Hex, wrapInto,
  type PdfLib, type Wb11Terms,
} from '../supabase/functions/_shared/contractPdf'
import { WB11_B64 } from '../supabase/functions/_shared/wb11Template.generated'
import { RECR_QUESTIONS, recrProblems, type RecrAnswers } from '../supabase/functions/_shared/recr'

const lib = PDFLib as unknown as PdfLib
const OUT = process.env.CONTRACT_PDF_OUT
const save = (name: string, bytes: Uint8Array) => {
  if (!OUT) return
  mkdirSync(OUT, { recursive: true })
  writeFileSync(path.join(OUT, name), bytes)
}

export const TERMS: Wb11Terms = {
  draftDate: 'October 21, 2026',
  buyerName: 'Colin Merrill',
  street: '2847 N Burleigh St',
  muniType: 'City',
  muniName: 'Milwaukee',
  county: 'Milwaukee',
  price: 182500,
  included: 'Range, refrigerator, washer and dryer as they sit.',
  excluded: '',
  bindingDeadline: 'October 24, 2026 at 5:00 p.m.',
  closing: 'November 20, 2026',
  earnestMoney: 1000,
  earnestDays: 3,
  earnestHolder: 'Knight Barry Title, Milwaukee',
  inspection: true,
  inspectionComponents: 'roof and foundation',
  inspectionDays: 10,
  proofOfFundsDays: 5,
  additional: 'Property is sold AS IS. '.repeat(3),
  sellerAddress: '2847 N Burleigh St, Milwaukee WI 53210',
  buyerAddress: 'PO Box 1, Mequon WI 53092',
  sellerEmail: 'dale@example.com',
  buyerEmail: 'colin@example.com',
}

export function fullRecr(yes: string[] = []): RecrAnswers {
  const answers = Object.fromEntries(RECR_QUESTIONS.map((q) => [q.id, yes.includes(q.id) ? 'yes' : 'no'])) as RecrAnswers['answers']
  return { answers, explain: yes.length ? { B12: 'Roof leaks over the back porch.' } : {}, years: { G6: '22', G7: '0' } }
}

describe('contract pdfs', () => {
  it('writes the price in words the way the form expects', () => {
    expect(dollarsInWords(182500)).toBe('One Hundred Eighty-Two Thousand Five Hundred and 00/100')
    expect(dollarsInWords(1000.5)).toBe('One Thousand and 50/100')
    expect(dollarsInWords(2_013_019)).toBe('Two Million Thirteen Thousand Nineteen and 00/100')
  })

  it('keeps text the standard fonts can draw', () => {
    expect(safeText('Dale’s “house” — ok ✓ 🏠')).toBe('Dale’s “house” — ok ? ?')
  })

  it('wraps into the blanks and returns what does not fit', () => {
    const r = wrapInto('one two three four five', [20, 20], (s) => s.length * 2)
    expect(r.lines).toEqual(['one two', 'three four'])
    expect(r.rest).toBe('five')
  })

  it('fills the official 11-page WB-11 with signatures, and moves long terms to Addendum A', async () => {
    const short = await fillWb11(lib, b64ToBytes(WB11_B64), TERMS, {
      buyer: { name: 'Colin Merrill', date: '10/21/2026' },
      sellers: [{ name: 'Dale Novak', date: '10/22/2026' }],
    })
    const d = await lib.PDFDocument.load(short.bytes)
    expect(d.getPageCount()).toBe(11)
    expect(short.addendum).toBe(false)
    save('wb11-signed.pdf', short.bytes)

    const long = await fillWb11(lib, b64ToBytes(WB11_B64), { ...TERMS, additional: 'Buyer may assign this Offer. '.repeat(120) },
      { watermark: 'PREVIEW - NOT FOR SIGNATURE' })
    expect(long.addendum).toBe(true)
    expect((await lib.PDFDocument.load(long.bytes)).getPageCount()).toBe(12)
    save('wb11-preview-addendum.pdf', long.bytes)
  })

  it('checks the condition report is complete before it can be signed', () => {
    expect(recrProblems(null)[0]).toMatch(/Answer every question/)
    expect(recrProblems(fullRecr())).toEqual([])
    const y = fullRecr(['B1'])
    expect(recrProblems({ ...y, explain: {} })).toEqual(['Explain each "yes" in section B (B1).'])
    expect(recrProblems({ ...fullRecr(), years: { G6: '22' } })).toHaveLength(1)
    expect(RECR_QUESTIONS.length).toBe(62)
  })

  it('renders the condition report, the certificate, and seals them together', async () => {
    const recr = await renderRecr(lib, { street: TERMS.street, muniType: 'City', muniName: 'Milwaukee', county: 'Milwaukee',
      asOf: 'October 22, 2026', buyerReceived: 'October 22, 2026 3:14 PM CT' }, fullRecr(['B1']),
    { sellers: [{ name: 'Dale Novak', date: '10/22/2026' }] })
    save('recr.pdf', recr)
    const cert = await renderCertificate(lib, { id: 'c-1', title: 'WB-11 for 2847 N Burleigh St', offerSha256: 'ab'.repeat(32),
      recrSha256: 'cd'.repeat(32), version: 'WB-11 10-1-2026',
      rows: [{ at: '10/21/2026 2:00 PM', who: 'Colin Merrill', what: 'Signed the Offer as Buyer and sent it', ip: '1.2.3.4', device: 'iPhone' },
        { at: '10/22/2026 3:10 PM', who: 'Dale Novak', what: 'Opened the signing link', ip: '5.6.7.8', device: 'Android Chrome' }] })
    save('certificate.pdf', cert)
    const offer = (await fillWb11(lib, b64ToBytes(WB11_B64), TERMS)).bytes
    const sealed = await mergePdfs(lib, [offer, recr, cert])
    const n = (await lib.PDFDocument.load(sealed)).getPageCount()
    expect(n).toBeGreaterThan(14)
    save('sealed.pdf', sealed)
    expect(await sha256Hex(new Uint8Array([1, 2, 3]))).toBe('039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81')
  })

  it('accepts only real PNG signatures', () => {
    expect(pngFromDataUrl('data:image/png;base64,iVBORw0KGgo=')).not.toBeNull()
    expect(pngFromDataUrl('data:image/svg+xml;base64,PHN2Zz4=')).toBeNull()
    expect(pngFromDataUrl('data:image/png;base64,AAAA')).toBeNull()
  })
})
