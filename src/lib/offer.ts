// The sellers an offer starts with: the card's owner name, split on "&" / "AND" (two people at most sign a WB-11).
export type SellerRow = { name: string; email: string; phone: string }

const titleCase = (s: string) => s.toLowerCase().replace(/\b([a-z])/g, (m) => m.toUpperCase()).replace(/\bLlc\b/g, 'LLC')

export function sellersFrom(owner: string): SellerRow[] {
  const parts = owner.split(/\s+(?:&|AND)\s+/i).map((p) => p.trim()).filter(Boolean).slice(0, 2)
  return (parts.length ? parts : [owner]).map((n) => ({ name: titleCase(n), email: '', phone: '' }))
}
