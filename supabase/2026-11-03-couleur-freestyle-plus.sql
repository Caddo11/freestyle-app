-- ===== Freestyle : la couleur de l'application devient Freestyle+ =====
-- Seuls Freestyle+ et l'admin peuvent porter un cadre ou une bannière ; « premium » n'est modifiable que par l'admin ou le serveur
create or replace function public.fs_protect_premium() returns trigger
language plpgsql set search_path = public as $$
declare ok boolean;
begin
  if current_user in ('postgres', 'service_role', 'supabase_admin') or public.fs_is_admin() then return new; end if;
  if tg_op = 'INSERT' then new.premium := false; new.badges := '{}'; else new.premium := old.premium; new.badges := old.badges; end if;
  ok := new.premium or exists(select 1 from public.admins where user_id = new.id);
  if not ok then
    if tg_op = 'INSERT' then new.frame := null; new.banner_style := null; new.banner_fx := null; new.bar_color := null;
    else new.frame := old.frame; new.banner_style := old.banner_style; new.banner_fx := old.banner_fx; new.bar_color := old.bar_color; end if;
  end if;
  return new;
end $$;
drop trigger if exists fs_protect_premium_trg on public.profiles;
create trigger fs_protect_premium_trg before insert or update on public.profiles
  for each row execute function public.fs_protect_premium();

update public.profiles set bar_color = null
 where bar_color is not null and not premium and id not in (select user_id from public.admins);
select count(*) filter (where bar_color is not null) as couleurs_gardees from public.profiles;
