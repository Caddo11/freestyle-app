-- ===== Freestyle : badges évolutifs (5 niveaux) =====
create or replace function public.fs_tier(v bigint, th int[]) returns int
language sql immutable as $$ select count(*)::int from unnest(th) x where coalesce(v,0) >= x $$;

-- Badges gagnés par un membre (calculés à partir de son activité)
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
  select case when requester = pid then addressee else requester end into partner
    from public.training_partners where status = 'accepted' and pid in (requester, addressee) limit 1;
  if partner is not null then
    begin aff := public.fs_partner_affinity(pid, partner); best := coalesce((aff->>'best')::int, 0); score := coalesce((aff->>'score')::int, 0);
    exception when others then null; end;
  end if;

  -- badges uniques
  if exists(select 1 from public.admins where user_id = pid) then b := array_append(b, 'fondateur'); end if;
  if p.premium then b := array_append(b, 'plus'); end if;
  if p.verified then b := array_append(b, 'verifie'); end if;
  if n_checks >= 100 or exists(select 1 from public.admins where user_id = pid) then b := array_append(b, 'valide'); end if;
  if p.created_at < '2027-01-01' then b := array_append(b, 'pionnier'); end if;
  if n_flash >= 1 then b := array_append(b, 'flash'); end if;
  if n_given >= 5 then b := array_append(b, 'genereux'); end if;
  if partner is not null then b := array_append(b, 'duo'); end if;
  if score >= 100 then b := array_append(b, 'affinite'); end if;
  if n_ann >= 1 and not exists(select 1 from public.admins where user_id = pid) then b := array_append(b, 'organisateur'); end if;
  -- badges évolutifs (niveau 1 à 5)
  t := public.fs_tier(n_fol, array[100,500,1000,10000,100000]); if t > 0 then b := array_append(b, 'followers:' || t); end if;
  t := public.fs_tier(n_posts, array[1,10,50,200,1000]); if t > 0 then b := array_append(b, 'posts:' || t); end if;
  t := public.fs_tier(n_clips, array[1,10,50,200,500]); if t > 0 then b := array_append(b, 'clips:' || t); end if;
  t := public.fs_tier(n_shouts, array[10,50,200,500,1000]); if t > 0 then b := array_append(b, 'shouts:' || t); end if;
  t := public.fs_tier(n_checks, array[10,50,100,500,1000]); if t > 0 then b := array_append(b, 'checks:' || t); end if;
  t := public.fs_tier(n_likes, array[100,1000,10000,100000,1000000]); if t > 0 then b := array_append(b, 'likes:' || t); end if;
  t := public.fs_tier(max_views, array[500,5000,50000,500000,1000000]); if t > 0 then b := array_append(b, 'vues:' || t); end if;
  t := public.fs_tier(n_cmt, array[50,250,1000,5000,10000]); if t > 0 then b := array_append(b, 'comments:' || t); end if;
  t := public.fs_tier(n_ref, array[3,10,25,50,100]); if t > 0 then b := array_append(b, 'parrain:' || t); end if;
  t := public.fs_tier(best, array[7,30,90,180,365]); if t > 0 then b := array_append(b, 'serie:' || t); end if;
  t := public.fs_tier(n_following, array[50,200,500,1000,2000]); if t > 0 then b := array_append(b, 'suivis:' || t); end if;
  -- le créateur de Freestyle a tout, au niveau maximum
  if exists(select 1 from public.admins where user_id = pid) then
    b := array['fondateur','plus','verifie','valide','pionnier','flash','genereux','duo','affinite','organisateur',
      'followers:5','posts:5','clips:5','shouts:5','checks:5','likes:5','vues:5','comments:5','parrain:5','serie:5','suivis:5'];
  end if;
  update public.profiles set badges = b where id = pid and badges is distinct from b;
  return to_jsonb(b);
end $$;
revoke execute on function public.fs_badges(uuid) from public, anon;
grant execute on function public.fs_badges(uuid) to authenticated;

-- convertit l'ordre déjà choisi vers les nouvelles familles
update public.profiles set badges_order = (
  select array_agg(k order by pos) from (
    select distinct on (k) k, pos from (
      select case
        when o in ('premier_post','posts10','posts50') then 'posts' when o = 'clip' then 'clips' when o = 'shout10' then 'shouts'
        when o = 'checke10' then 'checks' when o in ('serie7','serie30') then 'serie' when o in ('populaire','star') then 'followers'
        when o = 'sociable' then 'suivis' when o = 'bavard' then 'comments' when o = 'aime' then 'likes' when o = 'viral' then 'vues'
        when o in ('ambassadeur','recruteur') then 'parrain' else o end as k, pos
      from unnest(badges_order) with ordinality as u(o, pos)) m order by k, pos) d)
where badges_order is not null;

select count(public.fs_badges(id)) as profils_maj from public.profiles;
select badges, badges_order from public.profiles where id in (select user_id from public.admins);
