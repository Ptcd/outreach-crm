// The top of a card (Colin 2026-11-22): a name to say, why in a line, the number to dial first.
import { describe, expect, it } from 'vitest'
import { displayOwner, noteEntries, rankPhones, whyLine } from '@/lib/cardTop'
import type { Contact, Message } from '@/lib/types'

const phone = (value: string, x: Partial<Contact> = {}) => ({ id: value, lead_id: 'L', kind: 'phone', value, value_normalized: value, line_type: 'mobile',
  status: 'ok', dnc_app: false, suppressed: false, dnc_vendor: false, dnc_scrub: 'clear', person_name: 'Russel Thompson', source: 'fps', ...x }) as unknown as Contact
const msg = (x: Partial<Message>) => ({ id: Math.random().toString(), lead_id: 'L', direction: 'out', channel: 'sms', body: '', from_number: null, to_number: null,
  status: null, is_opener: false, is_opt_out: false, sent_at: '2026-11-20T15:00:00Z', seen_at: null, ...x }) as Message

describe('the top of a card', () => {
  it('says the owner the way a person would', () => {
    expect(displayOwner('THOMPSON, RUSSEL J / HUTH, RACHAEL L')).toBe('Russel J Thompson and Rachael L Huth')
    expect(displayOwner('BLAISDELL KAREN')).toBe('Blaisdell Karen')          // no comma: the order is not guessed
    expect(displayOwner("O'BRIEN, MARY-ANN")).toBe("Mary-Ann O'Brien")
    expect(displayOwner('MAIN STREET HOLDINGS LLC')).toBe('Main Street Holdings LLC')
    expect(displayOwner(null)).toBe('')
  })

  it('says why in a line: each kind once, the heaviest first', () => {
    expect(whyLine(['behind on taxes', 'Behind on taxes', 'Foreclosure - Fond du Lac County case 2026CV000496', 'Probate / estate - case 2026PR000012']))
      .toEqual(['Foreclosure', 'Estate', 'Behind on taxes'])
    expect(whyLine(['Tax warrant 2026TW000012', 'something the list said'])).toEqual(['State tax warrant', 'something the list said'])
    expect(whyLine(null)).toEqual([])
  })

  it('ranks the phones by what happened on them', () => {
    const cs = [phone('4145550001', { line_type: 'landline' }), phone('4145550002'), phone('4145550003'), phone('4145550004'),
      phone('4145550005', { person_name: 'Somebody Else' }), phone('4145550006', { suppressed: true })]
    const ms = [
      msg({ to_number: '+14145550002', status: 'undelivered' }),                               // our text bounced: dead
      msg({ channel: 'call', direction: 'in', from_number: '+14145550003', status: 'no_answer' }),
      msg({ to_number: '+14145550003', status: 'delivered' }),
      msg({ channel: 'call', direction: 'in', from_number: '+14145550004', status: 'reached' }),
    ]
    const r = rankPhones(cs, 'THOMPSON, RUSSEL J', ms, [])
    expect(r.map((p) => p.value)).toEqual(['4145550004', '4145550003', '4145550001', '4145550005', '4145550002', '4145550006'])
    expect(r[0].note).toBe('They picked up on this number')
    expect(r[1].note).toBe('No answer once, text delivered')
    expect(r[4].note).toBe('Our text did not go through')
    expect(r[5].note).toMatch(/Blocked/)
    // a number they texted us from beats everything
    expect(rankPhones(cs, 'THOMPSON, RUSSEL J', ms, [{ from10: '4145550001' }])[0].value).toBe('4145550001')
  })

  it('splits the notes into entries with a first line', () => {
    const e = noteEntries('STEP 6 PACK - imported\nCase: 2026PR000012\nParcel: 039 | Seller said the roof leaks')
    expect(e).toEqual([{ head: 'STEP 6 PACK - imported', rest: 'Case: 2026PR000012\nParcel: 039' }, { head: 'Seller said the roof leaks', rest: '' }])
  })
})

describe('the page as Tyler saw it, 2026-11-22', () => {
  it('a number on the card twice is listed once', async () => {
    const { rankPhones } = await import('@/lib/cardTop')
    const c = (id: string, value: string) => ({ id, lead_id: 'L', kind: 'phone', value, value_normalized: value, line_type: 'mobile', status: 'ok',
      dnc_app: false, suppressed: false, dnc_vendor: false, dnc_scrub: 'clear', person_name: 'Russel Thompson', source: 'fps' }) as never
    expect(rankPhones([c('a', '7155747260'), c('b', '7155747260'), c('c', '7155510753')], 'THOMPSON, RUSSEL J', [], []).map((p) => p.value))
      .toEqual(['7155747260', '7155510753'])
  })
  it('an agent task note is read as a person would write it', async () => {
    const { plainTaskNote } = await import('@/lib/cardTop')
    expect(plainTaskNote('Muse (Muse) 2026-11-18: Schmid book #1 (Tyler). Ask for Russel J Thompson. Estate / owner died: Probate / estate - Fond du Lac County case 2026PR000012; Foreclosure: Foreclosure - Fond du Lac County case 2026CV000496; Back taxes: 2 years delinquent, $8,478. Dial (715) 574-7260. call list (#1) A logged call closes this task.'))
      .toBe('Schmid book #1 (Tyler). Ask for Russel J Thompson.')
    expect(plainTaskNote('Call back after 5, she is at work')).toBe('Call back after 5, she is at work')
    expect(plainTaskNote(null)).toBe('')
  })
})

describe('who to ask for', () => {
  it('never the person the card says has died; the living co-owner instead', async () => {
    const { whoToAskFor } = await import('@/lib/cardTop')
    const people = [{ name: 'Russel J Thompson', kind: 'person', role: 'owner_of_record', status: 'deceased' },
      { name: 'THOMPSON, RUSSEL J / HUTH, RACHAEL L', kind: 'person', role: 'owner_of_record', status: 'active' },
      { name: 'Rachael L. Huth', kind: 'person', role: 'co_owner', status: 'active' }]
    expect(whoToAskFor(people, 'THOMPSON, RUSSEL J / HUTH, RACHAEL L')).toEqual({ living: ['Rachael L. Huth'], died: ['Russel J Thompson'], askFor: 'Rachael' })
    // nobody marked: the county's name, as said
    expect(whoToAskFor([], 'THOMPSON, RUSSEL J / HUTH, RACHAEL L').living).toEqual(['Russel J Thompson', 'Rachael L Huth'])
    // everyone on the card has died: nobody to ask for by name
    expect(whoToAskFor([{ name: 'JANE ROE', status: 'deceased' }], 'JANE ROE')).toEqual({ living: [], died: ['Jane Roe'], askFor: '' })
    // a personal representative comes first
    expect(whoToAskFor([{ name: 'JANE ROE', status: 'deceased' }, { name: 'Sam Roe', role: 'personal_representative', status: 'active' }], 'JANE ROE').askFor).toBe('Sam')
  })
})
