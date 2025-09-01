import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { supabase } from '@/lib/supabaseClient'
import { useAuth } from '@/providers/AuthProvider'

type Task = { id: string; title: string; due_at: string | null; status: 'open' | 'done' | 'in_progress' }

export default function Tasks() {
  const { orgId } = useAuth()
  const qc = useQueryClient()

  const { data: tasks = [], isLoading } = useQuery({
    queryKey: ['tasks', orgId],
    queryFn: async (): Promise<Task[]> => {
      if (!orgId) return []
      const { data, error } = await supabase
        .from('tasks')
        .select('id,title,due_at,status')
        .eq('org_id', orgId)
        .order('due_at', { ascending: true, nullsFirst: true })
      if (error) throw error
      return (data as any) ?? []
    },
  })

  const createMutation = useMutation({
    mutationFn: async (payload: { title: string; due_at?: string | null }) => {
      if (!orgId) throw new Error('Missing org context')
      const { error } = await supabase
        .from('tasks')
        .insert({ org_id: orgId, title: payload.title, due_at: payload.due_at ?? null, status: 'open' })
      if (error) throw error
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: ['tasks', orgId] }),
  })

  const toggleDoneMutation = useMutation({
    mutationFn: async (payload: { id: string; done: boolean }) => {
      const { error } = await supabase
        .from('tasks')
        .update({ status: payload.done ? 'done' : 'open' })
        .eq('id', payload.id)
      if (error) throw error
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: ['tasks', orgId] }),
  })

  const [title, setTitle] = useState('')
  const [due, setDue] = useState('')

  async function addTask() {
    if (!title.trim()) return
    await createMutation.mutateAsync({ title: title.trim(), due_at: due || null })
    setTitle('')
    setDue('')
  }

  return (
    <div className="space-y-6">
      <h1 className="page-title">Tasks</h1>
      <Card className="card">
        <CardHeader className="card-header">
          <CardTitle>Quick Add</CardTitle>
          <CardDescription>Create a follow-up or reminder</CardDescription>
        </CardHeader>
        <CardContent className="card-body">
          <div className="flex gap-2 items-center">
            <Input placeholder="Task title" value={title} onChange={(e) => setTitle(e.target.value)} />
            <Input type="date" value={due} onChange={(e) => setDue(e.target.value)} className="w-40" />
            <Button onClick={addTask} disabled={createMutation.isPending}>Add</Button>
          </div>
        </CardContent>
      </Card>

      <Card className="card">
        <CardHeader className="card-header">
          <CardTitle>Your Tasks</CardTitle>
          <CardDescription>Open, due today, and done</CardDescription>
        </CardHeader>
        <CardContent className="card-body">
          {isLoading ? (
            <p className="text-muted-foreground">Loading…</p>
          ) : (
            <div className="divide-y">
              {tasks.map((t: any) => (
                <div key={t.id} className="py-3 flex items-center justify-between">
                  <div className="flex items-center gap-3">
                    <input
                      type="checkbox"
                      checked={t.status === 'done'}
                      onChange={(e) => toggleDoneMutation.mutate({ id: t.id, done: e.target.checked })}
                    />
                    <div>
                      <p className={t.status === 'done' ? 'line-through' : ''}>{t.title}</p>
                      <p className="text-xs text-muted-foreground">Due: {t.due_at ? new Date(t.due_at).toLocaleDateString() : '—'}</p>
                    </div>
                  </div>
                  <span className="text-xs rounded-full px-2 py-1 border bg-gray-50 capitalize">{t.status}</span>
                </div>
              ))}
              {tasks.length === 0 && <p className="py-3 text-muted-foreground">No tasks yet.</p>}
            </div>
          )}
        </CardContent>
      </Card>
    </div>
  )
}
