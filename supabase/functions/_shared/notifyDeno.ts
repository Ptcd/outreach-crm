// Wiring for the notifications inside an Edge Function (Deno): push subscriptions from the
// database, Web Push with the VAPID secret, email through Gmail SMTP on port 465.
// Secrets: VAPID_PUBLIC_KEY, VAPID_PRIVATE_JWK (push); SMTP_USER, SMTP_PASSWORD, NOTIFY_EMAIL_TO
// (email; SMTP_HOST defaults to smtp.gmail.com). A missing group just turns that channel off.
import type { SupabaseClient } from 'npm:@supabase/supabase-js@2.56.1'
import type { NotifyDeps } from './notify.ts'
import type { Rpc } from './sending.ts'
import { sendMail } from './smtp.ts'
import { sendPush, vapidFromEnv, type PushSubscriptionKeys } from './webpush.ts'

export function notifyDeps(sb: SupabaseClient, rpc: Rpc): NotifyDeps {
  const get = (n: string) => Deno.env.get(n)
  const vapid = vapidFromEnv(get)
  const user = get('SMTP_USER') ?? ''
  const pass = get('SMTP_PASSWORD') ?? ''
  const host = get('SMTP_HOST') || 'smtp.gmail.com'
  const from = get('SMTP_FROM') || user
  return {
    rpc,
    appUrl: get('NOTIFY_APP_URL') || 'https://deals.junkcarsmequon.com',
    emailTo: get('NOTIFY_EMAIL_TO') || null,
    subscriptions: async () => {
      const r = await sb.from('push_subscriptions').select('endpoint, p256dh, auth')
      return (r.data ?? []) as PushSubscriptionKeys[]
    },
    push: vapid ? (sub, message) => sendPush(sub, message, vapid, fetch) : null,
    email: user && pass
      ? async (m) => {
        // Edge Functions may not use port 587; Gmail takes implicit TLS on 465.
        const conn = await Deno.connectTls({ hostname: host, port: 465 })
        await sendMail(conn, { user, pass }, { ...m, from })
      }
      : null,
  }
}
