-- ===== Freestyle : le créateur a tous les badges =====
create or replace function public.fs_badges(pid uuid) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  p public.profiles; b text[] := '{}';
  n_posts int; n_clips int; n_shouts int; n_flash int; n_fol int; n_following int; n_cmt int;
  n_likes int; max_views int; n_checks int; n_given int; n_ref int; n_ann int;
  partner uuid; aff jsonb; best int := 0; score int := 0; t int;
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
  if n_checks >= 100 or exists(select 1 from public.admins where user_id = pid) then b := array_append(b, 'valide'); end if;
  if p.created_at < '2027-01-01' then b := array_append(b, 'pionnier'); end if;
  if n_flash >= 1 then b := array_append(b, 'flash'); end if;
  if n_given >= 5 then b := array_append(b, 'genereux'); end if;
  if n_ann >= 1 and not exists(select 1 from public.admins where user_id = pid) then b := array_append(b, 'organisateur'); end if;
  -- badges évolutifs (niveau 1 à 3)
  t := public.fs_tier(n_fol, array[100,1000,100000]); if t > 0 then b := array_append(b, 'followers:' || t); end if;
  t := public.fs_tier(n_posts, array[1,50,500]); if t > 0 then b := array_append(b, 'posts:' || t); end if;
  t := public.fs_tier(n_clips, array[1,25,200]); if t > 0 then b := array_append(b, 'clips:' || t); end if;
  t := public.fs_tier(n_shouts, array[10,100,1000]); if t > 0 then b := array_append(b, 'shouts:' || t); end if;
  t := public.fs_tier(n_checks, array[10,100,1000]); if t > 0 then b := array_append(b, 'checks:' || t); end if;
  t := public.fs_tier(n_likes, array[100,10000,1000000]); if t > 0 then b := array_append(b, 'likes:' || t); end if;
  t := public.fs_tier(max_views, array[500,50000,1000000]); if t > 0 then b := array_append(b, 'vues:' || t); end if;
  t := public.fs_tier(n_cmt, array[50,500,5000]); if t > 0 then b := array_append(b, 'comments:' || t); end if;
  t := public.fs_tier(n_ref, array[3,25,100]); if t > 0 then b := array_append(b, 'parrain:' || t); end if;
  t := public.fs_tier(n_following, array[50,500,2000]); if t > 0 then b := array_append(b, 'suivis:' || t); end if;
  -- le créateur de Freestyle a tous les badges au niveau maximum
  if exists(select 1 from public.admins where user_id = pid) then
    b := array['fondateur','plus','verifie','valide','pionnier','flash','genereux','organisateur',
      'followers:3','posts:3','clips:3','checks:3','likes:3','vues:3','shouts:3','comments:3','parrain:3','suivis:3'];
  end if;
  update public.profiles set badges = b where id = pid and badges is distinct from b;
  return to_jsonb(b);
end $$;
select public.fs_badges(user_id) as createur from public.admins limit 1;
