// Which number to dial first (found walking the app as Thalia, 2026-10-27: a card showed 11 numbers, 10 of them a
// relative's from the skip trace, with nothing saying whose was whose). The owner's own numbers come first (mobile,
// then landline), then other people's, each labelled; blocked numbers last.
import type { Contact } from './types'

const words = (s: string | null | undefined) => (s ?? '').toUpperCase().replace(/[^A-Z0-9 ]/g, ' ').split(/\s+/).filter((w) => w.length > 1)

/** A phone's name is the owner's when its first and last word appear in the owner name (or it has no name). */
export function isOwnersPhone(c: Pick<Contact, 'person_name'>, ownerName: string | null | undefined): boolean {
  const p = words(c.person_name)
  if (!p.length) return true
  const o = new Set(words(ownerName))
  return o.has(p[0]) && o.has(p[p.length - 1])
}

export const phoneBlocked = (c: Contact) => !!(c.suppressed || c.dnc_app || c.dnc_vendor || c.dnc_scrub === 'dnc' || c.status === 'bad')

export function orderPhones(contacts: Contact[], ownerName: string | null | undefined): (Contact & { owners: boolean })[] {
  const rank = (c: Contact & { owners: boolean }) =>
    (phoneBlocked(c) ? 10 : 0) + (c.owners ? 0 : 4) + (c.line_type === 'mobile' ? 0 : c.line_type === 'landline' ? 2 : 1)
  return contacts.filter((c) => c.kind === 'phone').map((c) => ({ ...c, owners: isOwnersPhone(c, ownerName) }))
    .sort((a, b) => rank(a) - rank(b))
}
