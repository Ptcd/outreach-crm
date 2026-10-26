// Display helpers. Times show in Milwaukee time.
export const TZ = 'America/Chicago'

export function fmtDateTime(iso: string | null | undefined): string {
  if (!iso) return ''
  return new Date(iso).toLocaleString('en-US', {
    timeZone: TZ, month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit',
  })
}

export function fmtDate(iso: string | null | undefined): string {
  if (!iso) return ''
  // plain dates (YYYY-MM-DD) are calendar days, not instants
  if (/^\d{4}-\d{2}-\d{2}$/.test(iso)) {
    const [y, m, d] = iso.split('-').map(Number)
    return new Date(Date.UTC(y, m - 1, d)).toLocaleDateString('en-US', { timeZone: 'UTC', month: 'short', day: 'numeric', year: 'numeric' })
  }
  return new Date(iso).toLocaleDateString('en-US', { timeZone: TZ, month: 'short', day: 'numeric', year: 'numeric' })
}

/** Today's date in Milwaukee as YYYY-MM-DD. */
export function todayLocal(now: Date = new Date()): string {
  return new Intl.DateTimeFormat('en-CA', { timeZone: TZ, year: 'numeric', month: '2-digit', day: '2-digit' }).format(now)
}

/** Milwaukee's offset from UTC at an instant, in ms (e.g. -5h in summer). Works whatever the device's own time zone. */
function tzOffsetMs(at: Date): number {
  const parts = new Intl.DateTimeFormat('en-US', {
    timeZone: TZ, year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit', hourCycle: 'h23',
  }).formatToParts(at)
  const get = (t: string) => Number(parts.find((p) => p.type === t)?.value)
  const wall = Date.UTC(get('year'), get('month') - 1, get('day'), get('hour'), get('minute'), get('second'))
  return wall - Math.floor(at.getTime() / 1000) * 1000
}

/** A Milwaukee wall-clock time "YYYY-MM-DDTHH:MM[:SS]" -> the instant. */
function wallToInstant(wall: string): Date {
  const asUtc = new Date(`${wall.length === 16 ? `${wall}:00` : wall}Z`).getTime()
  let t = asUtc - tzOffsetMs(new Date(asUtc))
  t = asUtc - tzOffsetMs(new Date(t)) // second pass settles DST edges
  return new Date(t)
}

/** End of today in Milwaukee, as an ISO instant. */
export function endOfTodayIso(now: Date = new Date()): string {
  return wallToInstant(`${todayLocal(now)}T23:59:59`).toISOString()
}

export function fmtPhone(v: string | null | undefined): string {
  const d = (v || '').replace(/\D/g, '').replace(/^1(?=\d{10}$)/, '')
  return d.length === 10 ? `(${d.slice(0, 3)}) ${d.slice(3, 6)}-${d.slice(6)}` : v || ''
}

export function pct(v: number | null | undefined): string {
  return v === null || v === undefined ? '-' : `${(Number(v) * 100).toFixed(1)}%`
}

/** A datetime-local input value (Milwaukee time) -> ISO instant. */
export function localInputToIso(value: string): string | null {
  if (!value) return null
  return wallToInstant(value).toISOString()
}

/** ISO instant -> datetime-local input value in Milwaukee time. */
export function isoToLocalInput(iso: string | null | undefined): string {
  if (!iso) return ''
  const parts = new Intl.DateTimeFormat('en-CA', {
    timeZone: TZ, year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hourCycle: 'h23',
  }).formatToParts(new Date(iso))
  const get = (t: string) => parts.find((p) => p.type === t)?.value ?? ''
  return `${get('year')}-${get('month')}-${get('day')}T${get('hour')}:${get('minute')}`
}

/** "CITY OF RACINE" -> "Racine"; "TOWN OF ARBOR VITAE" -> "Arbor Vitae"; "Milwaukee" stays. */
export function cityOf(municipality: string | null | undefined): string {
  const m = (municipality ?? '').replace(/^\s*(CITY|VILLAGE|TOWN)\s+OF\s+/i, '').replace(/\s*\(.*?\)\s*/g, ' ').trim()
  if (!m) return ''
  return m === m.toUpperCase() ? m.toLowerCase().replace(/\b([a-z])/g, (c) => c.toUpperCase()) : m
}

function streetOf(address: string | null | undefined): string {
  const a = (address ?? '').split(';')[0].trim()
  if (!a || a !== a.toUpperCase()) return a
  return a.toLowerCase().replace(/\b([a-z])/g, (c) => c.toUpperCase()).replace(/\b(\d+)(St|Nd|Rd|Th)\b/g, (_, n: string, x: string) => n + x.toLowerCase())
    .replace(/\b([NSEW])\b/g, (c) => c.toUpperCase()).replace(/\b(Po)\b/g, 'PO')
}

/** The whole address a person reads on a card: "1205 N State St, Appleton, WI 54911" (Colin 2026-10-26: "why do the
 *  cards only show the damn street and address and not the city and state"). */
export function fullAddress(x: { property_address?: string | null; municipality?: string | null; property_zip?: string | null } | null | undefined): string {
  if (!x) return ''
  const street = streetOf(x.property_address)
  const city = cityOf(x.municipality)
  const zip = (x.property_zip ?? '').slice(0, 5)
  const tail = ['WI', zip].filter(Boolean).join(' ')
  if (!street && !city) return ''
  return [street, city, tail].filter(Boolean).join(', ')
}
