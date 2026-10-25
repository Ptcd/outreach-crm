// Colin's agent keys (Colin 2026-10-25: "design it agent first"): one key per Muse agent (or any MCP client). An intake
// key loads prospects; a sender key writes and queues texts. The key shows once, here, for Colin to paste into the
// agent's credentials; the app keeps only its hash. "Turn off" stops that agent at once.
import { useState } from 'react'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { ErrorNote, Select } from '@/components/ui/form'
import { supabase } from '@/lib/supabaseClient'
import { fmtDateTime } from '@/lib/format'

const BASE = ((import.meta.env.NEXT_PUBLIC_SUPABASE_URL ?? import.meta.env.VITE_SUPABASE_URL) as string | undefined)
  || 'https://jyfetargyaaxcqmxdgft.supabase.co'
export const AGENT_DOOR_URL = `${BASE.replace(/\/+$/, '')}/functions/v1/agent-mcp`

type Key = { id: string; name: string; role: 'intake' | 'sender'; key_hint: string; created_at: string; last_used_at: string | null; revoked_at: string | null }

export function AgentKeys() {
  const qc = useQueryClient()
  const keys = useQuery({ queryKey: ['agent_keys'], queryFn: async () => {
    const r = await supabase.rpc('list_agent_keys')
    if (r.error) throw new Error(r.error.message)
    return (r.data ?? []) as Key[]
  } })
  const [name, setName] = useState('')
  const [role, setRole] = useState<'intake' | 'sender'>('intake')
  const [fresh, setFresh] = useState<string | null>(null)
  const [copied, setCopied] = useState(false)
  const [err, setErr] = useState<Error | null>(null)
  const make = async () => {
    setErr(null); setFresh(null); setCopied(false)
    const r = await supabase.rpc('create_agent_key', { p_name: name.trim() || (role === 'intake' ? 'Muse intake' : 'Muse sender'), p_role: role })
    if (r.error) { setErr(new Error(r.error.message)); return }
    setFresh(r.data as string)
    setName('')
    void qc.invalidateQueries({ queryKey: ['agent_keys'] })
  }
  const off = async (id: string) => {
    const r = await supabase.rpc('revoke_agent_key', { p_id: id })
    if (r.error) setErr(new Error(r.error.message))
    void qc.invalidateQueries({ queryKey: ['agent_keys'] })
  }
  const copy = async (t: string) => { try { await navigator.clipboard.writeText(t); setCopied(true) } catch { setCopied(false) } }

  return (
    <div className="space-y-3 text-sm">
      <p className="text-muted-foreground">
        Agents connect here over MCP. Give each one its own key: an <strong>intake</strong> key loads prospects, a <strong>sender</strong> key
        writes and queues the texts. In the agent, add an MCP server with this address and send the key as <code>Authorization: Bearer &lt;key&gt;</code>.
      </p>
      <div className="flex items-center gap-2 rounded-lg bg-muted px-3 py-2">
        <code className="min-w-0 flex-1 truncate text-xs">{AGENT_DOOR_URL}</code>
        <Button size="sm" variant="outline" onClick={() => void copy(AGENT_DOOR_URL)}>Copy</Button>
      </div>
      <div className="grid gap-2 sm:grid-cols-[1fr_10rem_auto]">
        <Input className="h-11" placeholder="Name, e.g. Muse intake" value={name} onChange={(e) => setName(e.target.value)} aria-label="Key name" />
        <Select className="h-11" value={role} onChange={(e) => setRole(e.target.value as 'intake' | 'sender')} aria-label="What the key may do">
          <option value="intake">Intake: load prospects</option>
          <option value="sender">Sender: run the texts</option>
        </Select>
        <Button className="h-11" onClick={() => void make()}>Make a key</Button>
      </div>
      {fresh && (
        <div className="space-y-2 rounded-lg border-2 border-amber-400 bg-amber-50 p-3 text-amber-950 dark:bg-amber-950/30 dark:text-amber-100">
          <p className="font-semibold">Copy this key now. It is shown only once.</p>
          <div className="flex items-center gap-2">
            <code className="min-w-0 flex-1 break-all rounded bg-background/70 px-2 py-1 text-xs">{fresh}</code>
            <Button size="sm" onClick={() => void copy(fresh)}>{copied ? 'Copied' : 'Copy'}</Button>
          </div>
          <Button size="sm" variant="ghost" onClick={() => setFresh(null)}>I saved it</Button>
        </div>
      )}
      <ErrorNote error={err ?? keys.error} />
      <ul className="divide-y rounded-lg border">
        {(keys.data ?? []).length === 0 && <li className="p-3 text-muted-foreground">No agent keys yet.</li>}
        {(keys.data ?? []).map((k) => (
          <li key={k.id} className="flex flex-wrap items-center gap-2 p-3">
            <div className="min-w-0 flex-1">
              <p className="font-medium">{k.name} <span className="text-xs text-muted-foreground">({k.role}, ends ...{k.key_hint})</span></p>
              <p className="text-xs text-muted-foreground">
                {k.revoked_at ? `Turned off ${fmtDateTime(k.revoked_at)}` : k.last_used_at ? `Last used ${fmtDateTime(k.last_used_at)}` : 'Not used yet'}
              </p>
            </div>
            {!k.revoked_at && <Button size="sm" variant="outline" onClick={() => void off(k.id)}>Turn off</Button>}
          </li>
        ))}
      </ul>
    </div>
  )
}
