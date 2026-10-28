// Reading the voicemails (migration 0118): the rule words decide a clear stop or the wrong person; Claude reads the
// rest; the verdict goes to voicemail_set_verdict; without a key the unclear ones wait.
import { describe, expect, it, vi } from 'vitest'
import { readVoicemail, runVoicemailRead, voicemailRule } from '../supabase/functions/_shared/voicemailRead'

const claude = (verdict: string, reason = 'because') => vi.fn(async () => new Response(JSON.stringify({
  stop_reason: 'end_turn', content: [{ type: 'text', text: JSON.stringify({ verdict, reason }) }] }), { status: 200 }))

describe('voicemails', () => {
  it('the rule words: a stop, the wrong person, or nothing', () => {
    expect(voicemailRule('Please erase my number out of your system. Stop calling me.')).toBe('stop')
    expect(voicemailRule("There is no Nora at this number, you have the wrong number")).toBe('wrong_person')
    expect(voicemailRule("Hi, I got your letter about my place on Main, I want to move out of state, call me back")).toBeNull()
  })

  it('Claude reads the rest, and the verdict is stored', async () => {
    const calls: [string, Record<string, unknown>][] = []
    const rpc = vi.fn(async (fn: string, args: Record<string, unknown>) => {
      calls.push([fn, args])
      if (fn === 'voicemail_to_read') return { data: [
        { call_sid: 'CA1', words: 'Stop calling me', owner_name: 'X', property_address: '1 A St' },
        { call_sid: 'CA2', words: 'Who the hell are you people, this is the fifth time', owner_name: 'Y', property_address: '2 B St' },
      ], error: null }
      return { data: { ok: true }, error: null }
    })
    const fetchFn = claude('upset', 'angry about being contacted')
    const s = await runVoicemailRead(rpc as never, { apiKey: 'k', fetchFn: fetchFn as never })
    expect(fetchFn).toHaveBeenCalledTimes(1)   // the stop needed no Claude
    expect(calls.filter(([f]) => f === 'voicemail_set_verdict').map(([, a]) => [a.p_call_sid, a.p_verdict]))
      .toEqual([['CA1', 'stop'], ['CA2', 'upset']])
    expect(s).toMatchObject({ read: 2, by_rule: 1, by_claude: 1, verdicts: { stop: 1, upset: 1 } })
  })

  it('without a key, only the rule words decide; the others wait', async () => {
    const rpc = vi.fn(async (fn: string) => fn === 'voicemail_to_read'
      ? { data: [{ call_sid: 'CA3', words: 'call me back about the house', owner_name: null, property_address: null }], error: null }
      : { data: { ok: true }, error: null })
    const s = await runVoicemailRead(rpc as never, { apiKey: '', fetchFn: vi.fn() as never })
    expect(s.read).toBe(0)
    expect(rpc).toHaveBeenCalledTimes(1)
  })

  it('a bad answer from Claude is a failure, never a made-up verdict', async () => {
    const bad = vi.fn(async () => new Response(JSON.stringify({ content: [{ type: 'text', text: '{"verdict":"maybe"}' }] }), { status: 200 }))
    await expect(readVoicemail({ words: 'hello' }, { apiKey: 'k', fetchFn: bad as never })).rejects.toThrow()
  })
})
