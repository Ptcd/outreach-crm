// Things a text cannot do (Colin 2026-10-21): the seller asks for an email, photos or paperwork,
// a records request, someone else to be contacted, or a visit/meeting. The reply agent opens a Task
// for a person (Adil by default) with the seller's exact words; the text reply still goes to Colin
// as a draft as usual. Pure function, tested in tests/needsWork.test.ts.

export interface WorkNeeded {
  kind: 'email' | 'send_docs' | 'records' | 'contact_other' | 'appointment'
  title: string          // what is needed, in plain words
  email: string | null   // an address they gave, if any
}

const EMAIL_ADDR = /[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/i
const EMAIL_ASK = /\b(?:e-?mail|email)\s+(?:me|it|that|them|the\b|something|info|details|over)|\b(?:by|via|over|through|in an?|to my)\s+e-?mail\b|\bmy\s+e-?mail\s+(?:is|address)\b|\bsend\b.{0,40}\be-?mail\b/i
const RECORDS = /\b(?:proof of funds|pof|deed|title (?:work|search|report|info)|tax (?:bill|records?)|property records?|appraisal|inspection report|comps\b|comparables|your (?:license|company info|w-?9|references))\b/i
const DOCS = /\b(?:send|mail|text|email|forward|share|show|get)\b.{0,40}\b(?:photos?|pictures?|pics|paperwork|papers|documents?|docs|contract|agreement|purchase agreement|offer letter|something in writing|in writing|the info|more info|information|details|brochure)\b|\b(?:put (?:it|that|an offer) in writing|written offer|offer in writing)\b/i
// Only when WE are asked to reach them ("please call my son", "talk to my attorney", "you'll have to
// go through my POA"), not "I'll talk to my wife" or "don't text my husband".
const NEGATED_ASK = /\b(?:don'?t|do not|never|no need to)\s+(?:talk|speak|call|contact|text|reach)\b/i
const THEY_SEND = /\b(?:can|could|should|may|want to)\s+i\s+(?:send|text|email|share)\b/i
const OTHER_PERSON = /(?:^\W*|[.,;!?]\s*|\b(?:you(?:'ll| will| can| could| should| would)?(?: have to| need to)?|please|pls|just)\s+)(?:talk|speak|call|contact|text|reach|get (?:a )?hold of|go through|deal with|work with)\b.{0,30}\b(?:my|our|the)\s+(son|daughter|wife|husband|brother|sister|mom|mother|dad|father|kids|children|family|lawyer|attorney|realtor|agent|accountant|partner|business partner|property manager|manager|executor|trustee|power of attorney|poa|nephew|niece|cousin)\b/i
const VISIT = /\b(?:meet (?:me|us|up|at)|come (?:by|over|out|see|look)|see the (?:house|place|property|building|unit)|look at (?:it|the (?:house|place|property))|walk ?-?through|showing|tour (?:it|the)|inspect(?:ion)?\b|check (?:it|the place) out|open house)\b/i

export function workNeeded(text: string): WorkNeeded | null {
  const t = (text ?? '').trim()
  if (!t) return null
  const addr = t.match(EMAIL_ADDR)?.[0] ?? null
  if (addr || EMAIL_ASK.test(t)) {
    return { kind: 'email', title: addr ? `Email them at ${addr}` : 'They asked for an email: get their address and send it', email: addr }
  }
  if (RECORDS.test(t)) return { kind: 'records', title: 'They asked for records or proof (e.g. proof of funds, title, tax bill): send or arrange it', email: null }
  if (THEY_SEND.test(t)) return { kind: 'send_docs', title: 'They want to send you photos or paperwork: tell them where (email or this number)', email: null }
  if (DOCS.test(t)) return { kind: 'send_docs', title: 'They want something sent (photos, paperwork, details or an offer in writing)', email: null }
  const who = NEGATED_ASK.test(t) ? undefined : t.match(OTHER_PERSON)?.[1]
  if (who) return { kind: 'contact_other', title: `They want you to contact their ${who.toLowerCase()}: get the name and number`, email: null }
  if (VISIT.test(t)) return { kind: 'appointment', title: 'They want to meet or have someone see the property: set up a time', email: null }
  return null
}
