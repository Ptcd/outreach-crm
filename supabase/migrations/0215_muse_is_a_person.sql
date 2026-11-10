-- 0215: a fourth team person, muse (Colin 2026-11-10: Muse gets its own WPIE login as an owner, "Owner"). The value is
-- added on its own: Postgres will not let a new enum value be used in the transaction that adds it, and every migration
-- runs in one. 0216 adds the team row.
alter type public.team_person add value if not exists 'muse';
