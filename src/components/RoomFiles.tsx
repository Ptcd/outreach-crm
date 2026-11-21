import { useRef, useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { Paperclip, X } from 'lucide-react'
import { supabase } from '@/lib/supabaseClient'
import { cn } from '@/lib/utils'

// Files and images in the room (0264; Colin 2026-11-20: "Make it so files and images can be uploaded in the chat").
// The bucket is private: a file goes up on a one-time link the server gives, and comes back on a 10-minute link the
// server gives only to someone who may read the line it is on. Used by Colin's Room page and the callers' Help page.

export type RoomFile = { id: string; name: string; mime: string | null; size: number | null }
const MAX_BYTES = 25 * 1024 * 1024
const MAX_FILES = 8
const kb = (n: number | null) => (n == null ? '' : n < 1024 * 1024 ? `${Math.max(1, Math.round(n / 1024))} KB` : `${(n / 1024 / 1024).toFixed(1)} MB`)
const isImage = (f: { mime: string | null; name: string }) => (f.mime ?? '').startsWith('image/') || /\.(png|jpe?g|gif|webp|heic)$/i.test(f.name)

/** Put one file up; the id that comes back is named on the line. */
export async function uploadRoomFile(file: File): Promise<{ id: string } | { error: string }> {
  if (file.size > MAX_BYTES) return { error: `${file.name} is over 25 MB` }
  const made = await supabase.functions.invoke('room-file', { body: { action: 'upload', name: file.name, mime: file.type || null, size: file.size } })
  const d = made.data as { ok?: boolean; reason?: string; file_id?: string; path?: string; token?: string } | null
  if (made.error || !d?.ok || !d.file_id || !d.path || !d.token) return { error: d?.reason ?? made.error?.message ?? `${file.name} could not be sent` }
  const up = await supabase.storage.from('room').uploadToSignedUrl(d.path, d.token, file, { contentType: file.type || 'application/octet-stream' })
  if (up.error) return { error: `${file.name} did not upload: ${up.error.message}` }
  return { id: d.file_id }
}

/** The files someone has picked and not sent yet, with the paperclip that picks them. */
export function useAttach() {
  const [picked, setPicked] = useState<File[]>([])
  const [error, setError] = useState<string | null>(null)
  const add = (list: FileList | null) => {
    if (!list) return
    const next = [...picked, ...Array.from(list)]
    const big = next.find((f) => f.size > MAX_BYTES)
    setError(big ? `${big.name} is over 25 MB` : next.length > MAX_FILES ? 'Eight files on one line at most' : null)
    setPicked(next.filter((f) => f.size <= MAX_BYTES).slice(0, MAX_FILES))
  }
  const remove = (i: number) => setPicked(picked.filter((_, k) => k !== i))
  /** upload everything picked; the ids to name on the line, or the first thing that went wrong */
  const send = async (): Promise<{ ids: string[] } | { error: string }> => {
    const ids: string[] = []
    for (const f of picked) {
      const r = await uploadRoomFile(f)
      if ('error' in r) { setError(r.error); return r }
      ids.push(r.id)
    }
    return { ids }
  }
  const clear = () => { setPicked([]); setError(null) }
  return { picked, add, remove, send, clear, error }
}

export function AttachButton({ onPick, disabled }: { onPick: (list: FileList | null) => void; disabled?: boolean }) {
  const input = useRef<HTMLInputElement | null>(null)
  return (
    <>
      <input ref={input} type="file" multiple className="hidden" aria-label="Attach files or images"
        onChange={(e) => { onPick(e.target.files); e.target.value = '' }} />
      <button type="button" disabled={disabled} aria-label="Attach a file or an image" title="Attach a file or an image (25 MB each)"
        className="flex h-11 w-11 shrink-0 items-center justify-center rounded-md border text-muted-foreground hover:bg-accent disabled:opacity-50"
        onClick={() => input.current?.click()}>
        <Paperclip className="h-5 w-5" aria-hidden />
      </button>
    </>
  )
}

export function PickedFiles({ files, onRemove }: { files: File[]; onRemove: (i: number) => void }) {
  if (files.length === 0) return null
  return (
    <ul className="flex flex-wrap gap-1 text-xs" aria-label="Files to send">
      {files.map((f, i) => (
        <li key={`${f.name}-${i}`} className="flex items-center gap-1 rounded border bg-muted/50 px-2 py-1">
          <span className="max-w-[12rem] truncate">{f.name}</span><span className="text-muted-foreground">{kb(f.size)}</span>
          <button type="button" aria-label={`Remove ${f.name}`} onClick={() => onRemove(i)}><X className="h-3.5 w-3.5" aria-hidden /></button>
        </li>
      ))}
    </ul>
  )
}

/** The files on a line: an image shows itself, anything else is a link by its name. */
export function LineFiles({ files }: { files: RoomFile[] | undefined }) {
  if (!files || files.length === 0) return null
  return <ul className="mt-2 flex flex-wrap gap-2">{files.map((f) => <li key={f.id}><OneFile f={f} /></li>)}</ul>
}

function OneFile({ f }: { f: RoomFile }) {
  // the link is good for 10 minutes: asked for once, and again after 8
  const q = useQuery({ queryKey: ['room_file', f.id], staleTime: 8 * 60_000, refetchInterval: 8 * 60_000, queryFn: async () => {
    const r = await supabase.functions.invoke('room-file', { body: { action: 'link', file_id: f.id } })
    const d = r.data as { ok?: boolean; url?: string; reason?: string } | null
    if (r.error || !d?.ok || !d.url) throw new Error(d?.reason ?? 'could not open the file')
    return d.url
  } })
  const label = `${f.name}${f.size ? ` (${kb(f.size)})` : ''}`
  if (q.isError) return <span className="rounded border px-2 py-1 text-xs text-red-700">{f.name}: could not be opened</span>
  if (!q.data) return <span className="rounded border px-2 py-1 text-xs text-muted-foreground">{label}...</span>
  if (isImage(f)) {
    return (
      <a href={q.data} target="_blank" rel="noreferrer" title={label}>
        <img src={q.data} alt={f.name} loading="lazy" className={cn('max-h-56 max-w-full rounded-md border object-contain')} />
      </a>
    )
  }
  return <a href={q.data} target="_blank" rel="noreferrer" className="inline-flex items-center gap-1 rounded border bg-background px-2 py-1 text-xs font-medium underline"><Paperclip className="h-3.5 w-3.5" aria-hidden />{label}</a>
}
