-- A text from a number with no card (a broker, someone answering a letter) can get a card from Needs you
-- (Colin 2026-10-23: "this doesn't have a card"). Like new_caller, but it also ties that number's drafts and
-- texts to the card, so the reply shows its "Open the full card" link and the thread lands on the card.

create or replace function public.card_from_text(p_draft uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare d public.reply_drafts; lid uuid; nm text; existing boolean := true;
begin
  if not public.is_team() then raise exception 'team only'; end if;
  select * into d from public.reply_drafts where id = p_draft;
  if not found then return jsonb_build_object('ok', false, 'reason', 'That text is gone.'); end if;
  if d.phone10 !~ '^[0-9]{10}$' then return jsonb_build_object('ok', false, 'reason', 'No usable phone number on that text.'); end if;
  lid := d.lead_id;
  if lid is null then
    select c.lead_id into lid from public.contacts c
     where c.kind = 'phone' and c.value_normalized = d.phone10 order by c.created_at limit 1;
  end if;
  if lid is null then
    existing := false;
    nm := format('New texter (%s) %s-%s', substr(d.phone10, 1, 3), substr(d.phone10, 4, 3), substr(d.phone10, 7));
    insert into public.leads (owner_name, stage, next_action, notes)
    values (nm, 'colin_call', 'Find out who they are and which property',
            'Created from a text: ' || left(coalesce(d.inbound_body, ''), 400))
    returning id into lid;
    insert into public.contacts (lead_id, kind, value, value_normalized, source, line_type)
    values (lid, 'phone', d.phone10, d.phone10, 'inbound_text', 'unknown');
  end if;
  update public.reply_drafts set lead_id = lid, updated_at = now() where phone10 = d.phone10 and lead_id is null;
  update public.twilio_inbound set lead_id = lid where from10 = d.phone10 and lead_id is null;
  return jsonb_build_object('ok', true, 'lead_id', lid, 'existing', existing);
end $$;

grant execute on function public.card_from_text(uuid) to authenticated;
