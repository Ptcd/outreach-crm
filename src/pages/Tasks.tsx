type Task = {
  id: string
  title: string
  due_at: string
  status: 'todo' | 'in_progress' | 'done'
}

const mockTasks: Task[] = [
  { id: '1', title: 'Research Company A', due_at: '2025-09-05', status: 'todo' },
  { id: '2', title: 'Write initial outreach', due_at: '2025-09-06', status: 'in_progress' },
  { id: '3', title: 'Follow-up with Jane', due_at: '2025-09-08', status: 'done' },
]

function Tasks() {
  return (
    <div className="p-6">
      <div className="max-w-4xl mx-auto bg-white border rounded-xl shadow p-6">
        <h1 className="text-xl font-semibold">Tasks</h1>
        <div className="mt-4 divide-y">
          {mockTasks.map((t) => (
            <div key={t.id} className="py-3 flex items-center justify-between">
              <div>
                <p className="font-medium">{t.title}</p>
                <p className="text-sm text-gray-600">Due: {t.due_at}</p>
              </div>
              <span className="text-xs rounded-full px-2 py-1 border bg-gray-50 capitalize">{t.status}</span>
            </div>
          ))}
        </div>
      </div>
    </div>
  )
}

export default Tasks


