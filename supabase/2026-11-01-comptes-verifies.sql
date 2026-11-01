-- ===== Freestyle : comptes vérifiés (pastille bleue, obtenue plus tard en payant) =====
-- La colonne existe, mais personne ne l'a pour l'instant. Seuls le serveur (paiement)
-- et les administrateurs pourront l'activer : un membre ne peut pas se l'attribuer lui-même.
alter table public.profiles add column if not exists verified boolean not null default false;
alter table public.profiles add column if not exists verified_at timestamptz;

create or replace function public.fs_protect_verified() returns trigger
language plpgsql set search_path = public as $$
begin
  if current_user in ('postgres', 'service_role', 'supabase_admin') or public.fs_is_admin() then
    if new.verified and (tg_op = 'INSERT' or not old.verified) then new.verified_at := now(); end if;
    if not new.verified then new.verified_at := null; end if;
    return new;
  end if;
  if tg_op = 'INSERT' then
    new.verified := false; new.verified_at := null;
  else
    new.verified := old.verified; new.verified_at := old.verified_at;
  end if;
  return new;
end $$;
drop trigger if exists fs_protect_verified_trg on public.profiles;
create trigger fs_protect_verified_trg before insert or update on public.profiles
  for each row execute function public.fs_protect_verified();
