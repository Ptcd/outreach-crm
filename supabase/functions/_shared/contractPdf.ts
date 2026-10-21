/* eslint-disable @typescript-eslint/no-explicit-any */
// Contract PDFs, built here and nowhere else: the official WB-11 filled in from Colin's terms,
// the seller's Real Estate Condition Report (Wis. Stat. 709.03) drawn from the statute text,
// and the electronic-signature certificate. pdf-lib is passed in (npm:pdf-lib on the server,
// node_modules in tests) so this file has no imports a Deno deploy has to resolve.
import { PAGE_HEIGHT, WB11_BOXES, WB11_MAP, WB11_SIGN, WB11_STRIKES, type Blank } from './wb11Map.ts'
import { RECR } from './recrForm.generated.ts'
import type { RecrAnswers } from './recr.ts'

export type PdfLib = { PDFDocument: any; StandardFonts: any; rgb: (r: number, g: number, b: number) => any }

export type Wb11Terms = {
  draftDate: string
  buyerName: string
  street: string
  street2?: string
  muniType: 'City' | 'Village' | 'Town'
  muniName: string
  county: string
  price: number
  included?: string
  excluded?: string
  bindingDeadline: string
  closing: string
  earnestMoney: number
  earnestDays?: number
  earnestHolder: string
  inspection: boolean
  inspectionComponents?: string
  inspectionDays?: number
  proofOfFundsDays?: number
  leaseTerms?: string
  additional?: string
  sellerAddress?: string
  buyerAddress?: string
  sellerEmail?: string
  buyerEmail?: string
  draftedBy?: string
}

export type SignatureMark = { name: string; date: string; png?: Uint8Array | null }
export type PropertyMeta = { street: string; muniType: string; muniName: string; county: string }

const INK = [0.05, 0.1, 0.45] as const
// Characters outside WinAnsi make the standard fonts throw; keep the common typographic ones.
const WIN_ANSI_EXTRA = new Set('€‚ƒ„…†‡ˆ‰Š‹ŒŽ‘’“”•–—˜™š›œžŸ')
export function safeText(s: string): string {
  return Array.from((s ?? '').replace(/\r/g, '').replace(/\t/g, ' ')).map((c) => {
    const code = c.codePointAt(0) ?? 63
    return c === '\n' || (code >= 32 && code <= 126) || (code >= 160 && code <= 255) || WIN_ANSI_EXTRA.has(c) ? c : '?'
  }).join('')
}

const ONES = ['', 'One', 'Two', 'Three', 'Four', 'Five', 'Six', 'Seven', 'Eight', 'Nine', 'Ten', 'Eleven', 'Twelve', 'Thirteen',
  'Fourteen', 'Fifteen', 'Sixteen', 'Seventeen', 'Eighteen', 'Nineteen']
const TENS = ['', '', 'Twenty', 'Thirty', 'Forty', 'Fifty', 'Sixty', 'Seventy', 'Eighty', 'Ninety']
function under1000(n: number): string {
  const h = Math.floor(n / 100)
  const r = n % 100
  const t = r < 20 ? ONES[r] : `${TENS[Math.floor(r / 10)]}${r % 10 ? '-' + ONES[r % 10] : ''}`
  return [h ? `${ONES[h]} Hundred` : '', t].filter(Boolean).join(' ')
}
/** 182500.5 -> "One Hundred Eighty-Two Thousand Five Hundred and 50/100" */
export function dollarsInWords(amount: number): string {
  if (!Number.isFinite(amount) || amount < 0 || amount >= 1e9) throw new Error('price out of range')
  const cents = Math.round(amount * 100) % 100
  let n = Math.floor(Math.round(amount * 100) / 100)
  if (n === 0) return `Zero and ${String(cents).padStart(2, '0')}/100`
  const parts: string[] = []
  for (const [size, label] of [[1e6, 'Million'], [1e3, 'Thousand'], [1, '']] as [number, string][]) {
    const chunk = Math.floor(n / size)
    if (chunk) parts.push(`${under1000(chunk)}${label ? ' ' + label : ''}`)
    n %= size
  }
  return `${parts.join(' ')} and ${String(cents).padStart(2, '0')}/100`
}
export const money = (n: number) => n.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })

/** Greedy word wrap into a list of widths; returns the lines and whatever did not fit. */
export function wrapInto(text: string, widths: number[], measure: (s: string) => number): { lines: string[]; rest: string } {
  const lines: string[] = []
  const paras = safeText(text).split('\n')
  let pi = 0
  let words = (paras[0] ?? '').split(/\s+/).filter(Boolean)
  for (let li = 0; li < widths.length; li++) {
    if (!words.length) {
      if (pi + 1 >= paras.length) break
      pi += 1
      words = paras[pi].split(/\s+/).filter(Boolean)
      if (!words.length) { lines.push(''); continue }
    }
    let line = ''
    while (words.length) {
      const next = line ? `${line} ${words[0]}` : words[0]
      if (measure(next) <= widths[li]) { line = next; words.shift() } else break
    }
    if (!line && words.length) {             // one word longer than the line: hard-break it
      let w = words[0]
      while (w.length > 1 && measure(w) > widths[li]) w = w.slice(0, -1)
      line = w
      words[0] = words[0].slice(w.length)
    }
    lines.push(line)
  }
  const rest = [words.join(' '), ...paras.slice(pi + 1)].filter((s) => s.trim()).join('\n')
  return { lines, rest }
}

async function fonts(doc: any, lib: PdfLib) {
  return {
    reg: await doc.embedFont(lib.StandardFonts.Helvetica),
    bold: await doc.embedFont(lib.StandardFonts.HelveticaBold),
    sig: await doc.embedFont(lib.StandardFonts.TimesRomanBoldItalic),
  }
}

function put(lib: PdfLib, page: any, font: any, text: string, blank: Blank, size = 10) {
  const s = safeText(text)
  if (!s) return
  let fs = size
  const room = blank.x1 - blank.x0 - 4
  while (fs > 6 && font.widthOfTextAtSize(s, fs) > room) fs -= 0.5
  page.drawText(s, { x: blank.x0 + 2, y: PAGE_HEIGHT - blank.base, size: fs, font, color: lib.rgb(...INK) })
}

function putLines(lib: PdfLib, pages: any[], font: any, text: string | undefined, blanks: readonly Blank[], size = 10): string {
  if (!text?.trim()) return ''
  const { lines, rest } = wrapInto(text, blanks.map((x) => x.x1 - x.x0 - 4), (s) => font.widthOfTextAtSize(s, size))
  lines.forEach((l, i) => put(lib, pages[blanks[i].p], font, l, blanks[i], size))
  return rest
}

async function drawSignature(lib: PdfLib, doc: any, page: any, f: { sig: any; reg: any }, s: SignatureMark,
  box: { x0: number; x1: number; line: number; dateX0: number; dateX1: number; nameX: number; nameBase: number }) {
  if (s.png?.length) {
    const img = await doc.embedPng(s.png)
    const h = 22
    const w = Math.min(box.x1 - box.x0 - 8, (img.width / img.height) * h)
    page.drawImage(img, { x: box.x0 + 4, y: PAGE_HEIGHT - box.line + 1.5, width: w, height: h })
  } else {
    page.drawText(safeText(s.name), { x: box.x0 + 4, y: PAGE_HEIGHT - box.line + 4, size: 16, font: f.sig, color: lib.rgb(...INK) })
  }
  put(lib, page, f.reg, s.date, { p: 0, x0: box.dateX0, x1: box.dateX1, base: box.line - 1.6 })
  put(lib, page, f.reg, s.name, { p: 0, x0: box.nameX, x1: 470, base: box.nameBase })
}

function watermark(lib: PdfLib, pages: any[], font: any, text: string) {
  for (const page of pages) {
    page.drawText(safeText(text), { x: 90, y: 300, size: 46, font, color: lib.rgb(0.85, 0.2, 0.2), opacity: 0.18,
      rotate: { type: 'degrees', angle: 35 } })
  }
}

/** Fill the official WB-11. Signatures are stamped when given; a preview gets a watermark. */
export async function fillWb11(lib: PdfLib, template: Uint8Array, t: Wb11Terms,
  opts: { buyer?: SignatureMark | null; sellers?: SignatureMark[]; watermark?: string } = {}): Promise<{ bytes: Uint8Array; addendum: boolean }> {
  const doc = await lib.PDFDocument.load(template)
  const pages = doc.getPages()
  const f = await fonts(doc, lib)
  const M = WB11_MAP
  const P = (x: Blank) => pages[x.p]
  const markBox = (bx: { p: number; x0: number; x1: number; bottom: number }) =>
    pages[bx.p].drawText('X', { x: (bx.x0 + bx.x1) / 2 - 3.5, y: PAGE_HEIGHT - bx.bottom + 2, size: 11, font: f.bold, color: lib.rgb(...INK) })

  put(lib, P(M.draftDate), f.reg, t.draftDate, M.draftDate)
  put(lib, P(M.buyerName), f.reg, t.buyerName, M.buyerName)
  putLines(lib, pages, f.reg, [t.street, t.street2].filter(Boolean).join('\n'), M.street)
  put(lib, P(M.muniType), f.reg, t.muniType, M.muniType)
  put(lib, P(M.muniName), f.reg, t.muniName, M.muniName)
  put(lib, P(M.county), f.reg, t.county, M.county)
  putLines(lib, pages, f.reg, dollarsInWords(t.price), M.priceWords)
  put(lib, P(M.priceDigits), f.reg, money(t.price), M.priceDigits)
  putLines(lib, pages, f.reg, t.included || 'None', M.included)
  putLines(lib, pages, f.reg, t.excluded || 'None', M.excluded)
  put(lib, P(M.bindingDeadline), f.reg, t.bindingDeadline, M.bindingDeadline)
  putLines(lib, pages, f.reg, t.closing, M.closing)
  for (const h of M.header) put(lib, P(h), f.reg, [t.street, t.muniName].filter(Boolean).join(', '), h, 9)
  put(lib, P(M.earnestAmount), f.reg, money(t.earnestMoney), M.earnestAmount)
  put(lib, P(M.earnestDays), f.reg, String(t.earnestDays ?? 5), M.earnestDays)
  putLines(lib, pages, f.reg, t.earnestHolder, M.earnestHolder)
  put(lib, P(M.recrDate), f.reg, 'N/A', M.recrDate)
  if (t.inspection) {
    markBox(WB11_BOXES.inspection)
    putLines(lib, pages, f.reg, t.inspectionComponents || 'N/A', M.inspectionComponents)
    put(lib, P(M.inspectionDays), f.reg, String(t.inspectionDays ?? 15), M.inspectionDays)
  }
  put(lib, P(M.proofOfFundsDays), f.reg, String(t.proofOfFundsDays ?? 7), M.proofOfFundsDays)
  putLines(lib, pages, f.reg, t.leaseTerms, M.leaseTerms)

  // Additional provisions: what does not fit on lines 570-590 goes to Addendum A.
  let addendum = false
  let rest = ''
  if (t.additional?.trim()) {
    const widths = M.additional.map((x) => x.x1 - x.x0 - 4)
    const first = wrapInto(t.additional, widths, (s) => f.reg.widthOfTextAtSize(s, 10))
    if (first.rest) {
      const shortWidths = [...widths.slice(0, -1), widths[widths.length - 1] - 200]
      const r = wrapInto(t.additional, shortWidths, (s) => f.reg.widthOfTextAtSize(s, 10))
      r.lines.forEach((l, i) => put(lib, pages[M.additional[i].p], f.reg, l, M.additional[i]))
      const last = M.additional[M.additional.length - 1]
      put(lib, pages[last.p], f.reg, '(continued in Addendum A)', { ...last, x0: last.x1 - 196 })
      rest = r.rest
      addendum = true
    } else {
      first.lines.forEach((l, i) => put(lib, pages[M.additional[i].p], f.reg, l, M.additional[i]))
    }
  }
  if (addendum) {
    markBox(WB11_BOXES.addenda)
    putLines(lib, pages, f.reg, 'Addendum A (additional provisions, attached)', M.addenda)
  }

  put(lib, pages[M.sellerAddress.p], f.reg, t.sellerAddress ?? '', M.sellerAddress)
  put(lib, pages[M.buyerAddress.p], f.reg, t.buyerAddress ?? '', M.buyerAddress)
  put(lib, pages[M.sellerEmail.p], f.reg, t.sellerEmail ?? '', M.sellerEmail)
  put(lib, pages[M.buyerEmail.p], f.reg, t.buyerEmail ?? '', M.buyerEmail)
  if (t.sellerEmail || t.buyerEmail) markBox(WB11_BOXES.emailDelivery)
  put(lib, pages[M.draftedBy.p], f.reg, t.draftedBy ?? 'N/A - drafted by Buyer, who is not a licensee', M.draftedBy)
  for (const s of WB11_STRIKES) {
    pages[s.p].drawLine({ start: { x: s.x0, y: PAGE_HEIGHT - s.y }, end: { x: s.x1, y: PAGE_HEIGHT - s.y }, thickness: 1, color: lib.rgb(...INK) })
  }

  if (addendum) {
    const pg = doc.addPage([612, 792])
    let y = 740
    pg.drawText('ADDENDUM A TO WB-11 RESIDENTIAL OFFER TO PURCHASE', { x: 50, y, size: 12, font: f.bold })
    y -= 16
    pg.drawText(safeText(`Property: ${[t.street, t.muniName].filter(Boolean).join(', ')}. Additional provisions continued from lines 570-590.`),
      { x: 50, y, size: 9, font: f.reg })
    y -= 22
    const { lines } = wrapInto(rest, Array(60).fill(510), (s) => f.reg.widthOfTextAtSize(s, 10))
    for (const l of lines) { pg.drawText(l, { x: 50, y, size: 10, font: f.reg, color: lib.rgb(...INK) }); y -= 13 }
    y -= 12
    pg.drawText('This Addendum is part of the Offer and is signed when the Offer is signed.', { x: 50, y, size: 9, font: f.reg })
  }

  const sign = pages[WB11_SIGN.buyer.p]
  if (opts.buyer) await drawSignature(lib, doc, sign, f, opts.buyer, WB11_SIGN.buyer)
  const sellers = opts.sellers ?? []
  if (sellers[0]) await drawSignature(lib, doc, sign, f, sellers[0], WB11_SIGN.seller1)
  if (sellers[1]) await drawSignature(lib, doc, sign, f, sellers[1], WB11_SIGN.seller2)
  if (opts.watermark) watermark(lib, doc.getPages(), f.bold, opts.watermark)
  return { bytes: await doc.save(), addendum }
}

/** A plain text-flow writer for the generated pages (condition report, certificate). */
function flow(lib: PdfLib, doc: any, f: { reg: any; bold: any }, footer: string) {
  let page = doc.addPage([612, 792])
  let y = 750
  const left = 50
  const width = 512
  const pagesMade = [page]
  const ensure = (h: number) => {
    if (y - h < 60) { page = doc.addPage([612, 792]); pagesMade.push(page); y = 750 }
  }
  const text = (s: string, o: { size?: number; bold?: boolean; indent?: number; right?: number; gray?: boolean; gap?: number } = {}) => {
    const size = o.size ?? 9
    const font = o.bold ? f.bold : f.reg
    const indent = o.indent ?? 0
    const { lines } = wrapInto(s, Array(400).fill(width - indent - (o.right ?? 0)), (t) => font.widthOfTextAtSize(t, size))
    for (const l of lines) {
      ensure(size + 3)
      page.drawText(l, { x: left + indent, y, size, font, color: o.gray ? lib.rgb(0.35, 0.35, 0.35) : lib.rgb(0, 0, 0) })
      y -= size + 3
    }
    y -= o.gap ?? 4
  }
  const row = (cells: { x: number; s: string; bold?: boolean; ink?: boolean }[], size = 9) => {
    ensure(size + 3)
    for (const c of cells) page.drawText(safeText(c.s), { x: left + c.x, y, size, font: c.bold ? f.bold : f.reg, color: c.ink ? lib.rgb(...INK) : lib.rgb(0, 0, 0) })
    y -= size + 4
  }
  const finish = () => {
    pagesMade.forEach((p: any, i: number) => p.drawText(safeText(`${footer}  Page ${i + 1} of ${pagesMade.length}`),
      { x: left, y: 30, size: 7, font: f.reg, color: lib.rgb(0.4, 0.4, 0.4) }))
  }
  return { text, row, ensure, finish, get y() { return y }, set y(v: number) { y = v }, get page() { return page } }
}

/** The seller's Real Estate Condition Report, in the statutory form, with their answers. */
export async function renderRecr(lib: PdfLib, meta: PropertyMeta & { asOf: string; buyerReceived?: string },
  a: RecrAnswers, opts: { sellers?: SignatureMark[]; watermark?: string } = {}): Promise<Uint8Array> {
  const doc = await lib.PDFDocument.create()
  const f = await fonts(doc, lib)
  const w = flow(lib, doc, f, `Real Estate Condition Report (Wis. Stat. s. 709.03) - ${meta.street}`)
  w.text('REAL ESTATE CONDITION REPORT', { size: 13, bold: true, gap: 6 })
  const muni = meta.muniType.toUpperCase()
  const disclaimer = RECR.preamble
    .replace(/^DISCLAIMER\s*/, '')
    .replace('LOCATED AT .... IN THE .... (CITY) (VILLAGE) (TOWN) OF ...., COUNTY OF ....,',
      `LOCATED AT ${meta.street.toUpperCase()} IN THE ${muni} OF ${meta.muniName.toUpperCase()}, COUNTY OF ${meta.county.toUpperCase()},`)
    .replace('AS OF .... (MONTH) .... (DAY), .... (YEAR).', `AS OF ${meta.asOf.toUpperCase()}.`)
  const [disc, ...restPre] = disclaimer.split(/(?=A buyer who does not receive)|(?=NOTICE TO PARTIES)/)
  w.text('DISCLAIMER', { bold: true, gap: 2 })
  w.text(disc.trim())
  for (const p of restPre) {
    if (p.startsWith('NOTICE TO PARTIES')) { w.text('NOTICE TO PARTIES REGARDING ADVICE OR INSPECTIONS', { bold: true, gap: 2 }); w.text(p.replace('NOTICE TO PARTIES REGARDING ADVICE OR INSPECTIONS', '').trim()) } else w.text(p.trim())
  }
  const mark = (v: string | undefined, want: string) => (v === want ? '[X]' : '[  ]')
  for (const s of RECR.sections) {
    w.y -= 4
    w.text(`${s.id}.  ${s.title}`, { size: 10, bold: true, gap: 3 })
    if (s.intro) w.text(s.intro)
    for (const it of s.items) {
      if (it.kind === 'note') {
        const [main, caution] = it.text.split(/(?=CAUTION:)/)
        w.text(`${it.id}.  ${main.trim()}`)
        if (caution) w.text(caution.trim(), { bold: true })
        continue
      }
      if (it.kind === 'ynna') {
        const v = a.answers?.[it.id]
        w.ensure(30)
        w.row([{ x: 0, s: `${it.id}.`, bold: true },
          { x: 360, s: `${mark(v, 'yes')} Yes   ${mark(v, 'no')} No   ${mark(v, 'na')} N/A`, bold: true, ink: true }])
        w.y += 13
        w.text(it.text, { indent: 28, right: 165, gap: 1 })
        if (it.hint) w.text(it.hint, { indent: 28, right: 165, size: 7.5, gray: true, gap: 3 })
        continue
      }
      if (it.kind === 'explain') {
        w.text(`${it.id}.  Explanation of "yes" responses:`, { bold: true, gap: 1 })
        w.text(a.explain?.[it.id]?.trim() || 'None.', { indent: 28 })
        continue
      }
      if (it.kind === 'years') {
        w.text(`${it.id}.  ${it.text.replace('___', a.years?.[it.id]?.trim() || '___')}`)
      }
    }
  }
  w.y -= 6
  w.text("OWNER'S CERTIFICATION", { size: 10, bold: true, gap: 2 })
  w.text(RECR.certification)
  for (const s of opts.sellers ?? []) {
    w.ensure(34)
    if (s.png?.length) {
      const img = await doc.embedPng(s.png)
      const h = 22
      w.page.drawImage(img, { x: 100, y: w.y - 6, width: Math.min(220, (img.width / img.height) * h), height: h })
    } else {
      w.page.drawText(safeText(s.name), { x: 100, y: w.y, size: 15, font: f.sig, color: lib.rgb(...INK) })
    }
    w.y -= 10
    w.row([{ x: 0, s: 'Owner' }, { x: 50, s: s.name, ink: true }, { x: 330, s: 'Date' }, { x: 360, s: s.date, ink: true }])
  }
  w.text('CERTIFICATION BY PERSON SUPPLYING INFORMATION: none.', { bold: true })
  w.text("BUYER'S ACKNOWLEDGEMENT", { size: 10, bold: true, gap: 2 })
  w.text(RECR.buyerAck)
  w.text(meta.buyerReceived ? `Delivered to the buyer electronically: ${meta.buyerReceived}. See the signature certificate.` : 'Not yet delivered to the buyer.', { gray: true })
  w.finish()
  if (opts.watermark) watermark(lib, doc.getPages(), f.bold, opts.watermark)
  return doc.save()
}

export type AuditRow = { at: string; who: string; what: string; ip?: string | null; device?: string | null }

/** The electronic signature certificate that ends the sealed PDF. */
export async function renderCertificate(lib: PdfLib, c: { id: string; title: string; offerSha256: string; recrSha256?: string | null;
  version: string; rows: AuditRow[] }): Promise<Uint8Array> {
  const doc = await lib.PDFDocument.create()
  const f = await fonts(doc, lib)
  const w = flow(lib, doc, f, `Signature certificate - contract ${c.id}`)
  w.text('ELECTRONIC SIGNATURE CERTIFICATE', { size: 13, bold: true, gap: 6 })
  w.text(c.title, { bold: true })
  w.text(`Contract id: ${c.id}`)
  w.text(`Form: ${c.version}. SHA-256 of the Offer as sent for signature: ${c.offerSha256}`)
  if (c.recrSha256) w.text(`SHA-256 of the Real Estate Condition Report as completed by the seller: ${c.recrSha256}`)
  w.text('Each signer agreed to use electronic records and signatures (Wis. Stat. ch. 137; 15 U.S.C. 7001) before signing, '
    + 'adopted the signature shown, and was given a copy of the signed documents. The events below were recorded by the system '
    + 'at the time they happened (Central Time).', { gap: 8 })
  w.row([{ x: 0, s: 'When', bold: true }, { x: 120, s: 'Who', bold: true }, { x: 250, s: 'What', bold: true }, { x: 400, s: 'IP / device', bold: true }])
  for (const r of c.rows) {
    w.ensure(24)
    const y0 = w.y
    w.row([{ x: 0, s: r.at }, { x: 120, s: r.who.slice(0, 26) }, { x: 400, s: (r.ip ?? '').slice(0, 30) }], 8)
    w.y = y0
    w.text(r.what, { indent: 250, size: 8, gap: 0 })
    if (r.device) w.text(r.device.slice(0, 160), { indent: 250, size: 6.5, gray: true, gap: 3 })
  }
  w.finish()
  return doc.save()
}

/** Join PDFs in order. */
export async function mergePdfs(lib: PdfLib, parts: Uint8Array[]): Promise<Uint8Array> {
  const out = await lib.PDFDocument.create()
  for (const part of parts) {
    const src = await lib.PDFDocument.load(part)
    const copied = await out.copyPages(src, src.getPageIndices())
    copied.forEach((p: any) => out.addPage(p))
  }
  return out.save()
}

export async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const d = await crypto.subtle.digest('SHA-256', bytes)
  return Array.from(new Uint8Array(d)).map((x) => x.toString(16).padStart(2, '0')).join('')
}

export function b64ToBytes(b64: string): Uint8Array {
  const bin = atob(b64)
  const out = new Uint8Array(bin.length)
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i)
  return out
}
export function bytesToB64(bytes: Uint8Array): string {
  let s = ''
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000))
  return btoa(s)
}

/** "data:image/png;base64,..." from a signature pad -> bytes (PNG only, size-capped). */
export function pngFromDataUrl(u: string | null | undefined): Uint8Array | null {
  const m = /^data:image\/png;base64,([A-Za-z0-9+/=]+)$/.exec(u ?? '')
  if (!m || m[1].length > 400_000) return null
  const bytes = b64ToBytes(m[1])
  return bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47 ? bytes : null
}
