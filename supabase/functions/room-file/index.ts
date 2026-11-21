// room-file: a signed-in person puts a file in the room or opens one (0264). Called with the user's token. This file
// only works out who is asking (the login -> who they are in the room); what they may have is the database's to say
// (_shared/roomFiles.ts, room_file_new, room_file_for). The bucket is private; links last 10 minutes.
//   { action: 'upload', name, mime, size }  -> { ok, file_id, path, token, upload_url }   then put the bytes, then name file_id on the line
//   { action: 'link', file_id }             -> { ok, url, name, mime, size }
import { createClient } from 'npm:@supabase/supabase-js@2.56.1'
import { ROOM_LINK_SECONDS, roomFileLink, roomFileUpload, type RoomFilePorts } from '../_shared/roomFiles.ts'

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS })
  const json = (body: unknown, status = 200) => Response.json(body, { status, headers: CORS })
  const url = Deno.env.get('SUPABASE_URL') ?? ''
  const asUser = createClient(url, Deno.env.get('SUPABASE_ANON_KEY') ?? '', {
    global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } }, auth: { persistSession: false } })
  const u = await asUser.auth.getUser()
  const myEmail = (u.data.user?.email ?? '').toLowerCase()
  if (!myEmail) return json({ ok: false, reason: 'Sign in again.' }, 401)
  const sb = createClient(url, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '', { auth: { persistSession: false } })
  const ports: RoomFilePorts = {
    rpc: async (fn, args) => {
      const r = await sb.rpc(fn, args)
      if (r.error) throw new Error(r.error.message)
      return r.data
    },
    uploadUrl: async (path) => {
      const r = await sb.storage.from('room').createSignedUploadUrl(path, { upsert: true })
      return r.error || !r.data ? null : { url: r.data.signedUrl, token: r.data.token }
    },
    link: async (path) => {
      const r = await sb.storage.from('room').createSignedUrl(path, ROOM_LINK_SECONDS)
      return r.error || !r.data ? null : r.data.signedUrl
    },
  }
  try {
    const who = await ports.rpc('room_who_email', { p_email: myEmail }) as string | null
    const body = await req.json().catch(() => ({})) as Record<string, unknown>
    if (body.action === 'upload') return json(await roomFileUpload(ports, who, body))
    if (body.action === 'link') return json(await roomFileLink(ports, who, body.file_id))
    return json({ ok: false, reason: 'action is upload or link' }, 400)
  } catch (_e) {
    return json({ ok: false, reason: 'Something went wrong. Try again in a minute.' }, 500)
  }
})
