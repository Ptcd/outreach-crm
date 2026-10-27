-- Read access for the tables added since 0072 (found walking the app as Thalia, 2026-10-27: the card's Package section
-- said "permission denied for table deal_packages", and Colin's fee-quote list on the Approve page could not load).
-- Row security still decides who sees which rows: the team sees packages, people and interests; Colin alone sees
-- records requests and agent call logs.
grant select on public.deal_packages, public.people, public.interests, public.records_requests, public.records_drafts,
  public.records_batches, public.records_replies, public.agent_calls, public.text_templates to authenticated;
