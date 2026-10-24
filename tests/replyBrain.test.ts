// The reply agent's classifier and routing (supabase/functions/_shared/replyBrain.ts) against WPIE.
import { describe, expect, it } from 'vitest'
import data from '../supabase/functions/_shared/replyRedteam.generated.json'
import { classify, decide, isCarrierKeyword, isSpanish, scoreRedteam, type RedteamRow } from '../supabase/functions/_shared/replyBrain'

describe('parity with wpie/reply/rules.py', () => {
  const rows = data.parity as { text: string; classify: string; is_spanish: boolean; is_carrier_keyword: boolean }[]
  it('classify agrees on every red-team text', () => {
    const bad = rows.filter((r) => classify(r.text) !== r.classify).map((r) => `${r.classify} vs ${classify(r.text)}: ${r.text}`)
    expect(bad).toEqual([])
  })
  it('is_spanish and carrier keywords agree', () => {
    expect(rows.filter((r) => isSpanish(r.text) !== r.is_spanish).map((r) => r.text)).toEqual([])
    expect(rows.filter((r) => isCarrierKeyword(r.text) !== r.is_carrier_keyword).map((r) => r.text)).toEqual([])
  })
})

describe('red team', () => {
  it('passes every row with no missed removal', () => {
    const r = scoreRedteam(data.rows as unknown as RedteamRow[])
    console.log(`red team: ${r.passed}/${r.total}; answered automatically ${r.handled_automatically}, to Colin ${r.to_colin}; Python ${data.python_passed}/${r.total}`)
    expect(r.failures).toEqual([])
    expect(r.missed_removals).toBe(0)
    expect(r.ok).toBe(true)
  })
})

describe('routing', () => {
  const base = { priorInbound: [], lastAgentText: null, propertyAddress: '2847 N Burleigh St' }
  it('says nothing to a bare STOP (Twilio confirms) but suppresses', () => {
    expect(decide({ ...base, inbound: 'STOP' })).toMatchObject({ kind: 'removal', removal: true, reply: null })
  })
  it('confirms a plain-language removal once', () => {
    expect(decide({ ...base, inbound: 'please take me off your list' })).toMatchObject({ removal: true, outcome: 'dnc' })
  })
  it('sends interest, prices and anything uncertain to Colin', () => {
    for (const t of ['Maybe, what would you pay?', 'yes interested', 'my mom passed and the house is empty', '150k']) {
      expect(decide({ ...base, inbound: t }).kind).toBe('candidate')
    }
  })
  it('asks the exit question once, then closes', () => {
    expect(decide({ ...base, inbound: 'not interested' })).toMatchObject({ kind: 'routine', outcome: 'open' })
    const exit = decide({ ...base, inbound: 'not interested' }).reply
    expect(decide({ ...base, inbound: 'no thanks not interested', priorInbound: ['not interested'], lastAgentText: exit }))
      .toMatchObject({ kind: 'routine', outcome: 'not_interested' })
  })
  it('names the street in the who-is-this line', () => {
    expect(decide({ ...base, inbound: 'who is this?' }).reply).toMatch(/on N Burleigh St/)
  })
})

describe('Colin 2026-10-24: "needs you" fills with replies that should be dead', () => {
  const opener = 'Hi, Colin Merrill here. Do you still own 1825 Kelly St? No worries if not, just reply STOP.'
  const ctx = { inbound: '', priorInbound: [] as string[], lastAgentText: opener, propertyAddress: '1825 Kelly St', ownerName: 'PAT', ourTurns: 0 }
  it('a plain "No, I don\'t" to "do you still own it?" closes as a no, by itself', () => {
    for (const t of ["No, I don't", 'No', 'nope', 'Not anymore', 'I don\'t']) {
      expect(decide({ ...ctx, inbound: t })).toMatchObject({ kind: 'routine', outcome: 'not_interested' })
    }
  })
  it('still asks the exit question on a plain no, and leaves anything longer to Colin', () => {
    expect(decide({ ...ctx, inbound: 'No thanks', lastAgentText: 'Thanks for getting back to me. Would you ever consider selling?' }))
      .toMatchObject({ kind: 'routine', outcome: 'open' })
    expect(decide({ ...ctx, inbound: 'No I sold it last year to my nephew' }).outcome).not.toBe('dnc')
  })
})
