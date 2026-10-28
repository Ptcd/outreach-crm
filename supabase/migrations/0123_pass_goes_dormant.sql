-- A pass on a package moves the card off the hot-lead belt to the 90-day check-in (Colin 2026-10-28). Before this,
-- Shirikin's card kept its "said yes, not booked" calls (one due that evening, more at 2 days and 2 weeks) after Colin
-- passed. The promised callback (not a belt task) stays, so the caller still closes politely at the time promised.

create or replace function public.package_decide(p_id uuid, p_walk boolean, p_note text, p_grade text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare d public.deal_packages;
begin
  if not public.is_owner() then raise exception 'only Colin decides'; end if;
  select * into d from public.deal_packages where id = p_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such package'); end if;
  if d.status not in ('waiting_value', 'waiting_number', 'go_walk') then return jsonb_build_object('ok', false, 'reason', 'this package is ' || d.status); end if;
  if p_walk is null then return jsonb_build_object('ok', false, 'reason', 'walk it or pass'); end if;
  update public.deal_packages set colin_call = case when p_walk then 'walk' else 'pass' end, number_note = nullif(btrim(coalesce(p_note, '')), ''),
         grade = nullif(p_grade, ''), priced_at = now(), status = case when p_walk then 'go_walk' else 'declined' end, ready_pinged_at = null
   where id = p_id;
  update public.tasks set note = case when p_walk
           then 'Callback: Colin wants to walk it. Ask the yes-or-no question, then book his walk (script on the card) (package ' || left(p_id::text, 8) || ')'
           else 'Callback: Colin is passing on this one. Call at the time promised and close politely (script on the card) (package ' || left(p_id::text, 8) || ')' end
   where lead_id = d.lead_id and kind = 'callback' and done_at is null and coalesce(source, '') <> 'walk_confirm';
  update public.leads set next_action = case when p_walk then 'Callback: book Colin''s walk' else 'Callback: Colin passed, close politely' end where id = d.lead_id;
  -- a pass ends the hot-lead chase (Colin 2026-10-28, Shirikin: "i dispo'd it as pass, now what happens with it"): the
  -- belt's "said yes, not booked" calls stop, the promised callback stays for the polite close, and the card goes to the
  -- 90-day check-in (dormant: "We spoke before about {street}; still yours, and has anything changed?")
  if not p_walk then
    update public.tasks set done_at = now(), note = concat_ws(E'\n', note, 'Closed: Colin passed on the package.')
     where lead_id = d.lead_id and source = 'belt' and done_at is null;
    perform public.belt_enter(d.lead_id, 'dormant', 1, 'package_pass', jsonb_build_object('reason', 'Colin passed on the package'), 'colin', now());
  end if;
  return jsonb_build_object('ok', true, 'status', case when p_walk then 'go_walk' else 'declined' end);
end $$;
