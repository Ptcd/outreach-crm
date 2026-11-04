-- 0181: the callback line never mentions what the house would list for (Colin 2026-11-04: "why do we say he can't be
-- anywhere near what it would list for? is that what Rick does?" It is not: Rick anchors against the seller's own number,
-- and with no number he says "we'd have to be definitely under X, that's not an offer"). With a seller number: "He can't
-- be at Y; he'd be closer to X." Without one: "He'd have to be under X on this one."

create or replace function public.callback_script(p_number numeric, p_reason text, p_their_number text default null) returns text
language sql immutable as $$
  select 'Say once, as a ceiling, not an offer: "Colin looked at it. '
      || coalesce(nullif(btrim(p_reason), '') || '. ', '')
      || case when nullif(btrim(coalesce(p_their_number, '')), '') is not null and p_their_number ~ '\d'
              then 'He can''t be at ' || btrim(p_their_number) || '; he''d be closer to $' || to_char(round(p_number), 'FM999,999,999') || '.'
              else 'He''d have to be under $' || to_char(round(p_number), 'FM999,999,999') || ' on this one.' end
      || ' Does that still work?" Then silence; count to five. '
      || 'If they push: "That''s not an offer, I''m just saying he''d have to be under that." '
      || 'Could work: book Colin''s walk. "I''d need Y": ask "Why doesn''t that work?" then "How''d you get to Y?", write it word for word, '
      || '"Colin will look at that and I''ll get back to you." No: their words in the notes, set a check-back. '
      || 'Never defend the number, explain it, go up, or offer anything in between.'
$$;

-- a callback already carrying the old line gets the new one
update public.tasks t set note = 'Callback: Colin''s number is ready, non-firm (package ' || left(d.id::text, 8) || '). ' || public.callback_script(d.our_number, d.number_note, d.their_number),
       updated_at = now()
  from public.deal_packages d
 where d.lead_id = t.lead_id and t.kind = 'callback' and t.done_at is null and d.status = 'number_ready' and d.our_number is not null
   and t.note like '%anywhere near what it would list for%';
