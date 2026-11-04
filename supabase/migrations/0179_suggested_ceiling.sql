-- 0179: a suggested ceiling on every package, for Colin only (Colin 2026-11-04, after "ready": the number he sets on a
-- lane 2 package is approved, not typed). package_suggest(package) does Rick's math the way the card already does it
-- (offer_shoot, 0149-0158: sold comps' price per sq ft x the county size, repairs by the square foot from the condition
-- answers, his buyer share per value band, the opening discount under that) and adds the reason the caller will say,
-- built from the package's own condition words and the card's reasons. Nothing here reaches a caller: the Quick number
-- stays off (offer_settings.mode), offer_shoot's seller-facing fields are not used, and the function refuses anyone but
-- the owner or the mailer (service role), which prints the line in the package email.

create or replace function public.package_reason(p_condition jsonb, p_reasons text[]) returns text
language plpgsql immutable as $$
declare parts text[] := '{}'; v text; k text;
  labels jsonb := '{"roof":"the roof","hvac":"the furnace and AC","kitchen_baths":"the kitchen and baths","windows":"the windows","foundation":"the foundation","water":"the water damage","electrical":"the wiring","plumbing":"the plumbing","exterior":"the outside","other":null}'::jsonb;
  bad text := '(old|original|not (that |very |really )?(updated|new|great|good)|needs?|leak|broken|dated|worn|bad|rough|crack|rot|damage|shot|ancient|outdated)';
  good text := '^(new|newer|updated|replaced|fine|good|great|no leaks?|both working|working|recent|redone)';
begin
  for k in select * from jsonb_object_keys(coalesce(p_condition, '{}'::jsonb)) loop
    v := lower(coalesce(p_condition->>k, ''));
    if k = 'layout' or v = '' or labels->>k is null then continue; end if;
    if v ~ good and v !~ bad then continue; end if;
    if v ~ bad then
      parts := array_append(parts, case when k = 'windows' and v ~ 'original' then 'the original windows'
                                        when k = 'kitchen_baths' and v ~ 'bath' and v !~ 'kitchen' then 'the baths'
                                        when k = 'kitchen_baths' and v ~ 'kitchen' and v !~ 'bath' then 'the kitchen'
                                        else labels->>k end);
    end if;
  end loop;
  if p_reasons && array['behind on taxes', 'deep tax delinquency', 'tax foreclosure', 'in rem'] then parts := array_append(parts, 'the taxes owed'); end if;
  if p_reasons && array['code violations', 'code violation', 'raze order'] then parts := array_append(parts, 'the code case'); end if;
  if cardinality(parts) = 0 then return null; end if;
  if cardinality(parts) = 1 then return parts[1]; end if;
  return array_to_string(parts[1:cardinality(parts) - 1], ', ') || ' and ' || parts[cardinality(parts)];
end $$;

create or replace function public.package_suggest(p_package_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare d public.deal_packages; l public.leads; shot jsonb; ceiling numeric; reason text;
begin
  if not (public.is_owner() or coalesce(auth.jwt() ->> 'role', '') = 'service_role') then raise exception 'only Colin'; end if;
  select * into d from public.deal_packages where id = p_package_id;
  if not found then return jsonb_build_object('ok', false, 'reason', 'no such package'); end if;
  select * into l from public.leads where id = d.lead_id;
  shot := public.offer_shoot(d.lead_id);
  reason := public.package_reason(d.condition, l.reasons_to_sell);
  if coalesce((shot->>'ok')::boolean, false) then
    ceiling := coalesce((shot->>'number')::numeric, (shot->>'lao')::numeric);
    return jsonb_build_object('ok', true, 'ceiling', round(ceiling), 'mao', (shot->>'mao')::numeric, 'value', (shot->>'value')::numeric,
      'value_basis', shot->>'value_basis', 'sqft', shot->>'sqft', 'sqft_basis', shot->>'sqft_basis', 'repairs', shot->>'repairs', 'tier', shot->>'tier',
      'pct', shot->>'pct', 'off', shot->>'off', 'n_comps', jsonb_array_length(coalesce(shot->'comps', '[]'::jsonb)),
      'reason', reason, 'their_number', d.their_number);
  end if;
  return jsonb_build_object('ok', false, 'reason', coalesce(shot->>'reason', 'no comps or size on file'), 'value', shot->>'value', 'value_basis', shot->>'value_basis',
    'walk_first', coalesce((shot->>'walk_first')::boolean, false), 'suggested_reason', reason, 'their_number', d.their_number);
end $$;
revoke all on function public.package_suggest(uuid) from public, anon;
grant execute on function public.package_suggest(uuid) to authenticated, service_role;
revoke all on function public.package_reason(jsonb, text[]) from public, anon;
grant execute on function public.package_reason(jsonb, text[]) to authenticated, service_role;
