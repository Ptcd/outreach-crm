// The package email (Colin 2026-10-27: "should send me an email with everything"): when a caller sends a package,
// Colin gets one email with every answer in it and a link to the card to price it. When Colin sets the number, every
// registered phone gets a push so the caller can make the callback. Run by reply-agent every minute; migration 0085.
import type { NotifyDeps } from './notify.ts'
import type { Rpc } from './sending.ts'

export type PackageRow = {
  package: Record<string, unknown> & { id: string; condition?: Record<string, string> | null }
  lead: { id: string; owner_name: string | null; property_address: string | null; municipality: string | null; property_zip: string | null }
  person: string | null
}

export const CONDITION_ITEMS: [string, string][] = [
  ['roof', 'Roof'], ['hvac', 'Furnace and AC'], ['water_heater', 'Water heater'], ['foundation', 'Foundation and basement'],
  ['electrical', 'Electrical'], ['plumbing', 'Plumbing'], ['windows', 'Windows'], ['kitchen_baths', 'Kitchen and baths'],
  ['yard', 'Yard and outside'], ['fix_first', 'Fix first before listing'], ['other', 'Anything else'],
]

const FIELDS: [string, string][] = [
  ['need', 'Need'], ['timeline', 'Timeline'], ['their_number', 'Their number'], ['their_basis', 'How they came up with it'],
  ['on_title', 'On the title / decision makers'], ['owed', 'What is owed'], ['occupancy', 'Who lives there'], ['photos', 'Photos'],
  ['other_buyers', 'Other buyers or agents'], ['concerns', 'What concerns them most'], ['motivation', 'Motivation learned in conversation'],
]

const SOURCE: Record<string, string> = { hot_text: 'hot lead from texting', inbound: 'inbound call', cold_list: 'cold call', other: 'other' }

const esc = (s: string) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')

function whereOf(r: PackageRow): string {
  return [r.lead.property_address, r.lead.municipality, r.lead.property_zip].filter(Boolean).join(', ')
}

export function packageEmail(r: PackageRow, appUrl: string): { subject: string; text: string; html: string } {
  const p = r.package
  const where = whereOf(r)
  const who = r.person || r.lead.owner_name || 'the seller'
  const link = `${appUrl.replace(/\/$/, '')}/lead/${r.lead.id}#package`
  const cb = p.walk_booked_on_call ? 'Walk booked on the call' : p.callback_at
    ? `Callback promised ${new Date(String(p.callback_at)).toLocaleString('en-US', { timeZone: 'America/Chicago', weekday: 'short', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' })} Central`
    : ''
  const subject = `${p.hot ? 'HOT ' : ''}Package: ${who}, ${r.lead.property_address ?? 'no address'}`
  const rows: [string, string][] = []
  rows.push(['Property', where])
  rows.push(['Talked to', `${who}${r.person && r.lead.owner_name && r.person !== r.lead.owner_name ? ` (owner of record: ${r.lead.owner_name})` : ''}`])
  rows.push(['From', `${SOURCE[String(p.source)] ?? String(p.source)}, by ${String(p.created_by ?? 'the team')}`])
  if (cb) rows.push(['Next', cb])
  for (const [k, label] of FIELDS) if (p[k]) rows.push([label, String(p[k])])
  const cond = (p.condition ?? {}) as Record<string, string>
  const condRows = CONDITION_ITEMS.filter(([k]) => cond[k]).map(([k, label]) => [label, cond[k]] as [string, string])
  const text = [
    subject, '',
    ...rows.map(([k, v]) => `${k}: ${v}`), '',
    'Condition, in their words:',
    ...(condRows.length ? condRows.map(([k, v]) => `- ${k}: ${v}`) : ['- (nothing recorded)']), '',
    `Price it on the card: ${link}`,
  ].join('\n')
  const tr = (k: string, v: string) => `<tr><td style="padding:4px 10px 4px 0;color:#52606d;vertical-align:top;white-space:nowrap">${esc(k)}</td><td style="padding:4px 0">${esc(v)}</td></tr>`
  const html = `<div style="font-family:Segoe UI,Arial,sans-serif;font-size:14px;color:#1f2933">
<h2 style="margin:0 0 8px">${esc(subject)}</h2>
<table style="border-collapse:collapse">${rows.map(([k, v]) => tr(k, v)).join('')}</table>
<h3 style="margin:14px 0 6px">Condition, in their words</h3>
<table style="border-collapse:collapse">${condRows.length ? condRows.map(([k, v]) => tr(k, v)).join('') : tr('', '(nothing recorded)')}</table>
<p style="margin-top:16px"><a href="${esc(link)}" style="background:#102a43;color:#fff;padding:9px 14px;border-radius:6px;text-decoration:none">Price it on the card</a></p>
</div>`
  return { subject, text, html }
}

export type PackageSummary = { emailed: number; failed: number; ready_pings: number; number_due_pings: number }

/** Email new packages to Colin; push "Colin's number is ready" for priced ones, and "number needed by" for a callback
 *  coming up (within 3 hours, or past) whose number is not in yet (migration 0112). */
export async function runPackageMail(deps: NotifyDeps, rpc: Rpc, fanOut?: (m: { title: string; body: string; url: string; tag: string }) => Promise<unknown>): Promise<PackageSummary> {
  const s: PackageSummary = { emailed: 0, failed: 0, ready_pings: 0, number_due_pings: 0 }
  if (deps.email && deps.emailTo) {
    const r = await rpc('package_mail_claim', { p_limit: 5 })
    for (const row of ((r.data as PackageRow[] | null) ?? [])) {
      try {
        await deps.email({ to: deps.emailTo, ...packageEmail(row, deps.appUrl) })
        s.emailed++
      } catch (e) {
        s.failed++
        await rpc('package_mail_failed', { p_id: row.package.id, p_error: String(e) })
      }
    }
  }
  if (fanOut) {
    const r = await rpc('package_ready_claim', {})
    for (const x of ((r.data as { lead_id: string; property_address: string | null; callback_at: string | null }[] | null) ?? [])) {
      await fanOut({ title: `Colin's number is ready: ${x.property_address ?? 'a package'}`,
        body: x.callback_at ? 'Make the callback at the time you promised.' : 'Call them back with it.',
        url: `${deps.appUrl.replace(/\/$/, '')}/lead/${x.lead_id}#package`, tag: `package-${x.lead_id}` }).catch(() => null)
      s.ready_pings++
    }
    const due = await rpc('package_number_due_claim', {})
    for (const x of ((due.data as { lead_id: string; property_address: string | null; callback_at: string }[] | null) ?? [])) {
      await fanOut({ title: `Number needed by ${clock(x.callback_at)}: ${x.property_address ?? 'a package'}`,
        body: 'Thalia promised this callback and there is no number yet. Price it on the card, or she calls on time and sets a new callback.',
        url: `${deps.appUrl.replace(/\/$/, '')}/lead/${x.lead_id}#package`, tag: `package-due-${x.lead_id}` }).catch(() => null)
      s.number_due_pings++
    }
  }
  return s
}

/** "2:00 PM" today, "Thu 2:00 PM" another day, "2:00 PM (late)" once past; Central time. */
export function clock(at: string, now = new Date()): string {
  const d = new Date(at)
  const tz = 'America/Chicago'
  const day = (x: Date) => x.toLocaleDateString('en-US', { timeZone: tz })
  const t = d.toLocaleTimeString('en-US', { timeZone: tz, hour: 'numeric', minute: '2-digit' })
  const w = day(d) === day(now) ? t : `${d.toLocaleDateString('en-US', { timeZone: tz, weekday: 'short' })} ${t}`
  return d < now ? `${w} (late)` : w
}
