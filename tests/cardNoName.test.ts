// 0294 (Colin 2026-11-22, 226 60th Ave, Somers): the roll's "NOT AVAILABLE" was the card's heading, the opener said
// "Hi, is this Not?", and the next-step line carried a story stamp and ten phone numbers.
import { describe, expect, it } from 'vitest'
import { displayOwner, plainTaskNote, whoToAskFor } from '@/lib/cardTop'

describe('a roll with no owner name, and a task note a person can read', () => {
  it('a placeholder is not a name: the people on the card are', () => {
    expect(displayOwner('NOT AVAILABLE')).toBe('')
    expect(displayOwner('Unknown Owner')).toBe('')
    expect(displayOwner('AVAILABLE, NOT A')).toBe('Not A Available')          // only the whole placeholder, never a real surname
    const who = whoToAskFor([{ name: 'CHERANA RUTH SALAMIN', role: 'other', status: 'active' }, { name: 'NOT AVAILABLE', role: 'owner_of_record', status: 'active' }], 'NOT AVAILABLE')
    expect(who.living).toEqual(['Cherana Ruth Salamin'])
    expect(who.askFor).toBe('Cherana')
  })

  it('the task note loses the story stamp and the list of numbers', () => {
    const note = 'STORY: Has to be paid at closing: $0 (mortgage, amount not known, tax $0). The full story and the script are on the card: read them before you dial.\n'
      + 'Say: You asked for a call about 226 60th Ave. Call (414) 369-0305 (mobile), (262) 676-1606 (mobile), (262) 553-9567 (landline)'
    expect(plainTaskNote(note)).toBe('You asked for a call about 226 60th Ave.')
    expect(plainTaskNote('Call them back after 5')).toBe('Call them back after 5')   // an ordinary note is left alone
  })
})
