import Papa from 'papaparse'
import { useRef, useState } from 'react'
import { supabase } from '../lib/supabaseClient'

function Prospects() {
  const fileInputRef = useRef<HTMLInputElement | null>(null)
  const [uploading, setUploading] = useState(false)
  const [message, setMessage] = useState<string | null>(null)

  function handleImportClick() {
    fileInputRef.current?.click()
  }

  async function handleFileChange(e: React.ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0]
    if (!file) return
    setMessage(null)
    setUploading(true)
    Papa.parse(file, {
      header: true,
      skipEmptyLines: true,
      complete: async (results) => {
        const rows = (results.data as any[]).filter(Boolean)
        // Map CSV headers to DB columns: email, full_name, company, campaign_id(optional)
        const session = await supabase.auth.getSession()
        const userId = session.data.session?.user.id
        if (!userId) {
          setMessage('You must be signed in to import.')
          setUploading(false)
          return
        }
        const upserts = rows.map((r) => ({
          email: (r.email || r.Email || r.E_mail || '').toString().trim(),
          full_name: (r.full_name || r.name || r.FullName || '').toString().trim() || null,
          company: (r.company || r.Company || '').toString().trim() || null,
          campaign_id: (r.campaign_id || r.CampaignId || null) || null,
          user_id: userId,
        })).filter((r) => r.email)
        if (upserts.length === 0) {
          setMessage('No valid rows found in CSV.')
          setUploading(false)
          return
        }
        const { error } = await supabase.from('prospects').upsert(upserts, { onConflict: 'user_id,email' })
        if (error) {
          setMessage(`Import failed: ${error.message}`)
        } else {
          setMessage(`Imported ${upserts.length} prospect(s).`)
        }
        setUploading(false)
      },
      error: (err) => {
        setMessage(`CSV parse error: ${err.message}`)
        setUploading(false)
      },
    })
    e.target.value = ''
  }

  return (
    <div className="p-6">
      <div className="max-w-4xl mx-auto bg-white border rounded-xl shadow p-6">
        <div className="flex items-center justify-between">
          <h1 className="text-xl font-semibold">Prospects</h1>
          <div>
            <input
              ref={fileInputRef}
              type="file"
              accept=".csv"
              onChange={handleFileChange}
              className="hidden"
            />
            <button onClick={handleImportClick} disabled={uploading} className="bg-blue-600 text-white rounded-md px-4 py-2 hover:bg-blue-700 disabled:opacity-60">
              {uploading ? 'Importing…' : 'Import CSV'}
            </button>
          </div>
        </div>
        <p className="text-gray-600 mt-2">Upload a CSV of prospects to get started.</p>
        {message && <p className="mt-3 text-sm text-gray-700">{message}</p>}
      </div>
    </div>
  )
}

export default Prospects


