-- 0247: "I'm Colin Merrill" in a thread that speaks as Tyler.
--
-- 2026-11-16, 991 Howard St: the seller asked what company we are with. The door refused three drafts for the word
-- "company" with "sounds like a business: write as Colin, one person" (wording left from when every text went out as
-- Colin), and the agent did what the refusal said: "Just me personally, Jason. I'm Colin Merrill". The thread had
-- spoken as Tyler since its first text (desk 287). Two faults in the door, both fixed here and in agentDoor.ts:
--
--   1. the refusal named a person to write as. It no longer does (agentDoor.ts BUSINESS_WORDING).
--   2. the one-name rule (0219, 0221; Colin 2026-11-10) knew "this is X", "my name is X", "it's X", "X here" and
--      "X again", and not "I'm X" or "I am X", so the second name went out. It knows them now.
--
-- Nothing else about the rule changes: the thread speaks with the name the seller saw last.

-- The words that introduce a speaker, ahead of the name. One place, read by both functions below.
create or replace function public.text_intro_words() returns text language sql immutable as $$
  select '\m(this is|this|my name is|it''s|its|i''m|i’m|im|i am)\s+'
$$;

create or replace function public.text_speaker(p_body text) returns text language sql stable security definer set search_path = public as $$
  select k.name from public.text_voices() k(name)
   where coalesce(p_body, '') ~* (public.text_intro_words() || k.name || '\M')
      or coalesce(p_body, '') ~* ('\m' || k.name || '\s+(here|again)\M')
   order by position(lower(k.name) in lower(p_body)) limit 1
$$;

-- text_rule_problem: as it stands (0223), reading the same intro words
create or replace function public.text_rule_problem(p_lead_id uuid, p_body text, p_step integer, p_now timestamp with time zone DEFAULT now())
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $$
declare
  voice text;
  other text;
  rb    text;
  op    text;
begin
  op := public.text_offer_problem(p_lead_id, p_body);
  if op is not null then return op; end if;
  if not coalesce((select cc.day_rules_on from public.campaign_control cc where cc.id = 1), true) then return null; end if;
  voice := public.card_voice(p_lead_id);
  select k.name into other from public.text_voices() k(name)
   where lower(k.name) <> lower(voice)
     and (coalesce(p_body, '') ~* (public.text_intro_words() || k.name || '\M')
          or coalesce(p_body, '') ~* ('\m' || k.name || '\s+(here|again)\M'))
   limit 1;
  if other is not null then
    return 'this person hears from ' || voice || ', not ' || other || ': one name per seller, across their cards and numbers (Colin 2026-11-10)';
  end if;
  if coalesce(p_step, 1) = 0 then return null; end if;
  -- the intro belongs on the first text to a person, and only there (Colin 2026-11-10)
  if coalesce(p_step, 1) = 1 and public.text_speaker(p_body) is null and not public.card_texted_before(p_lead_id) then
    return 'the first text to a person says who is writing: this card speaks as ' || voice;
  end if;
  if coalesce(p_step, 1) > 1 and position('STOP' in coalesce(p_body, '')) > 0 then
    return 'a follow-up carries no STOP line: only a first text to a number does (Colin 2026-11-10)';
  end if;
  rb := public.card_record_block(p_lead_id, (p_now at time zone 'America/Chicago')::date);
  if rb is not null then
    return 'the records say no text for this card: ' || rb
           || case rb when 'want_not_need' then ' (a want is not a need: Colin 2026-11-07)'
                      when 'actively_listed' then ' (a listed property is not a lead)'
                      when 'sheriff_sale_inside_14d' then ' (a sale inside 14 days is not a lead)'
                      when 'record_verdict_stale' then ' (the laptop has not judged this card in a week)'
                      when 'no_record_verdict' then ' (the laptop has no record verdict for this owner)'
                      else '' end;
  end if;
  return null;
end $$
;

revoke all on function public.text_intro_words() from public, anon;
grant execute on function public.text_intro_words() to authenticated, service_role;
