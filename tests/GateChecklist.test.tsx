// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, within } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { GateChecklist } from '@/components/GateChecklist'

afterEach(cleanup)

function pick(item: string, value: number) {
  const group = screen.getByRole('radiogroup', { name: item })
  fireEvent.click(within(group).getAllByRole('radio')[value])
}

describe('GateChecklist', () => {
  it('scores the six items and shows what the written rule says', () => {
    const onSave = vi.fn()
    render(<GateChecklist latest={null} canEdit onSave={onSave} />)
    expect(screen.getAllByRole('radiogroup')).toHaveLength(6)
    const summary = () => screen.getByTestId('gate-summary').textContent
    expect(summary()).toContain('Total 0/12')
    expect(summary()).toContain("Don't walk")

    for (const item of ['Reason + clock', 'Decision makers', 'Their number + why', 'Flexibility']) pick(item, 2)
    pick('Condition', 1)
    pick('Numbers close', 1)
    expect(summary()).toContain('Total 10/12')
    expect(summary()).toContain('Walk it')

    fireEvent.click(screen.getByLabelText(/Listed with an agent/))
    expect(summary()).toContain("Don't walk")

    fireEvent.click(screen.getByRole('button', { name: 'Save gate score' }))
    expect(onSave).toHaveBeenCalledWith({
      scores: { reason_and_clock: 2, decision_makers: 2, number_and_anchor: 2, flexibility: 2, condition: 1, numbers_close: 1 },
      hard_stops: ['listed_active'],
      decision: 'no_walk',
      note: null,
    })
  })

  it('is read-only for the caller', () => {
    render(<GateChecklist latest={null} canEdit={false} />)
    for (const r of screen.getAllByRole('radio')) expect((r as HTMLInputElement).disabled).toBe(true)
    expect(screen.queryByRole('button', { name: 'Save gate score' })).toBeNull()
    expect(screen.getByText(/Colin scores the gate/)).toBeTruthy()
  })

  it('never shows a price or offer field', () => {
    const { container } = render(<GateChecklist latest={null} canEdit />)
    expect(container.querySelector('input[type="number"], input[inputmode="decimal"]')).toBeNull()
    expect(container.textContent).not.toMatch(/\$\s?\d/)
  })
})
