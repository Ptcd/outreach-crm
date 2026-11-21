// @vitest-environment jsdom
// The Research page reads weeks (0248): which week it is, who ran, who is behind, in words a phone shows without scrolling.
import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { afterEach, describe, expect, it, vi } from 'vitest'

const job = (id: number, category: string, more: Record<string, unknown>) => ({ id, key: `k${id}`, priority: 'P1', category, job: 'what it is', data: null, source: null,
  cadence: 'Weekly', status: null, status_at: null, status_by: null, ticks: {}, last_done: null, weeks_missed: 0, behind: false, ...more })
const board = {
  week: '2026-11-30', weeks: ['2026-11-30', '2026-11-23', '2026-11-16', '2026-11-09'], months: [],
  jobs: [
    job(1, 'Foreclosure', { last_done: '2026-11-30', ticks: { '2026-11-30': { done: true, note: 'rotation ran', by: 'Muse', at: '2026-12-01T15:00:00Z' } } }),
    job(5, 'Tax', { last_done: '2026-11-23', weeks_missed: 0 }),
    job(4, 'Probate', { last_done: '2026-11-16', weeks_missed: 1 }),
    job(7, 'Bankruptcy', { last_done: '2026-11-09', weeks_missed: 2, behind: true }),
    job(11, 'Municipal/records', { last_done: null, weeks_missed: 3, behind: true }),
  ],
  legs: ['tax'], counties: [{ county: 'Dane', legs: {} }], as_of: '2026-12-01T15:00:00Z',
}
// 0258: the category instructions sit on the same page: the folder, and one document read on a tap
const folder = [
  { id: 8, key: 'money_judgments', category: 'Need-signal', job: 'Pre-lien money judgments', written: true, chars: 1200, version: 3, updated_at: '2026-11-20T18:00:00Z', updated_by: 'Muse' },
  { id: 9, key: 'divorce_fa', category: 'Need-signal', job: 'Divorce filings (FA).', written: false, chars: 0, version: 0, updated_at: null, updated_by: null },
]
const saved: Record<string, unknown>[] = []
vi.mock('@/lib/supabaseClient', () => ({ supabase: { rpc: vi.fn(async (fn: string, args?: Record<string, unknown>) => {
  if (fn === 'research_docs_index') return { data: folder, error: null }
  if (fn === 'research_doc') return { data: { ok: true, ...folder[0], body: 'Read this whole document before touching the category.' }, error: null }
  if (fn === 'research_doc_save') { saved.push(args ?? {}); return { data: { ok: true, version: 4 }, error: null } }
  return { data: board, error: null }
}) }, supabaseConfigured: true }))
vi.mock('@/providers/AuthProvider', () => ({ useAuth: () => ({ isOwner: true }) }))

import ResearchBoard, { standing } from '@/pages/ResearchBoard'

afterEach(cleanup)

describe('the Research page, weekly', () => {
  it('says which week it is, how many ran, and lists the jobs behind in their own section', async () => {
    render(<QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}><ResearchBoard /></QueryClientProvider>)
    expect(await screen.findByText('Source jobs (1 of 5 ticked this week, the week of Nov 30; 2 behind)')).toBeTruthy()
    expect(screen.getByText('Behind more than two weeks (2)')).toBeTruthy()
    expect(screen.getByText('Ran this week')).toBeTruthy()
    expect(screen.getByText('Not ticked yet this week (last ran the week of Nov 23)')).toBeTruthy()
    expect(screen.getByText('1 week with no tick (last ran the week of Nov 16)')).toBeTruthy()
    expect(screen.getByText('Behind: 2 weeks with no tick (last ran the week of Nov 9)')).toBeTruthy()
    expect(screen.getByText('Behind: 3 weeks with no tick (never ticked)')).toBeTruthy()
    expect(document.body.textContent).not.toMatch(/Nov 26\b/)                // the label that read as a day
    expect(screen.getAllByRole('columnheader').map((h) => h.textContent).slice(0, 6)).toEqual(['#', 'Job', 'Nov 30', 'Nov 23', 'Nov 16', 'Nov 9'])
  })
  it('lists the category instructions, opens one on a tap, and Colin can edit and save it against the version he read', async () => {
    render(<QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}><ResearchBoard /></QueryClientProvider>)
    expect(await screen.findByText('Category instructions (1 of 2 written)')).toBeTruthy()
    expect(screen.getByText('not written')).toBeTruthy()
    fireEvent.click(screen.getByText('Pre-lien money judgments'))
    expect(await screen.findByText('Read this whole document before touching the category.')).toBeTruthy()
    fireEvent.click(screen.getByText('Edit'))
    fireEvent.change(screen.getByLabelText('Instructions for Need-signal'), { target: { value: 'New method.' } })
    fireEvent.click(screen.getByText('Save'))
    await vi.waitFor(() => expect(saved).toEqual([{ p_job: 'money_judgments', p_body: 'New method.', p_base_version: 3 }]))
  })
  it('a board with no weeks yet (an old server) still renders', () => {
    expect(standing({ last_done: null, weeks_missed: undefined, behind: undefined }, '')).toEqual({ tone: 'ok', text: 'Not ticked yet this week (never ticked)' })
  })
})
