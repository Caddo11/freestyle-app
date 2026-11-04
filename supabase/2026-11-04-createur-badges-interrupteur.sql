-- ===== Freestyle : le créateur choisit « tous les badges » ou « seulement les miens » =====
alter table public.admins add column if not exists all_badges boolean not null default true;

create or replace function public.fs_admin_all_badges(val boolean) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
begin
  if not public.fs_is_admin() then raise exception 'Réservé aux créateurs'; end if;
  update public.admins set all_badges = val where user_id = auth.uid();
  return public.fs_badges(auth.uid());
end $$;
revoke all on function public.fs_admin_all_badges(boolean) from public, anon;
grant execute on function public.fs_admin_all_badges(boolean) to authenticated;

-- pas d'avalanche de pings quand beaucoup de badges arrivent d'un coup (ex. « tous les badges »)
create or replace function public.fs_badge_notify() returns trigger
language plpgsql security definer set search_path = public as $$
declare b text; fam text; lvl int; old_lvl int; lab text; nnew int;
begin
  if new.badges is not distinct from old.badges then return new; end if;
  select count(*) into nnew from unnest(coalesce(new.badges,'{}')) x where not (x = any(coalesce(old.badges,'{}')));
  if nnew > 3 then return new; end if;
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

create or replace function public.fs_badges(pid uuid) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  p public.profiles; b text[] := '{}';
  n_posts int; n_clips int; n_shouts int; n_flash int; n_fol int; n_following int; n_cmt int;
  n_likes int; max_views int; n_checks int; n_given int; n_ref int; n_ann int; t int;
begin
  select * into p from public.profiles where id = pid;
  if p.id is null then return '[]'::jsonb; end if;
  select count(*) filter (where kind in ('photo','clip')), count(*) filter (where kind = 'clip'), count(*) filter (where kind = 'shout')
    into n_posts, n_clips, n_shouts from public.posts where user_id = pid;
  select count(*) into n_flash from public.fs_activity_days where user_id = pid and kind = 'story';
  select count(*) into n_fol from public.follows where following_id = pid;
  select count(*) into n_following from public.follows where follower_id = pid;
  select count(*) into n_cmt from public.comments where user_id = pid;
  select count(*) into n_likes from public.likes l join public.posts x on x.id = l.post_id where x.user_id = pid;
  select coalesce(max(c.views), 0) into max_views from public.post_view_counts c join public.posts x on x.id = c.post_id where x.user_id = pid;
  select count(*) into n_checks from public.respects where receiver = pid;
  select count(*) into n_given from public.respects where giver = pid;
  select count(*) into n_ref from public.profiles where referred_by = pid and onboarded;
  select count(*) into n_ann from public.announcements where author_id = pid and status = 'published';
  -- badges uniques
  if exists(select 1 from public.admins where user_id = pid) then b := array_append(b, 'fondateur'); end if;
  if p.premium then b := array_append(b, 'plus'); end if;
  if p.verified then b := array_append(b, 'verifie'); end if;
  if p.created_at < '2027-01-01' then b := array_append(b, 'pionnier'); end if;
  if n_flash >= 1 then b := array_append(b, 'flash'); end if;
  if n_given >= 5 then b := array_append(b, 'genereux'); end if;
  if n_ann >= 1 and not exists(select 1 from public.admins where user_id = pid) then b := array_append(b, 'organisateur'); end if;
  -- badges évolutifs (niveau 1 à 3)
  t := public.fs_tier(n_fol, array[100,1000,100000]); if t > 0 then b := array_append(b, 'followers:' || t); end if;
  t := public.fs_tier(n_posts, array[1,50,500]); if t > 0 then b := array_append(b, 'posts:' || t); end if;
  t := public.fs_tier(n_clips, array[1,25,200]); if t > 0 then b := array_append(b, 'clips:' || t); end if;
  t := public.fs_tier(n_shouts, array[10,100,1000]); if t > 0 then b := array_append(b, 'shouts:' || t); end if;
  t := public.fs_tier(n_checks, array[10,100,500]); if t > 0 then b := array_append(b, 'valide:' || t); end if;
  t := public.fs_tier(n_likes, array[100,10000,1000000]); if t > 0 then b := array_append(b, 'likes:' || t); end if;
  t := public.fs_tier(max_views, array[500,50000,1000000]); if t > 0 then b := array_append(b, 'vues:' || t); end if;
  t := public.fs_tier(n_cmt, array[50,500,5000]); if t > 0 then b := array_append(b, 'comments:' || t); end if;
  t := public.fs_tier(n_ref, array[3,25,100]); if t > 0 then b := array_append(b, 'parrain:' || t); end if;
  t := public.fs_tier(n_following, array[50,500,2000]); if t > 0 then b := array_append(b, 'suivis:' || t); end if;
  -- le créateur peut afficher tous les badges au niveau maximum (interrupteur dans l'espace créateur)
  if exists(select 1 from public.admins where user_id = pid and all_badges) then
    b := array['fondateur','plus','verifie','pionnier','flash','genereux','organisateur',
      'valide:3','followers:3','posts:3','clips:3','likes:3','vues:3','shouts:3','comments:3','parrain:3','suivis:3'];
  end if;
  update public.profiles set badges = b where id = pid and badges is distinct from b;
  return to_jsonb(b);
end $$;
select 'ok' as interrupteur_badges;
