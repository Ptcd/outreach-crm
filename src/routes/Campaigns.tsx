import { useMemo, useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Button } from '@/components/ui/button'
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogTrigger } from '@/components/ui/dialog.tsx'
import { Table, Tbody, Td, Th, Thead, Tr } from '@/components/ui/table'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { supabase } from '@/lib/supabaseClient'
import { useAuth } from '@/providers/AuthProvider'

type Campaign = {
  id: string
  org_id: string
  name: string
  inbox_email: string | null
  status: string | null
  created_at: string
}

export default function Campaigns() {
  const { orgId } = useAuth()
  const qc = useQueryClient()

  const { data: campaigns = [], isLoading } = useQuery({
    queryKey: ['campaigns', orgId],
    queryFn: async (): Promise<Campaign[]> => {
      if (!orgId) return []
      const { data, error } = await supabase
        .from('campaigns')
        .select('id, org_id, name, inbox_email, status, created_at')
        .eq('org_id', orgId)
        .order('created_at', { ascending: false })
      if (error) throw error
      return (data as Campaign[]) ?? []
    },
  })

  const createMutation = useMutation({
    mutationFn: async (payload: { name: string; inbox_email?: string | null }) => {
      if (!orgId) throw new Error('Missing org context')
      const { error } = await supabase
        .from('campaigns')
        .insert({ org_id: orgId, name: payload.name, inbox_email: payload.inbox_email ?? null })
      if (error) throw error
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: ['campaigns', orgId] }),
  })

  const updateMutation = useMutation({
    mutationFn: async (payload: { id: string; name: string; inbox_email?: string | null }) => {
      const { error } = await supabase
        .from('campaigns')
        .update({ name: payload.name, inbox_email: payload.inbox_email ?? null })
        .eq('id', payload.id)
      if (error) throw error
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: ['campaigns', orgId] }),
  })

  const deleteMutation = useMutation({
    mutationFn: async (id: string) => {
      const { error } = await supabase.from('campaigns').delete().eq('id', id)
      if (error) throw error
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: ['campaigns', orgId] }),
  })

  const [open, setOpen] = useState(false)
  const [editing, setEditing] = useState<Campaign | null>(null)
  const [name, setName] = useState('')
  const [inbox, setInbox] = useState('')
  const formTitle = useMemo(() => (editing ? 'Edit Campaign' : 'New Campaign'), [editing])

  function startNew() {
    setEditing(null)
    setName('')
    setInbox('')
    setOpen(true)
  }

  function startEdit(c: Campaign) {
    setEditing(c)
    setName(c.name)
    setInbox(c.inbox_email ?? '')
    setOpen(true)
  }

  async function submit() {
    if (!name.trim()) return
    if (editing) {
      await updateMutation.mutateAsync({ id: editing.id, name: name.trim(), inbox_email: inbox || null })
    } else {
      await createMutation.mutateAsync({ name: name.trim(), inbox_email: inbox || null })
    }
    setOpen(false)
  }

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <h1 className="page-title">Campaigns</h1>
        <Dialog open={open} onOpenChange={setOpen}>
          <DialogTrigger asChild>
            <Button onClick={startNew}>New Campaign</Button>
          </DialogTrigger>
          <DialogContent>
            <DialogHeader>
              <DialogTitle>{formTitle}</DialogTitle>
            </DialogHeader>
            <div className="space-y-3">
              <div className="space-y-1">
                <Label htmlFor="name">Name</Label>
                <Input id="name" value={name} onChange={(e) => setName(e.target.value)} placeholder="Fall outreach" />
              </div>
              <div className="space-y-1">
                <Label htmlFor="inbox">Inbox Email (optional)</Label>
                <Input id="inbox" value={inbox} onChange={(e) => setInbox(e.target.value)} placeholder="you@domain.com" />
              </div>
              <div className="text-right">
                <Button onClick={submit} disabled={createMutation.isPending || updateMutation.isPending}>
                  {editing ? 'Save' : 'Create'}
                </Button>
              </div>
            </div>
          </DialogContent>
        </Dialog>
      </div>

      <Card className="card">
        <CardHeader className="card-header">
          <CardTitle>Your Campaigns</CardTitle>
          <CardDescription>Organize prospects into targeted outreach campaigns.</CardDescription>
        </CardHeader>
        <CardContent className="card-body">
          {isLoading ? (
            <p className="text-muted-foreground">Loading…</p>
          ) : (
            <div className="overflow-x-auto">
              <Table>
                <Thead>
                  <Tr>
                    <Th>Name</Th>
                    <Th>Inbox</Th>
                    <Th>Created</Th>
                    <Th></Th>
                  </Tr>
                </Thead>
                <Tbody>
                  {campaigns.map((c) => (
                    <Tr key={c.id}>
                      <Td>{c.name}</Td>
                      <Td>{c.inbox_email ?? '—'}</Td>
                      <Td>{new Date(c.created_at).toLocaleDateString()}</Td>
                      <Td className="text-right">
                        <div className="flex gap-2 justify-end">
                          <Button variant="secondary" onClick={() => startEdit(c)}>Edit</Button>
                          <Button variant="destructive" onClick={() => deleteMutation.mutate(c.id)}>Delete</Button>
                        </div>
                      </Td>
                    </Tr>
                  ))}
                  {campaigns.length === 0 && (
                    <Tr>
                      <Td colSpan={4} className="text-muted-foreground">No campaigns yet. Create your first one.</Td>
                    </Tr>
                  )}
                </Tbody>
              </Table>
            </div>
          )}
        </CardContent>
      </Card>
    </div>
  )
}
