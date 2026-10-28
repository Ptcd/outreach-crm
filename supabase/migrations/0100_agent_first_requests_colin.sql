-- First requests stay on Colin's one-tap batch approval (Muse 2026-10-28, adopting the laptop agent's advice: "first
-- requests in batches you approve, follow-ups and re-requests flow on their own ... revisit after two weeks with no
-- corrections"). The records agent's first request to an office waits for Colin in the app; its follow-ups, forms and
-- re-requests go through Muse while the ramp runs, then on standing approval.
create or replace function public.records_draft_standing(p_draft_id uuid) returns text
language sql stable security definer set search_path = public as $$
  -- null when this letter may go on standing approval; otherwise why not
  select case
    when d.id is null then 'no such draft'
    when d.body ~* '(\$|agree to pay|will pay|happy to pay|invoice me|enclosed (is )?(a )?(check|payment))' then 'mentions money: Colin approves it'
    when d.body ~* '(colin|418-0202)' then 'records letters are signed by the Records Desk: no Colin, no phone number'
    when d.purpose = 'enforcement' and not exists (select 1 from public.records_drafts x join public.records_requests rx on rx.id = x.request_id
                    where x.purpose = 'enforcement' and x.status = 'sent' and rx.county = r.county)
      then 'the first DA / Attorney General letter in ' || coalesce(r.county, 'this county') || ': Colin approves it after the summary'
    when d.purpose = 'request' then 'a first request: Colin approves it in the app'
    when d.written_by = 'records_agent' and (public.records_agent_state()->>'ramp')::boolean then 'ramp: Muse reviews and releases the agent''s letters'
    when d.written_by = 'records_agent' then null
    when r.standing_approval is false then 'this request needs Colin''s approval every time'
    when r.standing_approval is not true and not (d.purpose = any(s.standing_purposes)) then 'a ' || d.purpose || ' waits for Colin'
    when not exists (select 1 from public.records_drafts x where x.request_id = d.request_id and x.status = 'sent'
                       and lower(btrim(x.to_email)) = lower(btrim(d.to_email))) then 'nothing was sent to that address for this request yet'
    else null end
    from public.records_drafts d join public.records_requests r on r.id = d.request_id
    cross join public.records_settings s
   where d.id = p_draft_id and s.id = 1
$$;
