-- Work that no text can do (Colin 2026-10-21: "it doesnt handle all the not simple things where
-- emails or other work are required yet"). When a seller asks for an email, photos or paperwork,
-- a records request, a family member to be contacted or a meeting, the reply agent opens a Task on
-- the lead in plain words, with the seller's exact ask quoted, assigned to Adil by default. Open
-- reply tasks count in the Needs-you badge and get one push (never in quiet hours).
-- Outbound email: Colin or Adil send it from the app with a tap (templates, never AI-sent); it is
-- logged on the lead's thread.
-- Sam's facts: what the drafting model learned (reason, clock, signers, number + anchor, ...) is
-- kept per reply so the lead card can show it.

alter type public.team_person add value if not exists 'adil';
alter type public.msg_channel add value if not exists 'email';

alter table public.tasks
  add column source            text,             -- 'reply' when the reply agent opened it
  add column title             text,             -- what is needed, in plain words
  add column quote             text,             -- the seller's exact words
  add column reply_inbound_sid text unique,      -- one task per inbound text
  add column email_to          text,             -- an address the seller gave, if any
  add column phone10           text,
  add column notified_at       timestamptz;
create index tasks_reply_open_idx on public.tasks (created_at) where source = 'reply' and done_at is null;

alter table public.reply_drafts add column facts jsonb;

-- Opened by the reply agent (service_role). Assigned to Adil; Colin can reassign in the app.
create or replace function public.reply_create_task(p_sid text, p_kind text, p_title text, p_quote text,
  p_email text default null, p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public as $$
declare t public.twilio_inbound; tid uuid;
begin
  select * into t from public.twilio_inbound where sid = p_sid;
  if not found then return jsonb_build_object('ok', false, 'reason', 'unknown_inbound'); end if;
  insert into public.tasks (lead_id, due_at, kind, owner, note, source, title, quote, reply_inbound_sid, email_to, phone10, created_by)
  values (t.lead_id, p_now, p_kind, 'adil'::public.team_person, p_title, 'reply', p_title, p_quote, p_sid,
          nullif(btrim(coalesce(p_email, '')), ''), t.from10, null)
  on conflict (reply_inbound_sid) do nothing
  returning id into tid;
  return jsonb_build_object('ok', tid is not null, 'id', tid);
end $$;

create or replace function public.reply_set_facts(p_sid text, p_facts jsonb)
returns void language sql security definer set search_path = public as $$
  update public.reply_drafts set facts = p_facts where inbound_sid = p_sid
$$;

-- Reply tasks to announce now (once each; nothing in quiet hours). Marked as they are handed out.
create or replace function public.notify_claim_tasks(p_now timestamptz default now(), p_limit integer default 20)
returns jsonb language plpgsql security definer set search_path = public as $$
declare out jsonb := '[]'::jsonb; k record;
begin
  if public.in_quiet_hours(p_now) then return out; end if;
  for k in
    select tk.* from public.tasks tk
     where tk.source = 'reply' and tk.done_at is null and tk.notified_at is null
     order by tk.created_at limit p_limit
     for update skip locked
  loop
    update public.tasks set notified_at = p_now where id = k.id;
    out := out || jsonb_build_object('id', k.id, 'title', k.title, 'quote', k.quote, 'owner', k.owner::text,
      'lead_id', k.lead_id, 'phone10', k.phone10,
      'owner_name', (select l.owner_name from public.leads l where l.id = k.lead_id),
      'property_address', (select l.property_address from public.leads l where l.id = k.lead_id));
  end loop;
  return out;
end $$;

-- An email Colin or Adil sent from the app, on the lead's thread.
create or replace function public.log_email(p_lead_id uuid, p_task_id uuid, p_to text, p_subject text, p_body text,
  p_actor text, p_now timestamptz default now())
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_lead_id is not null then
    insert into public.messages (lead_id, direction, channel, body, to_number, status, sent_at, created_by)
    values (p_lead_id, 'out', 'email'::public.msg_channel, 'Email to ' || p_to || E'\nSubject: ' || p_subject || E'\n\n' || p_body,
            p_to, 'sent by ' || coalesce(p_actor, 'Colin'), p_now, null);
  end if;
  if p_task_id is not null then
    update public.tasks set done_at = p_now,
           note = coalesce(note, '') || E'\nEmailed ' || p_to || ' (' || to_char(p_now at time zone 'America/Chicago', 'Mon DD HH12:MI AM') || ')'
     where id = p_task_id;
  end if;
end $$;

-- The badge: replies and reply tasks waiting.
create or replace view public.reply_waiting with (security_invoker = true) as
  select (select count(*) from public.reply_drafts where status = 'awaiting_approval')::int as drafts_waiting,
         (select count(*) from public.reply_drafts where status = 'would_send')::int as routine_would_send,
         (select count(*) from public.reply_drafts where status = 'queued')::int as queued,
         (select count(*) from public.tasks where source = 'reply' and done_at is null)::int as tasks_open;

revoke all on function public.reply_create_task(text, text, text, text, text, timestamptz), public.reply_set_facts(text, jsonb),
  public.notify_claim_tasks(timestamptz, integer), public.log_email(uuid, uuid, text, text, text, text, timestamptz)
  from public, anon, authenticated;
grant execute on function public.reply_create_task(text, text, text, text, text, timestamptz), public.reply_set_facts(text, jsonb),
  public.notify_claim_tasks(timestamptz, integer), public.log_email(uuid, uuid, text, text, text, text, timestamptz)
  to service_role;
grant select on public.reply_waiting to authenticated;
-- Reassigning a task (Colin <-> Adil) from the app.
grant update (owner) on public.tasks to authenticated;
