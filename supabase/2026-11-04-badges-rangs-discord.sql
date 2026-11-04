-- ===== Freestyle : badges des rangs du Discord (E, D, C, B, A, S) =====
-- Donnés à la main depuis l'espace créateur (le Discord n'est pas relié à l'appli).
-- Un seul rang affiché : le plus haut. Seul le fondateur (@caddo) peut donner ou retirer un rang.
create or replace function public.fs_badges(pid uuid) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  p public.profiles; b text[] := '{}';
  n_posts int; n_clips int; n_shouts int; n_flash int; n_fol int; n_following int; n_cmt int;
  n_likes int; n_likes_given int; n_days int; max_views int; n_checks int; n_given int; n_ref int; n_ann int; t int;
  g_b text; g_l int; fams text[] := array['followers','posts','clips','shouts','valide','likes','vues','comments','parrain','suivis'];
begin
  select * into p from public.profiles where id = pid;
  if p.id is null then return '[]'::jsonb; end if;
  select count(*) filter (where kind in ('photo','clip')), count(*) filter (where kind = 'clip'), count(*) filter (where kind = 'shout')
    into n_posts, n_clips, n_shouts from public.posts where user_id = pid;
  select count(*) into n_flash from public.fs_activity_days where user_id = pid and kind = 'story';
  select count(distinct day) into n_days from public.fs_activity_days where user_id = pid;
  select count(*) into n_likes_given from public.likes where user_id = pid;
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
  if p.created_at < '2027-01-01' and n_days >= 20 then b := array_append(b, 'pionnier'); end if;
  if n_flash >= 30 then b := array_append(b, 'flash'); end if;
  if n_given >= 5 and n_likes_given >= 300 then b := array_append(b, 'genereux'); end if;
  if n_ann >= 1 and not exists(select 1 from public.admins where user_id = pid) then b := array_append(b, 'organisateur'); end if;
  -- badges évolutifs (niveau 1 à 3)
  t := public.fs_tier(n_fol, array[200,2000,100000]); if t > 0 then b := array_append(b, 'followers:' || t); end if;
  t := public.fs_tier(n_posts, array[15,100,500]); if t > 0 then b := array_append(b, 'posts:' || t); end if;
  t := public.fs_tier(n_clips, array[10,50,200]); if t > 0 then b := array_append(b, 'clips:' || t); end if;
  t := public.fs_tier(n_shouts, array[50,300,1000]); if t > 0 then b := array_append(b, 'shouts:' || t); end if;
  t := public.fs_tier(n_checks, array[10,100,500]); if t > 0 then b := array_append(b, 'valide:' || t); end if;
  t := public.fs_tier(n_likes, array[500,10000,1000000]); if t > 0 then b := array_append(b, 'likes:' || t); end if;
  t := public.fs_tier(max_views, array[1000,50000,1000000]); if t > 0 then b := array_append(b, 'vues:' || t); end if;
  t := public.fs_tier(n_cmt, array[150,1000,5000]); if t > 0 then b := array_append(b, 'comments:' || t); end if;
  t := public.fs_tier(n_ref, array[5,25,100]); if t > 0 then b := array_append(b, 'parrain:' || t); end if;
  t := public.fs_tier(n_following, array[100,500,2000]); if t > 0 then b := array_append(b, 'suivis:' || t); end if;
  -- badges donnés (ou retirés) à la main par un créateur
  for g_b, g_l in select badge, level from public.badge_grants where user_id = pid loop
    if position(':' in g_b) > 0 then continue; end if;
    if g_b = any(fams) then
      b := array(select x from unnest(b) x where split_part(x, ':', 1) <> g_b);
      if g_l > 0 then b := array_append(b, g_b || ':' || g_l); end if;
    else
      b := array_remove(b, g_b);
      if g_l > 0 then b := array_append(b, g_b); end if;
    end if;
  end loop;
  -- rangs du Discord (donnés à la main) : on ne garde que le plus haut
  declare rk text; keep text := null; begin
    foreach rk in array array['rangs','ranga','rangb','rangc','rangd','range'] loop
      if keep is null and rk = any(b) then keep := rk; end if;
    end loop;
    b := array(select x from unnest(b) x where x not in ('rangs','ranga','rangb','rangc','rangd','range') or x = keep);
  end;
  -- le créateur peut afficher tous les badges au niveau maximum (interrupteur dans l'espace créateur)
  if exists(select 1 from public.admins where user_id = pid and all_badges) then
    b := array['fondateur','plus','shiny','verifie','rangs','pionnier','flash','genereux','organisateur',
      'valide:3','followers:3','posts:3','clips:3','likes:3','vues:3','shouts:3','comments:3','parrain:3','suivis:3'];
  end if;
  update public.profiles set badges = b where id = pid and badges is distinct from b;
  return to_jsonb(b);
end $$;

create or replace function public.fs_badge_label(k text) returns text
language sql immutable set search_path = public as $$
  select case when k = 'shiny' then 'Shiny' when k = 'flash' then 'Flash'
    when k in ('rangs','ranga','rangb','rangc','rangd','range') then 'Rang ' || upper(right(k, 1))
    else public.fs_badge_label_base(k) end
$$;

create or replace function public.fs_admin_set_badge(target uuid, badge text, lvl int) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
#variable_conflict use_variable
begin
  if not public.fs_is_admin() then raise exception 'Réservé aux créateurs'; end if;
  if badge !~ '^[a-z]+$' then raise exception 'Badge inconnu'; end if;
  if badge = 'shiny' and not public.fs_is_founder() then raise exception 'Seul le fondateur peut donner le badge Shiny'; end if;
  if badge in ('rangs','ranga','rangb','rangc','rangd','range') and not public.fs_is_founder() then raise exception 'Seul le fondateur peut donner un rang'; end if;
  if lvl is null then
    delete from public.badge_grants g where g.user_id = target and g.badge = fs_admin_set_badge.badge;
  else
    insert into public.badge_grants(user_id, badge, level, granted_by) values (target, badge, greatest(0, least(3, lvl)), auth.uid())
      on conflict on constraint badge_grants_pkey do update set level = excluded.level, granted_by = excluded.granted_by, created_at = now();
  end if;
  return jsonb_build_object('badges', public.fs_badges(target), 'grants', public.fs_admin_badge_grants(target));
end $$;

-- recalcul pour le compte créateur (affiche le rang S avec « tous les badges »)
do $x$ declare r record; begin
  for r in select user_id from public.admins loop perform public.fs_badges(r.user_id); end loop;
end $x$;
select 'ok' as badges_rangs_discord;
