-- Records letters are signed by the Records Desk (Colin's ruling, via Muse 2026-10-28: "the signature is Records Desk,
-- Merrill Holdings, no phone number, on all records correspondence"). The app's templates still signed "Colin Merrill /
-- (262) 418-0202 / merrillholdings@gmail.com"; now they sign as the laptop's templates do (wpie/records/*_template.txt).
-- The 185 unsent letters were re-signed the same day.
alter function public.records_templates() rename to records_templates_v3;
create or replace function public.records_templates() returns jsonb language sql stable as $fn$
  select replace(public.records_templates_v3()::text,
    'Colin Merrill\n(262) 418-0202\nmerrillholdings@gmail.com',
    'Records Desk\nMerrill Holdings\nmerrillholdings@gmail.com · Brookfield, WI')::jsonb
$fn$;
revoke all on function public.records_templates(), public.records_templates_v3() from public, anon, authenticated;
grant execute on function public.records_templates(), public.records_templates_v3() to service_role;

update public.records_drafts set body = replace(body, E'Records Desk\nMerrill Holdings\nmerrillholdings@gmail.com',
                                               E'Records Desk\nMerrill Holdings\nmerrillholdings@gmail.com · Brookfield, WI')
 where status in ('draft', 'in_batch', 'approved') and position(E'Records Desk\nMerrill Holdings\nmerrillholdings@gmail.com' in body) > 0
   and position('Brookfield' in body) = 0;
