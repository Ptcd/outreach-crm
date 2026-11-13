// Wiring for the contract Edge Functions (Deno): service-role database calls, the private
// "contracts" storage bucket, pdf-lib from npm, and the push/email notifier.
import { createClient } from 'npm:@supabase/supabase-js@2.56.1'
import * as PDFLib from 'npm:pdf-lib@1.17.1'
import type { ContractPorts } from './contracts.ts'
import type { PdfLib } from './contractPdf.ts'
import { b64ToBytes } from './contractPdf.ts'
import { WB11_B64 } from './wb11Template.generated.ts'
import { notifyEveryone } from './notify.ts'
import { notifyDeps } from './notifyDeno.ts'
import type { Rpc } from './sending.ts'
import { sendMail } from './smtp.ts'

export const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

export function serviceClient() {
  return createClient(Deno.env.get('SUPABASE_URL') ?? '', Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '', { auth: { persistSession: false } })
}

export function contractPorts(): ContractPorts {
  const sb = serviceClient()
  const rpc: Rpc = async (fn, args) => {
    const r = await sb.rpc(fn, args)
    return { data: r.data, error: r.error ? { message: r.error.message } : null }
  }
  const bucket = () => sb.storage.from('contracts')
  const deps = notifyDeps(sb, rpc)
  return {
    rpc,
    lib: PDFLib as unknown as PdfLib,
    template: b64ToBytes(WB11_B64),
    // sellers sign at the company's own address (welivewi.com, bought 2026-11-12); the team's alert links stay on the
    // address they are signed in on
    appUrl: Deno.env.get('OFFER_APP_URL') || 'https://offers.welivewi.com',
    teamUrl: Deno.env.get('NOTIFY_APP_URL') || 'https://deals.junkcarsmequon.com',
    storage: {
      put: async (path, bytes, contentType) => {
        const r = await bucket().upload(path, bytes, { contentType, upsert: false })
        if (r.error) throw new Error(`storage: ${r.error.message}`)
      },
      get: async (path) => {
        const r = await bucket().download(path)
        if (r.error || !r.data) throw new Error(`storage: ${r.error?.message ?? 'missing'}`)
        return new Uint8Array(await r.data.arrayBuffer())
      },
      signedUrl: async (path, seconds, downloadAs) => {
        const r = await bucket().createSignedUrl(path, seconds, downloadAs ? { download: downloadAs } : undefined)
        if (r.error || !r.data) throw new Error(`storage: ${r.error?.message ?? 'no url'}`)
        return r.data.signedUrl
      },
    },
    notify: async (m) => { await notifyEveryone(deps, m) },
    // Offers go out from the company mailbox at welivewi.com when it is set up (tools\set_offer_email.ps1 puts
    // OFFER_SMTP_* in the function secrets; Colin types the password, nobody else sees it). Until then, or if that
    // mailbox refuses, they go out from the Gmail sender the app's other emails use, so an offer is never stuck.
    mail: async (m) => {
      const send = async (host: string, user: string, pass: string, from: string) => {
        const conn = await Deno.connectTls({ hostname: host, port: 465 })
        await sendMail(conn, { user, pass }, { from, ...m })
      }
      const ou = Deno.env.get('OFFER_SMTP_USER') ?? ''
      const op = Deno.env.get('OFFER_SMTP_PASSWORD') ?? ''
      let fallback = ou && !op ? 'the company mailbox has no password saved yet' : undefined
      if (ou && op) {
        const from = Deno.env.get('OFFER_SMTP_FROM') || ou
        try {
          await send(Deno.env.get('OFFER_SMTP_HOST') || 'smtp.titan.email', ou, op, from)
          return { from }
        } catch (e) {
          fallback = `the company mailbox refused: ${String(e instanceof Error ? e.message : e).slice(0, 160)}`
          console.error(fallback)
        }
      }
      const user = Deno.env.get('SMTP_USER') ?? ''
      const pass = Deno.env.get('SMTP_PASSWORD') ?? ''
      if (!user || !pass) throw new Error('email is not set up (Colin runs tools/set_supabase_email.ps1 once)')
      const from = Deno.env.get('SMTP_FROM') || user
      await send(Deno.env.get('SMTP_HOST') || 'smtp.gmail.com', user, pass, from)
      return { from, fallback }
    },
  }
}

/** The caller's IP and device, for the audit trail. */
export function who(req: Request): { ip: string | null; ua: string | null } {
  const fwd = req.headers.get('x-forwarded-for') ?? ''
  return { ip: fwd.split(',')[0]?.trim() || req.headers.get('x-real-ip') || null, ua: (req.headers.get('user-agent') ?? '').slice(0, 300) || null }
}
