import { Link, useLocation } from 'react-router-dom'
import { useAuth } from '@/providers/AuthProvider'
import { Button } from '@/components/ui/button'
import { cn } from '@/lib/utils'

const navigation = [
  { name: 'Dashboard', href: '/dashboard' },
  { name: 'Prospects', href: '/prospects' },
  { name: 'Campaigns', href: '/campaigns' },
  { name: 'Tasks', href: '/tasks' },
  { name: 'Settings', href: '/settings' },
]

export function Navbar() {
  const { user, signOut } = useAuth()
  const location = useLocation()

  if (!user) return null

  return (
    <nav className="nav">
      <div className="container">
        <div className="flex h-12 items-center justify-between">
          <div className="flex items-center space-x-8">
            <Link to="/dashboard" className="text-xl font-bold">
              Outreach CRM
            </Link>
            <div className="hidden md:flex space-x-6">
              {navigation.map((item) => (
                <Link
                  key={item.name}
                  to={item.href}
                  className={cn('text-sm', location.pathname === item.href ? 'active' : '')}
                >
                  {item.name}
                </Link>
              ))}
            </div>
          </div>
          <div className="flex items-center space-x-4">
            <span className="text-sm text-muted-foreground">{user.email}</span>
            <Button variant="outline" size="sm" onClick={signOut}>
              Sign Out
            </Button>
          </div>
        </div>
      </div>
    </nav>
  )
}
