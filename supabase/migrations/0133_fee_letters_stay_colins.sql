-- A fee-route letter (one that talks about a charge) is Colin's even on the records agent's ramp, where Muse used to
-- release every agent letter (Colin 2026-10-27: records letters never ask about or accept fees; the desk flagged the
-- 2026-10-29 batch asking Racine to itemize an $800 charge). Everything else in 0132 is unchanged.
create or replace function public.records_muse_may_release(p_draft_id uuid) returns text
language sql stable security definer set search_path = public as $$
  select case
    when d.purpose = 'fee' then 'a fee-route letter (it talks about a charge): Colin approves it'
    when st is null then null
    when st like 'ramp:%' then null
    when not public.muse_in_charge() then st
    when st like 'mentions money%' or st like 'records letters are signed%' or st like 'the first DA%' or st = 'no such draft' then st
    else null end
    from (select public.records_draft_standing(p_draft_id) as st) x
    left join public.records_drafts d on d.id = p_draft_id
$$;
