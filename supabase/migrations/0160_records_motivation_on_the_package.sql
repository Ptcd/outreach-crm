-- 0160: why the records say this owner might sell, on every card and in the package email (Colin 2026-11-02, on the
-- Matthews package: "on these can you have the system generate their motivation reasons?"). The laptop counts each
-- card's distinct kinds of active distress from the county records (WPIE tools/motivation_stack.py: back taxes with
-- years and dollars, foreclosure, estate, property condition, liens and judgments, a listing that ended unsold) and the
-- owner traits that make it likelier (out of state, held 20+ years, free and clear, tired landlord), and pushes one row
-- per card. The package email carries it under "Why they might sell, from the records", beside what the seller said.

create table if not exists public.lead_motivation (
  lead_id uuid primary key references public.leads(id) on delete cascade,
  tier text,                                   -- A three kinds, B two, C one strong, D one weak or none
  families integer not null default 0,
  family_list text,
  lines jsonb not null default '[]'::jsonb,    -- ["Back taxes: 2 years delinquent, $4,051", ...], in the records' words
  amplifiers text[] not null default '{}',
  tax_years integer,
  tax_owed numeric,
  as_of date,
  updated_at timestamptz not null default now()
);
alter table public.lead_motivation enable row level security;
drop policy if exists lead_motivation_team_read on public.lead_motivation;
create policy lead_motivation_team_read on public.lead_motivation for select to authenticated using (public.is_team());
grant select on public.lead_motivation to authenticated;

create or replace function public.package_mail_claim(p_limit integer default 5) returns jsonb language plpgsql security definer set search_path = public as $$
declare out jsonb; ids uuid[];
begin
  with c as (
    select d.id from public.deal_packages d where d.emailed_at is null and d.created_at > now() - interval '3 days'
     order by d.created_at limit greatest(1, least(p_limit, 20)) for update skip locked),
  u as (update public.deal_packages d set emailed_at = now(), email_error = null from c where d.id = c.id returning d.id)
  select coalesce(array_agg(id), '{}') into ids from u;
  select coalesce(jsonb_agg(jsonb_build_object('package', to_jsonb(d), 'lead', jsonb_build_object('id', l.id, 'owner_name', l.owner_name,
           'property_address', l.property_address, 'municipality', l.municipality, 'property_zip', l.property_zip,
           'reasons_to_sell', to_jsonb(coalesce(l.reasons_to_sell, '{}'))),
           'person', (select pe.name from public.interests i join public.people pe on pe.id = i.person_id where i.id = d.interest_id),
           'motivation', (select jsonb_build_object('tier', m.tier, 'families', m.families, 'lines', m.lines, 'amplifiers', to_jsonb(m.amplifiers), 'as_of', m.as_of)
                            from public.lead_motivation m where m.lead_id = l.id))), '[]'::jsonb)
    into out
    from public.deal_packages d join public.leads l on l.id = d.lead_id
   where d.id = any(ids);
  return out;
end $$;
