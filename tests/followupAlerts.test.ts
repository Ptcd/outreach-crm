// A caller's own follow-up reminds them (0170/0171): a push to that person's phones and an email, once per task; a
// task nothing can reach is marked with a note so it does not come up every minute; a move clears the mark (database).
import { describe, expect, it } from 'vitest'
import { followupMessage, runFollowupReminders, type DueFollowup } from '../supabase/functions/_shared/followupAlerts'

const due = (over: Partial<DueFollowup> = {}): DueFollowup => ({ task_id: 'T1', lead_id: 'L1', kind: 'callback', due_at: '2026-11-04T22:00:00Z', title: 'Callback',
  note: 'she asked for after 4', owner_name: 'JANE ROE', address: '12 OAK ST', municipality: 'Racine', person: 'thalia', email: 'thalia@example.com', display_name: 'Thalia', ...over })

function fakeDb(rows: DueFollowup[]) {
  const marked: { id: string; note: string | null }[] = []
  const rpc = async (fn: string, args: Record<string, unknown>) => {
    if (fn === 'followups_due_to_alert') return { data: rows, error: null }
    if (fn === 'followup_alerted') { marked.push({ id: String(args.p_task_id), note: (args.p_note as string | null) ?? null }); return { data: null, error: null } }
    return { data: null, error: { message: 'unknown ' + fn } }
  }
  return { rpc, marked }
}

describe('follow-up reminders', () => {
  it('says what, when and who, and links the card', () => {
    const m = followupMessage(due(), 'https://app.example/')
    expect(m.title).toBe('Callback you promised at 4:00 PM: JANE ROE')
    expect(m.body).toBe('12 OAK ST, Racine. she asked for after 4')
    expect(m.url).toBe('https://app.example/lead/L1')
  })
  it('pushes the owner, emails them, marks the task once', async () => {
    const db = fakeDb([due()])
    const pushed: string[] = []; const mailed: string[] = []
    const s = await runFollowupReminders({ rpc: db.rpc, appUrl: 'https://app.example',
      push: async (person) => { pushed.push(person); return 2 }, email: async (m) => { mailed.push(m.to) } })
    expect(pushed).toEqual(['thalia']); expect(mailed).toEqual(['thalia@example.com'])
    expect(s).toMatchObject({ pushes: 2, emails: 1, nothing: 0, errors: [] })
    expect(db.marked).toEqual([{ id: 'T1', note: null }])
  })
  it('marks a task nobody can be reached about, with the reason, and never retries it every minute', async () => {
    const db = fakeDb([due({ email: null })])
    const s = await runFollowupReminders({ rpc: db.rpc, appUrl: 'https://app.example', push: null, email: async () => {} })
    expect(s.nothing).toBe(1)
    expect(db.marked[0].note).toMatch(/no phone registered or email on file for thalia/)
  })
  it('a push that reaches nobody but an email that lands still counts as reminded', async () => {
    const db = fakeDb([due()])
    const s = await runFollowupReminders({ rpc: db.rpc, appUrl: 'https://app.example', push: async () => 0, email: async () => {} })
    expect(s).toMatchObject({ pushes: 0, emails: 1 })
    expect(db.marked).toHaveLength(1)
  })
  it('is off, and says so, with neither channel', async () => {
    const db = fakeDb([due()])
    const s = await runFollowupReminders({ rpc: db.rpc, appUrl: 'https://app.example', push: null, email: null })
    expect(s.off).toMatch(/neither/); expect(db.marked).toHaveLength(0)
  })
})

describe('a heads-up from the other caller (0186/0187)', () => {
  it('says who it is from and what they wrote, and links the card', () => {
    const m = followupMessage(due({ kind: 'nudge', title: 'Heads-up from Adil', note: 'she asked for Thalia by name, call her first', person: 'thalia' }), 'https://app.example')
    expect(m.title).toBe('Heads-up from Adil: JANE ROE')
    expect(m.body).toBe('she asked for Thalia by name, call her first (12 OAK ST, Racine)')
    expect(m.url).toBe('https://app.example/lead/L1')
  })
  it('is pushed and marked like a reminder, the minute it lands', async () => {
    const db = fakeDb([due({ kind: 'nudge', title: 'Heads-up from Thalia', note: 'tenant leaves in March', person: 'adil', email: null })])
    const pushed: { person: string; title: string }[] = []
    const s = await runFollowupReminders({ rpc: db.rpc, appUrl: 'https://app.example', push: async (person, m) => { pushed.push({ person, title: m.title }); return 1 }, email: null })
    expect(pushed).toEqual([{ person: 'adil', title: 'Heads-up from Thalia: JANE ROE' }])
    expect(s.pushes).toBe(1)
    expect(db.marked).toEqual([{ id: 'T1', note: null }])
  })
})
