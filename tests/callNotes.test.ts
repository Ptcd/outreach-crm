// Call notes (migration 0073, supabase/functions/_shared/callNotes.ts): a recorded seller call becomes notes on the card.
// The pure steps (transcript lines, the model's answer checked, the card entry, the Claude request), the whole pipeline
// against fakes of Twilio and Claude, and on the real migrations (PGlite): the recording finds its card, the notes land
// as a call entry and in call_facts (never over an answer tapped during the call), agent_card carries the notes but
// never the words, and the caller's one tap logs the call like "Save the call".
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { PGlite } from '@electric-sql/pglite'
import { beforeAll, beforeEach, describe, expect, it } from 'vitest'
import { SUPABASE_STUB } from './supabaseStub'
import { CALL_SCRIPT } from '../src/lib/callScript'
import { loggedSince, markText } from '../src/components/CallNotes'
import {
  FACT_KEYS, NOTES_SCHEMA, cleanNotes, noonCentral, noteBody, onRecording, onTranscriptWebhook, summarizeCall, sweep,
  transcriptText, type CallContext, type CallNotes, type Deps, type Intelligence, type Rpc,
} from '../supabase/functions/_shared/callNotes'

const NOW = new Date('2026-10-27T15:00:00Z')   // Tue 10:00 AM Central (CDT)

describe('call notes: the pure steps', () => {
  it('knows every call script answer by its key and choice ids', () => {
    for (const q of CALL_SCRIPT) {
      if (!FACT_KEYS[q.id]) continue
      expect(FACT_KEYS[q.id].choices).toEqual((q.choices ?? []).map((c) => c.id))
      expect(!!FACT_KEYS[q.id].multi).toBe(!!q.multi)
      expect(!!FACT_KEYS[q.id].number).toBe(!!q.number)
    }
    const scripted = new Set(CALL_SCRIPT.map((q) => q.id))
    for (const k of Object.keys(FACT_KEYS)) expect(scripted.has(k)).toBe(true)
    expect([...NOTES_SCHEMA.properties.facts.items.properties.key.enum].sort()).toEqual(Object.keys(FACT_KEYS).sort())
    // the model's list form reads the same as the keyed form
    const listed = cleanNotes({ summary: 'x', facts: [{ key: 'motivation', choices: ['inherited'], text: '', number: '' }, { key: 'bogus', choices: ['x'] }] }, NOW)
    expect(listed.facts).toEqual({ motivation: { choices: ['inherited'] } })
  })

  it('labels the two sides by the call direction and joins a speaker\'s sentences', () => {
    const s = [
      { media_channel: 1, sentence_index: 0, transcript: 'Hi, this is Thalia.' },
      { media_channel: 2, sentence_index: 1, transcript: 'Hello.' },
      { media_channel: 2, sentence_index: 2, transcript: 'Who is this?' },
      { media_channel: 1, sentence_index: 3, transcript: '  ' },
    ]
    expect(transcriptText(s, 'out')).toBe('Us: Hi, this is Thalia.\nSeller: Hello. Who is this?')
    expect(transcriptText(s, 'in')).toBe('Seller: Hi, this is Thalia.\nUs: Hello. Who is this?')
  })

  it('a not-now day is noon Central, in daylight time and after it ends; a day already gone is none', () => {
    expect(noonCentral('2026-10-30', NOW)).toBe('2026-10-30T17:00:00.000Z')
    expect(noonCentral('2027-01-05', NOW)).toBe('2027-01-05T18:00:00.000Z')
    expect(noonCentral('2026-10-27', NOW)).toBe('2026-10-27T17:00:00.000Z')
    expect(noonCentral('2026-10-20', NOW)).toBeNull()
    expect(noonCentral('January', NOW)).toBeNull()
  })

  it('checks the model\'s answer: one short quote, no quotes elsewhere, the script\'s ids only, sane dates', () => {
    const n = cleanNotes({
      talked: true, summary: 'Jane said "we just want it gone" and her brother co-owns.', quote: 'We just want it gone before winter.',
      pillars: { motivation: 'Inherited from mom', condition: 'Old roof, wet basement, empty', timeline: 'January', price: '"140k" to pay off the reverse mortgage', signers: 'Jane and her brother' },
      outcome: 'Wants a call with Colin', next_step: 'Colin calls Tue 4 PM', next_step_kind: 'callback', next_step_at: '2026-11-03T16:00:00-06:00',
      suggested_mark: 'hot', suggested_until: '2027-01-05', suggested_reason: '',
      facts: {
        motivation: { choices: ['inherited', 'moving'], text: 'mom passed', number: '' },
        condition: { choices: ['roof', 'water', 'made_up'], text: '', number: '' },
        price: { choices: [], text: 'payoff', number: '$140,000' },
        timeline: { choices: [], text: '', number: '' },
        work_list: { choices: ['none_said'], text: '', number: '' },
      },
    }, NOW)
    expect(n.summary).toBe('Jane said we just want it gone and her brother co-owns.')
    expect(n.quote).toBe('We just want it gone before winter.')
    expect(n.pillars.price).toBe('140k to pay off the reverse mortgage')
    expect(n.facts.motivation).toEqual({ choices: ['inherited'], text: 'mom passed' })    // one choice for a one-choice question
    expect(n.facts.condition).toEqual({ choices: ['roof', 'water'] })                      // multi, unknown id dropped
    expect(n.facts.price).toEqual({ text: 'payoff', number: '140000' })
    expect(n.facts.timeline).toBeUndefined()
    expect(n.facts.work_list).toBeUndefined()
    expect(n.next_step_at).toBe('2026-11-03T22:00:00.000Z')
    expect(n.suggested_until).toBeNull()                                                   // only a not-now or a hold carries a date

    const long = cleanNotes({ talked: false, summary: 'Voicemail.', quote: 'one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen',
      suggested_mark: 'bogus', next_step_kind: 'callback', next_step_at: '2020-01-01T00:00:00Z' }, NOW)
    expect(long.quote).toBeNull()
    expect(long.suggested_mark).toBe('no_answer')
    expect(long.next_step_at).toBeNull()
    expect(() => cleanNotes({ summary: '  ' }, NOW)).toThrow(/no summary/)
  })

  it('writes the card entry from the notes alone', () => {
    const n = cleanNotes({ talked: true, summary: 'Wants to sell after the holidays.', quote: '',
      pillars: { motivation: 'Inherited', condition: '', timeline: 'January', price: '', signers: '' },
      outcome: 'Not now', next_step: '', next_step_kind: 'none', next_step_at: '', suggested_mark: 'not_now',
      suggested_until: '2027-01-05', suggested_reason: '', facts: {} }, NOW)
    const body = noteBody(n, { direction: 'out', caller: 'Thalia', phone10: '2625550101', duration_s: 370 })
    expect(body).toBe([
      'Call notes: Thalia called (262) 555-0101, 6 min',
      'Wants to sell after the holidays.',
      'Why selling: Inherited',
      'Timeline: January',
      'Outcome: Not now',
      'Suggested: Not now until Tue, Jan 5. Confirm on the card.',
    ].join('\n'))
    expect(noteBody(n, { direction: 'in', caller: null, phone10: '2625550101', duration_s: 30 }).split('\n')[0])
      .toBe('Call notes: (262) 555-0101 called us, 1 min')
  })

  it('asks Claude for the notes as structured output, and gives up cleanly on a refusal', async () => {
    const ctx = { direction: 'out', caller: 'Thalia', duration_s: 120, owner_name: 'JANE', address: '1 A ST', city: 'Waukesha' } as CallContext
    let sent: Record<string, unknown> = {}
    const answer = { talked: true, summary: 'Talked.', quote: '', pillars: {}, suggested_mark: 'reached', facts: {} }
    const fetchFn = (async (_u: string, init: RequestInit) => {
      sent = JSON.parse(String(init.body))
      return new Response(JSON.stringify({ stop_reason: 'end_turn', model: 'claude-opus-5-5', content: [{ type: 'text', text: JSON.stringify(answer) }] }))
    }) as unknown as typeof fetch
    const r = await summarizeCall(ctx, 'Us: Hi\nSeller: Hello', { apiKey: 'k', fetchFn, now: NOW })
    expect(r.notes.summary).toBe('Talked.')
    expect(sent).toMatchObject({ model: 'claude-opus-5-5', fallbacks: 'default', output_config: { format: { type: 'json_schema' } } })
    const user = (sent.messages as { content: string }[])[0].content
    expect(user).toContain('Today is Tuesday, October 27, 2026')
    expect(user).toContain('<transcript>\nUs: Hi\nSeller: Hello\n</transcript>')
    const refuse = (async () => new Response(JSON.stringify({ stop_reason: 'refusal', content: [] }))) as unknown as typeof fetch
    await expect(summarizeCall(ctx, 'x', { apiKey: 'k', fetchFn: refuse, now: NOW })).rejects.toThrow(/declined/)
  })

  it('the card block: the mark in words, and nothing to confirm once the call was logged by hand', () => {
    expect(markText('not_now', '2027-01-05T18:00:00Z', null)).toBe('Not now until Tue, Jan 5')
    expect(markText('held', null, 'probate')).toBe('Held (probate)')
    const note = { started_at: '2026-10-27T15:00:00Z', created_at: '2026-10-27T15:08:00Z', logged_before: null }
    expect(loggedSince(note, [{ channel: 'call', status: 'call_notes', sent_at: '2026-10-27T15:00:00Z' }])).toBeNull()
    expect(loggedSince(note, [{ channel: 'call', status: 'interested', sent_at: '2026-10-27T14:00:00Z' }])).toBeNull()
    expect(loggedSince(note, [{ channel: 'call', status: 'not_now', sent_at: '2026-10-27T15:06:00Z' }])).toBe('not_now')
  })
})

// ---------------------------------------------------------------------------------------------- on the real migrations
const MIGRATIONS = readdirSync(path.resolve(__dirname, '../supabase/migrations')).filter((f) => f.endsWith('.sql')).sort()
  .map((f) => readFileSync(path.resolve(__dirname, '../supabase/migrations', f), 'utf8')).join('\n')
const LEAD = '00000000-0000-0000-0000-0000000000e1'
const PHONE = '2625550101'
const SID = (n: number) => `CA${String(n).padStart(32, '0')}`
const RE = (n: number) => `RE${String(n).padStart(32, '0')}`
const GT = (n: number) => `GT${String(n).padStart(32, '0')}`
const THALIA = { sub: '00000000-0000-0000-0000-0000000000a7', email: 'thalia@example.com' }
const WORDS = 'Us: Hi, is this Jane?\nSeller: Yes. My mom passed and the house is empty.'

let db: PGlite
const one = async <T = Record<string, unknown>>(sql: string, params: unknown[] = []) => (await db.query<T>(sql, params)).rows[0]
const all = async <T = Record<string, unknown>>(sql: string, params: unknown[] = []) => (await db.query<T>(sql, params)).rows
const rpc: Rpc = async (fn, args) => {
  const keys = Object.keys(args)
  try {
    const r = await one<{ r: unknown }>(`select public.${fn}(${keys.map((k, i) => `${k} => $${i + 1}`).join(', ')}) r`,
      keys.map((k) => (args[k] !== null && typeof args[k] === 'object' ? JSON.stringify(args[k]) : args[k])))
    return { data: r.r, error: null }
  } catch (e) { return { data: null, error: { message: e instanceof Error ? e.message : String(e) } } }
}
const asThalia = async <T = Record<string, unknown>>(sql: string, params: unknown[] = []): Promise<T> => {
  await db.query(`select set_config('request.jwt.claims', $1, false)`, [JSON.stringify(THALIA)])
  await db.exec('set role authenticated')
  try { return (await db.query<{ r: T }>(sql, params)).rows[0].r } finally { await db.exec('reset role'); await db.query(`select set_config('request.jwt.claims', '{}', false)`) }
}

function fakeTwilio(over: Partial<Intelligence> = {}) {
  const made: string[] = []; const deleted: string[] = []; const recordingsDeleted: string[] = []
  let n = 0
  const t: Intelligence = {
    async createTranscript(rec) { made.push(rec); return GT(++n) },
    async transcriptStatus() { return 'completed' },
    async sentences() {
      return [{ media_channel: 1, sentence_index: 0, transcript: 'Hi, is this Jane?' },
              { media_channel: 2, sentence_index: 1, transcript: 'Yes. My mom passed and the house is empty.' }]
    },
    async deleteTranscript(sid) { deleted.push(sid) },
    async deleteRecording(sid) { recordingsDeleted.push(sid) },
    async call() { return { from: 'client:thalia', to: '', direction: 'inbound', start_time: null } },
    ...over,
  }
  return { t, made, deleted, recordingsDeleted }
}
const NOTES: CallNotes = cleanNotes({
  talked: true, summary: 'Jane inherited it from her mom; it is empty. She and her brother would sell in January.', quote: 'We just want it gone.',
  pillars: { motivation: 'Inherited', condition: 'Empty, old roof', timeline: 'January', price: '140k, the reverse mortgage payoff', signers: 'Jane and her brother' },
  outcome: 'Would sell in January', next_step: 'Colin calls Tue at 4', next_step_kind: 'callback', next_step_at: new Date(Date.now() + 7 * 86400_000).toISOString(),
  suggested_mark: 'hot', suggested_until: '', suggested_reason: '',
  facts: { motivation: { choices: ['inherited'], text: 'mom passed', number: '' }, occupancy: { choices: ['empty'], text: '', number: '' },
           price: { choices: [], text: 'payoff', number: '140000' } },
}, new Date())

function deps(twilio: Intelligence, summarize?: Deps['summarize']): Deps {
  const find = (col: string) => async (v: string) =>
    (await one<{ call_sid: string; status: string; transcript_sid: string | null }>(`select call_sid, status, transcript_sid from public.call_recordings where ${col} = $1`, [v])) ?? null
  return { rpc, twilio, summarize: summarize ?? (async () => ({ notes: NOTES, model: 'test' })), findByCall: find('call_sid'),
           findByTranscript: find('transcript_sid'), log: () => undefined }
}

beforeAll(async () => {
  db = new PGlite()
  await db.exec(SUPABASE_STUB)
  await db.exec(MIGRATIONS)
  await db.exec(`insert into public.team_members (email, role, person, display_name) values ('thalia@example.com', 'caller', 'thalia', 'Thalia')
                 on conflict do nothing`)
})

beforeEach(async () => {
  await db.exec(`
    truncate public.call_recordings, public.call_notes, public.call_transcripts, public.human_call_provider_claims, public.inbound_calls,
      public.belt_events, public.hot_alerts, public.tasks, public.messages, public.contacts, public.leads cascade;
    insert into public.leads (id, wpie_owner_id, owner_name, property_address, municipality, mailing_state, lane, stage, call_facts)
      values ('${LEAD}', 971, 'JANE SAMPLE', '123 ELM ST', 'Waukesha', 'WI', 'flip', 'reply_received',
              '{"timeline": {"value": {"choices": ["asap"]}, "at": "2026-10-01T00:00:00Z", "by": "Thalia"}}');
    insert into public.contacts (lead_id, kind, value, value_normalized, line_type) values ('${LEAD}', 'phone', '${PHONE}', '${PHONE}', 'mobile');
    insert into public.human_call_provider_claims (attempt_key, lead_id, phone10, provider_call_sid) values ('key-0001', '${LEAD}', '${PHONE}', '${SID(1)}');
  `)
})

const recording = (n: number, duration = '240') => ({ CallSid: SID(n), RecordingSid: RE(n), RecordingStatus: 'completed', RecordingDuration: duration,
  RecordingStartTime: 'Tue, 27 Oct 2026 15:00:00 +0000' })

describe('call notes: the pipeline on the real migrations', () => {
  it('an app call: recorded against its card, transcribed, summarized onto the card, Twilio\'s copy of the words dropped', async () => {
    const tw = fakeTwilio()
    const d = deps(tw.t)
    expect(await onRecording(recording(1), 'out', d)).toMatchObject({ ok: true, lead_id: LEAD, transcribe: true, transcribing: true })
    expect(tw.made).toEqual([RE(1)])
    expect(await one(`select status, caller, phone10, transcript_sid from public.call_recordings where call_sid = $1`, [SID(1)]))
      .toEqual({ status: 'transcribing', caller: 'Thalia', phone10: PHONE, transcript_sid: GT(1) })
    // Twilio retries the callback: nothing new
    expect(await onRecording(recording(1), 'out', d)).toMatchObject({ duplicate: true, transcribe: false })
    expect(tw.made).toHaveLength(1)

    expect(await onTranscriptWebhook({ transcript_sid: GT(1), event_type: 'voice_intelligence_transcript_available' }, d))
      .toMatchObject({ ok: true, mark: 'hot' })
    expect(tw.deleted).toEqual([GT(1)])
    expect(await one(`select status from public.call_recordings where call_sid = $1`, [SID(1)])).toEqual({ status: 'summarized' })
    expect(await one(`select words from public.call_transcripts where call_sid = $1`, [SID(1)])).toEqual({ words: WORDS })

    const msg = await all(`select direction::text d, channel::text c, status, body, to_number from public.messages where lead_id = $1`, [LEAD])
    expect(msg).toHaveLength(1)
    expect(msg[0]).toMatchObject({ d: 'in', c: 'call', status: 'call_notes', to_number: `+1${PHONE}` })
    expect(msg[0].body).toContain('Call notes: Thalia called (262) 555-0101, 4 min')
    expect(msg[0].body).toContain('Their number: 140k, the reverse mortgage payoff')
    expect(msg[0].body).not.toContain('My mom passed and the house is empty')   // the words never reach the card entry

    const lead = await one<{ call_facts: Record<string, { value: unknown; by: string }>; stage: string; belt: string | null }>(
      `select call_facts, stage, belt from public.leads where id = $1`, [LEAD])
    expect(lead.call_facts.motivation).toMatchObject({ value: { choices: ['inherited'], text: 'mom passed' }, by: 'Call notes' })
    expect(lead.call_facts.price.value).toEqual({ text: 'payoff', number: '140000' })
    expect(lead.call_facts.timeline.by).toBe('Thalia')   // not said this call: left alone
    expect(lead.stage).toBe('reply_received')            // a note moves nothing
    const note = await one<{ facts_written: string[] }>(`select facts_written, suggested_mark, logged_before from public.call_notes where call_sid = $1`, [SID(1)])
    expect({ ...note, facts_written: [...note.facts_written].sort() }).toEqual({ facts_written: ['motivation', 'occupancy', 'price'], suggested_mark: 'hot', logged_before: null })
  })

  it('an answer tapped during the call wins over the notes; an older answer is replaced', async () => {
    await db.exec(`update public.leads set call_facts = '{"motivation": {"value": {"choices": ["moving"]}, "at": "2026-10-27T15:02:00Z", "by": "Thalia"},
                                                          "price": {"value": {"number": "200000"}, "at": "2026-09-01T00:00:00Z", "by": "Thalia"}}'
                   where id = '${LEAD}'`)
    const d = deps(fakeTwilio().t)
    await onRecording(recording(1), 'out', d)
    await onTranscriptWebhook({ customer_key: SID(1) }, d)
    const f = (await one<{ f: Record<string, { value: Record<string, unknown>; by: string }> }>(`select call_facts f from public.leads where id = $1`, [LEAD])).f
    expect(f.motivation).toMatchObject({ value: { choices: ['moving'] }, by: 'Thalia' })
    expect(f.price).toMatchObject({ value: { number: '140000' }, by: 'Call notes' })
  })

  it('agent_card carries the notes and never the words', async () => {
    const d = deps(fakeTwilio().t)
    await onRecording(recording(1), 'out', d)
    await onTranscriptWebhook({ transcript_sid: GT(1) }, d)
    const card = (await one<{ c: Record<string, unknown> }>(`select public.agent_card($1) c`, [LEAD])).c
    const notes = card.call_notes as Record<string, unknown>[]
    expect(notes).toHaveLength(1)
    expect(notes[0]).toMatchObject({ direction: 'out', who: 'Thalia', minutes: 4, suggested_mark: 'hot',
      pillars: { motivation: 'Inherited', signers: 'Jane and her brother' }, next_step: 'Colin calls Tue at 4' })
    expect(JSON.stringify(card)).not.toContain('house is empty')
    expect((card.calls as { outcome: string }[])[0].outcome).toBe('call_notes')
  })

  it('a call to a seller line finds its card through the phone line\'s log; short calls and unknown callers are not transcribed', async () => {
    await rpc('inbound_call_log', { p_call_sid: SID(2), p_from: `+1${PHONE}`, p_to: '+12624180202', p_event: 'answered', p_duration: 300 })
    const tw = fakeTwilio({ async call() { return { from: `+1${PHONE}`, to: '+12624180202', direction: 'inbound', start_time: null } } })
    const d = deps(tw.t)
    expect(await onRecording(recording(2), 'in', d)).toMatchObject({ lead_id: LEAD, transcribing: true })
    expect(await one(`select direction, phone10, caller from public.call_recordings where call_sid = $1`, [SID(2)]))
      .toEqual({ direction: 'in', phone10: PHONE, caller: null })
    await onTranscriptWebhook({ transcript_sid: GT(1) }, d)
    expect((await one(`select status from public.messages where source_key = $1`, [`cnote:${SID(2)}`]))?.status).toBe('inbound_call_notes')

    expect(await onRecording(recording(3, '6'), 'in', d)).toMatchObject({ status: 'too_short', transcribe: false })
    const stranger = fakeTwilio({ async call() { return { from: '+14145550000', to: '+12624180202', direction: 'inbound', start_time: null } } })
    expect(await onRecording(recording(4), 'in', deps(stranger.t))).toMatchObject({ status: 'no_card', transcribe: false })
    expect(stranger.made).toHaveLength(0)
  })

  it('a failed step is retried by the sweep; Claude failing five times leaves it failed', async () => {
    const flaky = fakeTwilio({ async createTranscript() { throw new Error('Twilio answered 503') } })
    await onRecording(recording(1), 'out', deps(flaky.t))
    expect(await one(`select status, error, attempts from public.call_recordings where call_sid = $1`, [SID(1)]))
      .toEqual({ status: 'recorded', error: 'Twilio answered 503', attempts: 1 })
    await db.exec(`update public.call_recordings set updated_at = now() - interval '10 minutes'`)
    const tw = fakeTwilio()
    const broken = deps(tw.t, async () => { throw new Error('Claude answered 529') })
    expect(await sweep(broken)).toMatchObject({ handled: 1 })
    expect(await one(`select status, transcript_sid from public.call_recordings where call_sid = $1`, [SID(1)])).toEqual({ status: 'transcribing', transcript_sid: GT(1) })
    for (let i = 0; i < 5; i++) {
      await db.exec(`update public.call_recordings set updated_at = now() - interval '10 minutes'`)
      await sweep(broken)
    }
    expect(await one(`select status, error from public.call_recordings where call_sid = $1`, [SID(1)])).toEqual({ status: 'failed', error: 'Claude answered 529' })
    expect(await all(`select 1 from public.messages where lead_id = $1`, [LEAD])).toHaveLength(0)
  })

  it('a transcript still running waits; one Twilio failed asks for a new one', async () => {
    let status = 'in-progress'
    const tw = fakeTwilio({ async transcriptStatus() { return status } })
    const d = deps(tw.t)
    await onRecording(recording(1), 'out', d)
    expect(await onTranscriptWebhook({ transcript_sid: GT(1) }, d)).toMatchObject({ waiting: 'in-progress' })
    status = 'failed'
    await onTranscriptWebhook({ transcript_sid: GT(1) }, d)
    expect(await one(`select status, transcript_sid from public.call_recordings where call_sid = $1`, [SID(1)])).toEqual({ status: 'recorded', transcript_sid: null })
  })

  it('the one tap: Hot logs the call as interested and books the call-back they agreed to', async () => {
    const d = deps(fakeTwilio().t)
    await onRecording(recording(1), 'out', d)
    await onTranscriptWebhook({ transcript_sid: GT(1) }, d)
    const id = (await one<{ id: string }>(`select id from public.call_notes`)).id
    const r = await asThalia(`select public.call_note_confirm($1, 'hot') r`, [id])
    expect(r).toMatchObject({ ok: true, mark: 'hot', outcome: 'interested' })
    const lead = await one<{ stage: string; hot: boolean; ns: { value: { kind: string } } | null }>(
      `select stage, hot_at is not null hot, call_facts->'next_step' ns from public.leads where id = $1`, [LEAD])
    expect(lead.stage).toBe('colin_call')
    expect(lead.hot).toBe(true)
    expect(lead.ns?.value.kind).toBe('callback')
    const logged = await all(`select status, body from public.messages where lead_id = $1 and status = 'interested'`, [LEAD])
    expect(logged).toHaveLength(1)
    expect(logged[0].body).toContain('From the call notes: Jane inherited it')
    expect(await one(`select confirmed_mark, confirmed_by from public.call_notes where id = $1`, [id])).toEqual({ confirmed_mark: 'hot', confirmed_by: 'Thalia' })
    expect(await asThalia(`select public.call_note_confirm($1, 'dead') r`, [id])).toMatchObject({ ok: false, reason: 'already confirmed: hot' })
  })

  it('the one tap: Not now with a date; Held needs the blocker; a call logged by hand is not logged twice', async () => {
    const d = deps(fakeTwilio().t)
    await onRecording(recording(1), 'out', d)
    await onTranscriptWebhook({ transcript_sid: GT(1) }, d)
    const id = (await one<{ id: string }>(`select id from public.call_notes`)).id
    expect(await asThalia(`select public.call_note_confirm($1, 'held') r`, [id])).toMatchObject({ ok: false, reason: 'a hold needs what they are waiting on' })
    expect(await asThalia(`select public.call_note_confirm($1, 'not_now', '2099-01-05T18:00:00Z') r`, [id])).toMatchObject({ ok: true, outcome: 'not_now' })
    expect(await one(`select stage from public.leads where id = $1`, [LEAD])).toEqual({ stage: 'follow_up' })

    await db.exec(`insert into public.human_call_provider_claims (attempt_key, lead_id, phone10, provider_call_sid) values ('key-0005', '${LEAD}', '${PHONE}', '${SID(6)}')`)
    await onRecording({ ...recording(6), RecordingStartTime: new Date(Date.now() - 600_000).toUTCString() }, 'out', d)
    await asThalia(`select public.log_call($1, $2, 'reached_no_decision', 'talked') r`, [LEAD, PHONE])
    await onTranscriptWebhook({ customer_key: SID(6) }, d)
    const n6 = await one<{ id: string; logged_before: string }>(`select id, logged_before from public.call_notes where call_sid = $1`, [SID(6)])
    expect(n6.logged_before).toBe('reached_no_decision')
    expect(await asThalia(`select public.call_note_confirm($1, 'hot') r`, [n6.id])).toMatchObject({ ok: false, reason: 'this call is already logged (reached no decision)' })
  })

  it('a seller who may be in an all-party-consent state is not recorded: the recording is deleted, nothing transcribed', async () => {
    const allowed = async (phone: string, lead: string | null = null) =>
      (await one<{ r: Record<string, unknown> }>(`select public.call_recording_allowed($1, $2::uuid) r`, [phone, lead])).r
    expect(await allowed(PHONE, LEAD)).toEqual({ record: true })
    expect(await allowed('3125550101')).toMatchObject({ record: false, reason: 'area code 312 is in an all-party-consent state' })
    expect(await allowed('')).toMatchObject({ record: false })
    await db.exec(`update public.leads set mailing_state = 'FL' where id = '${LEAD}'`)
    expect(await allowed(PHONE)).toMatchObject({ record: false, reason: 'mailing state FL is all-party consent' })
    const tw = fakeTwilio()
    expect(await onRecording(recording(1), 'out', deps(tw.t))).toMatchObject({ status: 'not_allowed', delete: true, deleted: true })
    expect(tw.recordingsDeleted).toEqual([RE(1)])
    expect(tw.made).toHaveLength(0)
    expect(await one(`select status, error from public.call_recordings where call_sid = $1`, [SID(1)]))
      .toEqual({ status: 'not_allowed', error: 'mailing state FL is all-party consent' })
  })

  it('the tables are the team\'s: the words are not readable without a team login', async () => {
    await db.exec(`insert into public.call_recordings (call_sid, lead_id, direction, status) values ('${SID(9)}', '${LEAD}', 'out', 'summarized');
                   insert into public.call_transcripts (call_sid, lead_id, words) values ('${SID(9)}', '${LEAD}', 'secret words')`)
    await db.exec('set role anon')
    try { await expect(db.query(`select words from public.call_transcripts`)).rejects.toThrow() } finally { await db.exec('reset role') }
    expect(await asThalia(`select count(*)::int r from public.call_transcripts`)).toBe(1)
  })
})
