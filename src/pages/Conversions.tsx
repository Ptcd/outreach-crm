import { useEffect, useState } from 'react'
import { supabase } from '../lib/supabaseClient'

type Conversion = {
  id: string
  prospect_id: string | null
  campaign_id: string | null
  revenue: number
  converted_at: string
}

function Conversions() {
  const [rows, setRows] = useState<Conversion[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    let isMounted = true
    async function load() {
      setError(null)
      setLoading(true)
      const { data, error } = await supabase
        .from('conversions')
        .select('id, prospect_id, campaign_id, revenue, converted_at')
        .order('converted_at', { ascending: false })
      if (!isMounted) return
      if (error) {
        setError(error.message)
      } else {
        setRows((data as Conversion[]) || [])
      }
      setLoading(false)
    }
    load()
    return () => { isMounted = false }
  }, [])
  return (
    <div className="p-6">
      <div className="max-w-4xl mx-auto bg-white border rounded-xl shadow p-6">
        <h1 className="text-xl font-semibold mb-4">Conversions</h1>
        {loading && <p className="text-gray-600">Loading…</p>}
        {error && <p className="text-red-600">{error}</p>}
        {!loading && !error && (
          <div className="overflow-x-auto">
            <table className="min-w-full text-left border">
              <thead className="bg-gray-50">
                <tr>
                  <th className="px-4 py-2 border">Prospect ID</th>
                  <th className="px-4 py-2 border">Campaign ID</th>
                  <th className="px-4 py-2 border">Revenue</th>
                  <th className="px-4 py-2 border">Converted At</th>
                </tr>
              </thead>
              <tbody>
                {rows.map((c) => (
                  <tr key={c.id} className="odd:bg-white even:bg-gray-50">
                    <td className="px-4 py-2 border">{c.prospect_id ?? '—'}</td>
                    <td className="px-4 py-2 border">{c.campaign_id ?? '—'}</td>
                    <td className="px-4 py-2 border">${c.revenue.toLocaleString()}</td>
                    <td className="px-4 py-2 border">{new Date(c.converted_at).toLocaleString()}</td>
                  </tr>
                ))}
                {rows.length === 0 && (
                  <tr><td className="px-4 py-2 border" colSpan={4}>No conversions yet.</td></tr>
                )}
              </tbody>
            </table>
          </div>
        )}
      </div>
    </div>
  )
}

export default Conversions


