-- 0159: the rest of the assessor's record card on each card's parcel (Colin 2026-10-31: "get the bedroom and bath
-- counts on all of them and if they have a basement"). The laptop pushes them with the county facts
-- (tools/push_property_values.py); the comps engine and the Quick number read them next.
alter table public.property_values
  add column if not exists bedrooms integer,
  add column if not exists baths_full integer,
  add column if not exists baths_half integer,
  add column if not exists basement text,                 -- none | unfinished | partial | finished | crawl | slab
  add column if not exists basement_finished_sqft integer,
  add column if not exists stories numeric,
  add column if not exists style text,
  add column if not exists garage text;
