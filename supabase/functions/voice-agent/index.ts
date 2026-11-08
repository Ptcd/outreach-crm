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
import { callBlock, END_CALL, EXTRACTION_PROMPT, STATIC_PROMPT, greetingFor, type CallCard } from '../_shared/voicePrompt.ts'

const MODEL = Deno.env.get('VOICE_MODEL') || 'claude-sonnet-5-5'
const EXTRACT_MODEL = Deno.env.get('VOICE_EXTRACTION_MODEL') || MODEL
const MAX_CALL_MS = Number(Deno.env.get('VOICE_MAX_CALL_MS') || 170_000)   // the edge runtime's wall clock is the ceiling
const WRAP_UP_MS = Number(Deno.env.get('VOICE_WRAP_UP_MS') || 120_000)

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

/** One streamed Claude turn: yields text pieces with the END_CALL marker held back; sets ended when it appears. */
async function* claudeTurn(system: string, messages: Msg[], signal: AbortSignal, state: { ended: boolean }): AsyncGenerator<string> {
  const key = Deno.env.get('ANTHROPIC_API_KEY') ?? ''
  const res = await fetch('https://api.anthropic.com/v1/messages', {
    method: 'POST', signal,
    headers: { 'content-type': 'application/json', 'x-api-key': key, 'anthropic-version': '2023-06-01' },
    body: JSON.stringify({ model: MODEL, max_tokens: 300, stream: true,
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
      let ev: { type?: string; delta?: { type?: string; text?: string } }
      try { ev = JSON.parse(line.slice(6)) } catch { continue }
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
  const res = await fetch('https://api.anthropic.com/v1/messages', {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'x-api-key': key, 'anthropic-version': '2023-06-01' },
    body: JSON.stringify({ model: EXTRACT_MODEL, max_tokens: 700, system: EXTRACTION_PROMPT,
      messages: [{ role: 'user', content: `Current time: ${now.toISOString()} (America/Chicago is UTC-6 in November).\nCaller's number: ${from}.\nFile on record: ${card?.owner_name ?? 'unknown'}${card?.address ? `, ${card.address}` : ''}.\n\nTranscript:\n${text}\n\nReturn the JSON object only.` }] }),
  })
  if (!res.ok) return null
  const j = await res.json() as { content?: { type: string; text?: string }[] }
  const raw = (j.content ?? []).map((c) => c.text ?? '').join('').trim()
  const m = raw.match(/\{[\s\S]*\}/)
  if (!m) return null
  try { return JSON.parse(m[0]) as Record<string, unknown> } catch { return null }
}

async function finish(x: { callSid: string; from: string; to: string; card: CallCard | null; transcript: Turn[]; startedAt: number; test: boolean; outcome?: string }) {
  const seconds = Math.round((Date.now() - x.startedAt) / 1000)
  const extraction = x.transcript.some((t) => t.role === 'caller') ? await extract(x.transcript, x.card, x.from) : null
  if (x.test) return { test: true, seconds, extraction, transcript: x.transcript }
  const db = sb()
  const r = await db.rpc('voice_agent_result', { p: { call_sid: x.callSid, from: x.from, to: x.to, lead_id: x.card?.lead_id ?? null,
    transcript: x.transcript, extraction, seconds, outcome: x.outcome ?? (extraction ? null : 'hung_up') } })
  const d = (r.data ?? {}) as { ok?: boolean; outcome?: string; owner?: string; owner_whatsapp?: string | null; owner_name?: string; address?: string; municipality?: string; lead_id?: string; due_at?: string }
  if (r.error) console.error('[voice-agent] result:', r.error.message)
  // buzz the caller who owns the card: push to their phones, WhatsApp through pm-phone
  if (d.ok && d.owner && ['callback_booked', 'not_now'].includes(d.outcome ?? '')) {
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
  const startedAt = Date.now()
  const send = (m: object) => { try { socket.send(JSON.stringify(m)) } catch { /* closed */ } }
  const endCall = (reason: string) => { send({ type: 'end', handoffData: JSON.stringify({ reason, callSid }) }) }

  const speak = async (userText: string) => {
    turn?.abort()
    const ctl = new AbortController(); turn = ctl
    messages.push({ role: 'user', content: userText })
    transcript.push({ role: 'caller', text: userText })
    const said: string[] = []
    try {
      for await (const piece of claudeTurn(system, messages, ctl.signal, state)) {
        if (ctl.signal.aborted) break
        said.push(piece)
        send({ type: 'text', token: piece, last: false })
      }
      if (!ctl.signal.aborted) send({ type: 'text', token: '', last: true })
    } catch (e) {
      if (!ctl.signal.aborted) {
        console.error('[voice-agent] turn:', String(e).slice(0, 200))
        const line = "I'm sorry, I lost you for a second. Could you say that once more?"
        said.push(line); send({ type: 'text', token: line, last: true })
      }
    } finally {
      const text = said.join('').trim()
      if (text || state.ended) { messages.push({ role: 'assistant', content: text || '(ended the call)' }); transcript.push({ role: 'agent', text }) }
      if (state.ended && turn === ctl) endCall('conversation-complete')
    }
  }

  socket.onmessage = async (ev) => {
    let msg: Record<string, unknown>
    try { msg = JSON.parse(String(ev.data)) } catch { return }
    if (msg.type === 'setup') {
      callSid = String(msg.callSid ?? ''); from = String(msg.from ?? ''); to = String(msg.to ?? '')
      const custom = (msg.customParameters ?? {}) as Record<string, string>
      test = custom.test === '1'
      if (!Deno.env.get('ANTHROPIC_API_KEY')) { endCall('no-key'); return }
      card = custom.lead_id ? { lead_id: custom.lead_id, owner_name: custom.owner_name, address: custom.address, municipality: custom.municipality } : null
      const full = await cardFor(from)
      if (full) card = { ...card, ...full }
      const greeting = custom.greeting || greetingFor(card)
      transcript.push({ role: 'agent', text: greeting })
      system = `${STATIC_PROMPT}\n\n# This call\n${callBlock(card, from, greeting)}`
      wrapTimer = setTimeout(() => { if (!state.ended) messages.push({ role: 'user', content: '(system: the call is running long; book the callback in one sentence, say goodbye, and end)' }) }, WRAP_UP_MS)
      hardTimer = setTimeout(() => { if (!state.ended) { state.ended = true; send({ type: 'text', token: "I have to let you go now. Thanks for calling; the team will call you back shortly.", last: true }); endCall('time-limit') } }, MAX_CALL_MS)
      return
    }
    if (msg.type === 'prompt') {
      if (msg.last === false) return
      const text = String(msg.voicePrompt ?? msg.transcription ?? '').trim()
      if (!text || state.ended) return
      void speak(text)
      return
    }
    if (msg.type === 'interrupt') { turn?.abort(); return }
    if (msg.type === 'error') console.error('[voice-agent] relay:', String(msg.description ?? '').slice(0, 200))
  }

  socket.onclose = async () => {
    clearTimeout(wrapTimer); clearTimeout(hardTimer); turn?.abort()
    if (finished || !callSid) return
    finished = true
    try { await finish({ callSid, from, to, card, transcript, startedAt, test, outcome: state.ended ? undefined : 'hung_up' }) }
    catch (e) { console.error('[voice-agent] finish:', String(e).slice(0, 200)) }
  }
  socket.onerror = (e) => console.error('[voice-agent] socket:', String((e as ErrorEvent).message ?? '').slice(0, 200))
  return response
})
