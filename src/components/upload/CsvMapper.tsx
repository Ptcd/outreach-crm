import { useMemo, useState } from 'react'
import Papa from 'papaparse'
import { Button } from '@/components/ui/button'
import { supabase } from '@/lib/supabaseClient'
import { useAuth } from '@/providers/AuthProvider'

type Mapping = {
  email?: string
  company?: string
  contact_name?: string
  phone?: string
  city?: string
  state?: string
  website?: string
  tags?: string
}

const DB_FIELDS = [
  { key: 'email', label: 'Email (required)' },
  { key: 'company', label: 'Company' },
  { key: 'contact_name', label: 'Contact Name' },
  { key: 'phone', label: 'Phone' },
  { key: 'city', label: 'City' },
  { key: 'state', label: 'State' },
  { key: 'website', label: 'Website' },
  { key: 'tags', label: 'Tags (comma-separated)' },
]

export function CsvMapper() {
  const { orgId } = useAuth()
  const [file, setFile] = useState<File | null>(null)
  const [columns, setColumns] = useState<string[]>([])
  const [rows, setRows] = useState<any[]>([])
  const [mapping, setMapping] = useState<Mapping>({})
  const [uploading, setUploading] = useState(false)
  const [message, setMessage] = useState<string | null>(null)

  const canUpload = useMemo(() => !!mapping.email && rows.length > 0 && !!orgId, [mapping, rows, orgId])

  function onFileChange(e: React.ChangeEvent<HTMLInputElement>) {
    const f = e.target.files?.[0]
    if (!f) return
    setFile(f)
    setMessage(null)
    Papa.parse(f, {
      header: true,
      skipEmptyLines: true,
      complete: (result) => {
        const data = (result.data as any[]).filter(Boolean)
        setRows(data)
        const cols = Object.keys(data[0] ?? {})
        setColumns(cols)
      },
      error: (err) => setMessage(`CSV parse error: ${err.message}`),
    })
  }

  function updateMapping(field: keyof Mapping, value: string) {
    setMapping((m) => ({ ...m, [field]: value || undefined }))
  }

  async function upload() {
    if (!orgId) {
      setMessage('Missing org context')
      return
    }
    if (!mapping.email) {
      setMessage('Map the Email field')
      return
    }
    setUploading(true)
    setMessage(null)
    try {
      const payload = rows.map((r) => {
        const record: any = { org_id: orgId }
        for (const [dbKey, csvKey] of Object.entries(mapping)) {
          if (!csvKey) continue
          let value: any = r[csvKey]
          if (dbKey === 'tags' && typeof value === 'string') {
            value = value.split(',').map((t) => t.trim()).filter(Boolean)
          }
          record[dbKey] = value ?? null
        }
        return record
      }).filter((r) => !!r.email)

      // Batch in chunks to avoid row limits
      const chunkSize = 500
      let inserted = 0
      for (let i = 0; i < payload.length; i += chunkSize) {
        const slice = payload.slice(i, i + chunkSize)
        const { error, count } = await supabase
          .from('prospects')
          .upsert(slice, { onConflict: 'org_id,email', ignoreDuplicates: false, count: 'exact' })
        if (error) throw error
        inserted += count ?? slice.length
      }
      setMessage(`Imported ${inserted} prospect(s). Duplicates were deduped by (org_id, email).`)
      setFile(null)
    } catch (err: any) {
      setMessage(err.message || 'Import failed')
    } finally {
      setUploading(false)
    }
  }

  return (
    <div className="space-y-4">
      <div className="flex items-center gap-3">
        <input type="file" accept=".csv" onChange={onFileChange} />
        <Button onClick={upload} disabled={!canUpload || uploading}>
          {uploading ? 'Importing…' : 'Import'}
        </Button>
      </div>
      {message && <p className="text-sm text-muted-foreground">{message}</p>}
      {columns.length > 0 && (
        <div className="grid md:grid-cols-2 gap-6">
          <div>
            <h3 className="font-medium mb-2">Map fields</h3>
            <div className="space-y-3">
              {DB_FIELDS.map((f) => (
                <div key={f.key} className="flex items-center gap-2">
                  <label className="w-44 text-sm">{f.label}</label>
                  <select
                    className="border rounded-md px-2 py-1 text-sm"
                    value={(mapping as any)[f.key] ?? ''}
                    onChange={(e) => updateMapping(f.key as keyof Mapping, e.target.value)}
                  >
                    <option value="">—</option>
                    {columns.map((c) => (
                      <option key={c} value={c}>{c}</option>
                    ))}
                  </select>
                </div>
              ))}
            </div>
          </div>
          <div>
            <h3 className="font-medium mb-2">Preview (first 5)</h3>
            <pre className="text-xs bg-gray-50 border rounded-md p-2 overflow-auto max-h-60">
{JSON.stringify(rows.slice(0, 5), null, 2)}
            </pre>
          </div>
        </div>
      )}
    </div>
  )
}

export default CsvMapper


