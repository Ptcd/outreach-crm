-- Colin 2026-10-21: no agent name anywhere (texts are from Colin, first person), and his test phone must
-- behave exactly like a real seller. Colin's cell plays the first owner on the 2026-10-21 plan,
-- with the opening text that owner was sent, so a test reply drafts with a real owner and property.
-- Drafts still need Colin's tap; nothing here sends.

create or replace function public.set_routine_replies(p_on boolean)
returns void language plpgsql security definer set search_path = public as $$
declare who text; c public.campaign_control;
begin
  if not public.is_owner() then raise exception 'only Colin (owner) can change this'; end if;
  select * into c from public.campaign_control where id = 1;
  if p_on and not (c.redteam_ok and c.redteam_version is not null and c.redteam_version = c.agent_rules_version) then
    raise exception 'the red-team test has not passed for the reply rules running now (%/% on %)',
      coalesce(c.redteam_passed, 0), coalesce(c.redteam_total, 0), coalesce(c.redteam_version, 'none');
  end if;
  select display_name into who from public.team_members where lower(email) = lower(auth.jwt() ->> 'email');
  update public.campaign_control set routine_enabled = p_on, routine_changed_by = who, routine_changed_at = now() where id = 1;
  insert into public.opener_send_events (event, actor) values (case when p_on then 'routine_on' else 'routine_off' end, who);
end $$;

alter table public.campaign_control add column if not exists test_opener text;

update public.campaign_control set
  test_phones = (select array(select distinct x from unnest(test_phones || array['2627770909']) x)),
  test_owner_name = 'JOHN W PANKIEWICZ JR',
  test_property_address = '2825 S LOGAN AV, Milwaukee',
  test_opener = 'Hi John, Colin Merrill here. I''m looking to buy another building and yours at 2825 S Logan Ave in Milwaukee caught my eye. Any interest in selling? No worries if not, just reply STOP.'
where id = 1;

-- Drafts made before the persona change still use the old agent name: withdraw the ones still waiting.
update public.reply_drafts
   set status = 'skipped', decided_by = 'system', decided_at = now(), updated_at = now(),
       note = coalesce(note, '') || ' | withdrawn: old wording'
 where status in ('awaiting_approval', 'would_send', 'queued') and body ~ '\mSam\M';
update public.reply_drafts set note = replace(note, 'Sam drafts, Colin approves', 'drafted for Colin to approve') where note like '%Sam drafts%';
