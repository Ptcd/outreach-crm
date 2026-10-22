-- Conditional "no" (Colin 2026-10-22, on Martin's "If you're looking to overpay ... I'm not looking to
-- sell": "I also should not have gotten this email, waste of time"). The reply brain now closes a
-- no whose only condition is price, and answers a no with a real condition (a tenant leaving, the
-- next place, a date, family) with one question. For the latter, this opens a quiet follow-up task
-- in 30 days and moves the lead to "Follow up later"; Colin is not emailed or pinged for it.
create or replace function public.reply_nurture(p_sid text, p_quote text, p_due timestamptz, p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public as $$
declare t public.twilio_inbound; tid uuid;
begin
  select * into t from public.twilio_inbound where sid = p_sid;
  if not found or t.lead_id is null then return jsonb_build_object('ok', false, 'reason', 'no lead'); end if;
  insert into public.tasks (lead_id, due_at, kind, owner, note, source, title, quote, reply_inbound_sid, phone10, notified_at)
  values (t.lead_id, p_due, 'not_now_with_date', 'colin', 'They said no for now, with a reason. Check back.', 'nurture',
          'Check back: their condition', left(p_quote, 500), p_sid, t.from10, p_now)
  on conflict (reply_inbound_sid) do nothing
  returning id into tid;
  update public.leads set stage = 'follow_up', next_action = 'Check back (their condition)', next_action_at = p_due
   where id = t.lead_id and stage not in ('dead', 'dnc', 'closed_won', 'under_contract', 'closed_no_contact');
  return jsonb_build_object('ok', true, 'task_id', tid);
end $$;
revoke all on function public.reply_nurture(text, text, timestamptz, timestamptz) from public, anon, authenticated;
grant execute on function public.reply_nurture(text, text, timestamptz, timestamptz) to service_role;
