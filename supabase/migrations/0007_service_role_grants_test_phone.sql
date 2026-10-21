-- 1. The Edge Functions (service_role) could not read campaign_control: every reply-agent and
--    send-openers run since 0003 failed with "permission denied for table campaign_control"
--    (found 2026-10-21 in net._http_response after Colin's first test text). Tables created by
--    `supabase db push` did not get Supabase's usual grants to service_role. Grant them, now and
--    for tables added later. service_role bypasses row-level security; anon / authenticated keep
--    exactly the rights the earlier migrations gave them.
grant usage on schema public to service_role;
grant select, insert, update, delete on all tables in schema public to service_role;
grant usage, select on all sequences in schema public to service_role;
alter default privileges in schema public grant select, insert, update, delete on tables to service_role;
alter default privileges in schema public grant usage, select on sequences to service_role;

-- 2. Test phones (Colin 2026-10-21): his own cell can play an owner so he can test the reply agent end to
--    end. A text from a test phone gets a sample owner and address, never touches a real lead,
--    and its drafts are marked TEST in the Inbox. A STOP from it is honoured like any other;
--    reset_test_phones() lifts that block so he can test again.
alter table public.campaign_control
  add column test_phones text[] not null default '{}',
  add column test_owner_name text not null default 'TEST - Colin''s phone',
  add column test_property_address text not null default '1234 N Test St, Milwaukee';
alter table public.reply_drafts add column is_test boolean not null default false;

create or replace function public.reply_claim_inbound(p_limit integer default 10)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  c public.campaign_control;
  out jsonb := '[]'::jsonb;
  t record;
  lid uuid;
  test boolean;
begin
  perform pg_advisory_xact_lock(hashtext('wpie.reply_claim_inbound'));
  select * into c from public.campaign_control where id = 1;
  for t in
    select * from public.twilio_inbound i
     where i.processed_at is null and i.to_number = any(c.reply_numbers)
     order by i.received_at
     limit p_limit
     for update skip locked
  loop
    test := t.from10 = any(c.test_phones);
    lid := case when test then null else coalesce(t.lead_id,
      (select ct.lead_id from public.contacts ct where ct.value_normalized = t.from10 order by ct.created_at limit 1)) end;
    update public.twilio_inbound set processed_at = now(), lead_id = case when test then null else coalesce(lead_id, lid) end
     where sid = t.sid;
    out := out || jsonb_build_object(
      'sid', t.sid, 'from10', t.from10, 'to_number', t.to_number, 'body', t.body, 'received_at', t.received_at,
      'lead_id', lid, 'is_test', test,
      'owner_name', case when test then c.test_owner_name else (select l.owner_name from public.leads l where l.id = lid) end,
      'property_address', case when test then c.test_property_address else (select l.property_address from public.leads l where l.id = lid) end,
      'prior_inbound', coalesce((select jsonb_agg(x.body order by x.received_at) from public.twilio_inbound x
                                  where x.from10 = t.from10 and x.received_at < t.received_at), '[]'::jsonb),
      'last_agent_text', (select y.body from (
          select d.sent_body as body, d.sent_at as at from public.reply_drafts d where d.phone10 = t.from10 and d.status = 'sent'
          union all
          select m.body, m.sent_at from public.messages m where m.lead_id = lid and m.direction = 'out' and m.channel = 'sms'
        ) y where y.at < t.received_at order by y.at desc limit 1),
      'history', coalesce((select jsonb_agg(jsonb_build_object('who', z.who, 'body', z.body) order by z.at) from (
          select 'them' as who, x.body, x.received_at as at from public.twilio_inbound x
           where x.from10 = t.from10 and x.received_at < t.received_at
          union all
          select 'us', d.sent_body, d.sent_at from public.reply_drafts d where d.phone10 = t.from10 and d.status = 'sent'
          union all
          select case when m.direction = 'out' then 'us' else 'them' end, m.body, m.sent_at
            from public.messages m where m.lead_id = lid and m.channel = 'sms' and m.provider_sid is not null
        ) z where z.at < t.received_at), '[]'::jsonb));
  end loop;
  return out;
end $$;

-- Mark drafts from test phones (lead effects never apply: a test phone has no lead).
create or replace function public.reply_drafts_mark_test() returns trigger
language plpgsql security definer set search_path = public as $$
declare tp text[];
begin
  select test_phones into tp from public.campaign_control where id = 1;
  new.is_test := new.phone10 = any(coalesce(tp, '{}'));
  return new;
end $$;
create trigger reply_drafts_mark_test before insert on public.reply_drafts
  for each row execute function public.reply_drafts_mark_test();

-- Colin's test-phone buttons (owner only).
create or replace function public.set_test_phone(p_phone text)
returns text language plpgsql security definer set search_path = public as $$
declare p text := right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 10);
begin
  if not public.is_owner() then raise exception 'only Colin (owner) can set the test phone'; end if;
  if p = '' then
    update public.campaign_control set test_phones = '{}' where id = 1;
    return null;
  end if;
  if p !~ '^[2-9][0-9]{2}[2-9][0-9]{6}$' then raise exception 'not a US phone number'; end if;
  update public.campaign_control set test_phones = array[p] where id = 1;
  return p;
end $$;

create or replace function public.reset_test_phones()
returns integer language plpgsql security definer set search_path = public as $$
declare n integer; tp text[];
begin
  if not public.is_owner() then raise exception 'only Colin (owner) can reset the test phone'; end if;
  select test_phones into tp from public.campaign_control where id = 1;
  delete from public.suppressed_phones where phone10 = any(coalesce(tp, '{}'));
  get diagnostics n = row_count;
  update public.reply_drafts set status = 'superseded', updated_at = now()
   where is_test and status in ('awaiting_approval', 'would_send', 'queued', 'no_reply', 'dry_sent');
  return n;
end $$;

revoke all on function public.set_test_phone(text), public.reset_test_phones() from public, anon;
grant execute on function public.set_test_phone(text), public.reset_test_phones() to authenticated;
revoke all on function public.reply_claim_inbound(integer) from public, anon, authenticated;
grant execute on function public.reply_claim_inbound(integer) to service_role;
