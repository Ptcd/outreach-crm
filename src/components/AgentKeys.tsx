// Colin's agent keys (Colin 2026-10-25: "design it agent first"; one key with scopes, Muse 2026-10-26). One key for
// Muse carries five switches: prospects, texting, calendar, records, marks. Each can be turned off on its own, here,
// and the door refuses that part at once; every call is logged with its scope. The older single-role keys (intake,
// sender, records) keep working with what their role had until Colin turns them off. A key shows once, here, for Colin
// to paste into the agent's credentials; the app keeps only its hash. "Turn off" stops that agent at once.
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

type Role = 'agent' | 'intake' | 'sender' | 'records'
type Scope = 'prospects' | 'texting' | 'calendar' | 'records' | 'marks'
export const SCOPES: { id: Scope; label: string }[] = [
  { id: 'prospects', label: 'Prospects' }, { id: 'texting', label: 'Texting' }, { id: 'calendar', label: 'Calendar' },
  { id: 'records', label: 'Records' }, { id: 'marks', label: 'Cards' },
]
type Key = { id: string; name: string; role: Role; key_hint: string; created_at: string; last_used_at: string | null; revoked_at: string | null
  scopes: Scope[] | null; calls_24h: number | null; refused_24h: number | null }

const DEFAULT_NAME: Record<Role, string> = { agent: 'Muse', intake: 'Muse intake', sender: 'Muse sender', records: 'Muse records' }

export function AgentKeys() {
  const qc = useQueryClient()
  const keys = useQuery({ queryKey: ['agent_keys'], queryFn: async () => {
    const r = await supabase.rpc('list_agent_keys')
    if (r.error) throw new Error(r.error.message)
    return (r.data ?? []) as Key[]
  } })
  const [name, setName] = useState('')
  const [role, setRole] = useState<Role>('agent')
  const [scopes, setScopes] = useState<Scope[]>(SCOPES.map((s) => s.id))
  const [fresh, setFresh] = useState<string | null>(null)
  const [copied, setCopied] = useState(false)
  const [err, setErr] = useState<Error | null>(null)
  const refresh = () => void qc.invalidateQueries({ queryKey: ['agent_keys'] })
  const make = async () => {
    setErr(null); setFresh(null); setCopied(false)
    const r = await supabase.rpc('create_agent_key', { p_name: name.trim() || DEFAULT_NAME[role], p_role: role, p_scopes: role === 'agent' ? scopes : null })
    if (r.error) { setErr(new Error(r.error.message)); return }
    setFresh(r.data as string)
    setName('')
    refresh()
  }
  const off = async (id: string) => {
    const r = await supabase.rpc('revoke_agent_key', { p_id: id })
    if (r.error) setErr(new Error(r.error.message))
    refresh()
  }
  const toggle = async (k: Key, s: Scope) => {
    const now = k.scopes ?? []
    const next = now.includes(s) ? now.filter((x) => x !== s) : SCOPES.map((x) => x.id).filter((x) => x === s || now.includes(x))
    const r = await supabase.rpc('set_agent_key_scopes', { p_id: k.id, p_scopes: next })
    if (r.error) setErr(new Error(r.error.message))
    refresh()
  }
  const copy = async (t: string) => { try { await navigator.clipboard.writeText(t); setCopied(true) } catch { setCopied(false) } }

  return (
    <div className="space-y-3 text-sm">
      <p className="text-muted-foreground">
        Agents connect here over MCP. One key can do everything you switch on for it: <strong>prospects</strong> (load cards),
        <strong> texting</strong>, <strong>calendar</strong> (book calls), <strong>records</strong> (records requests) and <strong>cards</strong> (mark
        and follow up cards). Turn a switch off and the door refuses that part at once. In the agent, add an MCP server with this address and send the
        key as <code>Authorization: Bearer &lt;key&gt;</code>.
      </p>
      <div className="flex items-center gap-2 rounded-lg bg-muted px-3 py-2">
        <code className="min-w-0 flex-1 truncate text-xs">{AGENT_DOOR_URL}</code>
        <Button size="sm" variant="outline" onClick={() => void copy(AGENT_DOOR_URL)}>Copy</Button>
      </div>
      <div className="grid gap-2 sm:grid-cols-[1fr_12rem_auto]">
        <Input className="h-11" placeholder="Name, e.g. Muse" value={name} onChange={(e) => setName(e.target.value)} aria-label="Key name" />
        <Select className="h-11" value={role} onChange={(e) => setRole(e.target.value as Role)} aria-label="What the key may do">
          <option value="agent">One key: pick what it may do</option>
          <option value="intake">Intake only (old style)</option>
          <option value="sender">Sender only (old style)</option>
          <option value="records">Records only (old style)</option>
        </Select>
        <Button className="h-11" onClick={() => void make()}>Make a key</Button>
      </div>
      {role === 'agent' && (
        <div className="flex flex-wrap gap-2" aria-label="Scopes for the new key">
          {SCOPES.map((s) => (
            <label key={s.id} className="flex items-center gap-1.5 rounded-full border px-3 py-1.5">
              <input type="checkbox" checked={scopes.includes(s.id)}
                onChange={() => setScopes((cur) => cur.includes(s.id) ? cur.filter((x) => x !== s.id) : SCOPES.map((x) => x.id).filter((x) => x === s.id || cur.includes(x)))} />
              {s.label}
            </label>
          ))}
        </div>
      )}
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
          <li key={k.id} className="space-y-2 p-3">
            <div className="flex flex-wrap items-center gap-2">
              <div className="min-w-0 flex-1">
                <p className="font-medium">{k.name} <span className="text-xs text-muted-foreground">({k.role === 'agent' ? 'one key' : k.role}, ends ...{k.key_hint})</span></p>
                <p className="text-xs text-muted-foreground">
                  {k.revoked_at ? `Turned off ${fmtDateTime(k.revoked_at)}` : k.last_used_at ? `Last used ${fmtDateTime(k.last_used_at)}` : 'Not used yet'}
                  {!k.revoked_at && (k.calls_24h ?? 0) > 0 && ` · ${k.calls_24h} calls today${(k.refused_24h ?? 0) > 0 ? `, ${k.refused_24h} refused` : ''}`}
                </p>
              </div>
              {!k.revoked_at && <Button size="sm" variant="outline" onClick={() => void off(k.id)}>Turn off</Button>}
            </div>
            {!k.revoked_at && (
              <div className="flex flex-wrap gap-1.5" aria-label={`What ${k.name} may do`}>
                {SCOPES.map((s) => {
                  const on = (k.scopes ?? []).includes(s.id)
                  return (
                    <button key={s.id} type="button" onClick={() => void toggle(k, s.id)} aria-pressed={on}
                      className={`rounded-full border px-2.5 py-1 text-xs ${on ? 'border-emerald-500 bg-emerald-50 text-emerald-900 dark:bg-emerald-950/40 dark:text-emerald-100' : 'text-muted-foreground line-through'}`}>
                      {s.label}
                    </button>
                  )
                })}
              </div>
            )}
          </li>
        ))}
      </ul>
    </div>
  )
}
