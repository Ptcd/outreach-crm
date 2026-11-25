-- 0319: the voicemail drop. One tap at the beep leaves a recorded message with the seller's name and street, and the
-- caller is free for the next card.
--
-- Thalia 2026-11-24, forwarded by Colin ("Great idea", "Can you ship this"): "could we have an automated voicemail
-- drop where I just click a button and it leaves a pre-recorded message, including the customer's address pulled from
-- their lead info? I'd also like to keep the option to leave a personal voicemail ... This way, I can save time and
-- move on to the next lead faster".
--
-- How it works: the app's call-voicemail function asks voicemail_drop_check (below) whether this number may get one
-- and for the words, then pm-phone (/api/voicemail/drop, lib/voicemailDrop) hands the seller's leg of the live call
-- the message and ends the caller's leg. The caller still leaves a personal voicemail the old way: by talking.
--
-- WHO MAY GET ONE (voicemail_drop_rules.mode). A recorded or computer voice left on a cell phone is the one kind of
-- call federal law (47 U.S.C. 227(b)(1)(A)(iii)) forbids without the called party's consent whatever the call is
-- about, at $500 to $1,500 a message, and a voicemail left this way counts. So as shipped the mode is 'engaged': only
-- a number that called us, or that wrote back interested, gets the recorded message; a cold number still gets the
-- caller's own voice. 'all' opens it to every number and is Colin's decision, not a default. 'off' removes the button.
-- The message says it is recorded, who it is from and the number to call back, which the same rules ask for.

create table if not exists public.voicemail_drop_rules (
  id              int primary key default 1 check (id = 1),
  mode            text not null default 'engaged' check (mode in ('off', 'engaged', 'all')),
  -- {hi} "Hi Olivia," or "Hi,"; {caller} the caller's name; {place} "the place on Tuckaway Shores Drive" or
  -- "your property"; {number} the line they were called from (filled in by the phone server)
  words           text not null default '{hi} this is a recorded message from {caller}, with Colin Merrill''s team. I had a quick question about {place}. You can call or text me back at {number}. Again, that''s {number}. Thanks, and have a good day.',
  voices          jsonb not null default '{"thalia": "Polly.Joanna-Neural", "adil": "Polly.Matthew-Neural", "colin": "Polly.Matthew-Neural"}'::jsonb,
  engaged_days    int not null default 90,     -- how far back a call or an interested text from the number counts
  per_number_days int not null default 3,      -- one recorded message per number in this many days
  updated_at      timestamptz not null default now()
);
insert into public.voicemail_drop_rules (id) values (1) on conflict (id) do nothing;
alter table public.voicemail_drop_rules enable row level security;
grant select on public.voicemail_drop_rules to authenticated, service_role;
drop policy if exists voicemail_drop_rules_team_read on public.voicemail_drop_rules;
create policy voicemail_drop_rules_team_read on public.voicemail_drop_rules for select to authenticated using (public.is_team());

-- every recorded message left: who, on which card, to which number, the words
create table if not exists public.voicemail_drops (
  id        bigint generated always as identity primary key,
  lead_id   uuid not null references public.leads(id) on delete cascade,
  phone10   text not null,
  person    text not null,
  call_sid  text unique,
  said      text,
  at        timestamptz not null default now()
);
create index if not exists voicemail_drops_phone on public.voicemail_drops (phone10, at desc);
create index if not exists voicemail_drops_lead on public.voicemail_drops (lead_id, at desc);
alter table public.voicemail_drops enable row level security;
grant select on public.voicemail_drops to authenticated, service_role;
drop policy if exists voicemail_drops_read on public.voicemail_drops;
-- a card has one owner: a caller reads only their own cards' rows (0250)
create policy voicemail_drops_read on public.voicemail_drops for select to authenticated
  using (public.is_team() and exists (select 1 from public.leads l where l.id = voicemail_drops.lead_id));

-- a street the way a person says it: "S Tuckaway Shores Drv" -> "South Tuckaway Shores Drive"
create or replace function public.speech_street(p_address text) returns text
language plpgsql immutable as $fn$
declare s text := public.text_street_name(p_address); ab text[]; i int;
begin
  if s is null then return null; end if;
  s := regexp_replace(s, '^St\.? ', 'Saint ', 'i');
  s := regexp_replace(s, '^Dr\.? ', 'Doctor ', 'i');
  s := regexp_replace(s, '^N\.? ', 'North ');  s := regexp_replace(s, '^S\.? ', 'South ');
  s := regexp_replace(s, '^E\.? ', 'East ');   s := regexp_replace(s, '^W\.? ', 'West ');
  s := regexp_replace(s, ' N\.?$', ' North');  s := regexp_replace(s, ' S\.?$', ' South');
  s := regexp_replace(s, ' E\.?$', ' East');   s := regexp_replace(s, ' W\.?$', ' West');
  ab := array['St', 'Street', 'Ave', 'Avenue', 'Av', 'Avenue', 'Rd', 'Road', 'Dr', 'Drive', 'Drv', 'Drive', 'Ln', 'Lane', 'Ct', 'Court',
              'Blvd', 'Boulevard', 'Pl', 'Place', 'Pkwy', 'Parkway', 'Pky', 'Parkway', 'Ter', 'Terrace', 'Terr', 'Terrace', 'Cir', 'Circle',
              'Hwy', 'Highway', 'Trl', 'Trail', 'Sq', 'Square', 'Xing', 'Crossing', 'Hts', 'Heights', 'Cv', 'Cove', 'Pt', 'Point'];
  for i in 1 .. array_length(ab, 1) by 2 loop
    s := regexp_replace(s, '\m' || ab[i] || '\M\.?', ab[i + 1], 'gi');
  end loop;
  return s;
end $fn$;

-- May this caller leave the recorded message on this number of this card, and what does it say?
create or replace function public.voicemail_drop_check(p_lead_id uuid, p_phone text) returns jsonb
language plpgsql stable security definer set search_path = public as $fn$
declare me text; me_name text; r public.voicemail_drop_rules; l public.leads; c public.contacts;
  d text := right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 10);
  blocked jsonb; engaged boolean; last_drop timestamptz; first text; street text; hi text; place text; say text;
begin
  perform public.card_guard(p_lead_id);
  if not public.is_team() then raise exception 'team only'; end if;
  select person::text, display_name into me, me_name from public.team_members where lower(email) = lower(auth.jwt() ->> 'email');
  if me is null then raise exception 'not on the team'; end if;
  select * into r from public.voicemail_drop_rules where id = 1;
  if not found or r.mode = 'off' then return jsonb_build_object('ok', false, 'code', 'off', 'reason', 'The recorded voicemail is switched off.'); end if;
  if d !~ '^[2-9][0-9]{9}$' then return jsonb_build_object('ok', false, 'code', 'number', 'reason', 'No number on this call.'); end if;
  select * into l from public.leads where id = p_lead_id;
  if not found then return jsonb_build_object('ok', false, 'code', 'card', 'reason', 'No such card.'); end if;
  if l.stage::text in ('dnc', 'dead') or coalesce(l.belt, '') in ('dnc', 'dead') then
    return jsonb_build_object('ok', false, 'code', 'closed', 'reason', 'This card is closed.');
  end if;
  select * into c from public.contacts where lead_id = p_lead_id and kind = 'phone' and value_normalized = d order by created_at limit 1;
  if not found then return jsonb_build_object('ok', false, 'code', 'number', 'reason', 'That number is not on this card.'); end if;
  blocked := public.phone_is_blocked(d);
  if coalesce((blocked->>'blocked')::boolean, false) or c.suppressed or c.dnc_app or public.phone_person_block(d) is not null then
    return jsonb_build_object('ok', false, 'code', 'blocked', 'reason', 'This number is do-not-contact.');
  end if;
  -- they called us, or wrote back interested, from this number
  engaged := exists (select 1 from public.inbound_calls i where i.from10 = d and i.status <> 'blocked'
                        and i.created_at > now() - make_interval(days => r.engaged_days))
          or exists (select 1 from public.reply_drafts x where x.phone10 = d and not coalesce(x.is_test, false)
                        and x.intent = any (public.warm_intents()) and x.inbound_at > now() - make_interval(days => r.engaged_days));
  if r.mode = 'engaged' and not engaged then
    return jsonb_build_object('ok', false, 'code', 'cold', 'reason', 'They have not called or written back from this number: leave this one in your own voice.');
  end if;
  select max(v.at) into last_drop from public.voicemail_drops v where v.phone10 = d and v.at > now() - make_interval(days => r.per_number_days);
  if last_drop is not null then
    return jsonb_build_object('ok', false, 'code', 'recent', 'reason', 'This number got the recorded message on '
      || to_char(last_drop at time zone 'America/Chicago', 'Dy Mon DD') || ': leave your own this time, or none.');
  end if;
  -- an estate card is never greeted by name: the name on it may be the person who died (0289)
  first := case when public.card_is_estate(p_lead_id) then 'there'
                else public.text_first_name(coalesce((select pe.name from public.people pe where pe.id = c.person_id and pe.kind = 'person'),
                                                     nullif(c.person_name, ''), l.owner_name)) end;
  hi := case when coalesce(first, 'there') = 'there' then 'Hi,' else 'Hi ' || first || ',' end;
  street := public.speech_street(l.property_address);
  place := case when street is null then 'your property' else 'the place on ' || street end;
  say := replace(replace(replace(r.words, '{hi}', hi), '{caller}', coalesce(nullif(me_name, ''), initcap(me))), '{place}', place);
  return jsonb_build_object('ok', true, 'person', me, 'say', say, 'voice', coalesce(r.voices->>me, 'Polly.Joanna-Neural'), 'engaged', engaged);
end $fn$;

-- the message was left: keep the row (the per-number spacing reads it)
create or replace function public.voicemail_drop_done(p_lead_id uuid, p_phone text, p_call_sid text, p_said text) returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare me text; d text := right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 10);
begin
  perform public.card_guard(p_lead_id);
  if not public.is_team() then raise exception 'team only'; end if;
  select person::text into me from public.team_members where lower(email) = lower(auth.jwt() ->> 'email');
  if me is null then raise exception 'not on the team'; end if;
  if d !~ '^[0-9]{10}$' or coalesce(p_call_sid, '') !~ '^CA[0-9A-Fa-f]{32}$' then return jsonb_build_object('ok', false); end if;
  insert into public.voicemail_drops (lead_id, phone10, person, call_sid, said) values (p_lead_id, d, me, p_call_sid, left(p_said, 800))
  on conflict (call_sid) do nothing;
  return jsonb_build_object('ok', true);
end $fn$;

revoke all on function public.voicemail_drop_check(uuid, text), public.voicemail_drop_done(uuid, text, text, text) from public, anon;
grant execute on function public.voicemail_drop_check(uuid, text), public.voicemail_drop_done(uuid, text, text, text) to authenticated, service_role;
