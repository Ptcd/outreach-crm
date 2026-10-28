/* eslint-disable react-refresh/only-export-components -- provider module intentionally exports its tested call helpers */
// The app's own dialer (Colin 2026-10-22: "make it so we can call out right from the property card ...
// app/browser based dialer"). Tap Call on a lead: the browser places the call through Twilio's Voice SDK
// from the signed-in person's identity; Twilio asks the TwiML App "WPIE app dialer" (pm-phone's
// /api/twilio/voice/client), which dials the owner and shows a seller number as caller ID. The
// hot-lead nag stops when a call starts (mark_called); the outcome is logged afterwards with the call desk's
// "Save the call" on the lead card (log_call, migration 0013). WPIE's follow-up texts stop on their own once
// the call shows in Twilio's log.
//
// Calls in, too (Colin 2026-10-22: "if a lead calls in should the app ring or have a call coming in thing
// and then show the property card stuff"): the Device registers under the person's identity, and a seller
// calling a seller line rings here as well as Colin's cell (pm-phone dials both; whoever answers first takes
// it). The caller's number is looked up on the call desk (phone_lookup) while it rings, so the bar names the
// owner and property; Accept runs the call in the same in-call bar, opens the lead card, and marks the hot
// alert as called. Only an app that is open on screen rings; otherwise the cell rings as before.
//
// A seller calling in while the caller is already on a call (Colin 2026-10-28: "if our inbound phone rings when she's
// calling out she should take that call"): it shows too (busy), with a short ring in the headset. Accept ends the
// call she is on and takes theirs; Power hour drops a call that is still only ringing out on its own.
import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { supabase } from './supabaseClient'
import { fmtPhone } from './format'
import { useAuth } from '@/providers/AuthProvider'
import type { PhoneMatch } from './queries'
import { callAttemptKey, callerLineFor, humanCallAuthorized, humanCallProviderParams } from './callAttempt'

// The seller line the call shows (the pool's main texting number). Any number in the seller pool works;
// pm-phone refuses one that is not ours.
export const CALLER_ID = (import.meta.env.VITE_SELLER_CALLER_ID as string | undefined) || '+12629996513'

export type CallStatus = 'idle' | 'connecting' | 'ringing' | 'in_call' | 'ended' | 'error'

export interface ActiveCall {
  status: CallStatus
  to: string             // the other party's number
  label: string          // "Laurie - 3424 N Main St"
  leadId: string | null
  startedAt: number | null
  muted: boolean
  error: string | null
  answered: boolean
  inbound: boolean       // they called us
  line: string | null    // the seller number they called (inbound only)
  quiet?: boolean        // Power hour asks the outcome on its own card, so the call bar does not
}

/** A call ringing in, before Accept / Decline. `matches` is null while the call desk is still looking. */
export interface IncomingCall {
  from: string
  line: string | null
  matches: PhoneMatch[] | null
  lookupError: string | null
  busy: boolean          // she was on a call when it rang: Accept ends that call
}

interface DialerApi {
  active: ActiveCall | null
  incoming: IncomingCall | null
  supported: boolean
  ready: boolean          // registered with Twilio: a seller's call can ring here
  start: (x: { to: string; label: string; leadId: string | null; contactId: string | null; quiet?: boolean }) => Promise<void>
  accept: () => Promise<{ leadId: string | null; phone: string } | null>
  decline: () => void
  hangUp: () => void
  toggleMute: () => void
  dismiss: () => void
}

type TwilioCall = import('@twilio/voice-sdk').Call
type TwilioDevice = import('@twilio/voice-sdk').Device

const Ctx = createContext<DialerApi | null>(null)

/** "Laurie - 3424 N Main St" from what the card knows. */
export function callLabel(name: string | null | undefined, address: string | null | undefined): string {
  return [name?.trim(), address?.trim()].filter(Boolean).join(' - ') || 'the owner'
}

/** The ten digits of a caller's number ("+14145551234" -> "4145551234"), or "" for a withheld number. */
export function callerDigits(from: string | null | undefined): string {
  const d = (from ?? '').replace(/\D/g, '').replace(/^1(?=\d{10}$)/, '')
  return d.length === 10 ? d : ''
}

/** The lead a caller most likely is: the exact-number match first, then the call desk's own order. */
export function pickInbound(matches: PhoneMatch[] | null | undefined): PhoneMatch | null {
  if (!matches?.length) return null
  return matches.find((m) => m.exact) ?? matches[0]
}

/** What the incoming bar says under the number. */
export function inboundLabel(from: string, matches: PhoneMatch[] | null | undefined): string {
  const pick = pickInbound(matches)
  if (!pick) return fmtPhone(from) || 'Withheld number'
  return callLabel(pick.owner_name, [pick.property_address, pick.municipality].filter(Boolean).join(', ') || null)
}

export function DialerProvider({ children }: { children: ReactNode }) {
  const { member } = useAuth()
  const qc = useQueryClient()
  const [active, setActive] = useState<ActiveCall | null>(null)
  const [incoming, setIncoming] = useState<IncomingCall | null>(null)
  const [ready, setReady] = useState(false)
  const deviceRef = useRef<TwilioDevice | null>(null)
  const callRef = useRef<TwilioCall | null>(null)
  const incomingRef = useRef<TwilioCall | null>(null)
  const lookupRef = useRef<Promise<PhoneMatch[]> | null>(null)
  const answeredRef = useRef(false)
  const supported = typeof window !== 'undefined' && !!navigator.mediaDevices && typeof RTCPeerConnection !== 'undefined'
  // the app's self-update (lib/appUpdate) never reloads during a call or while one is ringing in
  useEffect(() => {
    (window as Window & { __wpieOnCall?: boolean }).__wpieOnCall =
      (!!active && ['connecting', 'ringing', 'in_call'].includes(active.status)) || !!incoming
  }, [active, incoming])

  const finish = useCallback((status: CallStatus, error: string | null) => {
    callRef.current = null
    setActive((a) => (a ? { ...a, status, error, answered: answeredRef.current } : a))
  }, [])

  // A seller calling in: hold the call, look the number up, and let the bar ask Accept / Decline.
  const onIncoming = useCallback((call: TwilioCall) => {
    if (incomingRef.current) { call.reject(); return }   // one ringing in at a time
    incomingRef.current = call
    const busy = !!callRef.current
    if (busy) {   // Twilio stays quiet when a call is up: one short ring in her headset instead
      try { void new Audio('/sounds/ring.wav').play().catch(() => undefined) } catch { /* no audio here */ }
    }
    const from = call.parameters.From ?? ''
    const line = call.customParameters.get('line') ?? null
    const digits = callerDigits(from)
    setIncoming({ from, line, matches: null, lookupError: null, busy })
    const lookup: Promise<PhoneMatch[]> = (async () => {
      if (!digits) return []
      const r = await supabase.rpc('phone_lookup', { p_digits: digits })
      if (r.error) throw new Error(r.error.message)
      return (r.data ?? []) as PhoneMatch[]
    })()
    lookupRef.current = lookup
    const stillThis = (i: IncomingCall | null) => i && i.from === from && incomingRef.current === call
    lookup.then((m) => setIncoming((i) => (stillThis(i) ? { ...i!, matches: m } : i)))
      .catch((e: unknown) => setIncoming((i) => (stillThis(i) ? { ...i!, matches: [], lookupError: e instanceof Error ? e.message : String(e) } : i)))
    const gone = () => {   // the caller hung up, or Colin's cell answered first
      if (incomingRef.current === call) { incomingRef.current = null; lookupRef.current = null; setIncoming(null) }
    }
    call.on('cancel', gone)
    call.on('reject', gone)
    call.on('disconnect', () => { if (callRef.current === call) finish('ended', null); else gone() })
    call.on('error', (e: { message?: string }) => { if (callRef.current === call) finish('error', e?.message ?? 'Call failed'); else gone() })
  }, [finish])

  const device = useCallback(async () => {
    if (deviceRef.current) return deviceRef.current
    const r = await supabase.functions.invoke('voice-token')
    if (r.error) throw new Error(r.error.message)
    const d = r.data as { token?: string; error?: string }
    if (!d.token) throw new Error(d.error ?? 'No dialer token')
    const { Device } = await import('@twilio/voice-sdk')
    // our own ring for incoming calls (Colin 2026-10-27: "change the phone ringing tone"): a desk-phone double ring,
    // public/sounds/ring.wav, in place of Twilio's default
    // allowIncomingWhileBusy: a seller calling in while she is on a call still shows (Twilio's default ignores it)
    const dev = new Device(d.token, { closeProtection: true, logLevel: 'error', allowIncomingWhileBusy: true, sounds: { incoming: '/sounds/ring.wav' } as never })
    dev.on('tokenWillExpire', async () => {
      const rr = await supabase.functions.invoke('voice-token')
      const dd = rr.data as { token?: string } | null
      if (dd?.token) dev.updateToken(dd.token)
    })
    dev.on('registered', () => setReady(true))
    dev.on('unregistered', () => setReady(false))
    dev.on('error', () => setReady(dev.state === 'registered'))
    dev.on('incoming', onIncoming)
    deviceRef.current = dev
    await dev.register().catch(() => undefined)   // without this, calling out still works; only ringing in is lost
    return dev
  }, [onIncoming])

  // Registered as soon as a team member is signed in, so a seller's call can ring here; re-registered when
  // the phone comes back online or the app comes back on screen.
  useEffect(() => {
    if (!supported || !member) return
    let alive = true
    void device().catch(() => { if (alive) setReady(false) })
    const kick = () => {
      const dev = deviceRef.current
      if (dev && dev.state === 'unregistered' && (typeof document === 'undefined' || document.visibilityState !== 'hidden')) {
        void dev.register().catch(() => undefined)
      }
    }
    window.addEventListener('online', kick)
    document.addEventListener('visibilitychange', kick)
    return () => { alive = false; window.removeEventListener('online', kick); document.removeEventListener('visibilitychange', kick) }
  }, [supported, member, device])

  // A call that ended or failed before pm-phone claimed it never rang anyone: un-pause its card at once.
  // The database decides (migration 0043); a call that was placed stays paused for its outcome.
  const releaseIfUnclaimed = useCallback((leadId: string, key: string) => {
    void Promise.resolve(supabase.rpc('release_unclaimed_human_call', { p_lead_id: leadId, p_key: key }))
      .then(() => qc.invalidateQueries({ queryKey: ['lead', leadId] }))
      .catch(() => undefined)   // the minute sweep releases it anyway
  }, [qc])

  // Closing or leaving the page hangs up: no call is left running in a tab nobody is looking at.
  useEffect(() => {
    const hang = () => { callRef.current?.disconnect() }
    window.addEventListener('pagehide', hang)
    return () => window.removeEventListener('pagehide', hang)
  }, [])

  const start = useCallback<DialerApi['start']>(async ({ to, label, leadId, contactId, quiet }) => {
    if (callRef.current || incomingRef.current) return
    answeredRef.current = false
    setActive({ status: 'connecting', to, label, leadId, startedAt: null, muted: false, error: null, answered: false, inbound: false, line: null, quiet: !!quiet })
    let takeoverKey: string | null = null
    try {
      const dev = await device()
      if (!leadId) throw new Error('Open the property card before calling this number.')
      // The microphone first, before anything is authorized: a permission prompt nobody answers, or a
      // refusal, never leaves the card paused.
      const mic = await navigator.mediaDevices.getUserMedia({ audio: true })
      mic.getTracks().forEach((t) => t.stop())
      takeoverKey = callAttemptKey()
      const begin = () => supabase.rpc('begin_human_call', { p_lead_id: leadId, p_phone: to, p_source: 'app', p_key: takeoverKey })
      let gate = await begin()
      // a card busy for a moment (the laptop's sync writing it) can time the check out: one quiet retry before
      // showing an error (2026-10-28: "Call failed ... canceling statement due to statement timeout")
      if (gate.error && /statement timeout|lock timeout|deadlock/i.test(gate.error.message)) {
        await new Promise((r) => setTimeout(r, 1500))
        gate = await begin()
      }
      const allowed = gate.data as { ok?: boolean; paused?: boolean; reason?: string } | null
      if (gate.error || !humanCallAuthorized(allowed)) throw new Error(gate.error?.message ?? allowed?.reason ?? 'Call authorization is not active')
      void contactId
      const thread = await supabase.from('messages').select('direction, channel, from_number, to_number, sent_at')
        .eq('lead_id', leadId).eq('channel', 'sms').order('sent_at', { ascending: false }).limit(50)
      const line = callerLineFor(to, (thread.data ?? []) as Parameters<typeof callerLineFor>[1], CALLER_ID)
      const call = await dev.connect({ params: humanCallProviderParams(to, line, leadId, takeoverKey) })
      callRef.current = call
      call.on('ringing', () => setActive((a) => (a ? { ...a, status: 'ringing' } : a)))
      call.on('accept', () => {
        answeredRef.current = true
        setActive((a) => (a ? { ...a, status: 'in_call', startedAt: Date.now() } : a))
      })
      const key = takeoverKey
      const ended = () => releaseIfUnclaimed(leadId, key)
      // a call she ended to take one ringing in no longer owns the bar: only its card is released
      const mine = () => callRef.current === call
      call.on('disconnect', () => { if (mine()) finish('ended', null); ended() })
      call.on('cancel', () => { if (mine()) finish('ended', null); ended() })
      call.on('reject', () => { if (mine()) finish('ended', 'They declined the call.'); ended() })
      call.on('error', (e: { message?: string }) => { if (mine()) finish('error', e?.message ?? 'Call failed'); ended() })
    } catch (e) {
      // Authorized but the call failed: released if pm-phone never claimed it (nobody rang); a claimed
      // call stays paused for its outcome, with "call did not happen — resume" on the card.
      if (takeoverKey && leadId) releaseIfUnclaimed(leadId, takeoverKey)
      const msg = e instanceof Error ? e.message : String(e)
      finish('error', /Permission|NotAllowed|microphone/i.test(msg) ? 'Allow the microphone to call from here.' : msg)
    }
  }, [device, finish, releaseIfUnclaimed])

  // Accept the ringing call: it runs in the in-call bar; the matched lead (once the lookup is back) is
  // marked called and handed to the caller so the bar can open its card.
  const accept = useCallback<DialerApi['accept']>(async () => {
    const call = incomingRef.current
    if (!call) return null
    incomingRef.current = null
    const lookup = lookupRef.current ?? Promise.resolve([])
    lookupRef.current = null
    const from = call.parameters.From ?? ''
    const line = call.customParameters.get('line') ?? null
    const digits = callerDigits(from)
    const was = callRef.current   // the call she was on: it ends, theirs is answered
    if (was && was !== call) { callRef.current = null; was.disconnect() }
    answeredRef.current = true
    callRef.current = call
    setIncoming(null)
    setActive({ status: 'in_call', to: from, label: fmtPhone(from) || 'Withheld number', leadId: null, startedAt: Date.now(),
      muted: false, error: null, answered: true, inbound: true, line })
    call.accept()
    const matches = await lookup.catch(() => [] as PhoneMatch[])
    const pick = pickInbound(matches)
    if (pick) {
      setActive((a) => (a && a.inbound && a.to === from ? { ...a, leadId: pick.lead_id, label: inboundLabel(from, matches) } : a))
      void supabase.rpc('mark_called', { p_lead_id: pick.lead_id })   // the hot-lead reminders stop
    }
    return { leadId: pick?.lead_id ?? null, phone: digits }
  }, [])

  // Decline here only: Colin's cell keeps ringing, then voicemail, exactly as before the app existed.
  const decline = useCallback(() => {
    const call = incomingRef.current
    if (!call) return
    incomingRef.current = null
    lookupRef.current = null
    setIncoming(null)
    call.reject()
  }, [])

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

  const value = useMemo<DialerApi>(() => ({ active, incoming, supported, ready, start, accept, decline, hangUp, toggleMute, dismiss }),
    [active, incoming, supported, ready, start, accept, decline, hangUp, toggleMute, dismiss])
  return <Ctx.Provider value={value}>{children}</Ctx.Provider>
}

const NO_DIALER: DialerApi = {
  active: null, incoming: null, supported: false, ready: false, start: async () => undefined, accept: async () => null,
  decline: () => undefined, hangUp: () => undefined, toggleMute: () => undefined, dismiss: () => undefined,
}

/** Outside DialerProvider (tests, previews) the dialer is simply unavailable: buttons render disabled. */
export function useDialer(): DialerApi {
  return useContext(Ctx) ?? NO_DIALER
}

export function fmtDuration(ms: number): string {
  const s = Math.max(0, Math.floor(ms / 1000))
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`
}
