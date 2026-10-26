// call-notes: a recorded seller call becomes notes on the card (migration 0073, _shared/callNotes.ts).
//   POST ?d=out|in        Twilio's recording status callback (pm-phone sets it on the <Dial>); X-Twilio-Signature checked.
//   POST ?event=transcript Voice Intelligence's "transcript available" webhook. Only the ids in it are used: the
//                          transcript's state and words are fetched from Twilio with our own credentials.
//   POST ?event=sweep      pg_cron every 5 minutes (shared secret): whatever a lost callback left behind.
// Twilio gets its answer at once; the work carries on in the background (EdgeRuntime.waitUntil). Nothing about what
// was said is ever logged: failures log the call id and a reason.
import { createClient } from 'npm:@supabase/supabase-js@2.56.1'
import { validTwilioSignature } from '../_shared/sending.ts'
import { onRecording, onTranscriptWebhook, summarizeCall, sweep, twilioIntelligence, type CallContext, type Deps, type Rpc } from '../_shared/callNotes.ts'

declare const EdgeRuntime: { waitUntil(p: Promise<unknown>): void } | undefined

const SELFTEST_CONTEXT: CallContext = {
  call_sid: 'CA' + '0'.repeat(32), transcript_sid: 'GT' + '0'.repeat(32), lead_id: '00000000-0000-0000-0000-000000000000',
  direction: 'out', phone10: '2625550100', caller: 'Thalia', duration_s: 240, started_at: null, owner_name: 'JANE SAMPLE',
  address: '123 SAMPLE ST', city: 'Waukesha', mailing_state: 'WI', stage: 'colin_call', elderly_or_ill: false, grief: false,
}
const SELFTEST_WORDS = [
  'Us: Hi, is this Jane? This is Thalia, calling about 123 Sample Street.',
  'Seller: Yes. My mom passed in the spring and the house is just sitting there. My brother and I own it now.',
  'Us: I am sorry. What shape is it in?',
  'Seller: The roof is old and the basement leaks when it rains. Nobody lives there.',
  'Us: When would you two want it sold?',
  'Seller: After the holidays, probably January. We need about 140 to pay off the reverse mortgage.',
  'Us: Would a call with Colin next Tuesday at 4 work, with your brother on too?',
  'Seller: Yes, that works.',
].join('\n')

function deps(): Deps {
  const url = Deno.env.get('SUPABASE_URL') ?? ''
  const sb = createClient(url, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '', { auth: { persistSession: false } })
  const rpc: Rpc = async (fn, args) => {
    const r = await sb.rpc(fn, args)
    return { data: r.data, error: r.error ? { message: r.error.message } : null }
  }
  const find = (col: 'call_sid' | 'transcript_sid') => async (v: string) => {
    const r = await sb.from('call_recordings').select('call_sid, status, transcript_sid').eq(col, v).maybeSingle()
    return (r.data ?? null) as { call_sid: string; status: string; transcript_sid: string | null } | null
  }
  const apiKey = Deno.env.get('ANTHROPIC_API_KEY') ?? ''
  return {
    rpc,
    twilio: twilioIntelligence({
      accountSid: Deno.env.get('TWILIO_ACCOUNT_SID') ?? '', authToken: Deno.env.get('TWILIO_AUTH_TOKEN') ?? '',
      service: Deno.env.get('CALL_NOTES_SERVICE') ?? 'wpie-call-notes', fetchFn: fetch,
    }),
    summarize: (ctx, words) => {
      if (!apiKey) return Promise.reject(new Error('ANTHROPIC_API_KEY not set'))
      return summarizeCall(ctx, words, { apiKey, fetchFn: fetch, model: Deno.env.get('CALL_NOTES_MODEL') || undefined })
    },
    findByCall: find('call_sid'),
    findByTranscript: find('transcript_sid'),
  }
}

const later = (work: Promise<unknown>) => {
  const safe = work.catch((e) => console.warn(`[call-notes] ${e instanceof Error ? e.message : String(e)}`.slice(0, 300)))
  if (typeof EdgeRuntime !== 'undefined') EdgeRuntime.waitUntil(safe)
  return safe
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return new Response('method not allowed', { status: 405 })
  const base = Deno.env.get('SUPABASE_URL') ?? ''
  const q = new URL(req.url).searchParams
  const raw = await req.text()
  const d = deps()

  if (q.get('event') === 'sweep' || q.get('event') === 'selftest') {
    const ok = await d.rpc('cron_secret_ok', { p_secret: req.headers.get('x-wpie-cron-secret') })
    if (ok.error || ok.data !== true) return new Response('forbidden', { status: 403 })
    if (q.get('event') === 'sweep') return Response.json(await sweep(d))
    // a made-up call through the real summarizer, nothing saved: proves the Claude call and the schema
    const r = await d.summarize(SELFTEST_CONTEXT, SELFTEST_WORDS).catch((e) => ({ error: e instanceof Error ? e.message : String(e) }))
    return Response.json(r)
  }

  if (q.get('event') === 'transcript') {
    let body: Record<string, unknown> = {}
    try { body = JSON.parse(raw) } catch { body = Object.fromEntries(new URLSearchParams(raw)) }
    later(onTranscriptWebhook(body, d))
    return new Response('ok')
  }

  const direction = q.get('d')
  if (direction !== 'out' && direction !== 'in') return new Response('bad request', { status: 400 })
  const params = Object.fromEntries(new URLSearchParams(raw)) as Record<string, string>
  const callbackUrl = `${base}/functions/v1/call-notes?d=${direction}`
  if (!(await validTwilioSignature(Deno.env.get('TWILIO_AUTH_TOKEN') ?? '', callbackUrl, params, req.headers.get('x-twilio-signature')))) {
    return new Response('forbidden', { status: 403 })
  }
  later(onRecording(params, direction, d))
  return new Response('ok')
})
