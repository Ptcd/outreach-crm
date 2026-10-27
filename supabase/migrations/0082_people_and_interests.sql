-- One property card, many interests (Muse's spec for Colin, 2026-10-27; Colin agreed to all three design calls), step 1:
-- the data model, filled in from today's cards. Nothing about sending changes here.
--   people     one global record per person or entity (one Eva Orlich everywhere): name, their own mailing address,
--              and person-level state (deceased, do_not_contact) that follows them onto every card
--   interests  a person's role on one property card: owner_of_record, co_owner, personal_representative,
--              special_administrator, heir, trustee, spouse, occupant, other; with its own status
--   contacts.person_id   a phone belongs to a person; the same number can sit under several people and cards
-- A card (leads) stays the property: stage, belt, reasons. Every writer (the laptop sync, the door, the app) gets the
-- model for free: a new card gets its owner of record, and a new phone is attached to the person it names.
-- Identity is careful on purpose: two records are one person only when the name matches AND they share a phone
-- number or the same mailing address. Same name alone is never enough (there are many John Smiths).

create table if not exists public.people (
  id            uuid primary key default gen_random_uuid(),
  kind          text not null default 'person' check (kind in ('person', 'entity', 'household')),   -- household: a couple's deed name
  name          text not null,
  name_key      text not null,
  mailing_street text,
  mailing_city  text,
  mailing_state text,
  mailing_zip   text,
  mail_key      text,
  status        text not null default 'active' check (status in ('active', 'deceased', 'do_not_contact')),
  status_reason text,
  status_at     timestamptz,
  notes         text,
  source        text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index if not exists people_name_key_idx on public.people (name_key);
create index if not exists people_mail_idx on public.people (name_key, mail_key);

create table if not exists public.interests (
  id          uuid primary key default gen_random_uuid(),
  lead_id     uuid not null references public.leads(id) on delete cascade,
  person_id   uuid not null references public.people(id) on delete cascade,
  role        text not null default 'other' check (role in ('owner_of_record', 'co_owner', 'personal_representative',
                'special_administrator', 'heir', 'trustee', 'spouse', 'occupant', 'other')),
  status      text not null default 'active' check (status in ('active', 'deceased', 'do_not_contact', 'not_the_contact', 'closed')),
  status_reason text,
  status_at   timestamptz,
  notes       text,
  source      text,
  created_at  timestamptz not null default now(),
  unique (lead_id, person_id)
);
create index if not exists interests_person_idx on public.interests (person_id);

alter table public.contacts add column if not exists person_id uuid references public.people(id) on delete set null;
create index if not exists contacts_person_idx on public.contacts (person_id);
create index if not exists contacts_value_idx on public.contacts (value_normalized);

alter table public.people enable row level security;
alter table public.interests enable row level security;
create policy people_team on public.people for select to authenticated using (public.is_team());
create policy interests_team on public.interests for select to authenticated using (public.is_team());

-- name words without punctuation, initials or filler: "SAM L ORLICH" and "Sam Orlich" -> {SAM, ORLICH}
create or replace function public.name_words(p text) returns text[] language sql immutable as $$
  select coalesce(array_agg(w order by o), '{}') from unnest(regexp_split_to_array(upper(regexp_replace(coalesce(p, ''), '[^A-Za-z0-9 ]', ' ', 'g')), '\s+'))
    with ordinality as t(w, o)
   where length(w) > 1 and w not in ('JR', 'SR', 'II', 'III', 'IV', 'MR', 'MRS', 'MS', 'DR', 'AND', 'THE', 'OF', 'ET', 'AL', 'UX', 'VIR')
$$;

create or replace function public.is_entity_name(p text) returns boolean language sql immutable as $$
  select coalesce(p, '') ~* '\m(LLC|L L C|INC|CORP|CORPORATION|COMPANY|CO|TRUST|TR|TRST|REVOCABLE|ESTATE|PARTNERSHIP|LP|LLP|LTD|BANK|ASSOCIATION|ASSN|CHURCH|CITY|COUNTY|VILLAGE|HOLDINGS|PROPERTIES|INVESTMENTS|GROUP|FOUNDATION)\M'
$$;

-- a person: first and last name word; an entity or a couple's deed name: every word
create or replace function public.person_key(p text, p_kind text) returns text language sql immutable as $$
  select case when p_kind <> 'person' then array_to_string(public.name_words(p), ' ')
              else coalesce((public.name_words(p))[1], '') || ' ' || coalesce((public.name_words(p))[cardinality(public.name_words(p))], '') end
$$;

-- does the phone's name belong to the deed name? its first and last word both appear in it
create or replace function public.name_in(p_whole text, p_part text) returns boolean language sql immutable as $$
  select cardinality(public.name_words(p_part)) > 0
     and (public.name_words(p_part))[1] = any(public.name_words(p_whole))
     and (public.name_words(p_part))[cardinality(public.name_words(p_part))] = any(public.name_words(p_whole))
$$;

create or replace function public.mail_key(p_street text, p_zip text) returns text language sql immutable as $$
  select nullif(upper(regexp_replace(coalesce(p_street, ''), '[^A-Za-z0-9]', '', 'g')), '') || '|' || left(coalesce(p_zip, ''), 5)
$$;

-- the person this name is, reusing a record only on name + (a shared phone or the same mailing address)
create or replace function public.person_for(p_name text, p_kind text, p_street text, p_city text, p_state text, p_zip text,
  p_phone10 text, p_source text) returns uuid language plpgsql security definer set search_path = public as $$
declare k text := public.person_key(p_name, p_kind); mk text := public.mail_key(p_street, p_zip); v uuid;
begin
  if coalesce(btrim(p_name), '') = '' or btrim(k) = '' then return null; end if;
  if p_phone10 is not null then
    select pe.id into v from public.people pe join public.contacts c on c.person_id = pe.id
     where pe.name_key = k and c.value_normalized = p_phone10 limit 1;
    if v is not null then return v; end if;
  end if;
  if mk is not null then
    select pe.id into v from public.people pe where pe.name_key = k and pe.mail_key = mk limit 1;
    if v is not null then return v; end if;
  end if;
  insert into public.people (kind, name, name_key, mailing_street, mailing_city, mailing_state, mailing_zip, mail_key, source)
  values (p_kind, btrim(p_name), k, p_street, p_city, p_state, p_zip, mk, p_source)
  returning id into v;
  return v;
end $$;

create or replace function public.add_interest(p_lead_id uuid, p_person_id uuid, p_role text, p_source text) returns uuid
language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  if p_person_id is null then return null; end if;
  insert into public.interests (lead_id, person_id, role, source) values (p_lead_id, p_person_id, p_role, p_source)
  on conflict (lead_id, person_id) do update set role = case
      when interests.role = 'other' then excluded.role          -- a real role beats "other"; a known role is never downgraded
      else interests.role end
  returning id into v;
  return v;
end $$;

-- the owner of record for a card: the deed name, at the owner's mailing address
create or replace function public.card_owner_interest(p_lead_id uuid) returns uuid language plpgsql security definer set search_path = public as $$
declare l public.leads; v uuid;
begin
  select * into l from public.leads where id = p_lead_id;
  if not found or coalesce(btrim(l.owner_name), '') = '' then return null; end if;
  select i.person_id into v from public.interests i where i.lead_id = p_lead_id and i.role = 'owner_of_record' limit 1;
  if v is not null then return v; end if;
  v := public.person_for(l.owner_name,
                         case when coalesce(l.owner_type, '') not in ('individual', 'couple', '') or public.is_entity_name(l.owner_name) then 'entity'
                              when l.owner_type = 'couple' or l.owner_name ~ '&| AND ' then 'household' else 'person' end,
                         l.mailing_street, l.mailing_city, l.mailing_state, l.mailing_zip, null, 'card owner');
  perform public.add_interest(p_lead_id, v, 'owner_of_record', 'card owner');
  return v;
end $$;

-- a phone goes to the person it names: the owner when the name is the owner's (an individual's phone), a co-owner when it
-- is one of a couple's names, the entity when it repeats the entity's name, otherwise its own person ("other": a member,
-- trustee or relative the skip trace found, until someone says what they are)
create or replace function public.contact_person(p_contact_id uuid) returns uuid language plpgsql security definer set search_path = public as $$
declare c public.contacts; l public.leads; owner uuid; v uuid; nm text; ent boolean;
begin
  select * into c from public.contacts where id = p_contact_id;
  if not found or c.lead_id is null then return null; end if;
  select * into l from public.leads where id = c.lead_id;
  owner := public.card_owner_interest(c.lead_id);
  nm := nullif(btrim(coalesce(c.person_name, '')), '');
  ent := public.is_entity_name(nm);
  if nm is null or upper(nm) = upper(btrim(coalesce(l.owner_name, ''))) then
    v := owner;
  elsif ent and public.name_in(l.owner_name, nm) then
    v := owner;
  elsif public.name_in(l.owner_name, nm) and coalesce(l.owner_type, '') <> 'couple' and l.owner_name !~ '&| AND ' and not public.is_entity_name(l.owner_name) then
    v := owner;                                          -- "RANDALL PEABODY" on RANDALL JOE PEABODY's card
  else
    -- the same name already on this card is the same person (a second number for them)
    select i.person_id into v from public.interests i join public.people pe on pe.id = i.person_id
     where i.lead_id = c.lead_id and pe.name_key = public.person_key(nm, case when ent then 'entity' else 'person' end) limit 1;
    if v is null then
      v := public.person_for(nm, case when ent then 'entity' else 'person' end, null, null, null, null, c.value_normalized, coalesce(c.source, 'phone'));
    end if;
    perform public.add_interest(c.lead_id, v,
      case when not public.name_in(l.owner_name, nm) then 'other'
           when coalesce(l.owner_type, '') = 'couple' or l.owner_name ~ '&| AND ' then 'co_owner'
           when l.owner_type = 'trust' or l.owner_name ~* '\m(TRUST|TR|TRST)\M' then 'trustee'
           else 'other' end, 'phone name');
  end if;
  update public.contacts set person_id = v where id = p_contact_id and person_id is distinct from v;
  return v;
end $$;

create or replace function public.leads_owner_interest() returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public.card_owner_interest(new.id);
  return new;
end $$;
drop trigger if exists leads_owner_interest on public.leads;
create trigger leads_owner_interest after insert on public.leads for each row execute function public.leads_owner_interest();

-- a new phone gets its person; a phone whose name or card changed is looked at again (a person set by hand is kept)
create or replace function public.contacts_person() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' and new.person_id is null then
    perform public.contact_person(new.id);
  elsif tg_op = 'UPDATE' and new.person_id is not distinct from old.person_id
        and (new.person_name is distinct from old.person_name or new.lead_id is distinct from old.lead_id) then
    update public.contacts set person_id = null where id = new.id;
    perform public.contact_person(new.id);
  end if;
  return new;
end $$;
drop trigger if exists contacts_person on public.contacts;
create trigger contacts_person after insert or update of person_name, lead_id on public.contacts
  for each row execute function public.contacts_person();

-- every phone a person has, on any card, with the global per-number facts
create or replace view public.person_phones with (security_invoker = true) as
  select c.person_id, c.value_normalized as phone10, max(c.line_type) as line_type,
         bool_or(c.status::text in ('bad', 'dead')) as bad, bool_or(c.suppressed or c.dnc_app) as do_not_text,
         exists (select 1 from public.suppressed_phones s where s.phone10 = c.value_normalized) as opted_out,
         array_agg(distinct c.lead_id) as on_cards
    from public.contacts c where c.kind = 'phone' and c.person_id is not null and c.value_normalized is not null
   group by c.person_id, c.value_normalized;

-- ------------------------------------------------------------------ fill in today's cards
do $$
declare r record;
begin
  for r in select id from public.leads loop perform public.card_owner_interest(r.id); end loop;
  for r in select id from public.contacts where person_id is null and lead_id is not null order by created_at loop perform public.contact_person(r.id); end loop;
end $$;

-- cards the agent already linked as the same person: one person
do $$
declare r record; a uuid; b uuid;
begin
  for r in select k.lead_id, k.other_id from public.lead_links k where k.kind = 'same_person' loop
    a := (select person_id from public.interests where lead_id = r.lead_id and role = 'owner_of_record' limit 1);
    b := (select person_id from public.interests where lead_id = r.other_id and role = 'owner_of_record' limit 1);
    if a is not null and b is not null and a <> b and (select name_key from public.people where id = a) = (select name_key from public.people where id = b) then
      update public.contacts set person_id = a where person_id = b;
      update public.interests set person_id = a where person_id = b and not exists (select 1 from public.interests x where x.lead_id = interests.lead_id and x.person_id = a);
      delete from public.interests where person_id = b;
      delete from public.people where id = b;
    end if;
  end loop;
end $$;

revoke all on function public.person_for(text, text, text, text, text, text, text, text), public.add_interest(uuid, uuid, text, text),
  public.card_owner_interest(uuid), public.contact_person(uuid) from public, anon, authenticated;
grant execute on function public.person_for(text, text, text, text, text, text, text, text), public.add_interest(uuid, uuid, text, text),
  public.card_owner_interest(uuid), public.contact_person(uuid) to service_role;
grant select on public.person_phones to authenticated, service_role;
