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
  q1_property: { id: 'owner', title: 'Which property', text: 'Address they named (if different)',
    choices: [c('yes', 'This one'), c('other_property', 'Different property'), c('sold', 'Sold it')] },
  q2_identity: { id: 'identity', title: 'Their place, or helping someone',
    choices: [c('owner', 'Owner'), c('spouse', 'Spouse'), c('adult_child', 'Adult child'), c('relative', 'Other relative'),
      c('tenant', 'Tenant'), c('manager', 'Manager'), c('agent', 'Agent'), c('wholesaler', 'Wholesaler')], text: 'Name' },
  q3_motivation: { id: 'motivation', title: 'Why selling (reason)', reply: ['motivation'], text: 'Their reason, in their words',
    choices: [c('tired_landlord', 'Tired landlord'), c('moving', 'Moving'), c('inherited', 'Inherited / death'), c('behind', 'Behind on payments'),
      c('repairs', 'Too many repairs'), c('divorce', 'Divorce'), c('health', 'Health / age'), c('just_price', 'Only for the right price')] },
  q4_condition: { id: 'condition', title: 'About the place (condition)', reply: ['condition'], multi: true, text: 'In their words',
    choices: [c('roof', 'Roof'), c('furnace', 'Furnace / AC'), c('water', 'Water / leaks'), c('foundation', 'Foundation'),
      c('electrical', 'Electrical'), c('plumbing', 'Plumbing'), c('cosmetic', 'Cosmetic only'), c('perfect', 'Says perfect')] },
  q4a_occupancy: { id: 'occupancy', title: 'Who lives there', reply: ['occupancy'],
    choices: [c('owner', 'They live there'), c('tenants', 'Tenants'), c('family', 'Family'), c('empty', 'Empty')], text: 'Access, rent, lease end' },
  q4b_list_tomorrow: { id: 'work_list', title: 'Work before listing', text: 'Their list of work' },
  q4c_happened: { id: 'happened', title: 'Anything happen to it', multi: true,
    choices: [c('leak', 'Leak / water'), c('fire', 'Fire'), c('foundation', 'Foundation'), c('code', 'Code / raze order'), c('none', 'Nothing')] },
  q5_timeline: { id: 'timeline', title: 'Where headed, and when (clock)', reply: ['timeline'], text: 'The plan and the date or event',
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
  q11_condition_decision: { id: 'ready', title: 'Can they say yes, with every signer there',
    choices: [c('yes', 'Yes, everyone there'), c('spouse', 'Has to bring someone'), c('think', 'Wants to think')] },
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

export const CALL_OUTCOMES: { id: 'interested' | 'not_now' | 'not_interested' | 'wrong_number' | 'dnc'; label: string; hint: string }[] = [
  { id: 'interested', label: 'Interested', hint: "Stage: Colin's call (or Walk booked)" },
  { id: 'not_now', label: 'Not now', hint: 'Stage: Follow up later, check back in 30 days' },
  { id: 'not_interested', label: 'Not interested', hint: 'Stage: Dead' },
  { id: 'wrong_number', label: 'Wrong number', hint: 'That phone marked bad; stage: Wrong number' },
  { id: 'dnc', label: 'Do not contact', hint: 'Every phone of this owner blocked, like a texted STOP' },
]
