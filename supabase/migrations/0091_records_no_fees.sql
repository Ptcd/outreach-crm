-- No fees on records requests (Colin 2026-10-27: "No don't ask for fees we need a free way to get them"). Every records
-- letter used to say "If you'll charge fees over $25, please send me the estimate before filling the request." Now it
-- asks for copies the office already keeps, which normally cost nothing, and to skip any part that would carry a fee
-- and tell us, so the request can be narrowed to a free one. The letters already drafted were changed the same day.
alter function public.records_templates() rename to records_templates_v2;
create or replace function public.records_templates() returns jsonb language sql stable as $fn$
  select regexp_replace(regexp_replace(public.records_templates_v2()::text,
    'If you''ll charge fees over \$25, please send me the estimate before filling the request\.', 'I''m asking for electronic copies of records you already keep, which I understand normally carry no cost. If any part of this would involve a fee, please don''t fill that part; let me know and I''ll narrow or change the request so it can be done at no cost.', 'g'),
    'and if fees will exceed \$25, please send me the estimate before filling the request\.',
    'which I understand normally carry no cost. If any part of this would involve a fee, please don''t fill that part; let me know and I''ll narrow the request so it can be done at no cost.', 'g')::jsonb
$fn$;
revoke all on function public.records_templates(), public.records_templates_v2() from public, anon, authenticated;
grant execute on function public.records_templates(), public.records_templates_v2() to service_role;
