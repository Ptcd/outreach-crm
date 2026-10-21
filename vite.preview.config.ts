// DEV ONLY: `npm run preview:mock` serves the real app with sample data (preview/*) instead of
// Supabase, to check the phone layout without signing in. Not used by `npm run build`.
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import path from 'path'

const r = (p: string) => path.resolve(__dirname, p)

export default defineConfig({
  plugins: [react()],
  resolve: {
    alias: [
      { find: '@/lib/queries', replacement: r('preview/mockQueries.ts') },
      { find: '@/providers/AuthProvider', replacement: r('preview/mockAuth.tsx') },
      { find: '@/lib/supabaseClient', replacement: r('preview/mockSupabase.ts') },
      { find: '@', replacement: r('src') },
    ],
  },
  server: { port: 5199, strictPort: true },
})
