// Where each blank on the official WB-11 (10-1-2026) sits, in PDF points measured from the TOP of the
// page (p = 0-based page, x0..x1 = the underline, base = text baseline). Measured from the drawn
// underlines in scripts/forms/wb11-2026.pdf (pymupdf); a new form version needs a new map.
export type Blank = { p: number; x0: number; x1: number; base: number }

const b = (p: number, x0: number, x1: number, underlineY: number): Blank => ({ p, x0, x1, base: underlineY - 1.6 })
const u = (p: number, x0: number, x1: number, wordBottom: number): Blank => ({ p, x0, x1, base: wordBottom - 3.6 })
const rows = (p: number, x0: number, x1: number, ys: number[]) => ys.map((y) => b(p, x0, x1, y))

export const WB11_MAP = {
  draftDate: u(0, 230, 423, 94.2),                                   // line 1
  buyerName: b(0, 90, 571.6, 115.6),                                 // line 3
  street: [b(0, 297, 576, 127.1), b(0, 38, 576, 138.6)],             // lines 4-5
  muniType: b(0, 65, 216, 150.1),                                    // line 6 "in the ___"
  muniName: b(0, 232, 532.8, 150.1),                                 // line 6 "of ___"
  county: b(0, 49, 276.4, 161.6),                                    // line 7
  priceWords: [b(0, 232, 576, 186.7), b(0, 38, 345.6, 200.2)],       // lines 9-10
  priceDigits: b(0, 396, 568.8, 200.2),                              // line 10
  included: [b(0, 462, 576, 227.2), ...rows(0, 38, 576, [238.6, 250.1, 261.6, 273.1])], // 12-16
  excluded: [b(0, 173, 576, 323.0), ...rows(0, 38, 576, [334.6, 346.1, 357.6])],        // 20-23
  bindingDeadline: b(0, 123, 545.5, 557.0),                          // line 40
  closing: [b(0, 244, 576, 649.7), b(0, 38, 439.2, 663.1)],          // lines 47-48
  // "Property Address: ____" in the header of pages 2-11
  header: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10].map((p) => u(p, 96, 502.7, 23.3)),
  earnestAmount: b(1, 158, 367.2, 82.9),                             // line 58
  earnestDays: b(1, 170, 208.8, 94.3),                               // line 59
  earnestHolder: [b(1, 476, 576, 105.8), b(1, 38, 403.2, 117.8)],    // lines 60-61 "other identified as"
  recrDate: b(1, 233, 345.6, 660.4),                                 // line 107
  inspectionComponents: [b(3, 129, 576, 269.9), b(3, 56, 417.6, 281.4)], // lines 197-198
  inspectionDays: u(3, 318, 361, 378.5),                             // line 206
  proofOfFundsDays: b(5, 399, 453.6, 46.4),                          // line 296
  leaseTerms: [b(7, 256, 576, 163.8), ...rows(7, 38, 576, [175.8, 187.3]), b(7, 38, 165.6, 198.8)], // 429-432
  additional: [b(9, 257, 576, 413.9), ...rows(9, 38, 576, [427.3, 438.8, 450.4, 461.9, 473.3, 484.8, 496.3,
    507.8, 519.4, 530.9, 542.3, 553.8, 565.3, 576.8, 588.4, 599.9, 611.3, 622.8, 634.3, 645.8])], // 570-590
  addenda: [b(9, 185, 576, 660.4), ...rows(9, 38, 576, [671.8, 683.3, 694.8, 706.3, 717.8, 729.4]), b(9, 38, 439, 740.8)], // 591-598
  sellerAddress: b(10, 126, 576, 209.4),                             // line 613
  buyerAddress: b(10, 126, 576, 220.8),                              // line 614
  sellerEmail: b(10, 154, 576, 243.8),                               // line 616
  buyerEmail: b(10, 154, 576, 255.4),                                // line 617
  draftedBy: b(10, 247, 576, 299.9),                                 // line 620
} as const

/** Open boxes: marked with an X to make that provision part of the Offer (lines 460-461). */
export const WB11_BOXES = {
  inspection: { p: 3, x0: 36.7, x1: 59.6, top: 213.5, bottom: 224.9 },   // line 193
  addenda: { p: 9, x0: 36.7, x1: 59.6, top: 650.0, bottom: 661.4 },         // line 591 "ADDENDA"
  emailDelivery: { p: 10, x0: 36.7, x1: 59.6, top: 222.0, bottom: 233.4 },  // line 615 "(5) Email"
} as const

/** Words struck through as not applicable (no licensee drafts; earnest money held by the title company). */
export const WB11_STRIKES = [
  { p: 0, x0: 477.8, x1: 575.9, y: 88.6 },   // (AGENT OF BUYER)
  { p: 0, x0: 36.0, x1: 205.9, y: 100.6 },   // (AGENT OF SELLER/LISTING FIRM)
  { p: 0, x0: 208.7, x1: 371.5, y: 100.6 },  // (AGENT OF BUYER AND SELLER)
  { p: 1, x0: 264.9, x1: 320.0, y: 102.6 },  // (listing Firm)
  { p: 1, x0: 322.8, x1: 385.6, y: 102.6 },  // (drafting Firm)
] as const

/** Signature lines on page 11: the (x) line, its date, and "Print Name Here ►". */
export const WB11_SIGN = {
  buyer: { p: 10, line: 492.1, x0: 50, x1: 475, dateX0: 480, dateX1: 576, nameX: 126, nameBase: 513.7 },     // 632-634
  seller1: { p: 10, line: 628.4, x0: 50, x1: 475, dateX0: 480, dateX1: 576, nameX: 126, nameBase: 649.9 },   // 641-643
  seller2: { p: 10, line: 674.4, x0: 50, x1: 475, dateX0: 480, dateX1: 576, nameX: 126, nameBase: 696.0 },   // 644-646
} as const

export const PAGE_HEIGHT = 792
