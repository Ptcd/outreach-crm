-- Pipes: a care-of line is not an owner (2026-10-28, checking ten days of MPROP against the cards: HAHA LLC and WAHA LLC
-- only gained "C/O PMC RENTALS" in OWNER_NAME_2, which would have opened two false re-screens). The names stay on the
-- staged row as the file printed them; the owner key that decides "the owner changed" leaves out C/O and ATTN lines.
create or replace function public.pipe_owner_key(p text[]) returns text language sql immutable as $$
  select nullif(array_to_string(array(select btrim(regexp_replace(upper(regexp_replace(coalesce(n, ''), '[^A-Za-z0-9 ]', ' ', 'g')), '\s+', ' ', 'g'))
                                         from unnest(coalesce(p, '{}')) n
                                        where btrim(coalesce(n, '')) <> '' and btrim(n) !~* '^(c\s*/\s*o\b|c/o|care of\b|attn\b|%)'), ' | '), '')
$$;

-- the stored keys, recomputed the same way (staging only; no change is logged for this)
update public.pipe_parcels set owner_key = public.pipe_owner_key(owner_names) where owner_key is distinct from public.pipe_owner_key(owner_names);
