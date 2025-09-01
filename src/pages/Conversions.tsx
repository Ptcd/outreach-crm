type Conversion = {
  id: string
  prospect: string
  campaign: string
  revenue: number
}

const mockConversions: Conversion[] = [
  { id: '1', prospect: 'Jane Doe', campaign: 'Campaign A', revenue: 1200 },
  { id: '2', prospect: 'Acme Inc.', campaign: 'Campaign B', revenue: 5000 },
]

function Conversions() {
  return (
    <div className="p-6">
      <div className="max-w-4xl mx-auto bg-white border rounded-xl shadow p-6">
        <h1 className="text-xl font-semibold mb-4">Conversions</h1>
        <div className="overflow-x-auto">
          <table className="min-w-full text-left border">
            <thead className="bg-gray-50">
              <tr>
                <th className="px-4 py-2 border">Prospect</th>
                <th className="px-4 py-2 border">Campaign</th>
                <th className="px-4 py-2 border">Revenue</th>
              </tr>
            </thead>
            <tbody>
              {mockConversions.map((c) => (
                <tr key={c.id} className="odd:bg-white even:bg-gray-50">
                  <td className="px-4 py-2 border">{c.prospect}</td>
                  <td className="px-4 py-2 border">{c.campaign}</td>
                  <td className="px-4 py-2 border">${c.revenue.toLocaleString()}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  )
}

export default Conversions


