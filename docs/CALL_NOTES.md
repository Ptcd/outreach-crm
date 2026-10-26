# Call notes

Colin 2026-10-26: calls kept going unlogged, and the Muse texting agent has to know what was said on the phone.
Every seller call through the app is recorded (after a disclosure line), transcribed, and summarized onto the card.

## The path of one call

1. **pm-phone** (`src/lib/recording.ts`). When `CALL_RECORDING` allows it, the `<Dial>` records both sides
   (`record-from-answer-dual`) and posts the finished recording to the `call-notes` function.
   - App call (Call button, TwiML App "WPIE app dialer" → `/api/twilio/voice/client`): the seller hears the
     disclosure the moment they pick up, before they are connected (`<Number url=/api/twilio/voice/disclosure>`).
   - Call in to a seller line (`/api/twilio/voice/incoming`): the caller hears the disclosure before it rings.
     The PM line is never recorded. A missed call goes to voicemail as before (Twilio's own voicemail transcript,
     migration 0063).
   - `CALL_RECORDING`: `off` (default: calls sound exactly as before), `test` (only numbers in
     `CALL_RECORDING_TEST_NUMBERS`), `on` (every seller call). `CALL_DISCLOSURE` overrides the line
     (default "This call may be recorded for notes.").
2. **call-notes** Edge Function (`supabase/functions/call-notes`, `_shared/callNotes.ts`):
   - `?d=out|in`: Twilio's recording callback (X-Twilio-Signature, the subaccount's token). `call_recording_ready`
     finds the card (an app call by its `human_call_provider_claims` row, an inbound call by its `inbound_calls` row,
     else the caller's phone). Under 15 seconds, or no card: not transcribed.
   - Twilio Voice Intelligence service `wpie-call-notes` (AutoTranscribe off, data logging off) transcribes the
     recording; its webhook (`?event=transcript`) is only a nudge: the transcript is re-read from Twilio.
   - Claude (`claude-opus-5-5`, structured output) writes the summary, the 4 pillars plus who signs, the outcome,
     the next step with its time, a suggested mark, and the call script answers.
   - `call_notes_save` keeps the words in `call_transcripts` (team only), writes the call entry
     (`messages`, channel `call`, status `call_notes` / `inbound_call_notes`: a note, the belt does not move), and
     fills `call_facts` keys the card has no answer for from this call (an answer tapped during the call wins).
     Twilio's copy of the transcript is then deleted; the recording stays in Twilio.
   - `?event=sweep` (pg_cron every 5 minutes, only while something is in flight) retries lost callbacks;
     5 tries, then `failed`. `?event=selftest` runs a made-up call through Claude (cron secret).
3. **The card** (`src/components/CallNotes.tsx`): the notes under the Call panel and one tap to confirm the
   suggested mark (`call_note_confirm`): Hot, Not now (date), Held (what they wait on), Dead, Reached, No answer,
   Wrong number, Do not contact. The tap logs the call through `log_call`, exactly like "Save the call"; Hot also books
   the call-back or walk-through they agreed to. A call already logged by hand is not logged again.
4. **The texting agent**: `agent_card.call_notes` (summary, pillars, outcome, next step, the mark) and the call entry in
   `calls`. Never the words.

## Privacy

The words are in `call_transcripts` only (RLS: team). Nothing logs them: failures log the call id and a reason.
The notes carry at most one quote, under 15 words.

## Checks

- `select status, error, attempts from call_recordings order by created_at desc limit 10;`
- Self-test: `net.http_post` to `call-notes?event=selftest` with the `send_openers_cron_secret` header.
