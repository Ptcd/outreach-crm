import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import { BrowserRouter } from 'react-router-dom'
import { AuthProvider } from '@/providers/AuthProvider'
import QueryProvider from '@/providers/QueryProvider'
import { DialerProvider } from '@/lib/dialer'
import './index.css'
import App from './App.tsx'
import { keepAppCurrent } from '@/lib/appUpdate'
import { applyTheme, getTheme } from '@/lib/theme'

// light or dark, chosen on this browser, before the first paint
applyTheme(getTheme())

// Installable app + "reply needs you" notifications (public/sw.js).
if ('serviceWorker' in navigator && import.meta.env.PROD) {
  window.addEventListener('load', () => { void navigator.serviceWorker.register('/sw.js') })
}
// an installed app left open on a phone picks up a new build when it comes back to the front
if (import.meta.env.PROD) keepAppCurrent()

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
