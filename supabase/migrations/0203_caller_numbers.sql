-- 0203: each caller's own number (Colin 2026-11-07: "Switch Tyler and Thalia's sms and outbound calls to another number
-- ... Two new numbers, I think what they're calling from is burned"). Bought the same night: Tyler (adil)
-- +1 262 384 6865, Thalia +1 262 429 9057, both West Bend. The automated first texts keep the pool; a text a caller
-- types on a card and a call they place from the app go out from their own number, and a seller who calls or texts
-- that number back reaches that caller (pm-phone reads this table through caller_numbers()).

create table if not exists public.caller_numbers (
  person public.team_person primary key,
  number text not null unique check (number ~ '^\+1[0-9]{10}$'),
  label text,
  created_at timestamptz not null default now()
);
alter table public.caller_numbers enable row level security;
drop policy if exists caller_numbers_team_read on public.caller_numbers;
create policy caller_numbers_team_read on public.caller_numbers for select to authenticated using (public.is_team());
grant select on public.caller_numbers to authenticated;

insert into public.caller_numbers (person, number, label) values
  ('adil', '+12623846865', 'Tyler''s line (West Bend)'),
  ('thalia', '+12624299057', 'Thalia''s line (West Bend)')
on conflict (person) do update set number = excluded.number, label = excluded.label;

create or replace function public.caller_numbers() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('person', c.person::text, 'number', c.number, 'label', c.label) order by c.person), '[]'::jsonb)
    from public.caller_numbers c
$$;
revoke all on function public.caller_numbers() from public, anon;
grant execute on function public.caller_numbers() to authenticated, service_role;

-- a text typed on the card goes from the caller's own number when they have one (0054 otherwise unchanged)
create or replace function public.start_card_text(p_lead_id uuid, p_phone text)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  l public.leads;
  p text := right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 10);
  ours text;
  id uuid;
  me public.team_person := public.wpie_person();
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
  -- the caller's own line first (0203); else our side of the latest text with this phone; else the latest number we texted the card from
  select c.number into ours from public.caller_numbers c where c.person = me;
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
  if ours is null then raise exception 'we have never texted this card: no number to text from yet'; end if;
  insert into public.reply_drafts (phone10, our_number, lead_id, inbound_at, intent, kind, outcome, note, draft_source, status, notified_at)
  values (p, ours, p_lead_id, now(), 'team_text', 'team', 'open', 'typed on the card by ' || coalesce(me::text, 'team'),
          'team', 'awaiting_approval', now())
  returning reply_drafts.id into id;
  return id;
end $$;
