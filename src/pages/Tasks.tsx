import { useEffect, useState } from 'react'
import { supabase } from '../lib/supabaseClient'

type Task = {
  id: string
  title: string
  due_at: string | null
  status: 'todo' | 'in_progress' | 'done'
}

function Tasks() {
  const [tasks, setTasks] = useState<Task[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    let isMounted = true
    async function load() {
      setError(null)
      setLoading(true)
      const { data, error } = await supabase
        .from('tasks')
        .select('id,title,due_at,status')
        .order('due_at', { ascending: true, nullsFirst: true })
      if (!isMounted) return
      if (error) {
        setError(error.message)
      } else {
        setTasks((data as Task[]) || [])
      }
      setLoading(false)
    }
    load()
    return () => { isMounted = false }
  }, [])

  return (
    <div className="p-6">
      <div className="max-w-4xl mx-auto bg-white border rounded-xl shadow p-6">
        <h1 className="text-xl font-semibold">Tasks</h1>
        {loading && <p className="mt-4 text-gray-600">Loading…</p>}
        {error && <p className="mt-4 text-red-600">{error}</p>}
        {!loading && !error && (
          <div className="mt-4 divide-y">
            {tasks.map((t) => (
              <div key={t.id} className="py-3 flex items-center justify-between">
                <div>
                  <p className="font-medium">{t.title}</p>
                  <p className="text-sm text-gray-600">Due: {t.due_at ?? '—'}</p>
                </div>
                <span className="text-xs rounded-full px-2 py-1 border bg-gray-50 capitalize">{t.status}</span>
              </div>
            ))}
            {tasks.length === 0 && <p className="py-3 text-gray-600">No tasks yet.</p>}
          </div>
        )}
      </div>
    </div>
  )
}

export default Tasks


