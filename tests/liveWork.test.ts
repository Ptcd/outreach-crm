// 0269 (Colin 2026-11-21, shown that Muse's most frequent scheduled run is a texting check every 5 minutes: "it has this
// on cron, why don't we give it an instruction packet to read and do when there is a live one then push it to you and
// then you ping our team member with the card"). live_work is the one call that run makes first; when the prices and the
// story land, the card's caller is told, once for each, and nobody else's caller.
import { readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { PGlite } from '@electric-sql/pglite'
import { beforeAll, describe, expect, it } from 'vitest'
import { SUPABASE_STUB } from './supabaseStub'
import { callTool, type Agent, type DoorDb } from '../supabase/functions/_shared/agentDoor'
import { runYesReadyAlerts, yesReadyMessage, type YesReady } from '../supabase/functions/_shared/yesReady'

const MIGRATIONS_DIR = path.resolve(__dirname, '../supabase/migrations')
const MIGRATION = readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith('.sql')).sort()
  .map((f) => readFileSync(path.join(MIGRATIONS_DIR, f), 'utf8')).join('\n')

let db: PGlite
type Json = Record<string, any>
const YES = '00000000-0000-0000-0000-00000000f001'     // Tyler's card
const LATER = '00000000-0000-0000-0000-00000000f002'   // Thalia's card, a yes that comes after
const THIRD = '00000000-0000-0000-0000-00000000f003'   // another card of Tyler's
const DAY = '2026-11-18T18:00:00Z'                       // a Wednesday, noon Central
const NIGHT = '2026-11-19T05:00:00Z'                     // 11 PM Central
const records = async (fn: string, args: Record<string, unknown>) => {
  const keys = Object.keys(args)
  await db.exec('set role service_role')
  try { return (await db.query<{ r: unknown }>(`select public.${fn}(${keys.map((k, i) => `${k} => $${i + 1}`).join(', ')}) as r`, keys.map((k) => typeof args[k] === 'object' && args[k] !== null ? JSON.stringify(args[k]) : args[k]))).rows[0].r }
  finally { await db.exec('reset role') }
}
const rpc = async (fn: string, args: Record<string, unknown>) => {
  const keys = Object.keys(args)
  await db.exec('set role service_role')
  try {
    const r = await db.query<{ r: unknown }>(`select public.${fn}(${keys.map((k, i) => `${k} => $${i + 1}${k === 'p_ids' ? '::uuid[]' : ''}`).join(', ')}) as r`, keys.map((k) => args[k]))
    return { data: r.rows[0].r, error: null }
  } finally { await db.exec('reset role') }
}
const muse: Agent = { id: 'k1', name: 'Muse', role: 'agent', scopes: ['marks', 'texting'], tools: null }
const call = async (name: string, args: Json = {}) => (await callTool(name, args, muse, { records } as unknown as DoorDb)) as { value: any; isError?: boolean }
const comps = (n: number) => Array.from({ length: n }, (_, i) => ({ address: `${10 + i} Near St`, sold_price: 200000 + i * 5000, sold_date: '2026-09-01', sqft: 1400 }))
const STREET = { image_date: 'June 2023', seen: [{ item: 'roof', cost: 12000, note: 'shingles curling' }] }
const PRICES = [{ inside: 'Inside light', repairs: 33000, repairs_basis: 'roof + paint and floors', open: 103500, top: 114000 },
  { inside: 'Inside heavy', repairs: 96000, repairs_basis: 'roof + a full gut', open: 40500, top: 51000 }]
const SCRIPT = ['**Open**', '"Hi Pat, this is Tyler. You wrote back about the house on Racine."', '', '**What is owed**',
  '"So there are no surprises for either of us: is there a mortgage, or anything owed against it?"', '', '**The house**', '"How is the roof, honestly? The furnace?"', '',
  '**Who decides**', '"Are you the only one who signs?"', '', '**Money**', 'Use the row on the card that fits what Pat says about the inside.', '',
  '**Close - if there is no mortgage**', '"If we put it in writing today, are we doing it?"', '', '**Close - if there is one**',
  '"It is paid at closing out of the price and the rest is yours."'].join('\n')
const claim = async (now: string) => (await rpc('yes_ready_claim', { p_now: now })).data as YesReady[]

beforeAll(async () => {
  db = new PGlite()
  await db.exec(SUPABASE_STUB)
  await db.exec(MIGRATION)
  await db.exec(`
    insert into public.team_members (email, role, person, display_name, alert_email) values
      ('colin@example.com', 'owner', 'colin', 'Colin', 'colin-alerts@example.com'), ('adil@example.com', 'caller', 'adil', 'Tyler', 'tyler-alerts@example.com'),
      ('thalia@example.com', 'caller', 'thalia', 'Thalia', null)
    on conflict (email) do update set role = excluded.role, person = excluded.person, display_name = excluded.display_name, alert_email = excluded.alert_email;
    insert into public.leads (id, wpie_owner_id, owner_name, lane, stage, property_address, municipality, county, mailing_state, locked_to, assigned_to) values
      ('${YES}', 9601, 'PAT SELLER', 'flip', 'reply_received', '1208 RACINE ST', 'CITY OF TEST', 'Brown', 'WI', 'adil', 'adil'),
      ('${LATER}', 9602, 'LEE LATER', 'flip', 'reply_received', '7 LATER LN', 'CITY OF TEST', 'Brown', 'WI', 'thalia', 'thalia'),
      ('${THIRD}', 9603, 'NO CALLER', 'flip', 'reply_received', '3 EMPTY CT', 'CITY OF TEST', 'Brown', 'WI', 'adil', 'adil');`)
}, 180_000)

describe('the live work packet', () => {
  it('nothing live is one short line, and no note rides on the other tools', async () => {
    expect((await call('live_work')).value).toEqual({ live: 0, say: 'Nothing live: no seller who said yes is waiting on you. Carry on with this run.' })
    expect((await records('agent_attention', { p_agent: 'Muse' }) as Json | null)?.live).toBeUndefined()
  })

  it('a yes puts the card in the packet with what is owed on it, the newest yes first, and every tool result says so', async () => {
    await db.exec(`update public.leads set belt = 'yes_unbooked', belt_step = 1 where id = '${YES}'`)
    await db.exec(`update public.text_offers set opened_at = now() - interval '5 minutes' where lead_id = '${YES}'`)
    await db.exec(`update public.leads set belt = 'yes_unbooked', belt_step = 1 where id = '${LATER}'`)
    const w = (await call('live_work')).value
    expect(w.live).toBe(2)
    expect(w.say).toMatch(/^2 sellers said yes and are waiting on you.*before anything else in this run, the newest yes first\.$/)
    expect(w.packet).toMatch(/^WHEN A SELLER HAS SAID YES/)
    expect(w.packet).toMatch(/a roof you can see is in every row/)
    expect(w.cards.map((c: Json) => c.address)).toEqual(['7 LATER LN', '1208 RACINE ST'])
    expect(w.cards[1]).toMatchObject({ lead_id: YES, owner_name: 'PAT SELLER', caller: 'tyler' })
    expect(w.cards[1].todo.map((t: Json) => t.what)).toEqual(['comp', 'call_prices', 'brief'])
    expect(w.cards[1].todo[0].do).toMatch(/^They said YES and a caller is being told to phone them\. Comp it NOW/)
    expect(String((await records('agent_attention', { p_agent: 'Muse' }) as Json).live)).toMatch(/^2 sellers said yes and are waiting on you/)
    expect((await records('agent_attention', { p_agent: 'Muse 2' }) as Json | null)?.live).toBeUndefined()   // the texting agent's job only
  })

  it('the comp alone tells no caller; the prices landing tells the card\'s caller once, and nobody else', async () => {
    expect((await call('offer_update', { lead_id: YES, arv: 210000, arv_basis: 'three sold within half a mile', comps: comps(3), sqft: 1400 })).value.ok).toBe(true)
    expect(await claim(DAY)).toEqual([])
    expect((await call('live_work')).value.cards.find((c: Json) => c.lead_id === YES).todo.map((t: Json) => t.what)).toEqual(['call_prices', 'brief'])
    expect((await call('offer_update', { lead_id: YES, street: STREET, call_prices: PRICES })).value.ok).toBe(true)
    expect(await claim(NIGHT)).toEqual([])                                   // held in quiet hours
    const told = await claim(DAY)
    expect(told).toHaveLength(1)
    expect(told[0]).toMatchObject({ lead_id: YES, person: 'adil', email: 'tyler-alerts@example.com', landed: ['prices'], prices: true, brief: false, has_caller: true })
    const m = yesReadyMessage(told[0], 'https://app.example.com/')
    expect(m.title).toBe('Ready to call: Pat, 1208 RACINE ST')
    expect(m.body).toBe('They said yes. The value and the prices are on the card; the story is still being written. Call now.')
    expect(m.url).toBe(`https://app.example.com/lead/${YES}`)
    expect(m.text + m.html).not.toMatch(/\$\d/)                              // the numbers stay on the card
    expect(await claim(DAY)).toEqual([])                                     // handed out once
    await call('offer_update', { lead_id: YES, street: STREET, call_prices: PRICES })   // stored again: no second alert
    expect(await claim(DAY)).toEqual([])
    expect((await call('live_work')).value.cards.find((c: Json) => c.lead_id === YES).todo.map((t: Json) => t.what)).toEqual(['brief'])
  })

  it('the story landing tells the caller again; then the card is out of the packet', async () => {
    const set = await call('call_brief_set', { lead_id: YES, story: 'Pat inherited the house in March and lives two hours away. The furnace died and the roof leaks.',
      owed: [{ kind: 'tax', creditor: 'City of Test', amount: 4200, basis: 'the tax roll, read today', follows_house: 'yes' }],
      unknowns: ['whether there is a mortgage'], script: SCRIPT, sources: ['the tax roll'] })
    expect(set.isError).toBeFalsy()
    const told = await claim(DAY)
    expect(told).toHaveLength(1)
    expect(told[0]).toMatchObject({ lead_id: YES, person: 'adil', landed: ['brief'], prices: true, brief: true })
    expect(yesReadyMessage(told[0], 'https://app.example.com').body).toBe('They said yes. The value, the prices and the script are on the card. Read it and call.')
    const w = (await call('live_work')).value
    expect(w.live).toBe(1)
    expect(w.cards.map((c: Json) => c.lead_id)).toEqual([LATER])
  })

  it('the sender pushes the caller\'s phone and emails their alert address, and writes down what got through', async () => {
    await db.exec(`update public.leads set belt = 'yes_unbooked', belt_step = 1 where id = '${THIRD}'`)
    await call('offer_update', { lead_id: THIRD, arv: 210000, arv_basis: 'three sold', comps: comps(3), sqft: 1400, street: STREET, call_prices: PRICES })
    await call('offer_update', { lead_id: LATER, arv: 210000, arv_basis: 'three sold', comps: comps(3), sqft: 1400, street: STREET, call_prices: PRICES })
    const pushes: string[] = []; const mails: string[] = []
    const s = await runYesReadyAlerts({ rpc, appUrl: 'https://app.example.com', now: () => new Date(DAY),
      push: async (person, m) => { pushes.push(`${person}: ${m.title}`); return person === 'thalia' ? 0 : 1 },
      email: async (m) => { mails.push(`${m.to}: ${m.subject}`) } })
    expect(s).toMatchObject({ cards: 2, pushes: 1, emails: 1, nothing: 1, errors: [] })
    // Tyler's phone and his alert address; Thalia has no phone registered and no alert address, and that is written down
    expect(pushes.sort()).toEqual(['adil: Ready to call: No, 3 EMPTY CT', 'thalia: Ready to call: Lee, 7 LATER LN'])
    expect(mails).toEqual(['tyler-alerts@example.com: Ready to call: No, 3 EMPTY CT'])
    const rows = (await db.query<Json>(`select l.property_address a, y.people, y.reached, y.note from public.yes_ready_alerts y join public.leads l on l.id = y.lead_id where y.lead_id in ($1, $2) order by 1`, [LATER, THIRD])).rows
    expect(rows).toEqual([{ a: '3 EMPTY CT', people: 'adil', reached: 2, note: null },
      { a: '7 LATER LN', people: 'thalia', reached: 0, note: 'no phone registered and no alert email on file for thalia' }])
  })

  it('a caller\'s login reads nothing of the alert ledger', async () => {
    await db.query(`select set_config('request.jwt.claims', $1, false)`, [JSON.stringify({ email: 'thalia@example.com' })])
    await db.exec('set role authenticated')
    try { await expect(db.query(`select count(*) from public.yes_ready_alerts`)).rejects.toThrow(/permission denied/) }
    finally { await db.exec('reset role'); await db.query(`select set_config('request.jwt.claims', '', false)`) }
  })
})
