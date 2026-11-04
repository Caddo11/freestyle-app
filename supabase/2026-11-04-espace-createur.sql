-- ===== Freestyle : espace créateur =====
-- Un créateur (table admins) peut donner ou retirer à n'importe quel membre :
--   plus    -> Freestyle Plus (cadres, effets, couleurs)
--   verifie -> compte vérifié (pastille bleue)
--   admin   -> créateur (tous les pouvoirs)
-- Un créateur ne peut pas se retirer lui-même son rôle de créateur (pour ne jamais perdre l'accès).
create or replace function public.fs_admin_set_perm(target uuid, perm text, val boolean)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
begin
  if not public.fs_is_admin() then raise exception 'Réservé aux créateurs'; end if;
  if not exists (select 1 from public.profiles where id = target) then raise exception 'Membre introuvable'; end if;
  if perm = 'plus' then
    update public.profiles set premium = val where id = target;
    if not val and not exists (select 1 from public.admins where user_id = target) then
      update public.profiles set frame = null, banner_style = null, banner_fx = null, bar_color = null, name_style = null where id = target;
    end if;
  elsif perm = 'verifie' then
    update public.profiles set verified = val where id = target;
  elsif perm = 'admin' then
    if val then
      insert into public.admins(user_id) values (target) on conflict do nothing;
    else
      if target = auth.uid() then raise exception 'Tu ne peux pas te retirer ton propre rôle de créateur'; end if;
      delete from public.admins where user_id = target;
    end if;
  else
    raise exception 'Permission inconnue';
  end if;
  perform public.fs_badges(target);
  return jsonb_build_object(
    'plus', (select premium from public.profiles where id = target),
    'verifie', (select verified from public.profiles where id = target),
    'admin', exists (select 1 from public.admins where user_id = target));
end $$;
revoke all on function public.fs_admin_set_perm(uuid, text, boolean) from public, anon;
grant execute on function public.fs_admin_set_perm(uuid, text, boolean) to authenticated;
