// The app's own dialer (Colin 2026-10-22: "make it so we can call out right from the property card ...
// app/browser based dialer"). Tap Call on a lead: the browser places the call through Twilio's Voice SDK
// from the signed-in person's identity; Twilio asks the TwiML App "WPIE app dialer" (pm-phone's
// /api/twilio/voice/client), which dials the owner and shows a seller number as caller ID. The call is
// hot-lead nag stops when a call starts (mark_called); the outcome is logged afterwards with the call desk's
// "Save the call" on the lead card (log_call, migration 0013). WPIE's follow-up texts stop on their own once
// the call shows in Twilio's log.
import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from 'react'
import { supabase } from './supabaseClient'

// The seller line the call shows (the pool's main texting number). Any number in the seller pool works;
// pm-phone refuses one that is not ours.
export const CALLER_ID = (import.meta.env.VITE_SELLER_CALLER_ID as string | undefined) || '+12629996513'

export type CallStatus = 'idle' | 'connecting' | 'ringing' | 'in_call' | 'ended' | 'error'

export interface ActiveCall {
  status: CallStatus
  to: string
  label: string          // "Laurie - 3424 N Main St"
  leadId: string | null
  startedAt: number | null
  muted: boolean
  error: string | null
  answered: boolean
}

interface DialerApi {
  active: ActiveCall | null
  supported: boolean
  start: (x: { to: string; label: string; leadId: string | null; contactId: string | null }) => Promise<void>
  hangUp: () => void
  toggleMute: () => void
  dismiss: () => void
}

const Ctx = createContext<DialerApi | null>(null)

/** "Laurie - 3424 N Main St" from what the card knows. */
export function callLabel(name: string | null | undefined, address: string | null | undefined): string {
  return [name?.trim(), address?.trim()].filter(Boolean).join(' - ') || 'the owner'
}

export function DialerProvider({ children }: { children: ReactNode }) {
  const [active, setActive] = useState<ActiveCall | null>(null)
  const deviceRef = useRef<import('@twilio/voice-sdk').Device | null>(null)
  const callRef = useRef<import('@twilio/voice-sdk').Call | null>(null)
  const answeredRef = useRef(false)
  const supported = typeof window !== 'undefined' && !!navigator.mediaDevices && typeof RTCPeerConnection !== 'undefined'

  const device = useCallback(async () => {
    if (deviceRef.current) return deviceRef.current
    const r = await supabase.functions.invoke('voice-token')
    if (r.error) throw new Error(r.error.message)
    const d = r.data as { token?: string; error?: string }
    if (!d.token) throw new Error(d.error ?? 'No dialer token')
    const { Device } = await import('@twilio/voice-sdk')
    const dev = new Device(d.token, { closeProtection: true, logLevel: 'error' })
    dev.on('tokenWillExpire', async () => {
      const rr = await supabase.functions.invoke('voice-token')
      const dd = rr.data as { token?: string } | null
      if (dd?.token) dev.updateToken(dd.token)
    })
    await dev.register().catch(() => undefined)   // outgoing only; registering is optional
    deviceRef.current = dev
    return dev
  }, [])

  const finish = useCallback((status: CallStatus, error: string | null) => {
    callRef.current = null
    setActive((a) => (a ? { ...a, status, error, answered: answeredRef.current } : a))
  }, [])

  const start = useCallback<DialerApi['start']>(async ({ to, label, leadId, contactId }) => {
    if (callRef.current) return
    answeredRef.current = false
    setActive({ status: 'connecting', to, label, leadId, startedAt: null, muted: false, error: null, answered: false })
    try {
      const dev = await device()
      if (leadId) void supabase.rpc('mark_called', { p_lead_id: leadId })   // the hot-lead reminders stop
      void contactId
      const call = await dev.connect({ params: { To: to, line: CALLER_ID } })
      callRef.current = call
      call.on('ringing', () => setActive((a) => (a ? { ...a, status: 'ringing' } : a)))
      call.on('accept', () => {
        answeredRef.current = true
        setActive((a) => (a ? { ...a, status: 'in_call', startedAt: Date.now() } : a))
      })
      call.on('disconnect', () => finish('ended', null))
      call.on('cancel', () => finish('ended', null))
      call.on('reject', () => finish('ended', 'They declined the call.'))
      call.on('error', (e: { message?: string }) => finish('error', e?.message ?? 'Call failed'))
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e)
      finish('error', /Permission|NotAllowed|microphone/i.test(msg) ? 'Allow the microphone to call from here.' : msg)
    }
  }, [device, finish])

  const hangUp = useCallback(() => {
    callRef.current?.disconnect()
    if (!callRef.current) finish('ended', null)
  }, [finish])

  const toggleMute = useCallback(() => {
    const c = callRef.current
    if (!c) return
    const next = !c.isMuted()
    c.mute(next)
    setActive((a) => (a ? { ...a, muted: next } : a))
  }, [])

  const dismiss = useCallback(() => setActive((a) => (a && (a.status === 'ended' || a.status === 'error') ? null : a)), [])

  useEffect(() => () => { deviceRef.current?.destroy() }, [])

  const value = useMemo<DialerApi>(() => ({ active, supported, start, hangUp, toggleMute, dismiss }),
    [active, supported, start, hangUp, toggleMute, dismiss])
  return <Ctx.Provider value={value}>{children}</Ctx.Provider>
}

const NO_DIALER: DialerApi = {
  active: null, supported: false, start: async () => undefined, hangUp: () => undefined, toggleMute: () => undefined,
  dismiss: () => undefined,
}

/** Outside DialerProvider (tests, previews) the dialer is simply unavailable: buttons render disabled. */
export function useDialer(): DialerApi {
  return useContext(Ctx) ?? NO_DIALER
}

export function fmtDuration(ms: number): string {
  const s = Math.max(0, Math.floor(ms / 1000))
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`
}
