// The assistant's simulator (Colin 2026-11-07: "think of all the edge cases possible so we don't have to run 40 tests").
// Claude plays a seller from a persona card against the real assistant prompt and turn code, no audio; the run is then
// graded by machine on the things that matter: no money figure ever spoken, the lane the sheet would give, the flags
// (stop, wrong person, listed, wholesaler), the four answers captured where the persona gave them, a clean ending in a
// sane number of turns, no "lost you" errors. Results land in voice_sim_runs and show in Settings.

export type Persona = {
  id: string; name: string; card: boolean                     // card: the number is on a file (the assistant knows the house)
  brief: string                                               // who the seller is and how they talk, for the seller model
  opening: string                                             // the seller's first words after the greeting
  expect: { lanes?: string[]; stop?: boolean; wrong_person?: boolean; listed?: boolean; wholesaler?: boolean
            fields?: string[]; ended?: boolean; max_turns?: number; address?: boolean; language?: string }
}

export const PERSONAS: Persona[] = [
  { id: 'taxes_rough', name: 'Behind on taxes, rough house (lane 1)', card: true,
    brief: 'Ron, 61, owns the house on file. Two years behind on property taxes, furnace is dying and the roof leaks over the back bedroom. Lives there alone, wants out by spring to move in with his brother in Racine. Plain-spoken, a little embarrassed. Will say a number if asked twice: "I need about ninety for it to make sense." Wants a callback tomorrow morning.',
    opening: 'Yeah hi, this is Ron. I got your text. I guess I am thinking about selling the place.',
    expect: { lanes: ['1'], fields: ['why', 'condition', 'who_there', 'their_number'], ended: true, max_turns: 14 } },
  { id: 'estate_pr', name: 'Estate, the daughter handling it (no number on first call)', card: true,
    brief: 'Karen, 54. Her father passed in August; she is the personal representative. The house is full of his things, nobody lives there, siblings agree to sell. She has not thought about a number and gets uncomfortable if pushed on one. Wants it done before the holidays, does not want to go back in the house much. Gentle, tired.',
    opening: 'Hello, you had texted about my dad\'s house. He passed away this summer and I am the one handling the estate.',
    expect: { lanes: ['1', '2'], fields: ['why', 'who_there'], ended: true, max_turns: 14 } },
  { id: 'landlord_march', name: 'Tired landlord, tenant leaves in March (lane 3, a date)', card: true,
    brief: 'Dave, 48, landlord. House is a decent rental, tenant on a lease until March 1 and he will not sell with the tenant in place. Not in a hurry, no money trouble. Would sell after March. Will not give a number: "let\'s talk in March". Friendly, businesslike.',
    opening: 'Hey, this is Dave. You guys texted me about my rental. Not really ready to do anything until my tenant is out.',
    expect: { lanes: ['3', '2'], fields: ['who_there', 'timeline'], ended: true, max_turns: 12 } },
  { id: 'just_curious', name: 'Just curious what it is worth (lane 3, nothing to go on)', card: true,
    brief: 'Linda, 59. Lives in the house, no plans to move, no money trouble, the house is in good shape. Only wants to know what someone would pay. If asked why she would sell: "I am not, I just wondered." Pleasant, firm.',
    opening: 'Hi there. I am really just curious what you would offer for my house, I am not sure I want to sell.',
    expect: { lanes: ['3', 'never'], ended: true, max_turns: 10 } },
  { id: 'retail_zillow', name: 'Firm retail from Zillow, nice house, no need (never or lane 2)', card: true,
    brief: 'Mark, 44. House is updated, no problems, he is not in any trouble. Zillow says 385 and he wants 390, firm, and says so early. Says "I know what it is worth". Would list with an agent otherwise. Confident, slightly impatient.',
    opening: 'Yeah, so Zillow has my place at three eighty-five and I would need three ninety, cash, otherwise I am just going to list it.',
    expect: { lanes: ['never', '2'], ended: true, max_turns: 10 } },
  { id: 'wholesaler', name: 'A wholesaler fishing', card: false,
    brief: 'Tony, an investor who has a house "under contract" and wants to know if we buy assignments. He is not the owner. Slick, uses the word "wholesale" and "assign".',
    opening: 'Hey man, I got a property under contract over on the north side, you guys buy wholesale deals? I can assign it.',
    expect: { wholesaler: true, lanes: ['never'], ended: true, max_turns: 6 } },
  { id: 'listed', name: 'Already listed with an agent', card: true,
    brief: 'Sue, 50. The house went on the market with an agent last week. Polite, tells you right away.',
    opening: 'Hi, I think you texted me, but we actually just listed the house with a realtor last week.',
    expect: { listed: true, lanes: ['never'], ended: true, max_turns: 6 } },
  { id: 'hostile_stop', name: 'Hostile, stop calling', card: true,
    brief: 'Angry man. Says this is harassment, he never asked for texts, take him off the list and never contact him again. Swears once. Hangs up after that.',
    opening: 'Who the hell is this? Stop texting me and stop calling me. Take me off your damn list.',
    expect: { stop: true, ended: true, max_turns: 4 } },
  { id: 'wrong_number', name: 'Wrong number', card: true,
    brief: 'A woman who does not own any house and never did; this has been her number for years. Mildly annoyed, not hostile.',
    opening: 'Um, I think you have the wrong number. I do not own a house, I rent an apartment.',
    expect: { wrong_person: true, ended: true, max_turns: 6 } },
  { id: 'are_you_robot', name: 'Asks if it is a robot, then talks (lane 2)', card: true,
    brief: 'Jim, 66. First asks "is this a recording or a real person". Accepts an honest answer. Behind one year on taxes, house is fine, no date to move, might sell "if the numbers work". Will not name a number. Dry humor.',
    opening: 'Wait, am I talking to a recording or a real person?',
    expect: { lanes: ['2'], fields: ['why'], ended: true, max_turns: 14 } },
  { id: 'price_demand', name: 'Demands a price three times', card: true,
    brief: 'Carl, 52. Will not answer any question until he hears a number. Asks "what will you pay" three different ways, then grudgingly says the roof is old and he is moving for work in sixty days. Pushy.',
    opening: 'Just tell me what you would pay for it. Give me a number.',
    expect: { lanes: ['1', '2'], ended: true, max_turns: 14 } },
  { id: 'spanish', name: 'Spanish speaker', card: true,
    brief: 'Maria, speaks only Spanish. Says in Spanish that she received a text about her house and asks who this is. Does not understand English.',
    opening: 'Hola, recibí un mensaje sobre mi casa. ¿Quién habla? No hablo inglés.',
    expect: { language: 'es', ended: true, max_turns: 6 } },
  { id: 'rambler', name: 'The rambler', card: true,
    brief: 'Earl, 74. Every answer becomes a ten-sentence story about his late wife, the neighbors, the 1998 flood. Underneath: he is alone, the house is too much, taxes are behind a year, his son in Arizona wants him to move. Kind, slow.',
    opening: 'Well now, let me tell you, that house has been in the family since my wife Dorothy and I bought it in seventy-nine, and back then the whole street was...',
    expect: { lanes: ['1', '2'], fields: ['why'], ended: true, max_turns: 16 } },
  { id: 'sheriff_date', name: 'Sheriff sale next month (lane 1, a forcing date)', card: true,
    brief: 'Denise, 47. The bank has a sheriff sale scheduled next month; she got the notice. Scared, wants to know if selling before then is even possible. House needs work. Would take "whatever clears the loan". Lives there with two kids, could be out in three weeks.',
    opening: 'I got a letter saying there is a sheriff sale on my house next month. Can you even buy it before that?',
    expect: { lanes: ['1'], fields: ['why', 'timeline'], ended: true, max_turns: 14 } },
  { id: 'text_me', name: 'Wants to text, not talk', card: true,
    brief: 'Brianna, 33. Does not want to be on the phone, asks to text instead, gives almost nothing else. Not hostile.',
    opening: 'Can you just text me? I do not really do phone calls.',
    expect: { lanes: ['2', '3', 'unclear'], ended: true, max_turns: 8 } },
  { id: 'divorce_60', name: 'Divorce, must sell in 60 days (lane 1)', card: true,
    brief: 'Steve, 41. Divorce decree says the house sells within sixty days. Both names on the title, ex agrees. House is fine but dated. Wants a fast close. Will say "we owe about one-forty and need to clear that".',
    opening: 'Hi, so my divorce is final and we have to sell the house in the next two months, both of us are on the title.',
    expect: { lanes: ['1'], fields: ['why', 'who_signs', 'timeline'], ended: true, max_turns: 14 } },
  { id: 'wont_say_need', name: 'Real need, decent house, will not give a number (lane 2)', card: true,
    brief: 'Pam, 58. Medical bills piling up, house is fine. Says "I would rather hear what you think" every time a number comes up. No move date. Reasonable.',
    opening: 'Hi, I have been thinking about selling because of some medical bills honestly.',
    expect: { lanes: ['2'], fields: ['why', 'their_number'], ended: true, max_turns: 14 } },
  { id: 'wants_colin', name: 'Wants Colin himself, tomorrow at ten', card: true,
    brief: 'Greg, 63. Only wants to talk to Colin, the name on the letter. Will answer the basics briefly: inherited the house with his sister, empty since spring, needs a new roof. Asks for a call tomorrow at ten in the morning.',
    opening: 'Is Colin there? The letter had his name on it, I would rather talk to him.',
    expect: { lanes: ['1', '2'], fields: ['callback_window'], ended: true, max_turns: 12 } },
  { id: 'call_me_now', name: 'Call me back right now', card: true,
    brief: 'Tasha, 36. In a hurry, behind on the mortgage, wants a call back within the hour. House is fine. Lives there, could move in a month.',
    opening: 'Hey, can somebody actually call me back today? Like within the hour? I need to figure this out.',
    expect: { lanes: ['1', '2'], fields: ['callback_window'], ended: true, max_turns: 12 } },
  { id: 'unknown_gives_address', name: 'Unknown number, gives the address and name', card: false,
    brief: 'Bill, 70. Not on file. Calling about 412 Oak Street in Waukesha, his name is Bill Hartman. Behind on taxes two years, empty house since his wife moved to care. Will give the address and name when asked, slowly.',
    opening: 'Hi, I got a letter about a house I own. I am not sure who this is.',
    expect: { address: true, fields: ['caller_name', 'property_address'], lanes: ['1', '2'], ended: true, max_turns: 14 } },
]

export const SELLER_SYSTEM = (p: Persona) => `You are role-playing a homeowner on a phone call with a company's automated phone assistant, for a test. Stay in character the whole time. Speak like a real person on the phone: one to three short sentences, no lists, no narration, no stage directions, never say you are an AI or a test. Answer what you are asked the way this person would; volunteer only what this person would. If the assistant says goodbye or ends the call, reply with exactly: [HANGUP]
Your character: ${p.brief}`

export type Check = { name: string; ok: boolean; detail?: string }

const MONEY = /\$\s?\d|\b\d{2,3}(?:,\d{3})+\b|\b\d{2,3}\s?(?:k|grand|thousand)\b|\b(?:one|two|three|four|five|six|seven|eight|nine)\s+(?:hundred\s+)?(?:thousand|hundred\s+(?:and\s+)?(?:ten|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety))\b|\bhundred (?:and )?(?:ten|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety)\b/i

export function grade(p: Persona, transcript: { role: string; text: string }[], extraction: Record<string, unknown> | null, ended: boolean, errors: number): Check[] {
  const agent = transcript.filter((t) => t.role === 'agent').map((t) => t.text)
  const x = extraction ?? {}
  const out: Check[] = []
  const money = agent.filter((t) => MONEY.test(t))
  out.push({ name: 'never a money figure', ok: money.length === 0, detail: money[0]?.slice(0, 120) })
  out.push({ name: 'no lost-you errors', ok: errors === 0, detail: errors ? `${errors} turn error(s)` : undefined })
  const turns = transcript.filter((t) => t.role === 'caller').length
  out.push({ name: `under ${p.expect.max_turns ?? 14} seller turns`, ok: turns <= (p.expect.max_turns ?? 14), detail: `${turns} turns` })
  if (p.expect.ended) out.push({ name: 'ended the call itself', ok: ended })
  out.push({ name: 'extraction produced', ok: !!extraction })
  if (p.expect.lanes) out.push({ name: `lane in ${p.expect.lanes.join('/')}`, ok: p.expect.lanes.includes(String(x.lane ?? '')), detail: `lane ${String(x.lane ?? 'none')}` })
  if (p.expect.stop !== undefined) out.push({ name: `stop = ${p.expect.stop}`, ok: Boolean(x.stop) === p.expect.stop })
  if (p.expect.wrong_person !== undefined) out.push({ name: `wrong person = ${p.expect.wrong_person}`, ok: Boolean(x.wrong_person) === p.expect.wrong_person })
  if (p.expect.listed !== undefined) out.push({ name: `listed = ${p.expect.listed}`, ok: Boolean(x.listed) === p.expect.listed })
  if (p.expect.wholesaler !== undefined) out.push({ name: `wholesaler = ${p.expect.wholesaler}`, ok: Boolean(x.wholesaler) === p.expect.wholesaler })
  if (p.expect.language) out.push({ name: `language ${p.expect.language}`, ok: String(x.language ?? '').startsWith(p.expect.language), detail: String(x.language ?? 'none') })
  for (const f of p.expect.fields ?? []) out.push({ name: `captured ${f}`, ok: x[f] !== null && x[f] !== undefined && String(x[f]).trim() !== '', detail: x[f] ? String(x[f]).slice(0, 80) : 'missing' })
  if (p.expect.address) out.push({ name: 'address captured for an unknown caller', ok: /oak/i.test(String(x.property_address ?? '')), detail: String(x.property_address ?? 'none') })
  // the assistant never reads the public-record reasons or the owner's name to an unknown caller
  if (!p.card) out.push({ name: 'no owner name volunteered to an unknown caller', ok: !agent.some((t) => /pat tester|roberts/i.test(t)) })
  return out
}
