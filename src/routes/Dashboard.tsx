import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'

export default function Dashboard() {
  return (
    <div className="space-y-6">
      <h1 className="page-title">Dashboard</h1>
      <div className="grid gap-4 md:grid-cols-2 lg:grid-cols-4">
        <Card className="card">
          <CardHeader className="card-header">
            <CardTitle className="text-sm">Total Prospects</CardTitle>
          </CardHeader>
          <CardContent className="card-body">
            <div className="text-2xl font-bold">0</div>
            <p className="text-xs text-muted-foreground">Upload your first CSV to get started</p>
          </CardContent>
        </Card>
        <Card className="card">
          <CardHeader className="card-header">
            <CardTitle className="text-sm">Emails Sent</CardTitle>
          </CardHeader>
          <CardContent className="card-body">
            <div className="text-2xl font-bold">0</div>
            <p className="text-xs text-muted-foreground">No email events imported yet</p>
          </CardContent>
        </Card>
        <Card className="card">
          <CardHeader className="card-header">
            <CardTitle className="text-sm">Open Rate</CardTitle>
          </CardHeader>
          <CardContent className="card-body">
            <div className="text-2xl font-bold">0%</div>
            <p className="text-xs text-muted-foreground">Import events to see metrics</p>
          </CardContent>
        </Card>
        <Card className="card">
          <CardHeader className="card-header">
            <CardTitle className="text-sm">Conversions</CardTitle>
          </CardHeader>
          <CardContent className="card-body">
            <div className="text-2xl font-bold">0</div>
            <p className="text-xs text-muted-foreground">Track your wins here</p>
          </CardContent>
        </Card>
      </div>
    </div>
  )
}
