import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import { BrowserRouter } from 'react-router-dom'
import { AuthProvider } from '@/providers/AuthProvider'
import QueryProvider from '@/providers/QueryProvider'
import { DialerProvider } from '@/lib/dialer'
import './index.css'
import App from './App.tsx'

// Installable app + "reply needs you" notifications (public/sw.js).
if ('serviceWorker' in navigator && import.meta.env.PROD) {
  window.addEventListener('load', () => { void navigator.serviceWorker.register('/sw.js') })
}

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <BrowserRouter>
      <AuthProvider>
        <QueryProvider>
          <DialerProvider>
            <App />
          </DialerProvider>
        </QueryProvider>
      </AuthProvider>
    </BrowserRouter>
  </StrictMode>,
)
