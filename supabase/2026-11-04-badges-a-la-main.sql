-- ===== Freestyle : badges donnés à la main par un créateur + badge unique « Shiny » =====
create table if not exists public.badge_grants(
  user_id uuid not null references public.profiles(id) on delete cascade,
  badge text not null check (char_length(badge) <= 30),
  level int not null default 1 check (level between 0 and 3),
  granted_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  primary key (user_id, badge)
);
alter table public.badge_grants enable row level security; -- aucune lecture/écriture directe

create or replace function public.fs_badges(pid uuid) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  p public.profiles; b text[] := '{}';
  n_posts int; n_clips int; n_shouts int; n_flash int; n_fol int; n_following int; n_cmt int;
  n_likes int; max_views int; n_checks int; n_given int; n_ref int; n_ann int; t int;
  g_b text; g_l int; fams text[] := array['followers','posts','clips','shouts','valide','likes','vues','comments','parrain','suivis'];
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
  -- le créateur peut afficher tous les badges au niveau maximum (interrupteur dans l'espace créateur)
  if exists(select 1 from public.admins where user_id = pid and all_badges) then
    b := array['fondateur','plus','shiny','verifie','pionnier','flash','genereux','organisateur',
      'valide:3','followers:3','posts:3','clips:3','likes:3','vues:3','shouts:3','comments:3','parrain:3','suivis:3'];
  end if;
  update public.profiles set badges = b where id = pid and badges is distinct from b;
  return to_jsonb(b);
end $$;

-- donner (lvl 1..3), retirer de force (lvl 0) ou revenir en automatique (lvl null)
create or replace function public.fs_admin_set_badge(target uuid, badge text, lvl int) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
#variable_conflict use_variable
begin
  if not public.fs_is_admin() then raise exception 'Réservé aux créateurs'; end if;
  if badge !~ '^[a-z]+$' then raise exception 'Badge inconnu'; end if;
  if lvl is null then
    delete from public.badge_grants g where g.user_id = target and g.badge = fs_admin_set_badge.badge;
  else
    insert into public.badge_grants(user_id, badge, level, granted_by) values (target, badge, greatest(0, least(3, lvl)), auth.uid())
      on conflict on constraint badge_grants_pkey do update set level = excluded.level, granted_by = excluded.granted_by, created_at = now();
  end if;
  return jsonb_build_object('badges', public.fs_badges(target), 'grants', public.fs_admin_badge_grants(target));
end $$;

create or replace function public.fs_admin_badge_grants(target uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.fs_is_admin() then raise exception 'Réservé aux créateurs'; end if;
  return coalesce((select jsonb_object_agg(badge, level) from public.badge_grants where user_id = target), '{}'::jsonb);
end $$;
revoke all on function public.fs_admin_set_badge(uuid, text, int) from public, anon;
revoke all on function public.fs_admin_badge_grants(uuid) from public, anon;
grant execute on function public.fs_admin_set_badge(uuid, text, int) to authenticated;
grant execute on function public.fs_admin_badge_grants(uuid) to authenticated;

-- nom du nouveau badge pour les pings
do $x$ begin
  if not exists(select 1 from pg_proc where proname = 'fs_badge_label_base') then
    alter function public.fs_badge_label(text) rename to fs_badge_label_base;
  end if;
end $x$;
create or replace function public.fs_badge_label(k text) returns text
language sql immutable set search_path = public as $$
  select case when k = 'shiny' then 'Shiny' else public.fs_badge_label_base(k) end
$$;
select 'ok' as badges_a_la_main;
