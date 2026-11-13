import { useEffect, useRef, useState } from 'react'
import { Button } from '@/components/ui/button'

// Draw a signature with a finger or mouse. Calls onChange with a PNG data URL, or null when cleared.
// Leaving it empty is fine: the typed name is then used as the signature. The PNG is cropped to the ink,
// so a small signature in a big box still prints at full size on the form's signature line.
export function SignaturePad({ onChange, label = 'Sign here' }: { onChange: (png: string | null) => void; label?: string }) {
  const ref = useRef<HTMLCanvasElement>(null)
  const drawing = useRef(false)
  const ink = useRef<{ x0: number; y0: number; x1: number; y1: number } | null>(null)
  const grow = (p: { x: number; y: number }) => {
    const b = ink.current
    ink.current = b ? { x0: Math.min(b.x0, p.x), y0: Math.min(b.y0, p.y), x1: Math.max(b.x1, p.x), y1: Math.max(b.y1, p.y) } : { x0: p.x, y0: p.y, x1: p.x, y1: p.y }
  }
  /** The drawing, cropped to the ink with a little margin. */
  const cropped = (): string | null => {
    const c = ref.current
    if (!c) return null
    const b = ink.current
    const k = c.width / (c.clientWidth || c.width)
    if (!b || !k) return c.toDataURL('image/png')
    const pad = 8
    const sx = Math.max(0, Math.floor((b.x0 - pad) * k))
    const sy = Math.max(0, Math.floor((b.y0 - pad) * k))
    const w = Math.min(c.width - sx, Math.ceil((b.x1 - b.x0 + 2 * pad) * k))
    const h = Math.min(c.height - sy, Math.ceil((b.y1 - b.y0 + 2 * pad) * k))
    const out = document.createElement('canvas')
    out.width = Math.max(1, w)
    out.height = Math.max(1, h)
    const ctx = out.getContext('2d')
    if (!ctx) return c.toDataURL('image/png')
    ctx.drawImage(c, sx, sy, w, h, 0, 0, w, h)
    return out.toDataURL('image/png')
  }
  const [empty, setEmpty] = useState(true)

  useEffect(() => {
    const c = ref.current
    if (!c) return
    const ratio = Math.max(1, window.devicePixelRatio || 1)
    const w = c.clientWidth || 320
    const h = c.clientHeight || 140
    c.width = w * ratio
    c.height = h * ratio
    const ctx = c.getContext('2d')
    if (!ctx) return
    ctx.scale(ratio, ratio)
    ctx.lineWidth = 2.4
    ctx.lineCap = 'round'
    ctx.lineJoin = 'round'
    ctx.strokeStyle = '#0d1a73'
  }, [])

  const pos = (e: React.PointerEvent<HTMLCanvasElement>) => {
    const r = e.currentTarget.getBoundingClientRect()
    return { x: e.clientX - r.left, y: e.clientY - r.top }
  }
  const down = (e: React.PointerEvent<HTMLCanvasElement>) => {
    const ctx = e.currentTarget.getContext('2d')
    if (!ctx) return
    e.currentTarget.setPointerCapture(e.pointerId)
    drawing.current = true
    const p = pos(e)
    grow(p)
    ctx.beginPath()
    ctx.moveTo(p.x, p.y)
    ctx.lineTo(p.x + 0.1, p.y + 0.1)
    ctx.stroke()
  }
  const move = (e: React.PointerEvent<HTMLCanvasElement>) => {
    if (!drawing.current) return
    const ctx = e.currentTarget.getContext('2d')
    if (!ctx) return
    const p = pos(e)
    grow(p)
    ctx.lineTo(p.x, p.y)
    ctx.stroke()
  }
  const up = () => {
    if (!drawing.current) return
    drawing.current = false
    setEmpty(false)
    onChange(cropped())
  }
  const clear = () => {
    const c = ref.current
    const ctx = c?.getContext('2d')
    if (!c || !ctx) return
    ctx.save()
    ctx.setTransform(1, 0, 0, 1, 0, 0)
    ctx.clearRect(0, 0, c.width, c.height)
    ctx.restore()
    ink.current = null
    setEmpty(true)
    onChange(null)
  }

  return (
    <div>
      <div className="flex items-center justify-between">
        <span className="text-sm font-medium">{label}</span>
        <Button type="button" variant="ghost" size="sm" onClick={clear} disabled={empty}>Clear</Button>
      </div>
      <canvas
        ref={ref}
        aria-label={label}
        className="mt-1 h-36 w-full touch-none rounded-md border-2 border-dashed bg-white"
        onPointerDown={down}
        onPointerMove={move}
        onPointerUp={up}
        onPointerCancel={up}
        onPointerLeave={up}
      />
      <p className="mt-1 text-xs text-muted-foreground">{empty ? 'Draw with your finger, or leave it empty to sign with your typed name.' : 'Signature drawn.'}</p>
    </div>
  )
}
