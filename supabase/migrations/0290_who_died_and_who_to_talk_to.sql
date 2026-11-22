-- 0290: who died and who to talk to, on the probate cards. Colin 2026-11-22: "You could look up obits". About 580 open
-- cards carry a probate case and the name of its subject in their research note, and say nothing about who is alive:
-- the card is in the dead owner's name, 113 of them were texted "Hi <that name>", and only 192 estate cards have a
-- personal representative or an heir on them. The obituaries the weekly funeral-home run already holds match 15 of
-- them by name, so this is a lookup an agent does card by card: the obituary (who died, when, who survives), checked
-- against the card, then the people put on the card with the tools that already exist (add_prospects, interests).
--
--   * estate_people_wanted: the list, built from the cards themselves; a card leaves it when someone on it is marked
--     deceased or a spouse, an heir or a representative is on it.
--   * estate_people (door): claim a batch with the method; estate_people_done: say what was found, with the source.
--     "found" is refused until the card itself shows it (someone marked deceased, or a living person added).
--   * Nobody is marked deceased here, and nobody is contacted: the agent marks a person only on a confirmed match.

create table if not exists public.estate_people_wanted (
  lead_id       uuid primary key references public.leads (id) on delete cascade,
  subject       text not null,                 -- the probate's subject, as the card's research note prints it
  probate_case  text,
  listed_at     timestamptz not null default now(),
  claimed_by    text,
  claimed_at    timestamptz,
  done_at       timestamptz,
  done_by       text,
  outcome       text check (outcome in ('found', 'not_found', 'not_the_owner', 'unsure')),
  source        text,
  note          text
);
alter table public.estate_people_wanted enable row level security;

create or replace function public.estate_people_build() returns integer
language plpgsql security definer set search_path = public as $fn$
declare n integer;
begin
  insert into public.estate_people_wanted (lead_id, subject, probate_case)
  select distinct on (l.id) l.id, left(btrim(m[1]), 120), (regexp_match(part, '([0-9]{4}PR[0-9]+)'))[1]
    from public.leads l, lateral unnest(string_to_array(l.notes, ' | ')) part,
         lateral regexp_matches(part, 'Court subject[^:\n]*:\s*([^\n]+)', 'g') m
   where not public.card_is_closed(l.stage) and l.notes ~* 'Court subject'
     and part ~* '[0-9]{4}PR[0-9]+' and part !~* '[0-9]{4}(CV|SC|FA|TW)[0-9]+'
     and not exists (select 1 from public.interests i where i.lead_id = l.id
                      and (i.status = 'deceased' or i.role in ('personal_representative', 'special_administrator', 'heir', 'spouse')))
  on conflict (lead_id) do nothing;
  get diagnostics n = row_count;
  return n;
end $fn$;
revoke all on function public.estate_people_build() from public, anon, authenticated;
grant execute on function public.estate_people_build() to service_role;

create or replace function public.agent_estate_people(p_agent text, p_count integer default 15) returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare cards jsonb; left_n integer; me text := coalesce(nullif(btrim(p_agent), ''), 'agent');
begin
  perform public.estate_people_build();
  with pick as (
    select w.lead_id
      from public.estate_people_wanted w join public.leads l on l.id = w.lead_id
     where w.done_at is null and not public.card_is_closed(l.stage)
       and (w.claimed_by is null or lower(w.claimed_by) = lower(me) or w.claimed_at < now() - interval '3 hours')
     order by (exists (select 1 from public.messages m where m.lead_id = w.lead_id and m.direction = 'out' and m.channel = 'sms')) desc, w.listed_at
     limit least(greatest(coalesce(p_count, 15), 1), 50)
       for update of w skip locked
  ), took as (
    update public.estate_people_wanted w set claimed_by = me, claimed_at = now()
      from pick where pick.lead_id = w.lead_id returning w.lead_id, w.subject, w.probate_case
  )
  select coalesce(jsonb_agg(jsonb_build_object('lead_id', t.lead_id, 'address', l.property_address, 'town', l.municipality, 'county', l.county,
           'owner_on_record', l.owner_name, 'probate_subject', t.subject, 'probate_case', t.probate_case,
           'caller', public.room_name(public.card_caller(t.lead_id)::text),
           'texts_sent', (select count(*) from public.messages m where m.lead_id = t.lead_id and m.direction = 'out' and m.channel = 'sms'),
           'people_on_card', (select coalesce(jsonb_agg(jsonb_build_object('interest_id', i.id, 'name', p.name, 'role', i.role, 'status', i.status)), '[]'::jsonb)
                                from public.interests i join public.people p on p.id = i.person_id where i.lead_id = t.lead_id))), '[]'::jsonb)
    into cards from took t join public.leads l on l.id = t.lead_id;
  select count(*) into left_n from public.estate_people_wanted w join public.leads l on l.id = w.lead_id where w.done_at is null and not public.card_is_closed(l.stage);
  return jsonb_build_object('left', left_n, 'cards', cards, 'how',
    'Each card is in the name of someone a probate case names: find out who died and who to talk to. '
    || '1) Find the obituary: the name, the town and Wisconsin; the funeral home''s page or the newspaper; the case number''s year is when probate was opened. '
    || '2) Confirm it is the same person before anything else: the town or street, the age, a relative''s name that is on the card. A name alone is not a match (a probate for "Steven Hall" sat on a card owned by "Shawn Steven Hall"). '
    || '3) Read who survives: spouse, children, and the personal representative if the court record names one. '
    || '4) Put it on the card with add_prospects: the card''s own address, and interests[]: the person who died with status deceased and status_reason = the date of death and the obituary link (use the interest already on the card: same name); each survivor or the representative with role spouse | heir | personal_representative and their town; phones only if you traced them. '
    || '5) estate_people_done {lead_id, outcome: found | not_found | not_the_owner | unsure, source, note}. unsure, with what you saw, is a good answer. '
    || 'Never contact anyone. Never mark someone deceased on a name alone.');
end $fn$;
revoke all on function public.agent_estate_people(text, integer) from public, anon, authenticated;
grant execute on function public.agent_estate_people(text, integer) to service_role;

create or replace function public.agent_estate_people_done(p jsonb, p_agent text) returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare lid uuid; w public.estate_people_wanted; o text := lower(btrim(coalesce(p->>'outcome', '')));
        src text := nullif(btrim(coalesce(p->>'source', '')), ''); nt text := nullif(btrim(coalesce(p->>'note', '')), '');
begin
  begin lid := nullif(p->>'lead_id', '')::uuid; exception when others then lid := null; end;
  if lid is null then return jsonb_build_object('ok', false, 'reason', 'lead_id is the card'); end if;
  select * into w from public.estate_people_wanted where lead_id = lid;
  if not found then return jsonb_build_object('ok', false, 'reason', 'this card is not on the list (estate_people gives you the list)'); end if;
  if o not in ('found', 'not_found', 'not_the_owner', 'unsure') then
    return jsonb_build_object('ok', false, 'reason', 'outcome is found | not_found | not_the_owner (the probate is someone else''s, not this owner) | unsure');
  end if;
  if o in ('found', 'not_the_owner') and src is null then
    return jsonb_build_object('ok', false, 'reason', 'source: where you read it (the obituary link, the court record)');
  end if;
  if o in ('not_found', 'unsure') and coalesce(length(nt), 0) < 20 then
    return jsonb_build_object('ok', false, 'reason', 'note: where you looked and what you saw, in a sentence');
  end if;
  if o = 'found' and not exists (select 1 from public.interests i where i.lead_id = lid
        and (i.status = 'deceased' or i.role in ('personal_representative', 'special_administrator', 'heir', 'spouse'))) then
    return jsonb_build_object('ok', false, 'reason', 'the card does not show it yet: add_prospects first (the card''s address, interests[] with the person who died as status deceased, and who survives), then this');
  end if;
  update public.estate_people_wanted set done_at = now(), done_by = coalesce(nullif(btrim(p_agent), ''), 'agent'), outcome = o, source = src, note = nt where lead_id = lid;
  return jsonb_build_object('ok', true, 'lead_id', lid, 'outcome', o,
    'left', (select count(*) from public.estate_people_wanted x join public.leads l on l.id = x.lead_id where x.done_at is null and not public.card_is_closed(l.stage)));
end $fn$;
revoke all on function public.agent_estate_people_done(jsonb, text) from public, anon, authenticated;
grant execute on function public.agent_estate_people_done(jsonb, text) to service_role;

select public.estate_people_build();
