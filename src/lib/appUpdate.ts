// The installed app keeps itself current (Colin 2026-10-27: a card showed none of David's replies because his phone
// was still running the Oct 23 copy of the app; an installed app left open never reloads). When the app comes back to
// the front, and every 10 minutes while it is open, it asks the site which build is live; if it is a newer one it
// reloads, never during a call and never while someone is typing.

const BUILD_RE = /\/assets\/index-[^"'\s]+\.js/

function runningBuild(): string | null {
  for (const s of Array.from(document.scripts)) {
    const m = s.src.match(BUILD_RE)
    if (m) return m[0]
  }
  return null
}

async function liveBuild(): Promise<string | null> {
  try {
    const res = await fetch('/', { cache: 'no-store' })
    if (!res.ok) return null
    return (await res.text()).match(BUILD_RE)?.[0] ?? null
  } catch {
    return null
  }
}

function busy(): boolean {
  if ((window as Window & { __wpieOnCall?: boolean }).__wpieOnCall) return true
  const el = document.activeElement as HTMLInputElement | HTMLTextAreaElement | null
  return !!el && (el.tagName === 'TEXTAREA' || el.tagName === 'INPUT') && !!el.value
}

export function keepAppCurrent(): void {
  const running = runningBuild()
  if (!running) return                                    // the dev server: nothing to compare
  let last = 0
  const check = async () => {
    if (document.visibilityState !== 'visible' || Date.now() - last < 60_000) return
    last = Date.now()
    const live = await liveBuild()
    if (live && live !== running && !busy()) window.location.reload()
  }
  document.addEventListener('visibilitychange', () => { void check() })
  window.addEventListener('focus', () => { void check() })
  window.setInterval(() => { void check() }, 10 * 60_000)
}
