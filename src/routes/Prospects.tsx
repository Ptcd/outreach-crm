import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Button } from '@/components/ui/button'

export default function Prospects() {
  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-3xl font-bold">Prospects</h1>
          <p className="text-muted-foreground">Manage your prospect database and upload new contacts.</p>
        </div>
        <Button>Import CSV</Button>
      </div>
      
      <Card>
        <CardHeader>
          <CardTitle>Prospect Database</CardTitle>
          <CardDescription>All your imported prospects will appear here.</CardDescription>
        </CardHeader>
        <CardContent>
          <div className="text-center py-8">
            <p className="text-muted-foreground">No prospects found. Upload a CSV to get started.</p>
          </div>
        </CardContent>
      </Card>
    </div>
  )
}
