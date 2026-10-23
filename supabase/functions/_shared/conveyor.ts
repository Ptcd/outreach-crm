// The conveyor's loop behind the conveyor Edge Function (pg_cron, every 15 minutes). No Deno globals,
// so tests/conveyor.test.ts runs it against the real migrations on PGlite with a fake Twilio.
// Every decision about a stop is made in Postgres (belt_claim_text, belt_sweep_missed, belt_canary,
// belt_health_check, migration 0031); this file only moves texts to Twilio and records what happened.
//   1. due text stops -> belt_claim_text: a queued belt text (switch on) goes out, or a draft waits for
//      Colin's tap (switch off), or the stop slides / is skipped. A live send is checked once more by
//      guardDraft (no price, offer or business name) before Twilio is called.
//   2. missed stops (due and not logged by end of day) are swept.
//   3. the daily canary (once a day after 7 AM Central), then the health heartbeat.
import { guardDraft } from './replyGuard.ts'
import { classifyFailure, type Rpc, type TwilioPort } from './sending.ts'

export interface ConveyorSummary {
  mode: 'live' | 'dry'
  texts: { sent: number; dry_sent: number; awaiting_approval: number; slid: number; skipped: number; failed: number; uncertain: number; refused: string[] }
  swept: number
  canary: { ok: boolean; why: string | null } | null
  health: { ok: boolean; summary: string }
  errors: string[]
}

export async function runConveyor(opts: {
  rpc: Rpc
  live: boolean
  twilio: TwilioPort | null
  now?: () => Date
  canary?: boolean
  companyName?: string
  maxTexts?: number
}): Promise<ConveyorSummary> {
  const now = opts.now ?? (() => new Date())
  const live = opts.live && opts.twilio != null
  const s: ConveyorSummary = { mode: live ? 'live' : 'dry', texts: { sent: 0, dry_sent: 0, awaiting_approval: 0, slid: 0, skipped: 0, failed: 0, uncertain: 0, refused: [] },
    swept: 0, canary: null, health: { ok: false, summary: 'not checked' }, errors: [] }
  const err = (where: string, e: unknown) => s.errors.push(`${where}: ${String(e instanceof Error ? e.message : e).slice(0, 200)}`)

  // 1. text stops whose time has come
  const due = await opts.rpc('belt_due_texts', { p_now: now().toISOString(), p_limit: opts.maxTexts ?? 40 })
  if (due.error) err('due', due.error.message)
  for (const l of ((due.data as { id: string }[] | null) ?? [])) {
    const c = await opts.rpc('belt_claim_text_guarded', { p_lead_id: l.id, p_dry: !live, p_force: false, p_now: now().toISOString() })
    if (c.error) { err(`claim ${l.id}`, c.error.message); continue }
    const j = c.data as { outcome: string; reason?: string; id?: string; to?: string; from?: string | null; body?: string }
    if (!j) continue
    if (j.outcome === 'send' && live && opts.twilio && j.id && j.to && j.body) {
      // the last word on the wording: never a price, an offer or the business name
      const g = guardDraft(j.body, { companyName: opts.companyName || 'Merrill Holdings', maxChars: 480 })
      const blocked = g.violations.filter((v) => v === 'price_or_offer' || v === 'names_company' || v === 'mentions_postcard')
      if (blocked.length) {
        await opts.rpc('reply_record_result', { p_id: j.id, p_status: 'failed', p_sid: null, p_error_code: 'guard',
          p_reason: `not sent: the text has ${blocked.join(', ')}`, p_now: now().toISOString() })
        s.texts.failed += 1
        s.texts.refused.push(`${j.id}: ${blocked.join(', ')}`)
        continue
      }
      let res
      try {
        res = await opts.twilio.send(j.to, j.body, j.from ?? null)
      } catch (e) {
        res = { ok: false as const, httpStatus: null, code: null, message: String(e).slice(0, 300) }
      }
      const status = res.ok ? 'sent' : classifyFailure(res)
      const rec = await opts.rpc('reply_record_result', { p_id: j.id, p_status: status, p_sid: res.ok ? res.sid : null,
        p_error_code: res.ok ? null : res.code,
        p_reason: res.ok ? null : `${res.httpStatus ?? 'no answer'} ${res.code ?? ''} ${res.message}`.trim().slice(0, 300),
        p_now: now().toISOString() })
      if (rec.error) err(`record ${j.id}`, rec.error.message)
      s.texts[status] += 1
    } else if (j.outcome === 'send') {
      s.texts.refused.push(`${j.id}: claimed for a live send with no Twilio`)
    } else if (j.outcome in s.texts) {
      (s.texts as unknown as Record<string, number>)[j.outcome] += 1
    } else if (j.outcome === 'refused') {
      s.texts.refused.push(`${l.id}: ${j.reason ?? ''}`)
    }
  }

  // 2. stops nobody logged
  const sw = await opts.rpc('belt_sweep_missed', { p_now: now().toISOString() })
  if (sw.error) err('sweep', sw.error.message)
  else s.swept = Number((sw.data as { swept?: number } | null)?.swept ?? 0)

  // 3. the daily canary, then the heartbeat
  if (opts.canary !== false) {
    const c = await opts.rpc('belt_canary_if_due', { p_now: now().toISOString() })
    if (c.error) err('canary', c.error.message)
    else if (c.data) s.canary = { ok: !!(c.data as { ok: boolean }).ok, why: (c.data as { why: string | null }).why ?? null }
  }
  const h = await opts.rpc('belt_health_check', { p_now: now().toISOString(), p_extra: { texts: s.texts, swept: s.swept, mode: s.mode, errors: s.errors } })
  if (h.error) err('health', h.error.message)
  else s.health = { ok: !!(h.data as { ok: boolean }).ok, summary: String((h.data as { summary: string }).summary ?? '') }
  return s
}
