-- The conveyor (Colin 2026-10-22: "build logic to e2e our whole system, we have messy pipes everywhere,
-- every card needs conveyor belts from the calls to texts"). Every live card sits on one BELT at one
-- STEP with one NEXT STOP: who does it (a text that goes on its own, a draft for Colin's tap, Thalia's
-- call, Colin's call, Colin's visit), when, and what to say (the thing the owner said, with the street).
-- Only an event moves a card, and every event goes through belt_event(): an inbound text, a call logged,
-- a slot booked, a stop logged with its outcome, STOP, a flag, a new public record. The cadence of every
-- belt is the table belt_steps, copied from WPIE docs/FOLLOWUP_CADENCE.md section 3 with Rick's caps:
-- at most three unanswered touches (four when they asked for the call), change the channel before
-- repeating, never before a date they named, Sundays and 8pm-8am recipient-local slid to the next open
-- hour, no text ever to an elderly, ill or grieving owner, nothing to dead or DNC.
-- Texts a stop sends are templates (touch_templates), each behind its own switch, default OFF: with the
-- switch off the stop becomes a draft for Colin's tap instead, so nothing automatic goes out and the belt
-- does not stall. The conveyor Edge Function (pg_cron, every 15 minutes, migration 0032) executes due
-- stops and writes a belt_health heartbeat; belt_watch() texts Colin through ops_alerts when it breaks.

-- ============================================================================ state on the lead
alter table public.leads
  add column if not exists belt             text,
  add column if not exists belt_step        smallint not null default 0,
  add column if not exists belt_round       integer  not null default 0,   -- times this belt was entered (task keys)
  add column if not exists belt_entered_at  timestamptz,
  add column if not exists next_stop_at     timestamptz,
  add column if not exists next_stop_who    text check (next_stop_who in ('auto_text', 'draft_text', 'thalia_call', 'colin_call', 'colin_visit')),
  add column if not exists next_stop_say    text,
  add column if not exists belt_reference   text,          -- what they said, in their words (carried across steps)
  add column if not exists named_date       timestamptz,   -- a date or slot they named (call / visit slot, "after the holidays")
  add column if not exists named_event      text,
  add column if not exists unanswered_count smallint not null default 0,
  add column if not exists dormant_round    smallint not null default 0 check (dormant_round between 0 and 3),
  add column if not exists dated_rounds     smallint not null default 0,   -- "not now, with a date" in a row (3 max)
  add column if not exists elderly_or_ill   boolean not null default false,
  add column if not exists grief            boolean not null default false;

alter table public.leads drop constraint if exists leads_belt_check;
alter table public.leads add constraint leads_belt_check check (belt is null or belt in (
  'cold_texts', 'replied_quiet', 'questions_quiet', 'yes_unbooked', 'call_booked', 'call_missed', 'visit_booked',
  'visit_missed', 'after_call_quiet', 'after_visit_quiet', 'offer_out', 'not_now_dated', 'not_now_condition',
  'needs_family', 'elderly', 'estate_waiting', 'hold_not_now', 'too_high_or_listed', 'dormant', 'dead', 'dnc'));
create index if not exists leads_belt_idx on public.leads (belt, next_stop_at);
create index if not exists leads_next_stop_idx on public.leads (next_stop_at) where next_stop_at is not null;

comment on column public.leads.belt is 'Which conveyor belt the card is on (belt_steps). Null: not texted yet, wrong number, closed won.';
comment on column public.leads.next_stop_say is 'The reference for the next stop: what they said, in their words, with the street.';

-- ============================================================================ the log
create table if not exists public.belt_events (
  id         bigint generated always as identity primary key,
  lead_id    uuid not null references public.leads (id) on delete cascade,
  event      text not null,
  from_belt  text,
  to_belt    text,
  step       smallint,
  payload    jsonb not null default '{}'::jsonb,
  at         timestamptz not null default now(),
  by         text
);
create index if not exists belt_events_lead_idx on public.belt_events (lead_id, at desc);
create index if not exists belt_events_at_idx on public.belt_events (at desc);
create index if not exists belt_events_event_idx on public.belt_events (event, at desc);
-- the same outside event never moves a card twice (a WPIE record, a synced text, a call-list day)
create unique index if not exists belt_events_key_idx on public.belt_events (lead_id, (payload->>'key')) where payload ? 'key';

-- A stage, next action or belt column written by a signed-in person outside belt_event (the health check counts these).
create table if not exists public.belt_direct_writes (
  id       bigint generated always as identity primary key,
  lead_id  uuid references public.leads (id) on delete cascade,
  by       text,
  changed  text[] not null,
  at       timestamptz not null default now()
);
create index if not exists belt_direct_writes_at_idx on public.belt_direct_writes (at desc);

-- ============================================================================ the cadence
-- One row per stop on each belt. delay_hours counts from the previous stop (anchor 'prev'), from the
-- named date (anchor 'named', may be negative), from the booked slot ('slot'), or is the morning of the
-- slot ('slot_morning'). 'owner_call' resolves to Colin's or Thalia's call by who has the card.
create table if not exists public.belt_steps (
  belt         text not null,
  step         smallint not null,
  who          text not null check (who in ('auto_text', 'draft_text', 'thalia_call', 'colin_call', 'colin_visit', 'owner_call')),
  anchor       text not null default 'prev' check (anchor in ('prev', 'now', 'named', 'slot', 'slot_morning')),
  delay_hours  numeric not null default 0,
  fallback_hours numeric,                 -- anchor 'named' with no named date: hours from the event instead
  call_hour    smallint,                  -- a call stop's default local hour (null: 14:00; 'other band' flips it)
  other_band   boolean not null default false,
  template_key text,                      -- touch_templates.key for a text stop
  say          text not null,             -- the reference line, with {street} {said} {time} {event} {name} {condition}
  primary key (belt, step)
);
-- Where a belt sends a card when its stops run out (null: the card stays, no next stop) and its cap.
create table if not exists public.belt_rules (
  belt        text primary key,
  label       text not null,
  meaning     text not null,
  then_belt   text,
  max_unanswered smallint not null default 3,
  stage       public.lead_stage,          -- the pipeline stage the belt shows as (null: unchanged)
  texts_ok    boolean not null default true
);

insert into public.belt_rules (belt, label, meaning, then_belt, max_unanswered, stage, texts_ok) values
  ('cold_texts',        'Cold texts',              'Never answered: texts 1, 2 (day 4) and 3 (day 18), then one call from the daily list', 'dead', 4, null, false),
  ('replied_quiet',     'Replied, went quiet',     'Answered once, never answered our question', 'dormant', 3, 'reply_received', true),
  ('questions_quiet',   'Mid-questions, quiet',    'Answered some questions, then stopped', 'dormant', 3, 'ai_qualifying', true),
  ('yes_unbooked',      'Said yes, not booked',    'Asked for a call or showed interest, never booked', 'dormant', 4, 'colin_call', true),
  ('call_booked',       'Call booked',             'A call slot is set', 'call_missed', 4, 'colin_call', true),
  ('call_missed',       'Call missed',             'They did not pick up at the slot', 'dormant', 4, 'colin_call', true),
  ('visit_booked',      'Visit booked',            'A walk-through is set', 'visit_missed', 4, 'walkthrough_booked', true),
  ('visit_missed',      'Visit missed',            'A no-show at the walk-through', 'dormant', 4, 'walkthrough_booked', true),
  ('after_call_quiet',  'After the call, no next step', 'Colin spoke to them, nothing was planted', 'dormant', 3, 'follow_up', true),
  ('after_visit_quiet', 'After the visit, quiet',  'Walked it, no decision yet', 'dormant', 4, 'walk_decision', true),
  ('offer_out',         'Offer out',               'A number is on the table', 'dormant', 4, 'offer', true),
  ('not_now_dated',     'Not now, with a date',    'They named a date or event', 'dormant', 3, 'follow_up', true),
  ('not_now_condition', 'Not now, with a condition', 'When the tenant leaves, after the insurance check', 'dormant', 3, 'follow_up', true),
  ('needs_family',      'Needs spouse or family',  'A signer not on board yet', 'dormant', 3, 'follow_up', true),
  ('elderly',           'Elderly, ill or grieving', 'Phone only, family on the line, their pace; never a nudge text', 'dormant', 2, 'follow_up', false),
  ('estate_waiting',    'Estate, waiting on papers', 'No letters yet', 'dormant', 5, 'follow_up', true),
  ('hold_not_now',      'Hold lane, not now',      'A landlord who said later', 'dormant', 3, 'follow_up', true),
  ('too_high_or_listed','Too high or listed',      'A market number held firm, or listed; nothing until a new public record', null, 0, 'follow_up', false),
  ('dormant',           'Dormant',                 'Replied once, ran out of touches, never said no: a quarterly check-in draft, three times', null, 3, 'follow_up', true),
  ('dead',              'Dead',                    'A clear no, sold, family keeping it. Nothing; one yearly sweep', null, 0, 'dead', false),
  ('dnc',               'Do not contact',          'STOP or take me off. Nothing, ever', null, 0, 'dnc', false)
on conflict (belt) do update set label = excluded.label, meaning = excluded.meaning, then_belt = excluded.then_belt,
  max_unanswered = excluded.max_unanswered, stage = excluded.stage, texts_ok = excluded.texts_ok;

insert into public.belt_steps (belt, step, who, anchor, delay_hours, fallback_hours, call_hour, other_band, template_key, say) values
  -- cold texts: WPIE's ledger owns 1-3 (mirrored here); step 4 is the daily call list
  ('cold_texts', 1, 'auto_text', 'now', 0, null, null, false, null, 'Text 1 (the opener)'),
  ('cold_texts', 2, 'auto_text', 'prev', 96, null, null, false, null, 'Text 2, day 4: no hurry, door open'),
  ('cold_texts', 3, 'auto_text', 'prev', 336, null, null, false, null, 'Text 3, day 18: the honest last text'),
  ('cold_texts', 4, 'thalia_call', 'prev', 72, null, 14, false, null, 'Never answered three texts about {street}; one call, then nothing'),
  -- 3.1 replied once, never answered the question
  ('replied_quiet', 1, 'auto_text', 'prev', 24, null, null, false, 'replied_reask', 'They replied "{said}" about {street}; re-ask simply, offer a call'),
  ('replied_quiet', 2, 'thalia_call', 'prev', 96, null, 14, false, null, 'You answered my text about {street}'),
  ('replied_quiet', 3, 'auto_text', 'prev', 432, null, null, false, 'door_open', 'We tried you the other day about {street}; happy to pick this up whenever'),
  -- 3.2 mid-qualification, then stopped
  ('questions_quiet', 1, 'draft_text', 'prev', 24, null, null, false, 'questions_call_offer', 'Their last answer: "{said}" about {street}; offer the call, no new question'),
  ('questions_quiet', 2, 'thalia_call', 'prev', 96, null, 14, false, null, 'Their last answer: "{said}" about {street}'),
  ('questions_quiet', 3, 'auto_text', 'prev', 432, null, null, false, 'door_open', 'Whenever you are ready, this number works ({street})'),
  -- 3.3 said yes, never booked
  ('yes_unbooked', 1, 'thalia_call', 'now', 0, null, null, false, null, 'You asked for a call about {street}'),
  ('yes_unbooked', 2, 'auto_text', 'prev', 1, null, null, false, 'just_tried', 'Just tried you about {street}: what time today or tomorrow works?'),
  ('yes_unbooked', 3, 'thalia_call', 'prev', 48, null, null, true, null, 'You asked for a call about {street}'),
  ('yes_unbooked', 4, 'auto_text', 'prev', 336, null, null, false, 'door_open', 'Still glad to talk about {street} whenever suits'),
  -- 3.4 booked call: reminder the morning of, then the call at the slot
  ('call_booked', 1, 'auto_text', 'slot_morning', 0, null, null, false, 'reminder_call', 'We are set to call you today around {time} about {street}; still good?'),
  ('call_booked', 2, 'owner_call', 'slot', 0, null, null, false, null, 'We have {time} set for {street}'),
  ('call_missed', 1, 'owner_call', 'prev', 0.75, null, null, false, null, 'We had {time} set aside for {street}; one more try'),
  ('call_missed', 2, 'auto_text', 'prev', 1, null, null, false, 'missed_each_other', 'Sorry we missed each other about {street}; pick a new time?'),
  ('call_missed', 3, 'owner_call', 'prev', 24, null, null, true, null, 'We had {time} set aside for {street}'),
  ('call_missed', 4, 'auto_text', 'prev', 168, null, null, false, 'door_open', 'No problem if the timing changed on {street}'),
  -- visit booked / missed: same shape, Colin
  ('visit_booked', 1, 'auto_text', 'slot_morning', 0, null, null, false, 'reminder_visit', 'We are set to come by {street} today around {time}; still good?'),
  ('visit_booked', 2, 'colin_visit', 'slot', 0, null, null, false, null, 'The visit at {street}, {time}'),
  ('visit_missed', 1, 'colin_call', 'prev', 0.75, null, null, false, null, 'We had {time} set to see {street}; one more try'),
  ('visit_missed', 2, 'auto_text', 'prev', 1, null, null, false, 'missed_each_other', 'Sorry we missed each other at {street}; pick a new time?'),
  ('visit_missed', 3, 'colin_call', 'prev', 24, null, null, true, null, 'We had {time} set to see {street}'),
  ('visit_missed', 4, 'auto_text', 'prev', 168, null, null, false, 'door_open', 'No problem if the timing changed on {street}'),
  -- 3.5 after Colin's call, nothing planted
  ('after_call_quiet', 1, 'colin_call', 'prev', 72, null, null, false, null, 'When we spoke about {street} you said "{said}"; how did that go?'),
  ('after_call_quiet', 2, 'draft_text', 'prev', 240, null, null, false, 'after_call_draft', 'You said "{said}" about {street}; offer the call, and a no is fine'),
  ('after_call_quiet', 3, 'colin_call', 'prev', 720, null, null, false, null, 'Anything changed with {street} since we talked?'),
  -- 3.6 / 3.7 after a walk or an offer: thinking it over
  ('after_visit_quiet', 1, 'colin_call', 'prev', 48, null, null, false, null, 'You were going to think {street} over; anything I can clear up?'),
  ('after_visit_quiet', 2, 'draft_text', 'prev', 4, null, null, false, 'thinking_draft', 'Thinking it over on {street}; anything to clear up, and a no is fine'),
  ('after_visit_quiet', 3, 'colin_call', 'prev', 168, null, null, false, null, 'If it is a no on {street}, that is fine, just tell me'),
  ('after_visit_quiet', 4, 'auto_text', 'prev', 720, null, null, false, 'door_open', 'No rush from me on {street}; if it is ever a fit, this number works'),
  ('offer_out', 1, 'colin_call', 'prev', 48, null, null, false, null, 'You were going to think {street} over; anything I can clear up?'),
  ('offer_out', 2, 'draft_text', 'prev', 4, null, null, false, 'thinking_draft', 'Thinking it over on {street}; anything to clear up, and a no is fine'),
  ('offer_out', 3, 'colin_call', 'prev', 168, null, null, false, null, 'If it is a no on {street}, that is fine, just tell me'),
  ('offer_out', 4, 'auto_text', 'prev', 720, null, null, false, 'door_open', 'No rush from me on {street}; if it is ever a fit, this number works'),
  -- 3.8 not now, with a date or event: permission text before, call on or after, never before
  ('not_now_dated', 1, 'auto_text', 'named', -96, null, null, false, 'predate_check', 'You mentioned {event} for {street}; still the plan, and a call after?'),
  ('not_now_dated', 2, 'colin_call', 'named', 0, null, 10, false, null, 'You mentioned {event} for {street}; how did it go?'),
  ('not_now_dated', 3, 'colin_call', 'named', 168, null, null, false, null, 'You mentioned {event} for {street}; anything changed?'),
  -- 3.9 not now, with a condition
  ('not_now_condition', 1, 'draft_text', 'prev', 720, null, null, false, 'condition_check', 'You mentioned {condition} for {street}; any movement?'),
  ('not_now_condition', 2, 'colin_call', 'prev', 2160, null, null, false, null, 'You mentioned {condition} for {street}; any movement? Not calling about the number'),
  ('not_now_condition', 3, 'auto_text', 'prev', 4320, null, null, false, 'still_here', 'Still here if {condition} ever lands for {street}'),
  -- 3.10 spouse or family must agree
  ('needs_family', 1, 'thalia_call', 'named', 24, 48, 14, false, null, 'You were going to talk with {name} about {street}; how did that land? Glad to get them on the line'),
  ('needs_family', 2, 'draft_text', 'prev', 168, null, null, false, 'family_draft', 'You were going to talk with {name} about {street}; how did that land?'),
  ('needs_family', 3, 'colin_call', 'prev', 720, null, null, false, null, 'You were going to talk with {name} about {street}; where does it stand?'),
  -- 3.11 elderly, ill or grieving: Colin only, phone only, mornings, family on the line
  ('elderly', 1, 'colin_call', 'named', 0, 168, 9, false, null, 'Exactly the day they named for {street}, family on the line, their pace'),
  ('elderly', 2, 'colin_call', 'prev', 2160, null, 9, false, null, 'Checking in as promised about {street}; family on the line, no deadlines'),
  -- 3.12 estates, letters pending: court or letters date +3, never before
  ('estate_waiting', 1, 'colin_call', 'named', 72, 720, null, false, null, 'Did the letters come through for {street}? Anything you need?'),
  ('estate_waiting', 2, 'colin_call', 'prev', 720, null, null, false, null, 'Whatever they said last about {street}: "{said}"'),
  ('estate_waiting', 3, 'colin_call', 'prev', 2160, null, null, false, null, 'Has the family made a decision on {street} yet?'),
  ('estate_waiting', 4, 'colin_call', 'prev', 4320, null, null, false, null, 'Has the family made a decision on {street} yet?'),
  ('estate_waiting', 5, 'draft_text', 'prev', 8760, null, null, false, 'estate_still_around', 'Still around if {street} ever needs to be sold; no hurry'),
  -- 3.13 hold lane, not now: the event they named +7, else +90; then +180
  ('hold_not_now', 1, 'colin_call', 'named', 168, 2160, null, false, null, 'You said {event} for {street}; did the unit turn over? Nobody has to move out for a sale'),
  ('hold_not_now', 2, 'colin_call', 'prev', 4320, null, null, false, null, 'Checking in on {street} as I said I would; any other property you would rather be rid of?'),
  -- 3.15 dormant: a quarterly draft, three times, then nothing
  ('dormant', 1, 'draft_text', 'prev', 2160, null, null, false, 'dormant_checkin', 'We spoke before about {street}; still yours, and has anything changed?'),
  ('dormant', 2, 'draft_text', 'prev', 2160, null, null, false, 'dormant_checkin', 'We spoke before about {street}; still yours, and has anything changed?'),
  ('dormant', 3, 'draft_text', 'prev', 2160, null, null, false, 'dormant_checkin', 'We spoke before about {street}; still yours, and has anything changed?')
on conflict (belt, step) do update set who = excluded.who, anchor = excluded.anchor, delay_hours = excluded.delay_hours,
  fallback_hours = excluded.fallback_hours, call_hour = excluded.call_hour, other_band = excluded.other_band,
  template_key = excluded.template_key, say = excluded.say;

-- ============================================================================ the texts
-- Colin in the first person; the street, a time or the thing they named; the STOP line; no business
-- name, no "cash", no price, offer or value. Every one is behind its own switch, default OFF: a stop
-- whose template is off becomes a draft for Colin's tap. {street} {time} {event} {condition} {name}.
create table if not exists public.touch_templates (
  key        text primary key,
  label      text not null,
  wording    text not null,
  auto       boolean not null default true,     -- false: always a draft (never sent on its own)
  enabled    boolean not null default false,
  changed_by text,
  changed_at timestamptz
);
insert into public.touch_templates (key, label, wording, auto) values
  ('replied_reask', 'Replied, went quiet: the re-ask (+1 day)',
   'Hi, Colin here again about {street}. Did not mean to leave you hanging. Would a quick call be easier than texting? If so, what time works for you? No worries if not, just reply STOP.', true),
  ('just_tried', 'Said yes: just tried you',
   'Colin here, we just tried calling you about {street}. What time today or tomorrow works, and is this the best number to reach you on? No worries if not, just reply STOP.', true),
  ('missed_each_other', 'Missed call or visit: pick a new time',
   'Colin here. Sorry we missed each other about {street}. Want to pick a new time? Reply with a day and time that suits you. No worries if not, just reply STOP.', true),
  ('reminder_call', 'Morning-of reminder for a booked call',
   'Colin here. We are set to call you today around {time} about {street}. Still good? Reply yes if that works, or send a better time. Reply STOP to opt out.', true),
  ('reminder_visit', 'Morning-of reminder for a booked visit',
   'Colin here. We are set to come by {street} today around {time}. Still good? Reply yes if that works, or send a better time. Reply STOP to opt out.', true),
  ('predate_check', 'Not now, with a date: the permission check 3-5 days before',
   'Colin here. You mentioned {event} for {street}. Is that still the plan, and would you like a call after? No worries if not, just reply STOP.', true),
  ('door_open', 'The door-left-open close (+7 / +14 / +18 / +30)',
   'Colin here. We tried you the other day about {street}. Happy to pick this up whenever suits; just reply here or call this number. No worries if not, just reply STOP.', true),
  ('still_here', 'Not now, with a condition: still here (+180)',
   'Colin here. Still around if {condition} ever lands for {street}; no hurry at all on my end. No worries if not, just reply STOP.', true),
  ('dormant_checkin', 'Dormant: the quarterly check-in (draft, Colin taps)',
   'Hi, Colin Merrill here. We spoke a while back about {street}. Is it still yours, and has anything changed? No hurry on my end. No worries if not, just reply STOP.', false),
  ('questions_call_offer', 'Mid-questions, quiet: the call offer (draft)',
   'Colin here, thanks for the details on {street}. I can just call you if that is easier; what time suits? No worries if not, just reply STOP.', false),
  ('after_call_draft', 'After the call, quiet: their words and a no is fine (draft)',
   'Colin here. When we spoke about {street} you mentioned {said}. How did that go? Happy to call again whenever suits, and if it is a no, that is completely fine, just say so. Reply STOP to opt out.', false),
  ('thinking_draft', 'Thinking it over (draft)',
   'Colin here, following up on {street}. Anything I can clear up while you think it over? And if it is a no, that is fine, just tell me. Reply STOP to opt out.', false),
  ('condition_check', 'Not now, with a condition: +30 (draft)',
   'Colin here, about {street}. You mentioned {condition}; any movement on that? No rush at all. No worries if not, just reply STOP.', false),
  ('family_draft', 'Needs family: +7 (draft)',
   'Colin here, about {street}. You were going to talk with {name}; how did that land? Glad to get them on a call with us whenever suits. No worries if not, just reply STOP.', false),
  ('estate_still_around', 'Estate: still around (+365, draft)',
   'Colin here, about the house at {street}. I am still around if it ever needs to be sold; no hurry at all. No worries if not, just reply STOP.', false)
on conflict (key) do update set label = excluded.label, wording = excluded.wording, auto = excluded.auto;

-- Colin's switch per template (owner only).
create or replace function public.set_touch_template(p_key text, p_on boolean)
returns void language plpgsql security definer set search_path = public as $$
declare who text;
begin
  if not public.is_owner() then raise exception 'only Colin (owner) can switch a text on or off'; end if;
  select display_name into who from public.team_members where lower(email) = lower(auth.jwt() ->> 'email');
  update public.touch_templates set enabled = p_on, changed_by = who, changed_at = now() where key = p_key;
  if not found then raise exception 'no such template %', p_key; end if;
end $$;
revoke all on function public.set_touch_template(text, boolean) from public, anon;
grant execute on function public.set_touch_template(text, boolean) to authenticated;

-- ============================================================================ health
create table if not exists public.belt_health (
  id       bigint generated always as identity primary key,
  at       timestamptz not null default now(),
  kind     text not null default 'run' check (kind in ('run', 'canary')),
  ok       boolean not null,
  checks   jsonb not null default '{}'::jsonb,
  summary  text
);
create index if not exists belt_health_at_idx on public.belt_health (kind, at desc);
create table if not exists public.belt_alerts_sent (
  key  text not null,
  day  date not null,
  primary key (key, day)
);
alter table public.campaign_control add column if not exists belt_canary_date date;
alter table public.campaign_control add column if not exists belt_last_run_at timestamptz;

-- ============================================================================ reply_drafts carries belt texts
alter table public.reply_drafts drop constraint if exists reply_drafts_kind_check;
alter table public.reply_drafts add constraint reply_drafts_kind_check
  check (kind in ('removal', 'routine', 'candidate', 'after_close', 'belt'));
alter table public.reply_drafts add column if not exists belt_stop_key text;
create unique index if not exists reply_drafts_belt_stop_idx on public.reply_drafts (belt_stop_key) where belt_stop_key is not null;

-- ============================================================================ access
alter table public.belt_events        enable row level security;
alter table public.belt_direct_writes enable row level security;
alter table public.belt_steps         enable row level security;
alter table public.belt_rules         enable row level security;
alter table public.touch_templates    enable row level security;
alter table public.belt_health        enable row level security;
alter table public.belt_alerts_sent   enable row level security;
grant select on public.belt_events, public.belt_direct_writes, public.belt_steps, public.belt_rules,
                public.touch_templates, public.belt_health to authenticated;
grant select, insert, update, delete on public.belt_events, public.belt_direct_writes, public.belt_steps, public.belt_rules,
                public.touch_templates, public.belt_health, public.belt_alerts_sent to service_role;
grant usage, select on all sequences in schema public to service_role;
create policy belt_events_read on public.belt_events for select to authenticated using (public.is_team());
create policy belt_direct_writes_read on public.belt_direct_writes for select to authenticated using (public.is_team());
create policy belt_steps_read on public.belt_steps for select to authenticated using (public.is_team());
create policy belt_rules_read on public.belt_rules for select to authenticated using (public.is_team());
create policy touch_templates_read on public.touch_templates for select to authenticated using (public.is_team());
create policy belt_health_read on public.belt_health for select to authenticated using (public.is_team());
