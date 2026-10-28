// @vitest-environment jsdom
// A callback or walk in the middle of the night (Thalia 2026-10-28: Shirikin's callback saved as 4:00 AM, Chrome's time
// box starts on AM): a warning and a one-tap fix to the afternoon.
import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { OddHourHint, oddHourFix } from '../src/components/OddHourHint'

afterEach(() => cleanup())
describe('odd hours', () => {
  it('4:00 AM Central becomes 4:00 PM; 9 AM and 4 PM are left alone', () => {
    expect(oddHourFix('2026-10-29T09:00:00.000Z')).toBe('2026-10-29T21:00:00.000Z')   // 4 AM CDT -> 4 PM CDT
    expect(oddHourFix('2026-10-29T14:00:00.000Z')).toBeNull()                          // 9 AM
    expect(oddHourFix('2026-10-29T21:00:00.000Z')).toBeNull()                          // 4 PM
    expect(oddHourFix(null)).toBeNull()
  })
  it('shows the warning and fixes it in one tap', () => {
    const onFix = vi.fn()
    render(<OddHourHint iso="2026-10-29T09:00:00.000Z" onFix={onFix} />)
    expect(screen.getByRole('alert').textContent).toMatch(/middle of the night/)
    fireEvent.click(screen.getByRole('button'))
    expect(onFix).toHaveBeenCalledWith('2026-10-29T21:00:00.000Z')
  })
})
