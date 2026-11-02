-- ===== Freestyle : vues et visites de profil effacées après 90 jours, totaux conservés =====
-- Les totaux de vues et de comptes touchés restent dans post_view_counts (déjà le cas).
-- Avant d'effacer, on « fige » ce que les statistiques d'un post calculaient à partir du détail :
-- comptes touchés abonnés, abonnements gagnés, visites du profil générées.
alter table public.post_view_counts add column if not exists arch_reach_followers integer not null default 0;
alter table public.post_view_counts add column if not exists arch_follows integer not null default 0;
alter table public.post_view_counts add column if not exists arch_visits integer not null default 0;

create table if not exists public.profile_visit_totals(
  profile_id uuid primary key references public.profiles(id) on delete cascade,
  visits integer not null default 0
);
alter table public.profile_visit_totals enable row level security;

create or replace function public.fs_purge_old_stats() returns json
language plpgsql security definer set search_path = public as $$
declare cutoff timestamptz := now() - interval '90 days'; n_views int; n_visits int;
begin
  -- 1. figer les contributions des vues qui vont être effacées
  with old as (
    select v.post_id, v.user_id, v.first_at, p.user_id as owner
      from post_views v join posts p on p.id = v.post_id
     where v.last_at < cutoff
  ), agg as (
    select o.post_id,
      count(*) filter (where exists(select 1 from follows f where f.follower_id = o.user_id and f.following_id = o.owner)) as rf,
      count(*) filter (where exists(select 1 from follows f where f.follower_id = o.user_id and f.following_id = o.owner and f.created_at >= o.first_at)) as fo,
      count(*) filter (where exists(select 1 from profile_visits pv where pv.visitor_id = o.user_id and pv.profile_id = o.owner
                                     and pv.created_at >= o.first_at and pv.created_at < o.first_at + interval '1 day')) as vi
      from old o group by o.post_id
  )
  insert into post_view_counts(post_id, arch_reach_followers, arch_follows, arch_visits)
    select post_id, rf, fo, vi from agg
  on conflict (post_id) do update set
    arch_reach_followers = post_view_counts.arch_reach_followers + excluded.arch_reach_followers,
    arch_follows = post_view_counts.arch_follows + excluded.arch_follows,
    arch_visits = post_view_counts.arch_visits + excluded.arch_visits;

  delete from post_views where last_at < cutoff;
  get diagnostics n_views = row_count;

  -- 2. visites de profil : on garde le total par profil, puis on efface le détail
  insert into profile_visit_totals(profile_id, visits)
    select profile_id, count(*) from profile_visits where created_at < cutoff group by profile_id
  on conflict (profile_id) do update set visits = profile_visit_totals.visits + excluded.visits;
  delete from profile_visits where created_at < cutoff;
  get diagnostics n_visits = row_count;

  return json_build_object('vues_effacees', n_views, 'visites_effacees', n_visits);
end $$;
revoke execute on function public.fs_purge_old_stats() from public, anon, authenticated;

-- Statistiques d'un post : détail récent + totaux figés
create or replace function public.fs_post_stats(pid uuid) returns json
language plpgsql stable security definer set search_path = public as $$
declare owner uuid; r json; c post_view_counts;
begin
  select user_id into owner from public.posts where id = pid;
  if owner is null then return null; end if;
  if owner <> auth.uid() and not public.fs_is_admin() then raise exception 'ACCES_REFUSE'; end if;
  select * into c from public.post_view_counts where post_id = pid;
  select json_build_object(
    'views', coalesce(c.views, 0),
    'reach', coalesce(c.reach, 0),
    'likes', (select count(*) from public.likes where post_id = pid),
    'comments', (select count(*) from public.comments where post_id = pid),
    'shares', (select count(*) from public.post_shares where post_id = pid),
    'reactions', (select count(*) from public.post_reactions where post_id = pid),
    'reach_followers', coalesce(c.arch_reach_followers, 0) + (select count(*) from public.post_views v where v.post_id = pid
        and exists(select 1 from public.follows f where f.follower_id = v.user_id and f.following_id = owner)),
    'follows', coalesce(c.arch_follows, 0) + (select count(*) from public.follows f join public.post_views v on v.user_id = f.follower_id and v.post_id = pid
        where f.following_id = owner and f.created_at >= v.first_at),
    'profile_visits', coalesce(c.arch_visits, 0) + (select count(distinct pv.visitor_id) from public.profile_visits pv join public.post_views v on v.user_id = pv.visitor_id and v.post_id = pid
        where pv.profile_id = owner and pv.created_at >= v.first_at and pv.created_at < v.first_at + interval '1 day'),
    'created_at', (select created_at from public.posts where id = pid)
  ) into r;
  return r;
end $$;
grant execute on function public.fs_post_stats(uuid) to authenticated;

-- Tous les jours à 3 h 27
select cron.unschedule('purge-stats-90j') where exists (select 1 from cron.job where jobname = 'purge-stats-90j');
select cron.schedule('purge-stats-90j', '27 3 * * *', $$select public.fs_purge_old_stats()$$);
