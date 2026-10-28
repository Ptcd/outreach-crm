-- The promised callback goes on the list of whoever is on the phone (found in the end-to-end test, 2026-10-28):
-- Thalia signs in with Colin's login, so package_submit wrote every package and its callback task as Colin's,
-- and the callback never showed on her list. The app now sends the person picked on that phone as p.caller.

create or replace function public.package_submit(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id uuid; login public.team_person := public.wpie_person();
        -- who is on the phone: the shared login is Colin's, so the app sends the person picked on this phone
        -- (a caller with a login of their own is always themself)
        who public.team_person := case
          when p->>'caller' in ('thalia', 'adil', 'colin') and (login is null or login = 'colin') then (p->>'caller')::public.team_person
          else login end; lid uuid := nullif(p->>'lead_id', '')::uuid; cb timestamptz := nullif(p->>'callback_at', '')::timestamptz;
        walk boolean := coalesce((p->>'walk_booked_on_call')::boolean, false); l public.leads;
begin
  if not public.is_team() then raise exception 'only the team sends packages'; end if;
  select * into l from public.leads where id = lid;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such card'); end if;
  if coalesce(btrim(p->>'need'), '') = '' and coalesce(p->'condition', '{}'::jsonb) = '{}'::jsonb then
    return jsonb_build_object('ok', false, 'reason', 'a package needs their reason or the condition, in their words');
  end if;
  if cb is null and not walk then return jsonb_build_object('ok', false, 'reason', 'set the callback time you promised (or say the walk is booked)'); end if;
  if exists (select 1 from public.deal_packages d where d.lead_id = lid and d.status in ('waiting_value', 'waiting_number', 'go_walk', 'number_ready', 'counter', 'agreed')) then
    return jsonb_build_object('ok', false, 'reason', 'this card already has an open package');
  end if;
  insert into public.deal_packages (lead_id, interest_id, source, hot, need, condition, timeline, their_number, their_basis, on_title, owed,
         occupancy, photos, other_buyers, concerns, motivation, callback_at, walk_booked_on_call, created_by)
  values (lid, nullif(p->>'interest_id', '')::uuid, coalesce(nullif(p->>'source', ''), public.lead_source_kind(lid)), coalesce((p->>'hot')::boolean, false),
          nullif(btrim(p->>'need'), ''), coalesce(p->'condition', '{}'::jsonb), nullif(btrim(p->>'timeline'), ''), nullif(btrim(p->>'their_number'), ''),
          nullif(btrim(p->>'their_basis'), ''), nullif(btrim(p->>'on_title'), ''), nullif(btrim(p->>'owed'), ''), nullif(btrim(p->>'occupancy'), ''),
          nullif(btrim(p->>'photos'), ''), nullif(btrim(p->>'other_buyers'), ''), nullif(btrim(p->>'concerns'), ''), nullif(btrim(p->>'motivation'), ''),
          cb, walk, who)
  returning id into v_id;
  if cb is not null then
    insert into public.tasks (lead_id, due_at, kind, owner, note)
    values (lid, cb, 'callback', coalesce(who, 'thalia'), 'Callback promised: waiting on Colin (walk it or pass) (package ' || left(v_id::text, 8) || ')');
  end if;
  update public.leads set next_action = case when walk then 'Package with Colin: walk booked on the call' else 'Package with Colin: callback ' || to_char(cb at time zone 'America/Chicago', 'Dy Mon DD HH12:MI AM') end,
         next_action_at = coalesce(cb, next_action_at),
         notes = concat_ws(' | ', notes, to_char(now() at time zone 'America/Chicago', 'YYYY-MM-DD') || ' package sent to Colin by ' || coalesce(who::text, 'the team')
                 || coalesce(': ' || nullif(btrim(p->>'motivation'), ''), ''))
   where id = lid;
  return jsonb_build_object('ok', true, 'package_id', v_id);
end $$;
