// WhatsApp missed-call alerts straight through Meta's Cloud API (Colin's build spec 2026-10-30; the Meta side is done:
// app "Merrill Holdings WPIE", system user wpie-server, template missed_call_alert, test sender until the production
// number lands). Replaces the Twilio-sandbox route through the forwarding app when META_WHATSAPP_TOKEN is set.
//
// Config (Supabase secrets): META_WHATSAPP_TOKEN (the system user's permanent token; never logged, never committed),
// META_WA_PHONE_NUMBER_ID (test 1360870210447247 until production), META_WABA_ID (2330456737707324, for the template
// status poll), META_WA_TEMPLATE (missed_call_alert), META_GRAPH_VERSION (v21.0).
//
// Every send is gated on the template being APPROVED: Meta refuses a PENDING template anyway, so we poll
// GET /{WABA}/message_templates?name=... (cached 10 minutes through the database) and skip, not fail, until it clears.
import type { WhatsAppSend } from './missedCalls.ts'

type Rpc = (fn: string, args: Record<string, unknown>) => Promise<{ data: unknown; error: { message: string } | null }>
type Get = (name: string) => string | undefined

export interface MetaConfig { token: string; phoneNumberId: string; wabaId: string; template: string; version: string }

export function metaConfig(get: Get): MetaConfig | null {
  const token = (get('META_WHATSAPP_TOKEN') ?? '').trim()
  const phoneNumberId = (get('META_WA_PHONE_NUMBER_ID') ?? '').trim()
  if (!token || !phoneNumberId) return null
  return { token, phoneNumberId, wabaId: (get('META_WABA_ID') ?? '').trim(), template: (get('META_WA_TEMPLATE') ?? '').trim() || 'missed_call_alert',
    version: (get('META_GRAPH_VERSION') ?? '').trim() || 'v21.0' }
}

/** The template's status, from the database cache when it is under 10 minutes old, else from Meta (and cached). */
export async function templateStatus(cfg: MetaConfig, rpc: Rpc, fetchFn: typeof fetch, now = () => new Date()): Promise<{ status: string; source: 'cache' | 'meta' | 'error'; error?: string }> {
  const cached = await rpc('meta_wa_template_get', { p_name: cfg.template })
  const c = (cached.data ?? null) as { status?: string; checked_at?: string } | null
  if (c?.status && c.checked_at && now().getTime() - new Date(c.checked_at).getTime() < 10 * 60_000) return { status: c.status, source: 'cache' }
  if (!cfg.wabaId) return { status: c?.status ?? 'UNKNOWN', source: 'error', error: 'META_WABA_ID not set' }
  try {
    const res = await fetchFn(`https://graph.facebook.com/${cfg.version}/${cfg.wabaId}/message_templates?name=${encodeURIComponent(cfg.template)}&fields=name,status,language`,
      { headers: { authorization: `Bearer ${cfg.token}` } })
    const j = (await res.json().catch(() => ({}))) as { data?: { name: string; status: string; language?: string }[]; error?: { message?: string } }
    if (!res.ok) return { status: c?.status ?? 'UNKNOWN', source: 'error', error: `meta ${res.status}: ${j.error?.message ?? 'error'}` }
    const row = (j.data ?? []).find((t) => t.name === cfg.template && (!t.language || t.language === 'en_US')) ?? (j.data ?? [])[0]
    const status = row?.status ?? 'MISSING'
    await rpc('meta_wa_template_set', { p_name: cfg.template, p_status: status })
    return { status, source: 'meta' }
  } catch (e) {
    return { status: c?.status ?? 'UNKNOWN', source: 'error', error: String(e).slice(0, 160) }
  }
}

/** The request body Meta expects for one alert: caller (name or number), property, time. */
export function templatePayload(cfg: MetaConfig, to: string, vars: Record<string, string>) {
  const digits = to.replace(/\D/g, '')
  return {
    messaging_product: 'whatsapp', to: digits, type: 'template',
    template: { name: cfg.template, language: { code: 'en_US' },
      components: [{ type: 'body', parameters: [
        { type: 'text', text: clean(vars['1'] || 'unknown caller') },
        { type: 'text', text: clean(vars['2'] || 'unknown property') },
        { type: 'text', text: clean(vars['3'] || 'just now') } ] }] },
  }
}
// Meta refuses newlines, tabs and 4+ spaces inside a parameter
const clean = (s: string) => s.replace(/[\r\n\t]+/g, ' ').replace(/ {2,}/g, ' ').trim().slice(0, 1000)

/** The WhatsApp dependency for runMissedCallAlerts, or null when the token or sender id is not set. */
export function metaWhatsAppSender(get: Get, fetchFn: typeof fetch, rpc: Rpc): WhatsAppSend | null {
  const cfg = metaConfig(get)
  if (!cfg) return null
  return async (to, _text, vars) => {
    const gate = await templateStatus(cfg, rpc, fetchFn)
    if (gate.status !== 'APPROVED') return { ok: false, skipped: true, error: `template ${cfg.template} is ${gate.status}${gate.error ? ` (${gate.error})` : ''}` }
    try {
      const res = await fetchFn(`https://graph.facebook.com/${cfg.version}/${cfg.phoneNumberId}/messages`,
        { method: 'POST', headers: { authorization: `Bearer ${cfg.token}`, 'content-type': 'application/json' }, body: JSON.stringify(templatePayload(cfg, to, vars)) })
      const j = (await res.json().catch(() => ({}))) as { messages?: { id: string }[]; error?: { message?: string; code?: number } }
      if (!res.ok) return { ok: false, error: `meta ${res.status}${j.error?.code ? ` #${j.error.code}` : ''}: ${j.error?.message ?? 'error'}` }
      return { ok: true, id: j.messages?.[0]?.id ?? null }
    } catch (e) {
      return { ok: false, error: `meta: ${String(e).slice(0, 160)}` }
    }
  }
}
