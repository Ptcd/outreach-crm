// Files and images in the room (0264; Colin 2026-11-20: "Make it so files and images can be uploaded in the chat").
// The bucket is private and nobody reads it directly. Two ways in: a signed-in person through the room-file function,
// an agent through the door. Both come here, and the database decides who may have what (room_file_new,
// room_file_for): a caller only the files on their own lines and on lines written to them by name.
// Pure: the database and the storage are passed in, so the rules are tested without either.

type Json = Record<string, unknown>
export const ROOM_LINK_SECONDS = 600
export const ROOM_MAX_BYTES = 25 * 1024 * 1024

export interface RoomFilePorts {
  /** a database function, as the service role */
  rpc(fn: string, args: Json): Promise<unknown>
  /** a one-time link to put a file at this path */
  uploadUrl(path: string): Promise<{ url: string; token: string } | null>
  /** a link to read the file at this path, good for ROOM_LINK_SECONDS */
  link(path: string): Promise<string | null>
}

const str = (v: unknown) => (typeof v === 'string' && v.trim() ? v.trim() : null)
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

/** A place for a file: the id to name on the line, and where to put the bytes. `who` is who is asking, already
 * established by the caller of this function (a login's email, an agent's key), never taken from the request. */
export async function roomFileUpload(ports: RoomFilePorts, who: string | null, x: { name?: unknown; mime?: unknown; size?: unknown }): Promise<Json> {
  if (!who) return { ok: false, reason: 'you are not in the room' }
  const name = str(x.name)
  if (!name) return { ok: false, reason: 'the file needs a name' }
  const size = typeof x.size === 'number' && Number.isFinite(x.size) && x.size >= 0 ? Math.floor(x.size) : null
  if (size !== null && size > ROOM_MAX_BYTES) return { ok: false, reason: 'too big: a file in the room is 25 MB at most' }
  const made = await ports.rpc('room_file_new', { p_who: who, p_name: name, p_mime: str(x.mime), p_size: size }) as Json | null
  if (!made || made.ok !== true) return { ok: false, reason: str(made?.reason) ?? 'could not make a place for the file' }
  const up = await ports.uploadUrl(String(made.path))
  if (!up) return { ok: false, reason: 'could not make an upload link: try again' }
  // the path is where the bytes go; it is the uploader's own and tells them nothing they did not already have
  return { ok: true, file_id: made.file_id, name: made.name, path: made.path, upload_url: up.url, token: up.token }
}

/** A link to read one file, when this reader may have it. */
export async function roomFileLink(ports: RoomFilePorts, who: string | null, fileId: unknown): Promise<Json> {
  if (!who) return { ok: false, reason: 'you are not in the room' }
  const id = str(fileId)
  if (!id || !UUID.test(id)) return { ok: false, reason: 'no such file' }
  const f = await ports.rpc('room_file_for', { p_file_id: id, p_who: who }) as Json | null
  if (!f || f.ok !== true) return { ok: false, reason: 'no such file' }     // not yours and not there read the same
  const url = await ports.link(String(f.path))
  if (!url) return { ok: false, reason: 'the file is not there yet: it may still be uploading' }
  return { ok: true, file_id: f.file_id, name: f.name, mime: f.mime ?? null, size: f.size ?? null, url, expires_in_seconds: ROOM_LINK_SECONDS }
}

/** The lines an agent reads, with a link on each file in place of nothing (the database gives id, name, type, size). */
export async function withFileLinks(ports: RoomFilePorts, who: string | null, read: unknown): Promise<unknown> {
  const r = read as Json | null
  if (!r || typeof r !== 'object') return read
  for (const key of ['lines', 'last_lines']) {
    const lines = r[key]
    if (!Array.isArray(lines)) continue
    for (const line of lines as Json[]) {
      const files = line.files
      if (!Array.isArray(files) || files.length === 0) continue
      const out: Json[] = []
      for (const f of files as Json[]) {
        const l = await roomFileLink(ports, who, f.id)
        out.push(l.ok === true ? { id: f.id, name: f.name, mime: f.mime ?? null, size: f.size ?? null, url: l.url, expires_in_seconds: ROOM_LINK_SECONDS }
                               : { id: f.id, name: f.name, mime: f.mime ?? null, size: f.size ?? null, url: null, note: 'no link right now: read the room again' })
      }
      line.files = out
    }
  }
  return r
}
