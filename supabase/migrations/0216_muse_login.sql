-- 0216: Muse's own login (Colin 2026-11-10, "Owner", after the risks were put to him: the UI has none of the door's
-- rules, owner means everything he can do including minting agent keys, a browser agent reads untrusted text, and
-- several functions attribute an owner's actions to "Colin" by name). The team row: role owner, person muse, shown as
-- Muse (agent). The auth user is created separately with a random code nobody holds; Colin sets the real code through
-- the app's own "forgot code" email to the plus-address below, which lands in his inbox, and puts it in Muse's vault.
-- No secret passes through the desk or the dev. Nobody has MFA; this login has none either, by his call.
insert into public.team_members (email, role, person, display_name)
values ('colin.merrill1+muse@gmail.com', 'owner', 'muse', 'Muse (agent)')
on conflict (email) do nothing;
