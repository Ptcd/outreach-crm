// The call script. Every word said on the phone comes from phoneScript.json, a verbatim copy of
// WPIE docs/phone_script.json (readable twin docs/PHONE_SCRIPT.md, from the Rick call corpus).
// To change the wording, replace that JSON; this file only adds the one-tap answers for each
// question (by its id) and where each answer is kept on the lead (call_facts[key]).
import SCRIPT from './phoneScript.json'

export type Choice = { id: string; label: string }
type Line = { id: string; say: string; note?: string }
export type ScriptJson = {
  version: string; source: string; voice: string; gate_legend: Record<string, string>
  before_pickup: string[]; pickup: string
  questions: { id: string; gate_item: number[]; say: string; listen_for?: string; branch?: string }[]
  booking: Line[]; objections: (Line & { trigger: string })[]; not_ready: Line[]
}
export const PHONE_SCRIPT = SCRIPT as ScriptJson

export type CallQuestion = {
  id: string          // the call_facts key the answer is kept under
  qid: string         // the question id in phoneScript.json
  title: string
  gate: number[]      // walk-gate items it settles (gate_legend)
  say: string[]
  listen?: string
  branch?: string
  choices?: Choice[]
  multi?: boolean
  text?: string
  number?: string
  when?: string
  reply?: string[]    // the reply agent's facts (seller texts) that may already answer it
}

type Answer = Omit<CallQuestion, 'qid' | 'gate' | 'say' | 'listen' | 'branch'>
const c = (id: string, label: string): Choice => ({ id, label })

// One-tap answers per question id. A question in the JSON without an entry here still shows,
// with a notes box.
const ANSWERS: Record<string, Answer> = {
  q1_property: { id: 'owner', title: 'Still the owner', text: 'Address they named (if different)',
    choices: [c('yes', 'Yes, the owner'), c('other_property', 'Different property'), c('sold', 'Sold it'), c('not_them', 'Not them')] },
  q1b_interest: { id: 'interest', title: 'Any interest in selling',
    choices: [c('yes', 'Yes'), c('maybe', 'Maybe'), c('no', 'No')], text: 'What they said' },
  q2_identity: { id: 'identity', title: 'Their place, or helping someone',
    choices: [c('owner', 'Owner'), c('spouse', 'Spouse'), c('adult_child', 'Adult child'), c('relative', 'Other relative'),
      c('tenant', 'Tenant'), c('manager', 'Manager'), c('agent', 'Agent'), c('wholesaler', 'Wholesaler')], text: 'Name' },
  q3_motivation: { id: 'motivation', title: 'Why selling (reason)', reply: ['motivation'], text: 'Their reason, in their words',
    choices: [c('tired_landlord', 'Tired landlord'), c('moving', 'Moving'), c('inherited', 'Inherited / death'), c('behind', 'Behind on payments'),
      c('repairs', 'Too many repairs'), c('divorce', 'Divorce'), c('health', 'Health / age'), c('just_price', 'Only for the right price')] },
  q4_condition: { id: 'condition', title: 'About the place (condition)', reply: ['condition'], multi: true, text: 'In their words',
    choices: [c('roof', 'Roof'), c('furnace', 'Furnace / AC'), c('water_heater', 'Water heater'), c('water', 'Water / leaks'),
      c('foundation', 'Foundation / basement'), c('electrical', 'Electrical'), c('plumbing', 'Plumbing'), c('windows', 'Windows'),
      c('kitchen_baths', 'Kitchen / baths'), c('yard', 'Yard / outside'), c('cosmetic', 'Cosmetic only'), c('perfect', 'Says perfect')] },
  q4a_occupancy: { id: 'occupancy', title: 'Who lives there', reply: ['occupancy'],
    choices: [c('owner', 'They live there'), c('tenants', 'Tenants'), c('family', 'Family'), c('empty', 'Empty')], text: 'Access, rent, lease end' },
  q4b_list_tomorrow: { id: 'work_list', title: 'Fix first', text: 'Their list of work' },
  q4c_happened: { id: 'happened', title: 'Anything happen to it', multi: true,
    choices: [c('leak', 'Leak / water'), c('fire', 'Fire'), c('foundation', 'Foundation'), c('code', 'Code / raze order'), c('none', 'Nothing')] },
  q4d_photos: { id: 'photos', title: 'Photos', choices: [c('will_send', 'Will text some'), c('sent', 'Sent'), c('no', 'No')], text: 'Notes' },
  q5_timeline: { id: 'timeline', title: 'Where moving, and when', reply: ['timeline'], text: 'The plan and the date or event',
    choices: [c('asap', 'ASAP'), c('under_30', 'Within 30 days'), c('one_to_three', '1-3 months'), c('three_to_six', '3-6 months'),
      c('no_plan', "Hasn't thought about it")] },
  q6_decision_makers: { id: 'decision_makers', title: 'Anyone else on it', reply: ['decision_makers'], multi: true,
    text: 'Names, and whether they can be on the next call or at the visit',
    choices: [c('only_them', 'Just them'), c('spouse', 'Spouse'), c('family', 'Siblings / kids'), c('estate', 'Estate'), c('company', 'Company / partner')] },
  q7_number: { id: 'price', title: 'Their number', reply: ['price_expectation', 'price_confirmed'], number: 'Their number ($), as said',
    choices: [c('refused_once', 'Would not say (1st ask)'), c('refused', 'Refused after two asks'), c('make_offer', '"Make me an offer"')] },
  q8_anchor: { id: 'anchor', title: 'Where the number came from', text: 'How they put it',
    choices: [c('own_need', 'Payoff / what they need'), c('paid', 'What they paid'), c('next_place', 'The next place'), c('online', 'Zillow / online'),
      c('bank', 'Bank estimate'), c('neighbor', 'Neighbor sold'), c('offers', 'Other offers')] },
  q9_flexibility: { id: 'flexibility', title: 'Would they hear a number under theirs',
    choices: [c('moved', 'Moved'), c('open', 'Open'), c('depends', 'Depends'), c('terms', 'Terms only'), c('firm', 'Firm')] },
  q10_owed: { id: 'debt', title: 'Anything owed', reply: ['known_debt'], number: 'Roughly left ($)',
    choices: [c('free_clear', 'Nothing owed'), c('mortgage', 'Mortgage'), c('dont_know', "Doesn't know")] },
  q10a_behind: { id: 'behind', title: 'Behind on anything', multi: true, text: 'Sale date, if any',
    choices: [c('no', 'Not behind'), c('payments', 'Payments'), c('taxes', 'Taxes'), c('sale_date', 'Sale date set'), c('sale_14', 'Sale inside 14 days')] },
  q10b_other_buyers: { id: 'other_buyers', title: 'Other buyers or agents', text: 'Who, and anything signed' },
  q10c_concerns: { id: 'concerns', title: 'What concerns them most', text: 'Their words' },
  q11_condition_decision: { id: 'ready', title: 'The callback, and a straight answer',
    choices: [c('yes', 'Agreed: a straight yes or no'), c('spouse', 'Has to bring someone'), c('think', 'Wants to think')] },
}

const fill = (s: string, v: Record<string, string>) => s.replace(/\{(\w+)\}/g, (m, k: string) => v[k] ?? m)

/** The questions in the script's order, with names filled in from the lead. */
export function callScript(vars: Record<string, string> = {}): CallQuestion[] {
  return PHONE_SCRIPT.questions.map((q) => {
    const a = ANSWERS[q.id] ?? { id: q.id.replace(/[^a-z_]/g, ''), title: q.id, text: 'Notes' }
    return { ...a, qid: q.id, gate: q.gate_item, say: [fill(q.say, vars)], listen: q.listen_for, branch: q.branch }
  })
}
export const CALL_SCRIPT = callScript()

export function scriptLine(l: Line, vars: Record<string, string> = {}) {
  return { ...l, say: fill(l.say, vars) }
}

/** The booking close's answer: books the walk-through or a call-back (sets the lead's next action). */
export const NEXT_STEP: Answer = { id: 'next_step', title: 'Booked', reply: ['callback_slot'], when: 'Day and time',
  choices: [c('walk', 'Walk-through'), c('callback', 'Call back')] }

export const CALL_OUTCOMES: { id: 'interested' | 'reached_no_decision' | 'no_answer' | 'not_now' | 'not_interested' | 'wrong_number' | 'disconnected' | 'dnc'; label: string; hint: string }[] = [
  { id: 'no_answer', label: 'No answer', hint: 'Rang out, no voicemail left; nothing changes on the card' },
  { id: 'interested', label: 'Interested', hint: "Stage: Colin's call (or Walk booked)" },
  { id: 'reached_no_decision', label: 'Reached, no decision', hint: "Talked, nothing settled yet; stage: Colin's call" },
  { id: 'not_now', label: 'Not now', hint: 'Use the exact date they gave, or record the event/condition they named' },
  { id: 'not_interested', label: 'Not interested', hint: 'Stage: Dead' },
  { id: 'wrong_number', label: 'Wrong number', hint: 'That phone marked bad; stage: Wrong number' },
  { id: 'disconnected', label: 'Disconnected', hint: 'Not in service, or the call fails before it rings: that number marked bad, and the next number of the owner gets tried' },
  { id: 'dnc', label: 'Do not contact', hint: 'Every phone of this owner blocked, like a texted STOP' },
]

/** Clearly hot (the packet's rule): a need and a rough house, or a sale or move date. Book Colin's walk on this call. */
export function packetHot(facts: Record<string, { value?: { choices?: string[] } } | undefined>): boolean {
  const ch = (k: string) => facts[k]?.value?.choices ?? []
  const need = ch('motivation').some((x) => x !== 'just_price')
  const rough = ch('condition').some((x) => !['cosmetic', 'perfect'].includes(x)) || ch('happened').some((x) => x !== 'none')
  const date = ch('timeline').some((x) => x === 'asap' || x === 'under_30') || ch('behind').includes('sale_date')
  const within90 = ch('timeline').some((x) => ['asap', 'under_30', 'one_to_three'].includes(x))
  // the packet's "It's hot when": a need and a rough house; a need or a rough house inside 90 days; a sale or move date
  return (need && rough) || ((need || rough) && within90) || date
}

/** "A clearly hot seller on call one" (the packet: a need and a rough house, or a sale or move date): book Colin's walk
 *  on this call instead of waiting for his number. Narrower than packetHot, which only marks the package hot. */
export function clearlyHot(facts: Record<string, { value?: { choices?: string[] } } | undefined>): boolean {
  const ch = (k: string) => facts[k]?.value?.choices ?? []
  const need = ch('motivation').some((x) => x !== 'just_price')
  const rough = ch('condition').some((x) => !['cosmetic', 'perfect'].includes(x)) || ch('happened').some((x) => x !== 'none')
  const date = ch('timeline').some((x) => x === 'asap' || x === 'under_30') || ch('behind').includes('sale_date')
  return (need && rough) || date
}

/** The call's answers, as a starting package for Colin (the caller checks it and sends it). */
export function packageFromCall(facts: Record<string, { value?: { choices?: string[]; text?: string; number?: string; when?: string } } | undefined>,
  labels: Record<string, string>): { fields: Record<string, string>; condition: Record<string, string>; hot: boolean; callback: string | null; walk: boolean } {
  const v = (k: string) => facts[k]?.value
  const words = (k: string) => {
    const x = v(k)
    if (!x) return ''
    return [...(x.choices ?? []).map((id) => labels[id] ?? id), x.number ? `$${x.number}` : '', x.text ?? ''].filter(Boolean).join('; ')
  }
  const cond: Record<string, string> = {}
  const map: Record<string, string> = { roof: 'roof', furnace: 'hvac', water_heater: 'water_heater', foundation: 'foundation', water: 'foundation',
    electrical: 'electrical', plumbing: 'plumbing', windows: 'windows', kitchen_baths: 'kitchen_baths', yard: 'yard' }
  for (const id of v('condition')?.choices ?? []) if (map[id]) cond[map[id]] = cond[map[id]] ?? 'mentioned on the call'
  if (v('condition')?.text) cond.other = v('condition')!.text!
  if (v('work_list')?.text) cond.fix_first = v('work_list')!.text!
  if (words('happened')) cond.other = [cond.other, words('happened')].filter(Boolean).join('; ')
  const step = v('next_step')
  return {
    fields: { need: words('motivation'), timeline: words('timeline'), their_number: v('price')?.number ? `$${v('price')!.number}` : words('price'),
      their_basis: words('anchor'), on_title: words('decision_makers'), owed: words('debt'), occupancy: words('occupancy'), photos: words('photos'),
      other_buyers: words('other_buyers'), concerns: words('concerns') },
    condition: cond, hot: packetHot(facts as never),
    callback: step?.choices?.includes('callback') ? step.when ?? null : null,
    walk: !!step?.choices?.includes('walk'),
  }
}

