-- 0325: a card has a number, and every call to it goes out from that number.
--
-- Colin 2026-11-25, after his own phone showed Thalia's line (262-429-9057) and the main seller line (262-418-0202)
-- as spam and sent them to voicemail without ringing: "I don't want Tyler and thalia to have one number to dial
-- from, they should have a number assigned to the card and the system should have the logic to call from that
-- number, that means if they do a power hour they'll call from a bunch of different numbers". And of the two flagged
-- numbers: "Ditch that number and 0202".
--
-- Since 2026-11-07 (0203) every call a caller placed showed the caller's own line: all of Thalia's dialing, about 60
-- calls a day, on one number. Texts already go out evenly across the pool. Now:
--   call_lines        the numbers we dial from. A number with dial = false is never shown on an outgoing call.
--   leads.call_line   the card's number.
--   card_call_line()  the number to call this card from: the number that texted this phone (the seller sees the
--                     number they know), else the card's kept number, else one picked from the pool by the card and
--                     kept. A number that is no longer dialed from is passed over and the card gets another.
-- The phone server (pm-phone clientDial) asks card_call_line for every call and no longer uses the caller's own line.
-- A seller who calls a pool number back still reaches the card's caller (inbound_call_ring goes by the card).
-- A text a caller types on a card follows the same rule (start_card_text, below).
--
-- The two flagged numbers are kept, with dial = false: sellers we already called and texted from them can still
-- call and text back. Releasing them is Colin's to confirm; it cannot be undone.

create table if not exists public.call_lines (
  number      text primary key check (number ~ '^\+1[0-9]{10}$'),
  dial        boolean not null default true,
  note        text,
  updated_at  timestamptz not null default now()
);
alter table public.call_lines enable row level security;
grant select on public.call_lines to authenticated, service_role;
drop policy if exists call_lines_team_read on public.call_lines;
create policy call_lines_team_read on public.call_lines for select to authenticated using (public.is_team());

insert into public.call_lines (number, dial, note) values
  ('+12629996513', true, null), ('+12624767158', true, null), ('+12623812196', true, null), ('+12626675223', true, null),
  ('+14144200081', true, null), ('+14144200843', true, null), ('+14146778472', true, null),
  ('+12624180202', false, 'Shows as spam on Colin''s phone and does not ring (2026-11-25). Still takes calls and texts back.'),
  ('+12624299057', false, 'Thalia''s old line: about 60 dials a day from it; shows as spam on Colin''s phone (2026-11-25). Still takes calls and texts back.'),
  ('+12623846865', false, 'Tyler''s old line. A call back to it rings Tyler alone, so it is not a card''s number.')
on conflict (number) do nothing;

alter table public.leads add column if not exists call_line text;

create or replace function public.card_call_line(p_lead_id uuid, p_phone text default null) returns text
language plpgsql security definer set search_path = public as $fn$
declare cur text; pick text; n int; d text := right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 10);
begin
  select l.call_line into cur from public.leads l where l.id = p_lead_id;
  if not found then return null; end if;
  -- the number that texted this phone, when we still dial from it
  if d ~ '^[0-9]{10}$' then
    select c.number into pick from public.call_lines c where c.dial and c.number = public.sender_for_phone(d);
  end if;
  -- else the number the card was last texted from
  if pick is null then
    select m.from_number into pick from public.messages m join public.call_lines c on c.number = m.from_number and c.dial
     where m.lead_id = p_lead_id and m.channel = 'sms' and m.direction = 'out' and m.provider_sid is not null
     order by m.sent_at desc limit 1;
  end if;
  -- else the card's own kept number, else one from the pool, by the card
  if pick is null and cur is not null and exists (select 1 from public.call_lines c where c.dial and c.number = cur) then pick := cur; end if;
  if pick is null then
    select count(*) into n from public.call_lines c where c.dial;
    if n = 0 then return null; end if;
    select c.number into pick from public.call_lines c where c.dial order by c.number
     offset ((hashtext(p_lead_id::text)::bigint & 2147483647) % n) limit 1;
  end if;
  if pick is distinct from cur then
    -- kept on the card; a card another write is holding is left for the next call rather than making this one wait
    begin
      perform set_config('lock_timeout', '1200ms', true);
      update public.leads set call_line = pick where id = p_lead_id;
    exception when lock_not_available then null;
    end;
  end if;
  return pick;
end $fn$;
revoke all on function public.card_call_line(uuid, text) from public, anon, authenticated;
grant execute on function public.card_call_line(uuid, text) to service_role;

-- a text typed on a card goes from the card's number
CREATE OR REPLACE FUNCTION public.start_card_text(p_lead_id uuid, p_phone text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  l public.leads;
  p text := right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 10);
  ours text;
  id uuid;
  nope text;
begin
  if not public.is_team() then raise exception 'not on the team'; end if;
  select * into l from public.leads where leads.id = p_lead_id;
  if not found then raise exception 'no such card'; end if;
  if l.stage = 'dnc' then raise exception 'this card is closed (do not contact)'; end if;
  -- 0249: a card is its caller's. George White, 2026-11-17: Tyler texted Thalia's seller from his own line.
  nope := public.card_not_yours(p_lead_id, now());
  if nope is not null then raise exception '%', nope; end if;
  if p !~ '^[2-9][0-9]{9}$' then raise exception 'not a phone number'; end if;
  if not exists (select 1 from public.contacts c where c.lead_id = p_lead_id and c.kind = 'phone'
                  and right(regexp_replace(coalesce(c.value_normalized, c.value), '\D', '', 'g'), 10) = p
                  and not coalesce(c.dnc_app, false) and c.status is distinct from 'bad') then
    raise exception 'that phone is not on this card';
  end if;
  if exists (select 1 from public.suppressed_phones s where s.phone10 = p) then raise exception 'this phone opted out'; end if;
  -- 0325: the card's number, not the caller's. Our side of the latest text with this phone, else the latest number we
  -- texted the card from, else the number the card is called from (card_call_line). Before, a caller's typed text went
  -- from their own line (0203), so a seller in a thread on one number got the next text from another.
  if ours is null then
    select case when m.direction = 'out' then m.from_number else m.to_number end into ours
      from public.messages m
     where m.lead_id = p_lead_id and m.channel = 'sms'
       and right(regexp_replace(coalesce(case when m.direction = 'out' then m.to_number else m.from_number end, ''), '\D', '', 'g'), 10) = p
     order by m.sent_at desc limit 1;
  end if;
  if ours is null then
    select m.from_number into ours from public.messages m
     where m.lead_id = p_lead_id and m.channel = 'sms' and m.direction = 'out' and m.from_number is not null
     order by m.sent_at desc limit 1;
  end if;
  if ours is null then ours := public.card_call_line(p_lead_id, p); end if;
  if ours is null then raise exception 'we have never texted this card: no number to text from yet'; end if;
  insert into public.reply_drafts (phone10, our_number, lead_id, inbound_at, intent, kind, outcome, note, draft_source, status, notified_at)
  values (p, ours, p_lead_id, now(), 'team_text', 'team', 'open', 'typed on the card by ' || coalesce(public.wpie_person()::text, 'team'),
          'team', 'awaiting_approval', now())
  returning reply_drafts.id into id;
  return id;
end $function$;
