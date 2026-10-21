// The seller's answers to the Real Estate Condition Report (Wis. Stat. 709.03) and the
// completeness check. 709.02 counts a report complete only if every item is answered, and A4
// requires an explanation for every "yes". Used by the signing page and by the server.
import { RECR } from './recrForm.generated.ts'

export type Ynna = 'yes' | 'no' | 'na'
export type RecrAnswers = {
  answers: Record<string, Ynna>
  explain: Record<string, string>     // keyed by the section's explanation item (B12, C8, ...)
  years: Record<string, string>       // G6 owned, G7 lived
}

export const emptyRecr = (): RecrAnswers => ({ answers: {}, explain: {}, years: {} })

export const RECR_QUESTIONS = RECR.sections.flatMap((s) => s.items.filter((i) => i.kind === 'ynna').map((i) => ({ ...i, section: s.id })))

/** Problems that stop the report counting as complete, in plain words. Empty means complete. */
export function recrProblems(a: RecrAnswers | null | undefined): string[] {
  const out: string[] = []
  const x = a ?? emptyRecr()
  const missing = RECR_QUESTIONS.filter((q) => !['yes', 'no', 'na'].includes(x.answers?.[q.id] as string)).map((q) => q.id)
  if (missing.length) out.push(`Answer every question (missing: ${missing.join(', ')}).`)
  for (const s of RECR.sections) {
    const explain = s.items.find((i) => i.kind === 'explain')
    if (!explain) continue
    const yes = s.items.filter((i) => i.kind === 'ynna' && x.answers?.[i.id] === 'yes').map((i) => i.id)
    if (yes.length && !(x.explain?.[explain.id] ?? '').trim()) {
      out.push(`Explain each "yes" in section ${s.id} (${yes.join(', ')}).`)
    }
  }
  for (const id of ['G6', 'G7']) {
    const v = (x.years?.[id] ?? '').trim()
    if (!/^\d{1,3}(\.\d)?$/.test(v)) out.push(id === 'G6' ? 'Say how many years you have owned the property.' : 'Say how many years you have lived in the property (0 if never).')
  }
  return out
}
