import { useEffect, useRef, useState } from 'react'
import { Button } from '@/components/ui/button'

// Draw a signature with a finger or mouse. Calls onChange with a PNG data URL, or null when cleared.
// Leaving it empty is fine: the typed name is then used as the signature.
export function SignaturePad({ onChange, label = 'Sign here' }: { onChange: (png: string | null) => void; label?: string }) {
  const ref = useRef<HTMLCanvasElement>(null)
  const drawing = useRef(false)
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
    ctx.lineTo(p.x, p.y)
    ctx.stroke()
  }
  const up = () => {
    if (!drawing.current) return
    drawing.current = false
    setEmpty(false)
    onChange(ref.current?.toDataURL('image/png') ?? null)
  }
  const clear = () => {
    const c = ref.current
    const ctx = c?.getContext('2d')
    if (!c || !ctx) return
    ctx.save()
    ctx.setTransform(1, 0, 0, 1, 0, 0)
    ctx.clearRect(0, 0, c.width, c.height)
    ctx.restore()
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
