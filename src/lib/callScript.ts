// THE CALL SCRIPT - the one file to edit when the wording changes.
// Wording today: docs/SELLER_QUALIFICATION_LOGIC.md (sections a and b) and the fixed lines in
// wpie/reply/brain.py. When docs/PHONE_SCRIPT.md (Rick's inbound-call wording) lands, replace the
// `say` lines (and choices if needed) here; nothing else has to change.
//
// Order is the order to ask, top to bottom. `say` is read out loud. `choices` are one-tap answers
// (multi: several at once); `text` adds a free-text box; `number` a dollar box; `when` a date-time.
// `reply` names the reply agent's fact (from the seller's texts) that already answers it.

export type Choice = { id: string; label: string }
export type CallQuestion = {
  id: string
  title: string
  pillar?: boolean
  say: string[]
  choices?: Choice[]
  multi?: boolean
  text?: string
  number?: string
  when?: string
  reply?: string[]
  then?: { id: string; say: string; choices: Choice[] }
}

export const CALL_OPENING = [
  'Hi, this is Colin. Thanks for calling me back.',
  '(Adil: "Hi, this is Adil, I work with Colin Merrill. Thanks for calling back.")',
]

export const CALL_SCRIPT: CallQuestion[] = [
  {
    id: 'owner',
    title: 'Still the owner, and which property',
    say: ['Which property are you calling about?', 'And it is still yours?'],
    choices: [
      { id: 'yes', label: 'Yes, owns it' },
      { id: 'other_property', label: 'Different property' },
      { id: 'sold', label: 'Sold it' },
      { id: 'not_owner', label: 'Not the owner' },
    ],
    text: 'Address they named, or who the owner is',
  },
  {
    id: 'occupancy',
    title: 'Who lives there',
    say: ['To start easy: is anyone living there right now, or is it sitting empty?'],
    choices: [
      { id: 'owner', label: 'They live there' },
      { id: 'tenants', label: 'Tenants' },
      { id: 'family', label: 'Family' },
      { id: 'empty', label: 'Empty' },
    ],
    text: 'Rent, lease end, anything about the tenants',
    reply: ['occupancy'],
  },
  {
    id: 'condition',
    title: 'Condition',
    pillar: true,
    say: ["How's the place holding up - anything big it needs, like the roof, the furnace, any water or leaks, or a fire?"],
    choices: [
      { id: 'roof', label: 'Roof' },
      { id: 'furnace', label: 'Furnace / AC' },
      { id: 'water', label: 'Water / leaks' },
      { id: 'fire', label: 'Fire' },
      { id: 'foundation', label: 'Foundation' },
      { id: 'electrical', label: 'Electrical' },
      { id: 'plumbing', label: 'Plumbing' },
      { id: 'none', label: 'Nothing big' },
    ],
    multi: true,
    text: 'In their words',
    reply: ['condition'],
  },
  {
    id: 'motivation',
    title: 'Motivation: why selling',
    pillar: true,
    say: ["What's got you thinking about selling? I ask everyone, so I don't waste your time."],
    choices: [
      { id: 'tired_landlord', label: 'Tired landlord' },
      { id: 'moving', label: 'Moving' },
      { id: 'inherited', label: 'Inherited' },
      { id: 'behind', label: 'Behind on payments' },
      { id: 'repairs', label: 'Too many repairs' },
      { id: 'divorce', label: 'Divorce' },
      { id: 'health', label: 'Health / age' },
      { id: 'just_price', label: 'Only for the right price' },
    ],
    text: 'Their reason, in their words',
    reply: ['motivation'],
  },
  {
    id: 'timeline',
    title: 'Timeline: when they want to be done',
    pillar: true,
    say: ["And timing - is there a date you're working toward, or something coming up that it depends on?"],
    choices: [
      { id: 'asap', label: 'ASAP' },
      { id: 'under_30', label: 'Within 30 days' },
      { id: 'one_to_three', label: '1-3 months' },
      { id: 'three_to_six', label: '3-6 months' },
      { id: 'no_rush', label: 'No rush' },
    ],
    text: 'The date or event (lease end, move, tax deadline...)',
    reply: ['timeline'],
  },
  {
    id: 'price',
    title: 'Price: their number and where it came from',
    pillar: true,
    say: ['What were you hoping to get for it? Even a rough figure helps me more than anything.', 'How did you come up with that?'],
    number: 'Their number ($)',
    choices: [
      { id: 'own_need', label: 'What they need / payoff' },
      { id: 'paid', label: 'What they paid' },
      { id: 'online', label: 'Zillow / online' },
      { id: 'listing', label: 'Agent / listing' },
      { id: 'neighbor', label: 'Neighbor sold' },
      { id: 'offers', label: 'Other offers' },
      { id: 'refused', label: 'Would not say' },
    ],
    text: 'How they put it',
    reply: ['price_expectation', 'price_confirmed'],
    then: {
      id: 'flexibility',
      say: "I buy as-is and cover the repairs and the selling costs, so my number usually lands under a retail sale. If it came in under yours, would you still want to hear it?",
      choices: [
        { id: 'moved', label: 'Moved already' },
        { id: 'open', label: 'Open to hear it' },
        { id: 'terms', label: 'Only on terms' },
        { id: 'firm', label: 'Firm' },
        { id: 'unclear', label: 'Unclear' },
      ],
    },
  },
  {
    id: 'decision_makers',
    title: 'Who is on title / who else decides',
    say: ["Is it just in your name, or is anyone else on the title or in the family who'd want a say?", 'Could they be there when I come by?'],
    choices: [
      { id: 'only_them', label: 'Only them' },
      { id: 'spouse', label: 'Spouse' },
      { id: 'family', label: 'Siblings / heirs' },
      { id: 'estate', label: 'Estate (PR)' },
      { id: 'company', label: 'LLC / partners' },
    ],
    multi: true,
    text: 'Names, and whether they can be at the walk-through',
    reply: ['decision_makers'],
    then: {
      id: 'all_at_walk',
      say: 'Can everyone who signs be there, or agree to it?',
      choices: [
        { id: 'yes', label: 'Yes, all of them' },
        { id: 'some', label: 'Not all' },
        { id: 'unknown', label: 'Not sure' },
      ],
    },
  },
  {
    id: 'debt',
    title: 'Mortgage or liens',
    say: ['Is there a mortgage or anything owed on it? A rough balance is fine.'],
    choices: [
      { id: 'free_clear', label: 'Free and clear' },
      { id: 'mortgage', label: 'Mortgage' },
      { id: 'behind', label: 'Behind on payments' },
      { id: 'taxes', label: 'Back taxes' },
      { id: 'liens', label: 'Liens / judgments' },
    ],
    multi: true,
    number: 'Rough balance ($)',
    text: 'Anything about a sale date or foreclosure',
    reply: ['known_debt'],
  },
  {
    id: 'other_buyer',
    title: 'Listed or signed with anyone',
    say: ['Have you signed anything with anyone, or is it listed with an agent?'],
    choices: [
      { id: 'no', label: 'No' },
      { id: 'listed', label: 'Listed' },
      { id: 'signed', label: 'Signed with a buyer' },
    ],
    reply: ['signed_with_other'],
  },
  {
    id: 'next_step',
    title: 'Next step',
    say: ['When could I come take a look at it?', "Or: what's a good time for me to call you back?"],
    choices: [
      { id: 'walk', label: 'Walk-through' },
      { id: 'callback', label: 'Colin calls back' },
      { id: 'none', label: 'No next step' },
    ],
    when: 'Day and time',
    reply: ['callback_slot'],
  },
]

export const CALL_OUTCOMES: { id: 'interested' | 'not_now' | 'not_interested' | 'wrong_number' | 'dnc'; label: string; hint: string }[] = [
  { id: 'interested', label: 'Interested', hint: "Stage: Colin's call (or Walk booked)" },
  { id: 'not_now', label: 'Not now', hint: 'Stage: Follow up later, check back in 30 days' },
  { id: 'not_interested', label: 'Not interested', hint: 'Stage: Dead' },
  { id: 'wrong_number', label: 'Wrong number', hint: 'That phone marked bad; stage: Wrong number' },
  { id: 'dnc', label: 'Do not contact', hint: 'Every phone of this owner blocked, like a texted STOP' },
]
