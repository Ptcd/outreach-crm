# One property card, many interests

Muse's spec for Colin, 2026-10-27. Colin agreed to all three design calls:

1. Due items and check-backs live on the interest they concern, shown on the card.
2. When the last live interest on a card closes, the card holds itself ("no live interest") and lands on the re-trace list.
3. A person is one global record with a role on each property.

Claude added a fourth: one interest on a card is texted at a time. The next interest is texted only after the current one closes, or after its texts got no reply at all.

## The model (migration 0082)

| Table | What it is |
|---|---|
| `leads` | The property card: stage, belt, reasons, holds. `owner_name` is the name on the deed, as data. |
| `people` | One record per person or entity, global across cards. It holds their own mailing address and the person-level state that follows them everywhere: `active`, `deceased`, `do_not_contact`. A `household` is a couple's deed name. |
| `interests` | A person's role on one card, with its own status. Roles: `owner_of_record`, `co_owner`, `personal_representative`, `special_administrator`, `heir`, `trustee`, `spouse`, `occupant`, `other`. Statuses: `active`, `deceased`, `do_not_contact`, `not_the_contact`, `closed`. |
| `contacts.person_id` | The person a phone belongs to. The same number can be a row under several people and several cards. |
| `person_phones` (view) | Every number a person has, on any card, with the global facts: bad, do-not-text, opted out, and which cards it is on. |

Every writer gets the model without changes of its own: the laptop sync, the door and the app.

- **A new card** gets its owner of record (trigger on `leads`).
- **A new phone** is attached to the person it names (trigger on `contacts`).
  - It goes to the owner when the name is the owner's.
  - It goes to a co-owner when it is one of a couple's names.
  - It goes to a trustee when the name is in a trust's name.
  - Otherwise the name becomes its own person, with role `other`, until someone says what they are.

**Identity is careful on purpose.** Two records are one person only when:

- the name matches (first and last word) **and** they share a phone number or the same mailing address; or
- the same name is already on the same card.

The same name alone never merges people.

When it went live on 2026-10-27:

- 5,319 people.
- Every phone attached to a person.
- 58 owners on 2+ cards.
- 270 numbers on several cards that turn out to be one person.
- Orlich: Sam is deceased. Eva is the personal representative, at 3454 S Chase Ave, with her 5 numbers.

## The door (migration 0084, 2026-10-27)

- `add_prospects` takes `interests[]`: name, role, their mailing address, their phones and an optional status. The old flat `owner_name` + `phones` shape still works as one owner of record.
  - Cards match on the property address only. Ranges count: "2825 2827 S Logan Av" is 2825 S Logan Av.
  - A number already on another card is attached anyway, to the person it belongs to, and reported as `also_on`.
- Every card carries `people[]`: role, status, address, phones (textable or not, shared with whom), and the person's other cards.
- `mark_card` has person marks:
  - `deceased`: closed on every card.
  - `wrong_person`: this card only.
  - `dnc` with an `interest_id` or phone: that person is do-not-contact on every card, and that number is blocked. When the person is an owner, the property closes too, as before.
- **The Orlich rule.** A card that died only as no contact, or by the death, reopens when a live person with a phone remains. When nobody live is left, the card holds for a re-trace (`data_fix`, "no live person on this card").
- **Texts aim at a person.**
  - `queue_texts` takes `interest_id`; without it, the phone's person on the card. It is stamped on `planned_openers.interest_id`.
  - Never a do-not-contact person's number.
  - Never a deceased person's number, unless a living person shares it.
  - The next person gets a first text only after the one texted is closed, or every first text to them bounced.
- **The send check.** A number on several cards is no longer `phone_shared` when it is one person's. A do-not-contact person's number is refused as `person_do_not_contact`.
- **The laptop sync** never closes a card the app reopened.

Orlich, done through the door on 2026-10-27:
- Eva's verified mobile, 414-801-5081, was attached to her.
- Sam was marked deceased, and the card reopened to `opener_sent`.
- A first text to Eva is allowed.

## Still to build

1. **The duplicates.** Merge the cards that are one property: 9 addresses, 30 cards. Point the laptop's owner key at the property card, so a second owner of a house joins it.
2. **The app card.**
   - Each person with their role, status, address and phones, and "also on: other card".
   - Per-person buttons and text threads.
   - Due items and check-backs on the person (Colin's call 1).

Sending rules do not change: the window, the cap, the variant and slot tests, and every guardrail stay as they are.
