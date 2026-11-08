// voice-agent: the inbound assistant for seller calls nobody picked up (Colin 2026-11-07: "Build the agent"). pm-phone
// hands a twice-missed seller call here with <Connect><ConversationRelay url="wss://.../voice-agent" ...>; Twilio does
// speech-to-text and text-to-speech and streams the caller's words in over this WebSocket; Claude's words stream out.
// The script is the seller call flow, four steps and three lanes (_shared/voicePrompt.ts); the assistant never says a
// number of its own. When the call ends, one more model call turns the transcript into the four answers and a lane,
// and voice_agent_result (app 0202) logs the call on the card, books the callback for the card's caller, and says who
// to buzz; the buzz goes by push (the caller's registered phones) and WhatsApp (pm-phone's /api/alert).
// Deployed with --no-verify-jwt (Twilio carries no token); a plain GET answers "ok" so the URL can be checked.
// A customParameter test=1 runs the conversation but writes nothing and returns the extraction in handoffData.
import { createClient } from 'npm:@supabase/supabase-js@2.56.1'
import { pushToPerson } from '../_shared/notifyDeno.ts'
import { callBlock, END_CALL, EXTRACTION_PROMPT, EXTRACTION_SCHEMA, laneFrom, PROMPT_VERSION, STATIC_PROMPT, greetingFor, type CallCard } from '../_shared/voicePrompt.ts'
import { PERSONAS, SELLER_SYSTEM, grade } from '../_shared/voiceSim.ts'

const MODEL = Deno.env.get('VOICE_MODEL') || 'claude-sonnet-5-5'
const EXTRACT_MODEL = Deno.env.get('VOICE_EXTRACTION_MODEL') || MODEL
const MAX_CALL_MS = Number(Deno.env.get('VOICE_MAX_CALL_MS') || 170_000)   // the edge runtime's wall clock is the ceiling
const WRAP_UP_MS = Number(Deno.env.get('VOICE_WRAP_UP_MS') || 120_000)
const SILENCE_MS = 15_000          // nothing from the caller for this long: "Are you still there?"
const SILENCE_END_MS = 10_000      // and this much longer: goodbye
const MAX_TURN_ERRORS = 2          // model failures in a row before the assistant bows out

type Turn = { role: 'agent' | 'caller'; text: string }
type Msg = { role: 'user' | 'assistant'; content: string }

function sb() {
  return createClient(Deno.env.get('SUPABASE_URL') ?? '', Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '', { auth: { persistSession: false } })
}

async function cardFor(from: string): Promise<CallCard | null> {
  try {
    const db = sb()
    const r = await db.rpc('inbound_call_ring', { p_digits: from })
    const card = (r.data as { card?: CallCard | null } | null)?.card ?? null
    if (!card?.lead_id) return card
    const c = await db.rpc('agent_card', { p_lead: card.lead_id })
    const d = (c.data ?? {}) as Record<string, unknown>
    return { ...card, reasons: Array.isArray(d.reasons) ? (d.reasons as string[]) : null, stage: (d.stage as string) ?? null,
      owner_type: (d.owner_type as string) ?? null, say_next: typeof d.say_next === 'string' ? d.say_next : null }
  } catch { return null }
}

const API = 'https://api.anthropic.com/v1/messages'
const headersFor = (key: string) => ({ 'content-type': 'application/json', 'x-api-key': key, 'anthropic-version': '2023-06-01' })
const RETRY_STATUSES = new Set([408, 409, 425, 429, 500, 502, 503, 504, 529])
// Thinking is ON by default on claude-sonnet-5-5 (adaptive, effort high) when the request omits `thinking`; on a phone
// turn with max_tokens 300 the thinking blocks ate the whole budget and the caller heard silence (simulator runs 1-2,
// 2026-11-07). `disabled` is a 400 on this model; `between_tools` is the documented way to turn it off.
const THINKING = { type: 'between_tools' }
const wait = (ms: number) => new Promise((r) => setTimeout(r, ms))

/** A plain (non-streaming) Claude call, retried on 429/5xx/529 and dropped connections; throws with the reason. */
async function claudeJson(body: Record<string, unknown>, tries = 3): Promise<{ text: string; stop_reason: string; blocks: string }> {
  const key = Deno.env.get('ANTHROPIC_API_KEY') ?? ''
  let last = ''
  for (let i = 0; i < tries; i++) {
    try {
      const res = await fetch(API, { method: 'POST', headers: headersFor(key), body: JSON.stringify(body) })
      if (res.ok) {
        const j = await res.json() as { content?: { type?: string; text?: string }[]; stop_reason?: string }
        const text = (j.content ?? []).filter((c) => c.type === 'text').map((c) => c.text ?? '').join('').trim()
        if (!text) console.warn('[voice-agent] empty text; blocks', (j.content ?? []).map((c) => c.type).join(','), 'stop', j.stop_reason)
        return { text, stop_reason: j.stop_reason ?? '', blocks: (j.content ?? []).map((c) => c.type ?? '?').join(',') }
      }
      last = `claude ${res.status}: ${(await res.text().catch(() => '')).slice(0, 160)}`
      if (!RETRY_STATUSES.has(res.status)) break
    } catch (e) { last = String(e).slice(0, 160) }
    await wait(1200 * (i + 1))
  }
  throw new Error(last || 'claude: no answer')
}

/** One streamed Claude turn: yields text pieces with the END_CALL marker held back; sets ended when it appears.
 *  A failure before any text has been spoken (an in-stream overloaded/api error, a 429/5xx, a dropped connection, an
 *  empty stream) is retried twice in place, so the caller never hears a blank turn. The first simulator run
 *  (2026-11-07) showed the parser swallowing in-stream error events as silence, the same silence Colin's browser test hit. */
async function* claudeTurn(system: string, messages: Msg[], signal: AbortSignal, state: { ended: boolean }): AsyncGenerator<string> {
  let yielded = false
  for (let attempt = 0; ; attempt++) {
    try {
      const seen = { blocks: [] as string[], stop: '' }
      for await (const piece of claudeStream(system, messages, signal, state, seen)) { yielded = true; yield piece }
      if (!yielded && !state.ended) throw new Error(`empty reply (blocks ${seen.blocks.join(',') || 'none'}; stop ${seen.stop || '?'})`)
      return
    } catch (e) {
      if (yielded || signal.aborted || attempt >= 2) throw e
      console.warn('[voice-agent] turn retry', attempt + 1, String(e).slice(0, 120))
      await wait((/\b(429|529|overloaded)\b/.test(String(e)) ? 1500 : 400) * (attempt + 1))
    }
  }
}

async function* claudeStream(system: string, messages: Msg[], signal: AbortSignal, state: { ended: boolean }, seen?: { blocks: string[]; stop: string }): AsyncGenerator<string> {
  const key = Deno.env.get('ANTHROPIC_API_KEY') ?? ''
  const res = await fetch(API, {
    method: 'POST', signal, headers: headersFor(key),
    body: JSON.stringify({ model: MODEL, max_tokens: 400, stream: true, thinking: THINKING,
      system: [{ type: 'text', text: system, cache_control: { type: 'ephemeral' } }], messages }),
  })
  if (!res.ok || !res.body) throw new Error(`claude ${res.status}: ${(await res.text().catch(() => '')).slice(0, 200)}`)
  const reader = res.body.getReader()
  const dec = new TextDecoder()
  let buf = ''
  let hold = ''
  for (;;) {
    const { value, done } = await reader.read()
    if (done) break
    buf += dec.decode(value, { stream: true })
    const lines = buf.split('\n'); buf = lines.pop() ?? ''
    for (const line of lines) {
      if (!line.startsWith('data: ')) continue
      let ev: { type?: string; delta?: { type?: string; text?: string; stop_reason?: string }; error?: { type?: string; message?: string } }
      try { ev = JSON.parse(line.slice(6)) } catch { continue }
      // an error inside a 200 stream (overloaded_error, api_error) used to be skipped here and came out as a blank turn
      if (ev.type === 'error') throw new Error(`stream ${ev.error?.type ?? 'error'}: ${ev.error?.message ?? ''}`.slice(0, 200))
      if (ev.type === 'message_delta' && ev.delta?.stop_reason) { if (seen) seen.stop = ev.delta.stop_reason; if (ev.delta.stop_reason === 'max_tokens') console.warn('[voice-agent] turn cut at max_tokens') }
      if (ev.type === 'content_block_start' && seen) seen.blocks.push((ev as { content_block?: { type?: string } }).content_block?.type ?? '?')
      if (ev.type !== 'content_block_delta' || ev.delta?.type !== 'text_delta') continue
      let s = hold + (ev.delta.text ?? '')
      if (s.includes(END_CALL)) {
        state.ended = true
        const before = s.split(END_CALL)[0]
        if (before) yield before
        hold = ''
        continue
      }
      if (state.ended) continue
      let keep = 0
      for (let k = Math.min(END_CALL.length - 1, s.length); k > 0; k--) if (s.endsWith(END_CALL.slice(0, k))) { keep = k; break }
      const emit = keep ? s.slice(0, -keep) : s
      hold = keep ? s.slice(-keep) : ''
      if (emit) yield emit
    }
  }
  if (hold && !state.ended) yield hold
}

async function extract(transcript: Turn[], card: CallCard | null, from: string): Promise<Record<string, unknown> | null> {
  const key = Deno.env.get('ANTHROPIC_API_KEY') ?? ''
  if (!key || transcript.length < 2) return null
  const now = new Date()
  const text = transcript.map((t) => `${t.role === 'agent' ? 'Assistant' : 'Caller'}: ${t.text}`).join('\n')
  // retried on 429/5xx; a failure throws with its reason so the call's events (and the simulator) say why
  const r = await claudeJson({ model: EXTRACT_MODEL, max_tokens: 1500, thinking: THINKING, system: EXTRACTION_PROMPT,
    output_config: { format: { type: 'json_schema', schema: EXTRACTION_SCHEMA } },
    messages: [{ role: 'user', content: `Current time: ${now.toISOString()} (America/Chicago is UTC-6 in November).\nCaller's number: ${from}.\nFile on record: ${card?.owner_name ?? 'unknown'}${card?.address ? `, ${card.address}` : ''}.\n\nTranscript:\n${text}\n\nReturn the JSON object only.` }] })
  if (r.stop_reason === 'max_tokens') throw new Error('extraction cut at max_tokens')
  const m = r.text.match(/\{[\s\S]*\}/)
  if (!m) throw new Error(`extraction not JSON: ${r.text.slice(0, 120)}`)
  let x: Record<string, unknown>
  try { x = JSON.parse(m[0]) as Record<string, unknown> } catch { throw new Error(`extraction JSON invalid: ${m[0].slice(0, 120)}`) }
  x.lane_model = x.lane            // the model's opinion, kept for the record
  x.lane = laneFrom(x)             // the sheet's rule decides
  return x
}

/** One turn, collected (the simulator and the self-test): the reply text and whether the assistant ended the call. */
async function turnText(system: string, messages: Msg[], state: { ended: boolean }): Promise<string> {
  const parts: string[] = []
  for await (const piece of claudeTurn(system, messages, new AbortController().signal, state)) parts.push(piece)
  return parts.join('').trim()
}

async function sellerReply(persona: typeof PERSONAS[number], transcript: Turn[]): Promise<string> {
  // the seller model sees the assistant's lines as the user and its own as the assistant
  const msgs: Msg[] = transcript.map((t) => ({ role: t.role === 'agent' ? 'user' : 'assistant', content: t.text || '(silence)' }))
  if (msgs.length && msgs[msgs.length - 1].role !== 'user') msgs.push({ role: 'user', content: '(silence)' })
  for (let i = 0; i < 2; i++) {
    const r = await claudeJson({ model: MODEL, max_tokens: 200, thinking: THINKING, system: SELLER_SYSTEM(persona), messages: msgs })
    if (r.text) return r.text
    console.warn('[sim] seller empty reply, stop_reason', r.stop_reason)
    if (i === 1) throw new Error(`seller model: empty reply twice (blocks ${r.blocks}; stop ${r.stop_reason})`)
  }
  throw new Error('seller model: empty reply twice')
}

/** The simulator: Claude plays a persona against the real prompt and turn code; the run is graded and kept. */
async function simulate(personaId: string): Promise<Record<string, unknown>> {
  const persona = PERSONAS.find((p) => p.id === personaId)
  if (!persona) return { ok: false, error: `no persona ${personaId}`, personas: PERSONAS.map((p) => p.id) }
  const started = Date.now()
  const card: CallCard | null = persona.card
    ? { lead_id: null, owner_name: 'Pat Tester', address: '123 Test St', municipality: 'West Bend', reasons: ['behind on taxes'], owner_type: 'individual', ...(typeof persona.card === 'object' ? persona.card : {}) }
    : null
  const greeting = greetingFor(card)
  const system = `${STATIC_PROMPT}\n\n# This call\n${callBlock(card, '+14145550123', greeting)}`
  const transcript: Turn[] = [{ role: 'agent', text: greeting }]
  const messages: Msg[] = []
  const state = { ended: false }
  let errors = 0
  let harnessError = ''
  let extractionError = ''
  const turnErrors: string[] = []
  let sellerText = persona.opening
  const maxTurns = (persona.expect.max_turns ?? 14) + 2
  for (let i = 0; i < maxTurns && !state.ended; i++) {
    if (sellerText.includes('[HANGUP]')) break
    transcript.push({ role: 'caller', text: sellerText })
    messages.push({ role: 'user', content: sellerText })
    let reply = ''
    try { reply = await turnText(system, messages, state) } catch (e) { errors += 1; turnErrors.push(String(e).slice(0, 120)); reply = "I'm sorry, I lost you for a second. Could you say that once more?"; console.error('[sim] turn:', String(e).slice(0, 160)) }
    messages.push({ role: 'assistant', content: reply || '(ended the call)' })
    transcript.push({ role: 'agent', text: reply })
    if (state.ended) break
    try { sellerText = await sellerReply(persona, transcript) } catch (e) { harnessError = String(e).slice(0, 160); console.error('[sim] seller:', harnessError); break }
    if (!sellerText) { harnessError = 'seller model: empty reply'; break }
  }
  let extraction: Record<string, unknown> | null = null
  try { extraction = await extract(transcript, card, '+14145550123') } catch (e) { extraction = null; extractionError = String(e).slice(0, 160) }
  const checks = grade(persona, transcript, extraction, state.ended, errors, { harnessError, extractionError, turnErrors })
  const passed = checks.every((c) => c.ok)
  const seconds = Math.round((Date.now() - started) / 1000)
  await sb().from('voice_sim_runs').insert({ persona: persona.id, name: persona.name, passed, checks, transcript, extraction, seconds, model: MODEL, prompt_version: PROMPT_VERSION })
  return { ok: true, persona: persona.id, name: persona.name, passed, checks, seconds, turns: transcript.filter((t) => t.role === 'caller').length, ended: state.ended, extraction, transcript }
}

async function finish(x: { callSid: string; from: string; to: string; card: CallCard | null; transcript: Turn[]; startedAt: number; test: boolean; outcome?: string; events: object[] }) {
  const seconds = Math.round((Date.now() - x.startedAt) / 1000)
  let extraction: Record<string, unknown> | null = null
  try { extraction = x.transcript.some((t) => t.role === 'caller') ? await extract(x.transcript, x.card, x.from) : null }
  catch (e) { x.events.push({ at: Date.now() - x.startedAt, type: 'extract_error', detail: String(e).slice(0, 160) }) }
  const db = sb()
  if (x.test) {
    // a test call (Settings, "Test the assistant"): nothing touches a card; the transcript, extraction and events are kept as a test
    await db.from('voice_calls').upsert({ call_sid: x.callSid, lead_id: null, from10: x.from.replace(/\D/g, '').slice(-10), to_number: x.to, ended_at: new Date().toISOString(),
      seconds, transcript: x.transcript, extraction, outcome: 'test', events: x.events }, { onConflict: 'call_sid' })
    return { test: true, seconds, extraction }
  }
  const callerTurns = x.transcript.filter((t) => t.role === 'caller').length
  if (!extraction && callerTurns >= 2) {
    // a real conversation whose read failed: the caller still gets the task, with the thread's tail (0206)
    const r0 = await db.rpc('voice_agent_talked_no_extraction', { p: { call_sid: x.callSid, from: x.from, to: x.to, lead_id: x.card?.lead_id ?? null,
      transcript: x.transcript, seconds, events: x.events } })
    if (r0.error) console.error('[voice-agent] talked_no_extraction:', r0.error.message)
    return (r0.data ?? {}) as Record<string, unknown>
  }
  const r = await db.rpc('voice_agent_result', { p: { call_sid: x.callSid, from: x.from, to: x.to, lead_id: x.card?.lead_id ?? null,
    transcript: x.transcript, extraction, seconds, outcome: x.outcome ?? (extraction ? null : 'hung_up') } })
  const d = (r.data ?? {}) as { ok?: boolean; outcome?: string; owner?: string; owner_whatsapp?: string | null; owner_name?: string; address?: string; municipality?: string; lead_id?: string; due_at?: string }
  if (r.error) { console.error('[voice-agent] result:', r.error.message); x.events.push({ at: Date.now() - x.startedAt, type: 'result_error', detail: r.error.message.slice(0, 160) }) }
  await db.from('voice_calls').update({ events: x.events }).eq('call_sid', x.callSid)
  // buzz the caller who owns the card: push to their phones, WhatsApp through pm-phone
  if (d.ok && d.owner && ['callback_booked', 'not_now', 'never_callback'].includes(d.outcome ?? '')) {
    const name = d.owner_name || x.from
    const where = [d.address, d.municipality].filter(Boolean).join(', ')
    const when = d.due_at ? new Date(d.due_at).toLocaleString('en-US', { timeZone: 'America/Chicago', weekday: 'short', hour: 'numeric', minute: '2-digit' }) : 'soon'
    const body = `${name} called and talked to the assistant${where ? ` (${where})` : ''}. Callback set for ${when}: it is on your list with everything they said.`
    const appUrl = Deno.env.get('NOTIFY_APP_URL') || 'https://deals.junkcarsmequon.com'
    const push = pushToPerson(db)
    if (push) await push(d.owner, { title: 'Assistant took a seller call', body, url: d.lead_id ? `${appUrl}/lead/${d.lead_id}` : `${appUrl}/today` }).catch(() => 0)
    const secret = (Deno.env.get('ALERT_SECRET') ?? '').trim()
    if (secret && d.owner_whatsapp) {
      await fetch((Deno.env.get('ALERT_URL') ?? '').trim() || 'https://junkcarsmequon.com/api/alert', { method: 'POST',
        headers: { 'content-type': 'application/json', 'x-alert-secret': secret }, body: JSON.stringify({ channel: 'whatsapp', to: d.owner_whatsapp, text: body }) }).catch(() => undefined)
    }
  }
  return d
}

Deno.serve(async (req) => {
  if (req.headers.get('upgrade')?.toLowerCase() !== 'websocket') {
    const info: Record<string, unknown> = { ok: true, agent: 'voice-agent', model: MODEL, key: !!Deno.env.get('ANTHROPIC_API_KEY') }
    // ?selftest=1: one tiny model request with the function's own key; the status and the API's words, never the key
    if (new URL(req.url).searchParams.get('selftest') === '1') {
      try {
        const r = await fetch('https://api.anthropic.com/v1/messages', { method: 'POST',
          headers: { 'content-type': 'application/json', 'x-api-key': Deno.env.get('ANTHROPIC_API_KEY') ?? '', 'anthropic-version': '2023-06-01' },
          body: JSON.stringify({ model: MODEL, max_tokens: 8, system: [{ type: 'text', text: 'Be terse.', cache_control: { type: 'ephemeral' } }], messages: [{ role: 'user', content: 'Say hi.' }] }) })
        const t = await r.text()
        info.selftest = { status: r.status, body: t.slice(0, 300) }
      } catch (e) { info.selftest = { error: String(e).slice(0, 300) } }
    }
    // ?selftest=2: the real streaming turn, as a call would run it
    if (new URL(req.url).searchParams.get('selftest') === '2') {
      const got: string[] = []
      const st = { ended: false }
      try {
        const sys = `${STATIC_PROMPT}

# This call
${callBlock(null, '+15555550100', greetingFor(null))}`
        for await (const piece of claudeTurn(sys, [{ role: 'user', content: 'Yeah, this is John. It is about the house on Highway 12.' }], new AbortController().signal, st)) got.push(piece)
        info.selftest2 = { ok: true, text: got.join('').slice(0, 300), ended: st.ended }
      } catch (e) { info.selftest2 = { error: String(e).slice(0, 400), stack: String((e as Error).stack ?? '').slice(0, 400) } }
    }
    const u = new URL(req.url)
    if (u.searchParams.get('personas') === '1') return Response.json({ personas: PERSONAS.map((p) => ({ id: p.id, name: p.name })) , prompt_version: PROMPT_VERSION })
    const simId = u.searchParams.get('sim')
    if (simId) {
      // auth: the shared alert secret (reply-send, on Colin's click), or a one-hour token the laptop wrote to voice_sim_tokens
      const secret = (Deno.env.get('ALERT_SECRET') ?? '').trim()
      const given = u.searchParams.get('s') ?? ''
      let allowed = !!secret && given === secret
      const token = u.searchParams.get('token') ?? ''
      if (!allowed && /^[A-Za-z0-9_-]{16,80}$/.test(token)) {
        const t = await sb().from('voice_sim_tokens').select('token, created_at').eq('token', token).maybeSingle()
        allowed = !!t.data && Date.now() - new Date((t.data as { created_at: string }).created_at).getTime() < 3_600_000
      }
      if (!allowed) return Response.json({ ok: false, error: 'forbidden' }, { status: 403 })
      if (!Deno.env.get('ANTHROPIC_API_KEY')) return Response.json({ ok: false, error: 'no key' }, { status: 503 })
      try { return Response.json(await simulate(simId)) } catch (e) { return Response.json({ ok: false, error: String(e).slice(0, 300) }, { status: 500 }) }
    }
    return Response.json(info)
  }
  // Twilio cannot send a token, so the socket is open to the world at the gateway; the phone system proves itself
  // with the shared alert secret on the URL (the same one it checks on /api/alert). No secret, no socket.
  const secret = (Deno.env.get('ALERT_SECRET') ?? '').trim()
  const given = new URL(req.url).searchParams.get('s') ?? ''
  if (!secret || given !== secret) return new Response('forbidden', { status: 403 })
  const { socket, response } = Deno.upgradeWebSocket(req)
  let callSid = ''; let from = ''; let to = ''; let test = false
  let card: CallCard | null = null
  let system = ''
  const messages: Msg[] = []
  const transcript: Turn[] = []
  const state = { ended: false }
  let turn: AbortController | null = null
  let finished = false
  let wrapTimer: number | undefined
  let hardTimer: number | undefined
  let resumeTimer: number | undefined
  let silenceTimer: number | undefined
  let silenceAsked = false
  let turnErrors = 0
  let lastUser = ''
  const startedAt = Date.now()
  const events: object[] = []
  const log = (type: string, detail?: string) => { if (events.length < 400) events.push({ at: Date.now() - startedAt, type, ...(detail ? { detail: detail.slice(0, 160) } : {}) }) }
  const send = (m: object) => { try { socket.send(JSON.stringify(m)) } catch { /* closed */ } }
  const endCall = (reason: string) => { send({ type: 'end', handoffData: JSON.stringify({ reason, callSid }) }) }
  // nothing from the caller: ask once, then go
  const armSilence = () => {
    clearTimeout(silenceTimer)
    if (state.ended) return
    silenceTimer = setTimeout(() => {
      if (state.ended) return
      if (!silenceAsked) {
        silenceAsked = true; log('silence_ask')
        send({ type: 'text', token: 'Are you still there?', last: true }); transcript.push({ role: 'agent', text: 'Are you still there?' })
        silenceTimer = setTimeout(() => { if (!state.ended) { state.ended = true; log('silence_end'); send({ type: 'text', token: "I'll let you go. Thanks for calling; the team will call you back. Goodbye.", last: true }); endCall('silence') } }, SILENCE_END_MS)
      }
    }, SILENCE_MS)
  }

  const speak = async (userText: string, resume = false) => {
    turn?.abort()
    const ctl = new AbortController(); turn = ctl
    if (!resume) { messages.push({ role: 'user', content: userText }); transcript.push({ role: 'caller', text: userText }) }
    lastUser = userText
    log(resume ? 'turn_resume' : 'turn_start', userText)
    const said: string[] = []
    try {
      for await (const piece of claudeTurn(system, messages, ctl.signal, state)) {
        if (ctl.signal.aborted) break
        said.push(piece)
        send({ type: 'text', token: piece, last: false })
      }
      if (!ctl.signal.aborted) { send({ type: 'text', token: '', last: true }); log('turn_done', said.join('').slice(0, 80)); turnErrors = 0; silenceAsked = false; armSilence() }
      else log('turn_aborted', said.join('').slice(0, 80))
    } catch (e) {
      if (!ctl.signal.aborted) {
        console.error('[voice-agent] turn:', String(e).slice(0, 200))
        log('turn_error', String(e))
        turnErrors += 1
        if (turnErrors >= MAX_TURN_ERRORS) {
          state.ended = true
          const line = "I'm having trouble on my end, so I won't keep you. Someone from the team will call you back shortly. Thanks for calling."
          said.push(line); send({ type: 'text', token: line, last: true })
        } else {
          const line = "I'm sorry, I lost you for a second. Could you say that once more?"
          said.push(line); send({ type: 'text', token: line, last: true }); armSilence()
        }
      } else log('turn_abort_error', String(e))
    } finally {
      const text = said.join('').trim()
      if (text || state.ended) { messages.push({ role: 'assistant', content: text || '(ended the call)' }); transcript.push({ role: 'agent', text }) }
      if (state.ended && turn === ctl) { log('end_sent'); endCall('conversation-complete') }
    }
  }

  socket.onmessage = async (ev) => {
    let msg: Record<string, unknown>
    try { msg = JSON.parse(String(ev.data)) } catch { return }
    log(String(msg.type), msg.type === 'prompt' ? `${msg.last === false ? 'partial: ' : ''}${String(msg.voicePrompt ?? '').slice(0, 80)}` : msg.type === 'interrupt' ? String(msg.utteranceUntilInterrupt ?? '').slice(0, 80) : msg.type === 'error' ? String(msg.description ?? '') : undefined)
    if (msg.type === 'setup') {
      callSid = String(msg.callSid ?? ''); from = String(msg.from ?? ''); to = String(msg.to ?? '')
      const custom = (msg.customParameters ?? {}) as Record<string, string>
      test = custom.test === '1'
      if (!Deno.env.get('ANTHROPIC_API_KEY')) { log('no_key'); endCall('no-key'); return }
      card = custom.lead_id ? { lead_id: custom.lead_id, owner_name: custom.owner_name, address: custom.address, municipality: custom.municipality } : null
      const full = await cardFor(from)
      if (full) card = { ...card, ...full }
      const greeting = custom.greeting || greetingFor(card)
      transcript.push({ role: 'agent', text: greeting })
      system = `${STATIC_PROMPT}\n\n# This call\n${callBlock(card, from, greeting)}`
      wrapTimer = setTimeout(() => { log('wrap_up'); if (!state.ended) messages.push({ role: 'user', content: '(system: the call is running long; book the callback in one sentence, say goodbye, and end)' }) }, WRAP_UP_MS)
      hardTimer = setTimeout(() => { log('hard_stop'); if (!state.ended) { state.ended = true; send({ type: 'text', token: "I have to let you go now. Thanks for calling; the team will call you back shortly.", last: true }); endCall('time-limit') } }, MAX_CALL_MS)
      log('ready', card?.address ?? 'no card')
      armSilence()
      return
    }
    if (msg.type === 'prompt') {
      if (msg.last === false) { clearTimeout(silenceTimer); return }
      clearTimeout(resumeTimer); clearTimeout(silenceTimer)
      const text = String(msg.voicePrompt ?? msg.transcription ?? '').trim()
      if (!text || state.ended) return
      void speak(text)
      return
    }
    if (msg.type === 'interrupt') {
      // the caller spoke over the reply: stop talking. Twilio then sends their words as a prompt; if none comes in
      // 2.5 s (a cough, an echo, a half word), answer the last thing they said instead of going quiet for good
      // (Colin's first browser test, 2026-11-07: "it died and stopped replying").
      turn?.abort()
      clearTimeout(resumeTimer)
      resumeTimer = setTimeout(() => { if (!state.ended && lastUser && !(turn && !turn.signal.aborted)) { log('resume_after_interrupt'); void speak(lastUser, true) } }, 2500)
      return
    }
    if (msg.type === 'error') console.error('[voice-agent] relay:', String(msg.description ?? '').slice(0, 200))
  }

  socket.onclose = async (ev) => {
    log('close', `code ${ev.code}${ev.reason ? ' ' + ev.reason : ''}`)
    clearTimeout(wrapTimer); clearTimeout(hardTimer); clearTimeout(resumeTimer); clearTimeout(silenceTimer); turn?.abort()
    if (finished || !callSid) return
    finished = true
    try { await finish({ callSid, from, to, card, transcript, startedAt, test, outcome: state.ended ? undefined : 'hung_up', events }) }
    catch (e) { console.error('[voice-agent] finish:', String(e).slice(0, 200)) }
  }
  socket.onerror = (e) => { const m = String((e as ErrorEvent).message ?? ''); log('socket_error', m); console.error('[voice-agent] socket:', m.slice(0, 200)) }
  return response
})
