// The app's query cache, kept on the phone so a weak signal still shows the last loaded data.
import { QueryClient, dehydrate, hydrate } from '@tanstack/react-query'

export const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      staleTime: 60 * 1000,
      retry: 2,
      // Show the last loaded data at once and refresh it in the background; on a dead signal the
      // data stays on screen (the offline banner explains) instead of a blank page.
      networkMode: 'offlineFirst',
    },
  },
})

// Keep the last loaded replies and texts on the phone, so a weak signal still shows them.
const KEY = 'wpie-cache-v1'
const KEEP = new Set(['reply_drafts', 'reply_waiting', 'inbox', 'campaign_control', 'planned_openers'])
try {
  const saved = typeof localStorage !== 'undefined' ? localStorage.getItem(KEY) : null
  if (saved) hydrate(queryClient, JSON.parse(saved))
} catch {
  // a broken copy is just ignored
}
let timer: ReturnType<typeof setTimeout> | null = null
queryClient.getQueryCache().subscribe(() => {
  if (timer || typeof localStorage === 'undefined') return
  timer = setTimeout(() => {
    timer = null
    try {
      const state = dehydrate(queryClient, {
        shouldDehydrateQuery: (q) => q.state.status === 'success' && KEEP.has(String(q.queryKey[0])),
      })
      const json = JSON.stringify(state)
      if (json.length < 2_000_000) localStorage.setItem(KEY, json)
    } catch {
      // storage full or blocked: the app still works, just without the offline copy
    }
  }, 2000)
})

/** Signing out forgets the copy on the phone. */
export function clearCachedData() {
  try { localStorage.removeItem(KEY) } catch { /* ignore */ }
  queryClient.clear()
}

