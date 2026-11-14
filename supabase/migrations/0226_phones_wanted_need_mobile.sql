-- 0226: an owner whose number came back dead stays on the phones-wanted list until a number we can TEXT is on the card.
--
-- The laptop now lists an owner whose every number is dead or tried (wpie.live.phones_wanted, phone_bad; 2026-11-13).
-- The sweep closed such a row at once whenever the card held any phone marked ok, and for 38 of the first 45 that
-- phone was a landline: nothing a text can reach. need_mobile says the row wants a textable number; the sweep then
-- closes it only for one. Other rows are swept as before.
alter table public.phones_wanted add column if not exists need_mobile boolean not null default false;

-- phones_wanted_sweep: from 0190, with need_mobile
create or replace function public.phones_wanted_sweep() returns integer
language sql security definer set search_path = public as $$
  with d as (
    update public.phones_wanted w set done_at = now(), done_how = coalesce(w.done_how, 'phone on the card'), updated_at = now(),
           lead_id = coalesce(w.lead_id, (select l.id from public.leads l where l.wpie_owner_id = w.wpie_owner_id))
     where w.done_at is null
       and exists (select 1 from public.leads l join public.contacts c on c.lead_id = l.id
                    where l.wpie_owner_id = w.wpie_owner_id and c.kind = 'phone' and c.status = 'ok' and c.value_normalized is not null
                      and (not w.need_mobile or (public.agent_phone_ok(c.value_normalized, c.line_type) and not c.dnc_app and not c.suppressed
                                                 and not c.dnc_vendor and c.dnc_scrub <> 'dnc')))
     returning 1)
  select count(*)::integer from d
$$;
