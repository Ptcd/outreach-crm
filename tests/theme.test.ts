// @vitest-environment jsdom
// Light or dark per browser (2026-10-28): Light by default, never the phone's setting; the class goes on <html>.
import { describe, expect, it } from 'vitest'
import { applyTheme, getTheme, setTheme } from '../src/lib/theme'

describe('theme', () => {
  it('starts light, switches to dark and back, remembered', () => {
    localStorage.clear()
    expect(getTheme()).toBe('light')
    applyTheme(getTheme())
    expect(document.documentElement.classList.contains('dark')).toBe(false)
    setTheme('dark')
    expect(getTheme()).toBe('dark')
    expect(document.documentElement.classList.contains('dark')).toBe(true)
    setTheme('light')
    expect(document.documentElement.classList.contains('dark')).toBe(false)
  })
})
