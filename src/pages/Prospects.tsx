import Papa from 'papaparse'
import { useRef } from 'react'

function Prospects() {
  const fileInputRef = useRef<HTMLInputElement | null>(null)

  function handleImportClick() {
    fileInputRef.current?.click()
  }

  function handleFileChange(e: React.ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0]
    if (!file) return
    Papa.parse(file, {
      header: true,
      skipEmptyLines: true,
      complete: (results) => {
        // eslint-disable-next-line no-console
        console.log('CSV parsed rows', results.data)
      },
      error: (err) => {
        // eslint-disable-next-line no-console
        console.error('CSV parse error', err)
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
            <button onClick={handleImportClick} className="bg-blue-600 text-white rounded-md px-4 py-2 hover:bg-blue-700">
              Import CSV
            </button>
          </div>
        </div>
        <p className="text-gray-600 mt-2">Upload a CSV of prospects to get started.</p>
      </div>
    </div>
  )
}

export default Prospects


