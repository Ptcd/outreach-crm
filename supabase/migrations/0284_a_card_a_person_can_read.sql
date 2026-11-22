-- 0284: a card a person can read. Colin 2026-11-22: "Do you see how bad of a mess the cards are, go look at one",
-- then "Figure out the best ux and way to fix it". The card looked at (74 Pioneer Ct, Fond du Lac, on Tyler's call
-- list): 24 note entries and 12,600 characters, 15 of them the same "Phones loaded from banked FPS results" line an
-- agent wrote again every night; "behind on taxes" and "Behind on taxes" both listed as reasons; 16 phones.
--
-- This migration is the data half (the page is the other half, src/pages/LeadDetail.tsx):
--   * leads.notes_log: the agents' bookkeeping (phones loaded, banked re-load, restack, held, release, texting check,
--     wrong_number) lives here, the newest line of each kind, not in the notes a person reads. Nothing is thrown
--     away except older copies of the same line.
--   * notes_tidy: what a write to leads.notes goes through, every time, whoever writes it (a trigger): bookkeeping
--     lines move to notes_log, and an entry already on the card (the same words, with or without the agent's name
--     in front) is not added twice. Research notes ("Parcel:" lines, the packs) stay in the notes.
--   * reasons_to_sell never lists the same reason twice, whatever its capitals.
--   * Every card is tidied once, now.

alter table public.leads add column if not exists notes_log text;

-- an agent's name in front of a note: "Muse:", "Muse (held):", "Grok:", "Muse 2 (release):"
create or replace function public.note_body(p text) returns text language sql immutable as $fn$
  select btrim(regexp_replace(coalesce(p, ''), '^\s*(muse( 2)?|grok|desk)\s*(\([^)]*\))?\s*:\s*', '', 'i'))
$fn$;

-- bookkeeping an agent writes about its own work, not about the seller or the house
create or replace function public.note_is_log(p text) returns boolean language sql immutable as $fn$
  select coalesce(p, '') ~* '^\s*(muse( 2)?|grok)\s*\((held|release|released|wrong_number|hold)\)\s*:'
      or public.note_body(p) ~* '^(phones (loaded )?from|phones loaded|banked re-load|restack\M|texting check|cascade owed|dial number digit-checked)'
$fn$;

-- what makes two entries the same: a log line by its kind (dates and times out, the first words); a note by its words
create or replace function public.note_key(p text, p_log boolean) returns text language sql immutable as $fn$
  select case when p_log
    then left(lower(regexp_replace(regexp_replace(coalesce(p, ''), '\d{4}-\d{2}-\d{2}|\d{1,2}:\d{2}|\d+', '', 'g'), '\s+', ' ', 'g')), 44)
    else left(lower(regexp_replace(public.note_body(p), '\s+', ' ', 'g')), 400) end
$fn$;

create or replace function public.notes_tidy(p_notes text, p_log text, out notes text, out log text)
language plpgsql immutable as $fn$
declare part text; k text; keep text[] := '{}'; seen text[] := '{}'; lg text[] := '{}'; lseen text[] := '{}'; i integer;
begin
  if coalesce(btrim(p_log), '') <> '' then
    foreach part in array string_to_array(p_log, ' | ') loop
      part := btrim(part);
      if part <> '' then
        k := public.note_key(part, true); i := array_position(lseen, k);
        if i is null then lg := lg || part; lseen := lseen || k; else lg[i] := part; end if;
      end if;
    end loop;
  end if;
  if coalesce(btrim(p_notes), '') <> '' then
    foreach part in array string_to_array(p_notes, ' | ') loop
      part := btrim(part);
      if part = '' then continue; end if;
      if public.note_is_log(part) then
        k := public.note_key(part, true); i := array_position(lseen, k);
        if i is null then lg := lg || part; lseen := lseen || k; else lg[i] := part; end if;   -- the newest copy of a repeated line
      else
        k := public.note_key(part, false);
        if array_position(seen, k) is null then keep := keep || part; seen := seen || k; end if;
      end if;
    end loop;
  end if;
  notes := nullif(array_to_string(keep, ' | '), '');
  log := nullif(array_to_string(lg, ' | '), '');
end $fn$;

-- the same reason once, whatever its capitals; the first spelling stands
create or replace function public.reasons_once(p text[]) returns text[] language sql immutable as $fn$
  select coalesce(array_agg(r order by first), '{}')
    from (select (array_agg(x.r order by x.ord))[1] as r, min(x.ord) as first
            from unnest(coalesce(p, '{}')) with ordinality x(r, ord)
           where btrim(coalesce(x.r, '')) <> ''
           group by lower(regexp_replace(btrim(x.r), '\s+', ' ', 'g'))) q
$fn$;

create or replace function public.leads_tidy() returns trigger language plpgsql as $fn$
declare t record;
begin
  if tg_op = 'INSERT' or new.notes is distinct from old.notes then
    select * into t from public.notes_tidy(new.notes, new.notes_log);
    new.notes := t.notes; new.notes_log := t.log;
  end if;
  if tg_op = 'INSERT' or new.reasons_to_sell is distinct from old.reasons_to_sell then
    new.reasons_to_sell := public.reasons_once(new.reasons_to_sell);
  end if;
  return new;
end $fn$;

drop trigger if exists leads_tidy on public.leads;
create trigger leads_tidy before insert or update of notes, reasons_to_sell on public.leads
  for each row execute function public.leads_tidy();

-- the notes and reasons exactly as they were, kept (no login reads it)
create table if not exists public.leads_before_0284 as select id, notes, reasons_to_sell, now() as kept_at from public.leads;
alter table public.leads_before_0284 enable row level security;

-- every card, once
update public.leads l set notes = t.notes, notes_log = t.log
  from (select id, (public.notes_tidy(notes, notes_log)).* from public.leads where notes is not null) t
 where t.id = l.id and (t.notes is distinct from l.notes or t.log is distinct from l.notes_log);
update public.leads set reasons_to_sell = public.reasons_once(reasons_to_sell)
 where reasons_to_sell is distinct from public.reasons_once(reasons_to_sell);
