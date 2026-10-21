// contract-sign: the seller's signing page. No login: the link token is the credential and only its
// SHA-256 is stored. open -> what the page shows (and an "opened" audit event); sign -> consent,
// the condition report when it is needed, the signature; the last signature seals the PDF.
import { openForSigner, signAsSeller } from '../_shared/contracts.ts'
import { CORS, contractPorts, who } from '../_shared/contractDeno.ts'

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS })
  const json = (body: unknown, status = 200) => Response.json(body, { status, headers: CORS })
  if (req.method !== 'POST') return json({ ok: false, reason: 'bad request' }, 405)
  const body = await req.json().catch(() => ({}))
  const token = String(body.token ?? '')
  const ports = contractPorts()
  const { ip, ua } = who(req)
  try {
    if (body.action === 'open') return json(await openForSigner(ports, token, ip, ua))
    if (body.action === 'sign') {
      return json(await signAsSeller(ports, { token, consent: body.consent === true, name: String(body.name ?? ''),
        signature: body.signature ?? null, recr: body.recr ?? null, ip, ua }))
    }
    return json({ ok: false, reason: 'bad request' }, 400)
  } catch (e) {
    return json({ ok: false, reason: `Something went wrong: ${String(e instanceof Error ? e.message : e).slice(0, 200)}` }, 500)
  }
})
