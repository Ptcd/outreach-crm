-- The call script now matches Thalia's packet (2026-10-27): four more answers the call notes may fill in (any interest,
-- photos, other buyers or agents, what concerns them most).
create or replace function public.call_note_fact_keys() returns text[] language sql immutable as $$
  select array['owner', 'interest', 'identity', 'motivation', 'condition', 'occupancy', 'work_list', 'happened', 'photos', 'timeline',
               'decision_makers', 'price', 'anchor', 'flexibility', 'debt', 'behind', 'other_buyers', 'concerns', 'ready']
$$;
