// A package's answers in their own question's words (2026-10-28: "Photos: Not behind" on Shirikin's package).
import { describe, expect, it } from 'vitest'
import { NEXT_STEP, callScript, packageFromCall } from '../src/lib/callScript'

describe('package labels', () => {
  it('a "no" to photos is not the "no" to behind', () => {
    const labels = Object.fromEntries([...callScript(), NEXT_STEP].flatMap((q) => (q.choices ?? []).flatMap((c) => [[c.id, c.label], [`${q.id}:${c.id}`, c.label]])))
    const p = packageFromCall({ photos: { value: { choices: ['no'], text: 'come see it' } }, behind: { value: { choices: ['no'] } } } as never, labels)
    expect(p.fields.photos).not.toMatch(/behind/i)
    expect(p.fields.photos).toMatch(/come see it/)
  })
})
