-- 0200: follow-ups from a text thread, and one follow-up structure across methods (Colin 2026-11-07, after the HOA
-- thread where the seller said "leave me to my fight" and Adil asked "can you mark something": "They need some way to
-- set followups from texting ... ux needs logic thought out for cross method followup structure").
--
-- The structure, in one place:
--   1. One follow-up per card per caller, whatever method it was set from (a call, the card, a text thread): the
--      caller's `mine` task (0170). Setting again moves it. It carries HOW the caller will reach back (tasks.kind:
--      'call' or 'text'), WHICH number (tasks.phone10) and the one line to open with (leads.say_next, 0186), which for
--      a text follow-up is the text itself.
--   2. Where it shows follows the method: a call follow-up lands in the caller's dialer, Today and My cards as before;
--      a text follow-up lands on the Texts page under "Follow-ups due" (text_followups_due) with the line ready to
--      send in one tap. A caller-set text is sent by the caller, never by the machine.
--   3. The seller moving first wins: a seller text after the follow-up was set flags it ("they texted first"), the
--      caller answers in the thread, and a team text sent on the card closes the open text follow-up by itself.
--      A call logged on the card closes a call follow-up as before (the dialer does that).
--   4. A STOP or a closed card (dnc, dead, closed) takes the follow-up off every list; nothing is ever sent to a
--      phone that opted out.
--   5. Setting a follow-up from a thread makes the thread the caller's (the app takes it over), so Muse and the
--      machine's texts stay off it while the caller waits for the date.

-- the one door: how, when, which number, what to say
create or replace function public.followup_set_how(p_lead_id uuid, p_at timestamptz, p_how text default 'call', p_say text default null,
                                                   p_phone text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r jsonb; k text := case when p_how in ('call', 'text') then p_how else 'call' end;
        p text := nullif(right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 10), '');
        say text := nullif(btrim(coalesce(p_say, '')), '');
begin
  if k = 'text' and p is not null and exists (select 1 from public.suppressed_phones s where s.phone10 = p) then
    return jsonb_build_object('ok', false, 'reason', 'that phone opted out: no text follow-up to it (set a call, or nothing)');
  end if;
  r := public.followup_set(p_lead_id, p_at, k, say);
  if coalesce((r->>'ok')::boolean, false) is false then return r; end if;
  update public.tasks set phone10 = coalesce(p, phone10), title = case when k = 'text' then 'Text them back' else 'Call them back' end,
         updated_at = now()
   where id = (r->>'task_id')::uuid;
  if say is not null then perform public.card_say_next(p_lead_id, say); end if;
  return r || jsonb_build_object('how', k, 'phone10', p);
end $$;
revoke all on function public.followup_set_how(uuid, timestamptz, text, text, text) from public, anon;
grant execute on function public.followup_set_how(uuid, timestamptz, text, text, text) to authenticated;

-- my text follow-ups due by the end of today (Central), overdue first; Colin sees everyone's
create or replace function public.text_followups_due(p_now timestamptz default now())
returns jsonb language sql stable security definer set search_path = public as $$
  with mine as (
    select t.*, l.owner_name, l.property_address, l.municipality, l.stage, l.say_next, l.locked_to,
           coalesce(t.phone10, (select c.value_normalized from public.contacts c
                                  where c.lead_id = t.lead_id and c.kind = 'phone' and c.status = 'ok' and not c.suppressed and not coalesce(c.dnc_app, false)
                                    and c.value_normalized ~ '^[0-9]{10}$'
                                    and not exists (select 1 from public.suppressed_phones s where s.phone10 = c.value_normalized)
                                  order by (c.line_type = 'mobile') desc, c.created_at limit 1)) as to10
      from public.tasks t join public.leads l on l.id = t.lead_id
     where t.done_at is null and t.kind = 'text' and t.lead_id is not null
       and t.due_at < (((p_now at time zone 'America/Chicago')::date + 1)::timestamp at time zone 'America/Chicago')
       and (public.is_owner() or t.owner = public.wpie_person())
       and l.stage not in ('dnc', 'dead', 'closed_no_contact', 'closed_won'))
  select coalesce(jsonb_agg(jsonb_build_object(
           'task_id', m.id, 'lead_id', m.lead_id, 'due_at', m.due_at, 'owner', m.owner, 'note', m.note, 'title', m.title,
           'say', coalesce(m.say_next, m.note), 'phone10', m.to10,
           'owner_name', m.owner_name, 'property_address', m.property_address, 'municipality', m.municipality, 'stage', m.stage,
           'overdue', m.due_at < p_now,
           'they_texted_first', exists (select 1 from public.twilio_inbound ti where ti.lead_id = m.lead_id and ti.received_at > m.updated_at),
           'last_in', (select ti.body from public.twilio_inbound ti where ti.lead_id = m.lead_id order by ti.received_at desc limit 1),
           'last_in_at', (select ti.received_at from public.twilio_inbound ti where ti.lead_id = m.lead_id order by ti.received_at desc limit 1))
         order by m.due_at), '[]'::jsonb)
    from mine m
   where m.to10 is not null and not exists (select 1 from public.suppressed_phones s where s.phone10 = m.to10)
$$;
revoke all on function public.text_followups_due(timestamptz) from public, anon;
grant execute on function public.text_followups_due(timestamptz) to authenticated, service_role;

-- a team text sent on the card answers the open text follow-up (rule 3)
create or replace function public.text_followup_on_team_text() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.kind <> 'team' or new.lead_id is null or coalesce(new.is_test, false) or new.status is not distinct from old.status or new.status <> 'sent' then return new; end if;
  update public.tasks set done_at = now(), updated_at = now(),
         note = concat_ws(' | ', note, 'answered in the thread by ' || coalesce(new.decided_by, 'the team') || ' ' || to_char(now() at time zone 'America/Chicago', 'Mon DD HH24:MI'))
   where lead_id = new.lead_id and done_at is null and kind = 'text' and coalesce(source, '') in ('mine', 'manual');
  return new;
end $$;
drop trigger if exists text_followup_on_team_text on public.reply_drafts;
create trigger text_followup_on_team_text after update of status on public.reply_drafts
  for each row execute function public.text_followup_on_team_text();
