import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { Button } from '@/components/ui/button'
import CsvMapper from '@/components/upload/CsvMapper'

export default function Prospects() {
  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-3xl font-bold">Prospects</h1>
          <p className="text-muted-foreground">Manage your prospect database and upload new contacts.</p>
        </div>
        <Button asChild>
          <a href="#import">Import CSV</a>
        </Button>
      </div>
      
      <Card id="import">
        <CardHeader>
          <CardTitle>Prospect Database</CardTitle>
          <CardDescription>All your imported prospects will appear here.</CardDescription>
        </CardHeader>
        <CardContent>
          <CsvMapper />
        </CardContent>
      </Card>
    </div>
  )
}
