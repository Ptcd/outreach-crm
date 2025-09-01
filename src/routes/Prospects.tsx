import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Button } from '@/components/ui/button'
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogTrigger } from '@/components/ui/dialog.tsx'
import { Table, Tbody, Td, Th, Thead, Tr } from '@/components/ui/table'
import CsvMapper from '@/components/upload/CsvMapper'
import { supabase } from '@/lib/supabaseClient'
import { useAuth } from '@/providers/AuthProvider'

export default function Prospects() {
  const { orgId } = useAuth()
  const qc = useQueryClient()
  const { data, isLoading, refetch } = useQuery({
    queryKey: ['prospects', orgId],
    queryFn: async () => {
      if (!orgId) return [] as any[]
      const { data, error } = await supabase
        .from('prospects')
        .select('id, email, company, contact_name, city, state, created_at')
        .eq('org_id', orgId)
        .order('created_at', { ascending: false })
        .limit(200)
      if (error) throw error
      return data as any[]
    },
  })

  const { data: campaigns = [] } = useQuery({
    queryKey: ['campaigns-for-assign', orgId],
    queryFn: async () => {
      if (!orgId) return [] as any[]
      const { data, error } = await supabase
        .from('campaigns')
        .select('id, name')
        .eq('org_id', orgId)
        .order('created_at', { ascending: false })
      if (error) throw error
      return data as any[]
    },
  })

  const assignMutation = useMutation({
    mutationFn: async (payload: { prospect_id: string; campaign_id: string }) => {
      if (!orgId) throw new Error('Missing org context')
      const { error } = await supabase
        .from('prospect_campaign')
        .upsert({
          org_id: orgId,
          prospect_id: payload.prospect_id,
          campaign_id: payload.campaign_id,
          status: 'new',
        }, { onConflict: 'org_id,prospect_id,campaign_id' })
      if (error) throw error
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['prospects', orgId] })
    },
  })

  const [assignOpen, setAssignOpen] = useState(false)
  const [selectedProspect, setSelectedProspect] = useState<any | null>(null)
  const [selectedCampaign, setSelectedCampaign] = useState('')
  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-3xl font-bold">Prospects</h1>
          <p className="text-muted-foreground">Manage your prospect database and upload new contacts.</p>
        </div>
        <Dialog>
          <DialogTrigger asChild>
            <Button>Import CSV</Button>
          </DialogTrigger>
          <DialogContent>
            <DialogHeader>
              <DialogTitle>Import Prospects (CSV)</DialogTitle>
            </DialogHeader>
            <CsvMapper />
            <div className="mt-4 text-right">
              <Button variant="secondary" onClick={() => refetch()}>Refresh Table</Button>
            </div>
          </DialogContent>
        </Dialog>
      </div>
      
      <Card>
        <CardHeader>
          <CardTitle>Prospect Database</CardTitle>
          <CardDescription>All your imported prospects will appear here.</CardDescription>
        </CardHeader>
        <CardContent>
          {isLoading ? (
            <p className="text-muted-foreground">Loading…</p>
          ) : (
            <div className="overflow-x-auto">
              <Table>
                <Thead>
                  <Tr>
                    <Th>Email</Th>
                    <Th>Company</Th>
                    <Th>Contact</Th>
                    <Th>Location</Th>
                    <Th>Added</Th>
                    <Th></Th>
                  </Tr>
                </Thead>
                <Tbody>
                  {(data ?? []).map((p) => (
                    <Tr key={p.id}>
                      <Td>{p.email}</Td>
                      <Td>{p.company ?? '—'}</Td>
                      <Td>{p.contact_name ?? '—'}</Td>
                      <Td>{[p.city, p.state].filter(Boolean).join(', ') || '—'}</Td>
                      <Td>{new Date(p.created_at).toLocaleDateString()}</Td>
                      <Td className="text-right">
                        <Dialog open={assignOpen} onOpenChange={setAssignOpen}>
                          <DialogTrigger asChild>
                            <Button variant="secondary" onClick={() => { setSelectedProspect(p); setSelectedCampaign('') }}>Assign</Button>
                          </DialogTrigger>
                          <DialogContent>
                            <DialogHeader>
                              <DialogTitle>Assign to Campaign</DialogTitle>
                            </DialogHeader>
                            <div className="space-y-3">
                              <div className="space-y-1">
                                <label className="text-sm">Campaign</label>
                                <select
                                  className="border rounded-md px-2 py-1 text-sm w-full"
                                  value={selectedCampaign}
                                  onChange={(e) => setSelectedCampaign(e.target.value)}
                                >
                                  <option value="">Select a campaign…</option>
                                  {campaigns.map((c: any) => (
                                    <option key={c.id} value={c.id}>{c.name}</option>
                                  ))}
                                </select>
                              </div>
                              <div className="text-right">
                                <Button
                                  onClick={async () => {
                                    if (!selectedProspect || !selectedCampaign) return
                                    await assignMutation.mutateAsync({ prospect_id: selectedProspect.id, campaign_id: selectedCampaign })
                                    setAssignOpen(false)
                                  }}
                                  disabled={assignMutation.isPending || !selectedCampaign}
                                >
                                  Assign
                                </Button>
                              </div>
                            </div>
                          </DialogContent>
                        </Dialog>
                      </Td>
                    </Tr>
                  ))}
                  {(data ?? []).length === 0 && (
                    <Tr>
                      <Td colSpan={6} className="text-muted-foreground">No prospects yet. Import a CSV to get started.</Td>
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
