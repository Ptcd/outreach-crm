// DEV ONLY: the Send offer flow end to end on this computer, nothing real touched.
//
//   npm run e2e:offer            # this server (127.0.0.1:5198) + the app with sample data (localhost:5199)
//   open http://localhost:5199/lead/L1
//
// The real screens (the card's Send offer panel, the seller's signing page) talk to the real server logic
// (supabase/functions/_shared/contractApi.ts) on a throwaway database with every migration applied (PGlite, in
// memory). Storage is a map, and email is captured instead of sent: read it at http://127.0.0.1:5198/e2e/mails.
// The login is pretend: everyone is Colin's shared login, as in production; the phone picker decides who sends.
import http from 'node:http'
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { PGlite } from '@electric-sql/pglite'
import * as PDFLib from 'pdf-lib'
import { SUPABASE_STUB } from '../tests/supabaseStub'
import { b64ToBytes, type PdfLib } from '../supabase/functions/_shared/contractPdf'
import { WB11_B64 } from '../supabase/functions/_shared/wb11Template.generated'
import { handleContract, handleContractSign } from '../supabase/functions/_shared/contractApi'
import type { ContractPorts, OfferContext, OutMail } from '../supabase/functions/_shared/contracts'
import type { Rpc } from '../supabase/functions/_shared/sending'

const here = path.dirname(fileURLToPath(import.meta.url))
const PORT = Number(process.env.E2E_PORT || 5198)
const APP = process.env.E2E_APP_URL || 'http://localhost:5199'
const SELF = `http://127.0.0.1:${PORT}`
const LEAD = '00000000-0000-0000-0000-0000000000e2'
const COLIN = 'owner@example.com'

const dir = path.join(here, '..', 'supabase', 'migrations')
const db = new PGlite()
await db.exec(SUPABASE_STUB)
await db.exec(readdirSync(dir).filter((f) => f.endsWith('.sql')).sort().map((f) => readFileSync(path.join(dir, f), 'utf8')).join('\n'))

const files = new Map<string, Uint8Array>()
const mails: (OutMail & { at: string })[] = []

async function seed() {
  files.clear()
  mails.length = 0
  await db.exec(`
    truncate public.contracts, public.tasks, public.deals, public.messages, public.leads cascade;
    insert into public.team_members (email, role, person, display_name) values ('${COLIN}', 'owner', 'colin', 'Colin') on conflict do nothing;
    update public.offer_standards set buyer_email = '${COLIN}', signature_png = null where id = 1;
    insert into public.leads (id, wpie_owner_id, owner_name, property_address, municipality, county, stage, mailing_street, mailing_city, mailing_state, mailing_zip)
    values ('${LEAD}', 9001, 'DALE NOVAK', '2847 N Burleigh St', 'Milwaukee', 'Milwaukee', 'colin_call', '2847 N Burleigh St', 'Milwaukee', 'WI', '53210');
    insert into public.contacts (lead_id, kind, value, value_normalized, person_name, source) values ('${LEAD}', 'phone', '4145550177', '4145550177', 'DALE NOVAK', 'e2e');
  `)
}
await seed()

/** A database function called the way the Edge Functions call it. */
const rpc: Rpc = async (fn, args) => {
  const names = Object.keys(args)
  try {
    await db.exec('set role service_role')
    const r = await db.query<{ r: unknown }>(`select public.${fn}(${names.map((n, i) => `${n} => $${i + 1}`).join(', ')}) as r`,
      names.map((n) => { const v = args[n]; return v !== null && typeof v === 'object' ? JSON.stringify(v) : v }))
    return { data: r.rows[0]?.r ?? null, error: null }
  } catch (e) {
    return { data: null, error: { message: String(e) } }
  } finally {
    await db.exec('reset role')
  }
}
/** A database function called the way the browser calls it: as the signed-in person. */
async function asColin(fn: string, args: Record<string, unknown>) {
  const names = Object.keys(args)
  await db.query(`select set_config('request.jwt.claims', $1, false)`, [JSON.stringify({ sub: '00000000-0000-0000-0000-0000000000c1', email: COLIN })])
  await db.exec('set role authenticated')
  try {
    const r = await db.query<{ r: unknown }>(`select public.${fn}(${names.map((n, i) => `${n} => $${i + 1}`).join(', ')}) as r`,
      names.map((n) => { const v = args[n]; return v !== null && typeof v === 'object' ? JSON.stringify(v) : v }))
    return { data: r.rows[0]?.r ?? null, error: null }
  } catch (e) {
    return { data: null, error: { message: String(e) } }
  } finally {
    await db.exec('reset role')
    await db.query(`select set_config('request.jwt.claims', '', false)`)
  }
}

const ports = (): ContractPorts => ({
  rpc, lib: PDFLib as unknown as PdfLib, template: b64ToBytes(WB11_B64), appUrl: APP,
  storage: {
    put: async (p, bytes) => { files.set(p, bytes) },
    get: async (p) => { const b = files.get(p); if (!b) throw new Error(`missing ${p}`); return b },
    signedUrl: async (p, _s, downloadAs) => `${SELF}/storage/${p}${downloadAs ? `?download=${encodeURIComponent(downloadAs)}` : ''}`,
  },
  notify: async (m) => { console.log(`[alert to the team] ${m.title}: ${m.body}`) },
  mail: async (m) => {
    if (/bounce/i.test(m.to)) throw new Error('550 no such mailbox')
    mails.push({ ...m, at: new Date().toISOString() })
    console.log(`[email] to ${m.to}: ${m.subject}${m.attachments?.length ? ` (+${m.attachments.map((a) => `${a.filename}, ${Math.round(a.bytes.length / 1024)} KB`).join('; ')})` : ''}`)
  },
})

const CORS = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': '*', 'Access-Control-Allow-Methods': 'GET, POST, OPTIONS' }
const esc = (s: string) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')

http.createServer(async (req, res) => {
  const url = new URL(req.url ?? '/', SELF)
  const send = (status: number, body: unknown, type = 'application/json') => {
    res.writeHead(status, { ...CORS, 'Content-Type': type })
    res.end(type === 'application/json' ? JSON.stringify(body) : (body as string | Uint8Array))
  }
  if (req.method === 'OPTIONS') return send(204, '')
  const chunks: Buffer[] = []
  for await (const c of req) chunks.push(c as Buffer)
  const body = chunks.length ? JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}') as Record<string, unknown> : {}
  const who = { ip: req.socket.remoteAddress ?? null, ua: String(req.headers['user-agent'] ?? '').slice(0, 300) }
  try {
    const p = url.pathname
    if (p === '/functions/v1/contract') {
      const ctx = (await rpc('offer_context', { p_lead_id: LEAD, p_email: COLIN })).data as OfferContext
      const r = await handleContract(ports(), ctx, { ...body, lead_id: LEAD }, { userId: null, ...who })
      return send(r.status, r.body)
    }
    if (p === '/functions/v1/contract-sign') {
      const r = await handleContractSign(ports(), body, who)
      return send(r.status, r.body)
    }
    if (p === '/rpc/offer_setup') return send(200, await asColin('offer_setup', { p_lead_id: LEAD }))
    if (p === '/rpc/offer_standards_set') return send(200, await asColin('offer_standards_set', { p: body.p ?? {} }))
    if (p === '/rpc/contact_add') {
      return send(200, await asColin('contact_add', { p_lead_id: LEAD, p_kind: body.kind, p_value: body.value, p_person_name: body.person_name ?? null, p_note: body.note ?? null }))
    }
    if (p === '/e2e/contracts') {
      const r = await db.query<{ r: unknown }>(`select coalesce(jsonb_agg(to_jsonb(c) || jsonb_build_object('contract_signers',
        (select coalesce(jsonb_agg(to_jsonb(s) - 'token_hash' order by s.position), '[]'::jsonb) from public.contract_signers s where s.contract_id = c.id))
        order by c.created_at desc), '[]'::jsonb) as r from public.contracts c`)
      return send(200, r.rows[0].r)
    }
    if (p === '/e2e/contacts') {
      return send(200, (await db.query(`select kind, value, person_name, note from public.contacts where lead_id = $1 order by created_at`, [LEAD])).rows)
    }
    if (p === '/e2e/state') {
      const q = async (sql: string) => (await db.query(sql)).rows
      return send(200, {
        contracts: await q(`select id, status, created_at, signed_at, terms->>'price' as price, terms->>'closing' as closing, final_path from public.contracts order by created_at`),
        signers: await q(`select name, email, emailed_to, emailed_at, opened_at, signed_at, signed_name, expires_at from public.contract_signers order by position`),
        events: await q(`select at, actor, kind, detail from public.contract_events order by at, id`),
        timeline: await q(`select sent_at, body from public.messages where status = 'contract' order by sent_at, id`),
        lead: await q(`select stage from public.leads`), deals: await q(`select status, colin_offer from public.deals`),
        tasks: await q(`select title, owner from public.tasks`).catch(() => []),
      })
    }
    if (p === '/e2e/colin-number') {      // Colin types his number on the card (or clears it)
      await db.query(`select set_config('request.jwt.claims', $1, false)`, [JSON.stringify({ email: COLIN })])
      await db.exec(`delete from public.deals where lead_id = '${LEAD}'`)
      if (Number(body.n) > 0) await db.exec(`insert into public.deals (lead_id, status, colin_offer) values ('${LEAD}', 'offer', ${Number(body.n)})`)
      await db.query(`select set_config('request.jwt.claims', '', false)`)
      return send(200, { ok: true })
    }
    if (p === '/e2e/reset') { await seed(); return send(200, { ok: true }) }
    if (p === '/e2e/mails') {
      if (url.searchParams.get('json') != null) {
        return send(200, mails.map((m, i) => ({ i, at: m.at, to: m.to, subject: m.subject, fromName: m.fromName, replyTo: m.replyTo, text: m.text,
          attachments: (m.attachments ?? []).map((a) => ({ filename: a.filename, bytes: a.bytes.length })) })))
      }
      return send(200, `<body style="font-family:system-ui;max-width:760px;margin:24px auto;padding:0 12px"><h2>Captured email (${mails.length})</h2>${mails.map((m, i) => `
        <div style="border:1px solid #ccc;border-radius:10px;margin:12px 0;padding:12px">
          <div style="font-size:13px;color:#555">#${i} - ${esc(m.at)}<br>From: ${esc(m.fromName ?? 'WPIE')} - To: <b>${esc(m.to)}</b> - Reply-To: ${esc(m.replyTo ?? '')}</div>
          <div style="font-weight:600;margin:6px 0">${esc(m.subject)}</div>
          ${(m.attachments ?? []).map((a, j) => `<a href="/e2e/attachment/${i}/${j}">${esc(a.filename)} (${Math.round(a.bytes.length / 1024)} KB)</a>`).join(' ')}
          <div style="border-top:1px solid #eee;margin-top:8px;padding-top:8px">${m.html}</div>
        </div>`).join('') || '<p>None yet.</p>'}</body>`, 'text/html; charset=utf-8')
    }
    const att = p.match(/^\/e2e\/attachment\/(\d+)\/(\d+)$/)
    if (att) {
      const a = mails[Number(att[1])]?.attachments?.[Number(att[2])]
      return a ? send(200, a.bytes, a.contentType) : send(404, 'no such attachment', 'text/plain')
    }
    if (p.startsWith('/storage/')) {
      const key = decodeURIComponent(p.slice('/storage/'.length))
      const b = files.get(key)
      if (!b) return send(404, 'not found', 'text/plain')
      const dl = url.searchParams.get('download')
      res.writeHead(200, { ...CORS, 'Content-Type': key.endsWith('.png') ? 'image/png' : 'application/pdf',
        ...(dl ? { 'Content-Disposition': `attachment; filename="${dl.replace(/"/g, '')}"` } : {}) })
      return res.end(b)
    }
    return send(404, { ok: false, reason: 'no such route' })
  } catch (e) {
    console.error(e)
    return send(500, { ok: false, reason: String(e instanceof Error ? e.message : e) })
  }
}).listen(PORT, '127.0.0.1', () => {
  console.log(`Send offer rig: ${SELF}  (email: ${SELF}/e2e/mails, state: ${SELF}/e2e/state)\nThe card: ${APP}/lead/L1`)
})
