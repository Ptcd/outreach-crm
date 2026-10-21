import { useOnline } from '@/lib/useOnline'

// A clear notice instead of a blank screen when the phone loses signal.
export function OfflineBanner() {
  const online = useOnline()
  if (online) return null
  return (
    <div role="status" className="border-b border-amber-300 bg-amber-100 px-4 py-2 text-center text-sm text-amber-950 dark:border-amber-800 dark:bg-amber-950 dark:text-amber-100">
      No signal. You&apos;re seeing what was last loaded; approvals will work again once you&apos;re back online.
    </div>
  )
}
