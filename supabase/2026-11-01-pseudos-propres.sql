-- ===== Freestyle : pseudos propres (comme sur Instagram) =====
-- Nom d'utilisateur (@) : lettres minuscules, chiffres, point, tiret et tiret bas.
alter table public.profiles drop constraint if exists profiles_handle_check;
alter table public.profiles add constraint profiles_handle_check
  check (handle ~ '^[a-z0-9][a-z0-9._-]{1,18}[a-z0-9]$') not valid;

-- Pseudo affiché : lettres (accents compris), chiffres, espaces, point, tiret et tiret bas.
-- Vérifié à la création et à chaque changement de pseudo (les anciens pseudos restent jusqu'au prochain changement).
create or replace function public.fs_clean_name() returns trigger
language plpgsql set search_path = public as $$
begin
  if tg_op = 'INSERT' or new.name is distinct from old.name then
    new.name := btrim(regexp_replace(new.name, '\s+', ' ', 'g'));
    if new.name !~ '^[A-Za-z0-9À-ÖØ-öø-ÿŒœ ._-]+$' then
      raise exception 'PSEUDO_INVALIDE' using errcode = 'P0001',
        hint = 'Lettres, chiffres, espaces, point, tiret et tiret bas uniquement';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists fs_clean_name_trg on public.profiles;
create trigger fs_clean_name_trg before insert or update on public.profiles
  for each row execute function public.fs_clean_name();
