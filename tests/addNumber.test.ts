// Colin 2026-11-22: "Tyler needs an easy way to add in phone numbers and names for contacts for cards". A seller on
// 515 Kase St texted "Name: Ellie / Tel: 1 (920) 728-1490" and the only place to add it was the fold at the bottom of
// the card. A number in a text of theirs is offered in one tap with the name the text gives, and a number a caller
// added sits right under the one the seller texted from.
import { describe, expect, it } from 'vitest'
import { phonesInText, rankPhones } from '@/lib/cardTop'
import type { Contact } from '@/lib/types'

describe('a number the seller gives goes on the card in one tap', () => {
  it('reads the number and the name out of their text, and skips numbers already on the card', () => {
    expect(phonesInText('Name: Ellie\nTel: 1 (920) 728-1490', ['6083336906'])).toEqual([{ phone10: '9207281490', name: 'Ellie' }])
    expect(phonesInText('call my son Mark at 920-555-0100 he handles it', [])).toEqual([{ phone10: '9205550100', name: 'Mark' }])
    expect(phonesInText("Ellie's number is 920.728.1490", [])).toEqual([{ phone10: '9207281490', name: 'Ellie' }])
    expect(phonesInText('try 9207281490', [])).toEqual([{ phone10: '9207281490', name: null }])
    expect(phonesInText('Tel: (920) 728-1490', ['(920) 728-1490'])).toEqual([])           // already on the card
    expect(phonesInText('it is 3 bed 2 bath, built 1972, about 1,751 sq ft', [])).toEqual([])
    expect(phonesInText('I want $500,000 for it', [])).toEqual([])
    expect(phonesInText(null, [])).toEqual([])
  })

  it('a number a caller added ranks right under the one they texted from, and says where it came from', () => {
    const c = (id: string, value: string, over: Partial<Contact> = {}) => ({ id, lead_id: 'L', kind: 'phone', value, value_normalized: value, person_name: 'KATIE R CLARK',
      line_type: 'mobile', dnc_vendor: false, dnc_scrub: 'unknown', suppressed: false, dnc_app: false, source: 'skip trace', status: 'ok', note: null, ...over }) as unknown as Contact
    const ranked = rankPhones([c('a', '6085550111'), c('b', '6083336906'), c('e', '9207281490', { person_name: 'Ellie', source: 'added by Tyler', line_type: null })],
      'KATIE R CLARK', [], [{ from10: '6083336906' }])
    expect(ranked.map((r) => r.id)).toEqual(['b', 'e', 'a'])
    expect(ranked[1].note).toBe('A number they gave us, not tried yet')
  })
})
