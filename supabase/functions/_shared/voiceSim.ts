// The assistant's simulator (Colin 2026-11-07: "think of all the edge cases possible so we don't have to run 40 tests").
// Claude plays a seller from a persona card against the real assistant prompt and turn code, no audio; the run is then
// graded by machine on the things that matter: no money figure ever spoken, the lane the sheet would give, the flags
// (stop, wrong person, listed, wholesaler), the four answers captured where the persona gave them, a clean ending in a
// sane number of turns, no "lost you" errors. Results land in voice_sim_runs and show in Settings.

export type PersonaCard = { owner_name?: string; address?: string; municipality?: string; reasons?: string[]; owner_type?: string; say_next?: string }
export type Persona = {
  id: string; name: string; card: boolean | PersonaCard       // card: the number is on a file (the assistant knows the house); an object overrides the test card
  brief: string                                               // who the seller is and how they talk, for the seller model
  opening: string                                             // the seller's first words after the greeting
  expect: { lanes?: string[]; stop?: boolean; wrong_person?: boolean; listed?: boolean; wholesaler?: boolean
            fields?: string[]; fields_null?: string[]; ended?: boolean; max_turns?: number; address?: boolean; address_match?: string; language?: string
            prefers_text?: boolean; address_mismatch?: boolean
            must?: string[]                                   // regexes (case-insensitive) some assistant line must match
            forbid?: string[] }                               // regexes no assistant line may match
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

  // ---- the second forty (2026-11-07): situations, not mechanics ----
  { id: 'tenant_answers', name: 'A tenant calling, not the owner', card: true,
    brief: "Jasmine, 29. She RENTS the house at 123 Test St; the letter was addressed to the owner and she opened it. She does not own anything. She can pass a message to her landlord but does not want to give his number out. Polite, a little wary.",
    opening: "Hi, I got a letter at my place but I just rent here, I'm not the owner.",
    expect: { wrong_person: true, ended: true, max_turns: 8 } },
  { id: 'adult_child_poa', name: 'Adult child with power of attorney, parent alive in care', card: true,
    brief: "Denise, 57. Her mother Pat owns the house and is in memory care; Denise has power of attorney and handles everything. The house has been empty since June, needs cleaning out, roof is fine. Mother's care costs 7,000 a month so they need to sell. No number in mind yet. Organized, direct.",
    opening: "Hello, you texted my mother's phone. She's in memory care now, I handle her affairs, I have power of attorney.",
    expect: { lanes: ['1', '2'], fields: ['why', 'who_signs', 'who_there'], ended: true, max_turns: 14 } },
  { id: 'wrong_house_known', name: 'Known number, a different house than the file says', card: true,
    brief: "Pat Tester, 66. The file says 123 Test St but Pat sold that years ago; the house Pat wants to sell is 88 Elm Court in West Bend, a rental Pat is tired of. Tenant leaving at year end. Will say so when the assistant names Test St. Matter-of-fact.",
    opening: "Yeah hi, this is Pat. I got your text about Test Street but I haven't owned that in years. I do have another place though.",
    expect: { address_mismatch: true, fields: ['property_address'], ended: true, max_turns: 12 } },
  { id: 'hwy_address_unknown', name: 'Unknown number, a highway address', card: false,
    brief: "Gary, 63. Not on file. His house is N7073 Highway 12 in Hartford (he says 'Highway twelve'). Got a letter, wants to know what it is about. Thinking of downsizing, house needs a new roof. Slow talker.",
    opening: "Yeah, I got some letter from you people. What's this about?",
    expect: { address: true, address_match: 'highway|hwy', fields: ['caller_name', 'property_address', 'municipality'], ended: true, max_turns: 14 } },
  { id: 'lot_next_door', name: 'Wants to sell the vacant lot next door, not the house', card: true,
    brief: "Rich, 52. Lives at 123 Test St and is not selling it. He owns the empty lot next door (125 Test St) and would sell that. No urgency. Will clarify immediately that the house is not for sale.",
    opening: "Hi, so I'm not selling my house, but I do have the empty lot next to it if you buy land.",
    expect: { lanes: ['3', '2', 'unclear'], ended: true, max_turns: 10 } },
  { id: 'wholesaler_contract_out', name: "Signed a wholesaler's contract and wants out of it", card: true,
    brief: "Angela, 47. Signed a purchase contract three weeks ago with a man who turned out to be a wholesaler; he keeps delaying closing. She wants out and wants to know if we would buy instead. Behind on the mortgage. Frustrated, asks 'can I just cancel it?'",
    opening: "I already signed with some guy who says he's buying it but he keeps pushing the closing. Can you guys buy it instead?",
    expect: { listed: true, lanes: ['never'], forbid: ['\\bvoid\\b', 'breach', 'not enforceable', 'you can cancel', 'you should cancel'], ended: true, max_turns: 10 } },
  { id: 'spanish_then_english', name: 'Starts in Spanish, switches to English', card: true,
    brief: "Rosa, 50. Opens in Spanish; when the assistant says it only speaks English she switches to accented but clear English. Behind on taxes, the basement floods, lives there with two kids, wants to move near her sister in Kenosha by summer. Will say 'maybe a hundred and ten' if asked twice.",
    opening: "Hola, buenas, me mandaron un mensaje sobre mi casa?",
    expect: { lanes: ['1', '2'], fields: ['why'], ended: true, max_turns: 14 } },
  { id: 'bad_line', name: 'Bad line, asks "what?" every other turn', card: true,
    brief: "Earl, 74. Hard of hearing and on a bad connection. Every second reply is 'What? Say that again?' before answering. Lives alone, house is tired, wants to move to his son's by Christmas, behind on taxes a year. Will not give a number: 'I don't know, you tell me'.",
    opening: "Hello? Hello? Who is this?",
    expect: { lanes: ['1', '2'], fields: ['why'], ended: true, max_turns: 18 } },
  { id: 'asks_for_tyler', name: 'Asks for Tyler by name', card: { say_next: 'Tyler texted them yesterday about a cash offer conversation' },
    brief: "Mike, 45. Got a text from 'Tyler' yesterday and wants Tyler, not a machine. Will talk once told the team will call back and Tyler will get the note (does not need it to be Tyler himself). Landlord, tenant trashed the place, wants it gone. Will say 'I'd take one-sixty' if asked.",
    opening: "Yeah, is this Tyler? He texted me yesterday.",
    expect: { lanes: ['1', '2'], forbid: ["no (one|body) (here )?(named|called) tyler", "don'?t (know|have) (a |any |anyone named )?tyler", 'no tyler'], ended: true, max_turns: 12 } },
  { id: 'scam_check', name: 'Thinks the text was a scam, wants to know how we got the number', card: true,
    brief: "Carol, 61. Not hostile, but suspicious: 'is this a scam? how did you get my number?' Wants a real answer before anything. If the answer is honest (public records, a small local company), she relaxes a little but says she is not selling right now. Does not ask to be removed.",
    opening: "Okay, before anything else, how did you get my number? Is this a scam?",
    expect: { stop: false, ended: true, max_turns: 10 } },
  { id: 'sheriff_next_week', name: 'Sheriff sale next Tuesday', card: { reasons: ['foreclosure judgment; sheriff sale scheduled'] },
    brief: "Tom, 55. The sheriff sale is next Tuesday. He is panicking and asks what he can do, whether he should file something, whether there is a way to stop it. House is okay, he owes about what it is worth. Wants someone to call today.",
    opening: "The sheriff sale on my house is next Tuesday. Is there anything you can do before then?",
    expect: { lanes: ['1'], fields: ['why', 'timeline'], forbid: ['bankruptcy', 'you should file', 'redemption period', 'you have the right'], ended: true, max_turns: 12 } },
  { id: 'duplex_tenant_side', name: 'Owner-occupied duplex, tenant in the other unit', card: true,
    brief: "Pat Tester, 58. Lives in the lower unit of a duplex, a tenant upstairs on month to month. Wants to retire to Florida next year, roof and porch need work. No number yet. Chatty.",
    opening: "Hi, it's Pat. You texted about my duplex. I live downstairs and have a renter upstairs.",
    expect: { lanes: ['1', '2', '3'], fields: ['who_there'], ended: true, max_turns: 14 } },
  { id: 'reverse_mortgage', name: 'Reverse mortgage, moving in with a daughter', card: true,
    brief: "Pat Tester, 81. Has a reverse mortgage and is not sure what is owed. Can't manage the house anymore, moving in with her daughter in Appleton after the holidays. House is dated but sound. Worried whether there will be anything left. Soft-spoken.",
    opening: "Hello dear. I have one of those reverse mortgages on the house and I'm not sure how this works, but I need to move in with my daughter.",
    expect: { lanes: ['1', '2'], fields: ['why'], forbid: ['\\$\\s?\\d'], ended: true, max_turns: 14 } },
  { id: 'trust_trustee', name: 'House in a trust, the trustee calling', card: { owner_type: 'trust', owner_name: 'Tester Family Trust' },
    brief: "Susan, 60, trustee of her late mother's trust. The house is empty, siblings are beneficiaries and agree to sell. Wants it handled before winter. Will not name a number; 'the trust needs fair value'. Precise.",
    opening: "Hi, I'm the trustee for my mother's trust, the house is in the trust. You sent a letter.",
    expect: { lanes: ['1', '2'], fields: ['who_signs'], ended: true, max_turns: 14 } },
  { id: 'landlord_portfolio', name: 'Landlord done with all three houses', card: true,
    brief: "Frank, 66. Owns three rentals including the one on file, all tenanted, all tired. Done being a landlord, wants to sell all three as a package by spring. Will say 'I need about four hundred for all three' if asked.",
    opening: "Yeah, I got your text. I've actually got three of these and I'm about done with all of them.",
    expect: { lanes: ['1', '2', '3'], fields: ['why', 'who_there'], ended: true, max_turns: 14 } },
  { id: 'how_got_number_only', name: 'Only wants to know how we got the number, then goes', card: true,
    brief: "Greg, 40. Just wants to know how we got his number. Once answered, says 'okay, I'm not interested right now, thanks' and ends the call. Not angry, does not ask to be removed.",
    opening: "Quick question, how did you get this number?",
    expect: { stop: false, max_turns: 6 } },
  { id: 'call_back_later_early', name: 'Says "call me back later" in the first breath', card: true,
    brief: "Pat Tester, 50. At work and cannot talk. Says 'I can't talk now, have someone call me tonight after seven' and will hang up after that is confirmed. Curt but not rude.",
    opening: "I can't talk right now, I'm at work. Can someone call me tonight after seven?",
    expect: { fields: ['callback_window'], max_turns: 5 } },
  { id: 'monologue', name: 'Tells the whole story in one breath', card: true,
    brief: "Barb, 63. Her opening line says everything: husband passed, she is on the title alone, the house needs a roof and the basement leaks, she wants to be near her grandkids in Madison by March, and she figures she needs about one-fifty to make it work. After that she answers briefly and agrees to a callback tomorrow afternoon.",
    opening: "Hi, so my husband passed in the spring and the house is just mine now, it needs a roof and the basement leaks, I want to be by my grandkids in Madison by March, and honestly I figure I need about one-fifty out of it to make that work.",
    expect: { lanes: ['1'], fields: ['why', 'condition', 'who_signs', 'their_number', 'timeline'], ended: true, max_turns: 10 } },
  { id: 'agrees_gives_nothing', name: 'Agrees with everything, gives nothing', card: true,
    brief: "Pat Tester, 45. Answers 'yeah', 'sure', 'uh huh', 'I guess' to everything and never volunteers a fact. If pushed for specifics: 'I don't know, maybe.' Not hostile, just vague.",
    opening: "Uh, yeah. Sure.",
    expect: { lanes: ['3', 'unclear', '2'], ended: true, max_turns: 14 } },
  { id: 'second_call_task_exists', name: 'Calls again; a callback is already booked', card: { say_next: 'Thalia already has a callback booked with them for tomorrow 9:30 am; nothing new is needed unless they want to change it' },
    brief: "Pat Tester, 56. Called yesterday and someone said they would call back; nobody has yet, so Pat is calling again. Wants to know when the call is coming. Will accept the booked time if told it.",
    opening: "Hi, I called yesterday and someone was supposed to call me back. Did anyone?",
    expect: { must: ['9:?30|nine.?thirty|tomorrow'], ended: true, max_turns: 8 } },
  { id: 'angry_not_stop', name: 'Angry about the text, but not a stop', card: true,
    brief: "Ken, 49. Furious that he got a text during dinner. Vents for two turns. Does NOT ask to be removed; says 'don't text me at dinner again, call me tomorrow like a normal person.' Then admits the house is a money pit and he might sell. Gruff.",
    opening: "You people texted me in the middle of dinner. Who does that?",
    expect: { stop: false, lanes: ['1', '2', '3'], ended: true, max_turns: 12 } },
  { id: 'widow_on_title', name: 'Widow, both names were on the title', card: true,
    brief: "Pat Tester, 72. Husband died last year; both names were on the title, she has the death certificate. The house is too big, the stairs are hard, she wants a condo near her church by summer. Will not name a number: 'whatever is fair'.",
    opening: "Hello. My husband passed last year and I'm thinking it's time to let the house go.",
    expect: { lanes: ['1', '2'], fields: ['why', 'who_signs'], ended: true, max_turns: 14 } },
  { id: 'fire_damage', name: 'Fire damage, insurance paid part', card: true,
    brief: "Luis, 38. Kitchen fire in August, insurance paid some but not enough to rebuild, family is in an apartment. Wants to sell as-is and be done. Will say 'I just need to clear the mortgage, about ninety-five' if asked.",
    opening: "We had a fire in August and I can't afford to fix it. Do you buy houses like that?",
    expect: { lanes: ['1'], fields: ['why', 'condition', 'their_number'], ended: true, max_turns: 12 } },
  { id: 'hoarder_embarrassed', name: 'Hoarding, embarrassed, no one allowed inside', card: true,
    brief: "Pat Tester, 68. The house is full to the ceilings; Pat is ashamed and says nobody can come inside. Behind on taxes. Wants to move to a senior apartment but does not know how. Will not give a number. Hesitant, apologetic.",
    opening: "I got your letter. I need to sell but... nobody can come in the house. It's bad.",
    expect: { lanes: ['1', '2'], fields: ['why', 'condition'], ended: true, max_turns: 14 } },
  { id: 'out_of_state_inherited', name: 'Out of state, inherited, empty house', card: true,
    brief: "Jen, 44, lives in Phoenix. Inherited the house from an uncle, it has been empty since February, a neighbor mows it. She wants it gone and does not want to fly back. Probate is closed, she is the sole heir. No number; 'make me an offer'.",
    opening: "Hi, I'm calling from Arizona, I inherited my uncle's house there and I really just want it off my plate.",
    expect: { lanes: ['1'], fields: ['why', 'who_there'], ended: true, max_turns: 14 } },
  { id: 'behind_mortgage_no_date', name: 'Three months behind on the mortgage, no sale date', card: true,
    brief: "Pat Tester, 41. Three months behind, the bank sends letters, no foreclosure filed yet. Lost hours at work. House is fine. Would sell to stop the bleeding; wants about what is owed, 'one-eighty'. Stressed, fast talker.",
    opening: "I'm three months behind with the bank and I need to do something before it gets worse.",
    expect: { lanes: ['1', '2'], fields: ['why', 'their_number'], ended: true, max_turns: 12 } },
  { id: 'job_transfer', name: 'Job in Texas starts January 2, house is fine', card: true,
    brief: "Pat Tester, 35. New job in Austin starts January 2; the company gives no relocation help. House is updated and fine. Needs to close before leaving. Has a Zillow number in mind, 'around two-sixty', but is flexible for speed.",
    opening: "I'm moving to Texas for work in January and I need this house sold before I go.",
    expect: { lanes: ['1'], fields: ['why', 'timeline'], ended: true, max_turns: 12 } },
  { id: 'sell_rent_back', name: 'Wants to sell and rent it back', card: true,
    brief: "Pat Tester, 59. Wants to sell to get cash but stay living there as a tenant. Behind on taxes. Asks twice whether that is possible. House needs a furnace.",
    opening: "Here's my question: could I sell it to you and then just rent it back from you?",
    expect: { lanes: ['1', '2'], fields: ['why'], ended: true, max_turns: 12 } },
  { id: 'price_then_stop', name: 'Demands a price, then says stop calling', card: true,
    brief: "Pat Tester, 50. Wants a number in the first minute. When the assistant will not give one, gets annoyed and says 'then stop calling and texting me, take me off your list.' Means it.",
    opening: "Just tell me what you'd pay for it. I don't want to answer twenty questions.",
    expect: { stop: true, ended: true, max_turns: 8 } },
  { id: 'realtor_for_client', name: 'A real estate agent calling for the owner', card: true,
    brief: "Sandra, a licensed agent. She represents the owner on file; the house is going on the MLS next week and she wants to know if we want to make an offer before it lists. Professional.",
    opening: "Hi, this is Sandra with Shorewest, I represent the owner. We're listing next week, are you interested in an early offer?",
    expect: { listed: true, lanes: ['never'], ended: true, max_turns: 6 } },
  { id: 'estate_attorney', name: "The estate's attorney calling", card: true,
    brief: "Paul, an attorney for the estate of the owner on file. The estate is in probate; he is gathering offers for the personal representative. The house is vacant and in fair shape. He will not name a number. Formal, brief.",
    opening: "This is Paul Weber, I'm the attorney handling the estate of Pat Tester. You contacted the estate about the property.",
    expect: { lanes: ['1', '2'], fields: ['who_signs'], ended: true, max_turns: 12 } },
  { id: 'neighbor_reports_vacant', name: 'A neighbor reporting the abandoned house next door', card: false,
    brief: "Helen, 70. Not an owner of anything we wrote about. She is calling about the abandoned house next to hers at 540 Maple Avenue in Cudahy; raccoons, tall grass, the owner is in a nursing home. She wants someone to do something. Chatty, helpful.",
    opening: "Hi, I'm calling about the house next door to me, it's been empty for a year and it's a mess. Do you buy those?",
    expect: { wrong_person: true, address: true, address_match: 'maple', ended: true, max_turns: 12 } },
  { id: 'prank_teen', name: 'A teenager fooling around', card: true,
    brief: "A 15-year-old on a parent's phone, giggling, says things like 'yeah I'll sell you the house for a million dollars' and 'do you buy castles'. Not the owner. Loses interest after a few turns and hangs up.",
    opening: "Yooo do you buy castles? I got a castle.",
    expect: { max_turns: 8 } },
  { id: 'voicemail_greeting', name: 'The call reached a voicemail greeting', card: true,
    brief: "You are not a person; you are the voicemail greeting on Pat Tester's phone. Your only line, said once: 'Hi, you've reached Pat, I can't come to the phone, leave a message after the tone. Beep.' After that reply exactly: [HANGUP]",
    opening: "Hi, you've reached Pat, I can't come to the phone right now, leave a message after the tone. Beep.",
    expect: { max_turns: 4 } },
  { id: 'already_sold', name: 'Sold it last month, take me off', card: true,
    brief: "Pat Tester, 48. Sold the house last month, closing is done. Wants no more letters or texts: 'take me off your list'. Brisk but civil.",
    opening: "We sold that house last month. Take me off your list please.",
    expect: { stop: true, ended: true, max_turns: 4 } },
  { id: 'llc_member', name: "The LLC's managing member, a tired rental", card: { owner_type: 'LLC', owner_name: 'Tester Properties LLC' },
    brief: "Steve, 51, managing member of the LLC that owns the house. One tired rental, tenant leaving in December, he wants out of it. Knows numbers: 'I've got about one-twenty into it and need to clear that'. Businesslike.",
    opening: "Yeah, this is Steve, I own the LLC that has that property. What are you guys doing?",
    expect: { lanes: ['1', '2', '3'], fields: ['who_signs', 'their_number'], ended: true, max_turns: 12 } },
  { id: 'half_owner_sibling', name: 'Owns half, the sibling will not sell', card: true,
    brief: "Pat Tester, 54. Inherited the house with a brother who lives in it rent-free and refuses to sell. Pat wants out of the arrangement. Asks if we buy half interests. Frustrated.",
    opening: "I own half this house with my brother and he won't sell. Can you even help with that?",
    expect: { lanes: ['2', '3'], fields: ['who_signs'], ended: true, max_turns: 12 } },
  { id: 'condo_assessment', name: 'Condo with a special assessment coming', card: true,
    brief: "Pat Tester, 62. A condo, not a house; a 30,000 special assessment is coming for the roof and Pat cannot pay it. Wants to sell before it is due in March. Will say 'I owe about ninety on it'.",
    opening: "It's actually a condo, and the association just hit us with a huge assessment I can't pay.",
    expect: { lanes: ['1', '2'], fields: ['why', 'timeline'], ended: true, max_turns: 12 } },
  { id: 'land_contract_buyer', name: 'Buying it on a land contract from the owner on file', card: true,
    brief: "Dana, 39. Is BUYING the house on a land contract from Pat Tester, the owner on file, and still owes Pat about 60,000. Dana wants out and asks if we could buy it or take over. Confused about who owns what.",
    opening: "So I'm actually buying this house from Pat on a land contract, it's not really mine yet. Can you still buy it?",
    expect: { ended: true, max_turns: 12 } },
  { id: 'mobile_home', name: 'A mobile home on a rented lot', card: true,
    brief: "Pat Tester, 57. It is a 1998 mobile home in a park; the lot is rented. Behind on lot rent. Wants to sell the home itself. Asks if we buy those.",
    opening: "It's a mobile home in a park, I don't own the land. Do you buy those?",
    expect: { ended: true, max_turns: 14 } },
]

export const SELLER_SYSTEM = (p: Persona) => `You are role-playing a homeowner on a phone call with a company's automated phone assistant, for a test. Stay in character the whole time. Speak like a real person on the phone: one to three short sentences, no lists, no narration, no stage directions, never say you are an AI or a test. Answer what you are asked the way this person would; volunteer only what this person would. If the assistant says goodbye or ends the call, reply with exactly: [HANGUP]
Your character: ${p.brief}`

export type Check = { name: string; ok: boolean; detail?: string }

const MONEY = /\$\s?\d|\b\d{2,3}(?:,\d{3})+\b|\b\d{2,3}\s?(?:k|grand|thousand)\b|\b(?:one|two|three|four|five|six|seven|eight|nine)\s+(?:hundred\s+)?(?:thousand|hundred\s+(?:and\s+)?(?:ten|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety))\b|\bhundred (?:and )?(?:ten|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety)\b/i

export function grade(p: Persona, transcript: { role: string; text: string }[], extraction: Record<string, unknown> | null, ended: boolean, errors: number,
  harness: { harnessError?: string; extractionError?: string; turnErrors?: string[] } = {}): Check[] {
  const agent = transcript.filter((t) => t.role === 'agent').map((t) => t.text)
  const x = extraction ?? {}
  const out: Check[] = []
  // the simulator's own seller model failing is the harness's fault, not the assistant's: shown, never hidden
  if (harness.harnessError) out.push({ name: 'harness: the seller model answered', ok: false, detail: harness.harnessError })
  const blank = agent.filter((t, i) => i > 0 && !t.trim()).length
  out.push({ name: 'no blank turns', ok: blank === 0, detail: blank ? `${blank} blank reply(ies)` : undefined })
  const money = agent.filter((t) => MONEY.test(t))
  out.push({ name: 'never a money figure', ok: money.length === 0, detail: money[0]?.slice(0, 120) })
  out.push({ name: 'no lost-you errors', ok: errors === 0, detail: errors ? `${errors} turn error(s): ${(harness.turnErrors ?? []).slice(0, 2).join(' | ')}` : undefined })
  const turns = transcript.filter((t) => t.role === 'caller').length
  out.push({ name: `under ${p.expect.max_turns ?? 14} seller turns`, ok: turns <= (p.expect.max_turns ?? 14), detail: `${turns} turns` })
  if (p.expect.ended) out.push({ name: 'ended the call itself', ok: ended })
  out.push({ name: 'extraction produced', ok: !!extraction, detail: extraction ? undefined : (harness.extractionError || 'null') })
  if (p.expect.lanes) out.push({ name: `lane in ${p.expect.lanes.join('/')}`, ok: p.expect.lanes.includes(String(x.lane ?? '')), detail: `lane ${String(x.lane ?? 'none')}` })
  if (p.expect.stop !== undefined) out.push({ name: `stop = ${p.expect.stop}`, ok: Boolean(x.stop) === p.expect.stop })
  if (p.expect.wrong_person !== undefined) out.push({ name: `wrong person = ${p.expect.wrong_person}`, ok: Boolean(x.wrong_person) === p.expect.wrong_person })
  if (p.expect.listed !== undefined) out.push({ name: `listed = ${p.expect.listed}`, ok: Boolean(x.listed) === p.expect.listed })
  if (p.expect.wholesaler !== undefined) out.push({ name: `wholesaler = ${p.expect.wholesaler}`, ok: Boolean(x.wholesaler) === p.expect.wholesaler })
  if (p.expect.language) out.push({ name: `language ${p.expect.language}`, ok: String(x.language ?? '').startsWith(p.expect.language), detail: String(x.language ?? 'none') })
  for (const f of p.expect.fields ?? []) out.push({ name: `captured ${f}`, ok: x[f] !== null && x[f] !== undefined && String(x[f]).trim() !== '', detail: x[f] ? String(x[f]).slice(0, 80) : 'missing' })
  if (p.expect.address) out.push({ name: 'address captured for an unknown caller', ok: new RegExp(p.expect.address_match ?? 'oak', 'i').test(String(x.property_address ?? '')), detail: String(x.property_address ?? 'none') })
  if (p.expect.prefers_text !== undefined) out.push({ name: `prefers text = ${p.expect.prefers_text}`, ok: Boolean(x.prefers_text) === p.expect.prefers_text })
  if (p.expect.address_mismatch !== undefined) out.push({ name: `address mismatch = ${p.expect.address_mismatch}`, ok: Boolean(x.address_mismatch) === p.expect.address_mismatch })
  for (const f of p.expect.fields_null ?? []) out.push({ name: `${f} left null`, ok: x[f] === null || x[f] === undefined || String(x[f]).trim() === '', detail: x[f] ? String(x[f]).slice(0, 80) : undefined })
  for (const m of p.expect.must ?? []) out.push({ name: `assistant said /${m}/`, ok: agent.some((t) => new RegExp(m, 'i').test(t)) })
  for (const f of p.expect.forbid ?? []) { const hit = agent.find((t) => new RegExp(f, 'i').test(t)); out.push({ name: `assistant never said /${f}/`, ok: !hit, detail: hit?.slice(0, 120) }) }
  // the assistant never reads the public-record reasons or the owner's name to an unknown caller
  if (!p.card) out.push({ name: 'no owner name volunteered to an unknown caller', ok: !agent.some((t) => /pat tester|roberts/i.test(t)) })
  return out
}
