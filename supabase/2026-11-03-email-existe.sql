-- ===== Freestyle : vérifier qu'un e-mail a un compte (écran « Mot de passe oublié ») =====
create table if not exists public.fs_email_checks(at timestamptz not null default now());
alter table public.fs_email_checks enable row level security;
create or replace function public.fs_email_exists(em text) returns text
language plpgsql security definer set search_path = public, auth as $$
begin
  -- limite anti-abus : 40 vérifications par 10 minutes pour toute l'app
  delete from public.fs_email_checks where at < now() - interval '10 minutes';
  if (select count(*) from public.fs_email_checks) >= 40 then return 'slow'; end if;
  insert into public.fs_email_checks default values;
  return case when exists(select 1 from auth.users where lower(email) = lower(btrim(em))) then 'yes' else 'no' end;
end $$;
revoke execute on function public.fs_email_exists(text) from public;
grant execute on function public.fs_email_exists(text) to anon, authenticated;
