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
    appUrl: Deno.env.get('NOTIFY_APP_URL') || 'https://deals.junkcarsmequon.com',
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
      signedUrl: async (path, seconds) => {
        const r = await bucket().createSignedUrl(path, seconds)
        if (r.error || !r.data) throw new Error(`storage: ${r.error?.message ?? 'no url'}`)
        return r.data.signedUrl
      },
    },
    notify: async (m) => { await notifyEveryone(deps, m) },
  }
}

/** The caller's IP and device, for the audit trail. */
export function who(req: Request): { ip: string | null; ua: string | null } {
  const fwd = req.headers.get('x-forwarded-for') ?? ''
  return { ip: fwd.split(',')[0]?.trim() || req.headers.get('x-real-ip') || null, ua: (req.headers.get('user-agent') ?? '').slice(0, 300) || null }
}
