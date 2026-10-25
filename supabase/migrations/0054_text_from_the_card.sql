-- A text typed on the card (Adil 2026-10-24: "unable to figure out where to send the text from"). Until now a person
-- could only send a reply the agent had drafted. start_card_text makes a one-off draft of kind 'team' on the card's
-- phone, from the number that texted them; reply-send then sends it through the same gate as an approved reply
-- (wording check, opted-out phones, quiet hours, live switch). A team text is not something they said: it never
-- moves the card as an inbound text. Once sent it counts as a person texting in the thread (the pending automatic
-- text is off, the same as the laptop's human_text).

alter table public.reply_drafts drop constraint if exists reply_drafts_kind_check;
alter table public.reply_drafts add constraint reply_drafts_kind_check
  check (kind = any (array['removal', 'routine', 'candidate', 'after_close', 'belt', 'team']));

create or replace function public.start_card_text(p_lead_id uuid, p_phone text)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  l public.leads;
  p text := right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 10);
  ours text;
  id uuid;
begin
  if not public.is_team() then raise exception 'not on the team'; end if;
  select * into l from public.leads where leads.id = p_lead_id;
  if not found then raise exception 'no such card'; end if;
  if l.stage = 'dnc' then raise exception 'this card is closed (do not contact)'; end if;
  if p !~ '^[2-9][0-9]{9}$' then raise exception 'not a phone number'; end if;
  if not exists (select 1 from public.contacts c where c.lead_id = p_lead_id and c.kind = 'phone'
                  and right(regexp_replace(coalesce(c.value_normalized, c.value), '\D', '', 'g'), 10) = p
                  and not coalesce(c.dnc_app, false) and coalesce(c.status, '') <> 'bad') then
    raise exception 'that phone is not on this card';
  end if;
  if exists (select 1 from public.suppressed_phones s where s.phone10 = p) then raise exception 'this phone opted out'; end if;
  -- our side of the latest text with this phone, else the latest number we texted the card from
  select case when m.direction = 'out' then m.from_number else m.to_number end into ours
    from public.messages m
   where m.lead_id = p_lead_id and m.channel = 'sms'
     and right(regexp_replace(coalesce(case when m.direction = 'out' then m.to_number else m.from_number end, ''), '\D', '', 'g'), 10) = p
   order by m.sent_at desc limit 1;
  if ours is null then
    select m.from_number into ours from public.messages m
     where m.lead_id = p_lead_id and m.channel = 'sms' and m.direction = 'out' and m.from_number is not null
     order by m.sent_at desc limit 1;
  end if;
  if ours is null then raise exception 'we have never texted this card: no number to text from yet'; end if;
  insert into public.reply_drafts (phone10, our_number, lead_id, inbound_at, intent, kind, outcome, note, draft_source, status, notified_at)
  values (p, ours, p_lead_id, now(), 'team_text', 'team', 'open', 'typed on the card by ' || coalesce(public.wpie_person()::text, 'team'),
          'team', 'awaiting_approval', now())
  returning reply_drafts.id into id;
  return id;
end $$;
revoke all on function public.start_card_text(uuid, text) from public, anon;
grant execute on function public.start_card_text(uuid, text) to authenticated;

-- a team text is not an inbound text
create or replace function public.belt_on_reply_draft() returns trigger
language plpgsql security definer set search_path = public as $$
declare pl jsonb;
begin
  if new.lead_id is null or new.kind in ('belt', 'team') or new.is_test then return new; end if;
  pl := jsonb_build_object('key', 'draft:' || new.id::text, 'intent', new.intent, 'kind', new.kind, 'outcome', new.outcome,
          'removal', new.kind = 'removal', 'said', left(coalesce(new.inbound_body, ''), 300), 'at', new.inbound_at,
          'facts', coalesce(new.facts, '{}'::jsonb), 'callback_slot', new.facts->>'callback_slot', 'reply', left(coalesce(new.body, ''), 300));
  perform public.belt_event(new.lead_id, 'inbound_text', pl, 'reply agent', coalesce(new.created_at, now()));
  return new;
end $$;

-- a sent team text: a person texted in the thread
create or replace function public.belt_on_team_text() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.kind <> 'team' or new.lead_id is null or new.is_test or new.status is not distinct from old.status or new.status <> 'sent' then return new; end if;
  perform public.belt_event(new.lead_id, 'human_text', jsonb_build_object('key', 'team_text:' || new.id::text, 'draft_id', new.id),
    coalesce(new.decided_by, 'team'), now());
  return new;
end $$;
drop trigger if exists belt_on_team_text on public.reply_drafts;
create trigger belt_on_team_text after update of status on public.reply_drafts
  for each row execute function public.belt_on_team_text();
