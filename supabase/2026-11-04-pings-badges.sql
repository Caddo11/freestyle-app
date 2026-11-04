-- ===== Freestyle : ping quand un membre débloque un badge (ou monte de niveau) =====
alter table public.notifications drop constraint if exists notifications_type_check;
alter table public.notifications add constraint notifications_type_check check (type = any (array[
  'story_like','like','comment','follow','reaction','reply','comment_like','message','announcement',
  'partner_request','partner_accept','respect','ann_request','ann_accept','ann_refuse','referral','badge']));

create or replace function public.fs_badge_label(k text) returns text
language sql immutable set search_path = public as $$
  select case k
    when 'fondateur' then 'Créateur de Freestyle'
    when 'plus' then 'Freestyle Plus'
    when 'verifie' then 'Compte vérifié'
    when 'pionnier' then 'Pionnier'
    when 'flash' then 'Premier flash'
    when 'genereux' then 'Généreux'
    when 'organisateur' then 'Organisateur'
    when 'followers:1' then 'Followers · Repéré'
    when 'followers:2' then 'Followers · Influent'
    when 'followers:3' then 'Followers · Icône'
    when 'posts:1' then 'Posts · Lancé'
    when 'posts:2' then 'Posts · Régulier'
    when 'posts:3' then 'Posts · Machine'
    when 'clips:1' then 'Clips · Caméra'
    when 'clips:2' then 'Clips · Réal'
    when 'clips:3' then 'Clips · Cinéaste'
    when 'valide:1' then 'Validé par la communauté · Reconnu'
    when 'valide:2' then 'Validé par la communauté · Respecté'
    when 'valide:3' then 'Validé par la communauté · Validé'
    when 'likes:1' then 'J’aime · Apprécié'
    when 'likes:2' then 'J’aime · Adoré'
    when 'likes:3' then 'J’aime · Culte'
    when 'vues:1' then 'Viral · Remarqué'
    when 'vues:2' then 'Viral · Viral'
    when 'vues:3' then 'Viral · Phénomène'
    when 'shouts:1' then 'Messages · Voix'
    when 'shouts:2' then 'Messages · Porte-voix'
    when 'shouts:3' then 'Messages · Tonnerre'
    when 'comments:1' then 'Commentaires · Bavard'
    when 'comments:2' then 'Commentaires · Animateur'
    when 'comments:3' then 'Commentaires · Orateur'
    when 'parrain:1' then 'Parrainage · Recruteur'
    when 'parrain:2' then 'Parrainage · Ambassadeur'
    when 'parrain:3' then 'Parrainage · Bâtisseur'
    when 'suivis:1' then 'Abonnements · Curieux'
    when 'suivis:2' then 'Abonnements · Connecté'
    when 'suivis:3' then 'Abonnements · Réseau'
    else null end
$$;

-- Après chaque mise à jour du cache de badges : un ping par badge nouveau ou niveau supérieur
create or replace function public.fs_badge_notify() returns trigger
language plpgsql security definer set search_path = public as $$
declare b text; fam text; lvl int; old_lvl int; lab text;
begin
  if new.badges is not distinct from old.badges then return new; end if;
  -- première fois que les badges sont calculés : pas d'avalanche de pings
  if old.badges is null or cardinality(old.badges) = 0 then
    if cardinality(coalesce(new.badges,'{}')) > 2 then return new; end if;
  end if;
  foreach b in array coalesce(new.badges, '{}') loop
    if b = any(coalesce(old.badges, '{}')) then continue; end if;
    fam := split_part(b, ':', 1); lvl := nullif(split_part(b, ':', 2), '')::int;
    if lvl is not null then
      select max(nullif(split_part(o, ':', 2), '')::int) into old_lvl from unnest(coalesce(old.badges, '{}')) o where split_part(o, ':', 1) = fam;
      if old_lvl is not null and old_lvl >= lvl then continue; end if;
    end if;
    lab := public.fs_badge_label(b);
    if lab is null then continue; end if;
    if not public.fs_notif_on(new.id, 'badges') then continue; end if;
    insert into public.notifications(user_id, actor_id, type, text) values (new.id, new.id, 'badge', b || '|' || lab);
  end loop;
  return new;
end $$;
drop trigger if exists fs_badge_notify_trg on public.profiles;
create trigger fs_badge_notify_trg after update of badges on public.profiles
  for each row execute function public.fs_badge_notify();

-- les validations recalculent tout de suite les badges de celui qui est validé (ping immédiat)
create or replace function public.fs_respect_badges() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform public.fs_badges(coalesce(new.receiver, old.receiver));
  perform public.fs_badges(coalesce(new.giver, old.giver));
  return null;
end $$;
drop trigger if exists fs_respect_badges_trg on public.respects;
create trigger fs_respect_badges_trg after insert or delete on public.respects
  for each row execute function public.fs_respect_badges();
select 'ok' as badges_pings;
