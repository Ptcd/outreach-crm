// The dialer's Twilio access token: shaped like twilio-node's AccessToken (Voice grant, outgoing through the
// TwiML App and incoming so the app rings, one hour), and signed with the API key secret so Twilio can verify it.
import { createHmac } from 'node:crypto'
import { describe, expect, it } from 'vitest'
import { decodeToken, voiceToken } from '../supabase/functions/_shared/voiceToken'

const opts = { accountSid: 'ACtest', apiKeySid: 'SKtest', apiKeySecret: 'shh-not-a-real-secret', appSid: 'APtest', identity: 'thalia', now: 1_760_000_000 }

describe('voice token', () => {
  it('carries the voice grant for this person, both ways, and nothing else', async () => {
    const tok = await voiceToken(opts)
    const { header, payload } = decodeToken(tok)
    expect(header).toEqual({ typ: 'JWT', alg: 'HS256', cty: 'twilio-fpa;v=1' })
    expect(payload.iss).toBe('SKtest')
    expect(payload.sub).toBe('ACtest')
    expect(payload.exp).toBe(1_760_000_000 + 3600)
    expect(payload.grants).toEqual({
      identity: 'thalia', voice: { outgoing: { application_sid: 'APtest' }, incoming: { allow: true } },
    })
  })
  it('lets a seller call ring this person (incoming allowed) under their own identity only', async () => {
    const { payload } = decodeToken(await voiceToken({ ...opts, identity: 'colin' }))
    const grants = payload.grants as { identity: string; voice: { incoming: { allow: boolean } } }
    expect(grants.identity).toBe('colin')
    expect(grants.voice.incoming.allow).toBe(true)
    expect(Object.keys(grants)).toEqual(['identity', 'voice'])
  })
  it('is signed with the API key secret', async () => {
    const tok = await voiceToken(opts)
    const [h, p, s] = tok.split('.')
    const expected = createHmac('sha256', opts.apiKeySecret).update(`${h}.${p}`).digest('base64url')
    expect(s).toBe(expected)
    expect(tok).not.toContain(opts.apiKeySecret)
  })
})
