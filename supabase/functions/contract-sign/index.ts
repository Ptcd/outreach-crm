// contract-sign: the seller's signing page. No login: the link token is the credential and only its
// SHA-256 is stored. open -> what the page shows (and an "opened" audit event); sign -> consent,
// the condition report when it is needed, the signature; the last signature seals the PDF and emails
// everyone their copy. The actions are in _shared/contractApi.ts.
import { handleContractSign } from '../_shared/contractApi.ts'
import { CORS, contractPorts, who } from '../_shared/contractDeno.ts'

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS })
  const json = (body: unknown, status = 200) => Response.json(body, { status, headers: CORS })
  if (req.method !== 'POST') return json({ ok: false, reason: 'bad request' }, 405)
  const body = await req.json().catch(() => ({}))
  const r = await handleContractSign(contractPorts(), body, who(req))
  return json(r.body, r.status)
})
