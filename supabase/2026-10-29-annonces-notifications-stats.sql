-- ===== Freestyle : annonces, commentaires évolués, notifications, vues & statistiques =====

-- ---------- Préférences de notifications ----------
create table if not exists public.notification_prefs(
  user_id uuid primary key references public.profiles(id) on delete cascade,
  likes boolean not null default true,
  comments boolean not null default true,
  follows boolean not null default true,
  messages boolean not null default true,
  announcements boolean not null default true,
  updated_at timestamptz not null default now()
);
alter table public.notification_prefs enable row level security;
drop policy if exists "prefs lues par soi" on public.notification_prefs;
create policy "prefs lues par soi" on public.notification_prefs for select using (user_id = auth.uid());
drop policy if exists "prefs creees par soi" on public.notification_prefs;
create policy "prefs creees par soi" on public.notification_prefs for insert with check (user_id = auth.uid());
drop policy if exists "prefs modifiees par soi" on public.notification_prefs;
create policy "prefs modifiees par soi" on public.notification_prefs for update using (user_id = auth.uid()) with check (user_id = auth.uid());

create or replace function public.fs_notif_on(uid uuid, cat text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select case cat when 'likes' then likes when 'comments' then comments when 'follows' then follows
    when 'messages' then messages when 'announcements' then announcements else true end
    from public.notification_prefs where user_id = uid), true)
$$;

create or replace function public.fs_push(owner uuid, actor uuid, ntype text, pid uuid, ntext text, cat text, dedupe boolean default false)
returns void language plpgsql security definer set search_path = public as $$
begin
  if owner is null or owner = actor then return; end if;
  if public.fs_blocked(owner, actor) then return; end if;
  if not public.fs_notif_on(owner, cat) then return; end if;
  if dedupe then
    delete from public.notifications where user_id = owner and actor_id = actor and type = ntype
      and post_id is not distinct from pid and (ntype <> 'message' or read_at is null);
  end if;
  insert into public.notifications(user_id, actor_id, type, post_id, text) values (owner, actor, ntype, pid, ntext);
end $$;
revoke execute on function public.fs_push(uuid,uuid,text,uuid,text,text,boolean) from public, anon, authenticated;

-- ---------- Commentaires : réponses + j'aime ----------
alter table public.comments add column if not exists parent_id uuid references public.comments(id) on delete cascade;
create index if not exists comments_parent_idx on public.comments(parent_id);
create index if not exists comments_post_idx on public.comments(post_id);

create table if not exists public.comment_likes(
  comment_id uuid not null references public.comments(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key(comment_id, user_id)
);
alter table public.comment_likes enable row level security;
drop policy if exists "likes commentaires lisibles" on public.comment_likes;
create policy "likes commentaires lisibles" on public.comment_likes for select using (true);
drop policy if exists "like commentaire par soi" on public.comment_likes;
create policy "like commentaire par soi" on public.comment_likes for insert with check (user_id = auth.uid());
drop policy if exists "like commentaire ban" on public.comment_likes;
create policy "like commentaire ban" on public.comment_likes as restrictive for insert with check (not public.fs_is_banned(auth.uid()));
drop policy if exists "unlike commentaire par soi" on public.comment_likes;
create policy "unlike commentaire par soi" on public.comment_likes for delete using (user_id = auth.uid());

-- ---------- Annonces (onglet Infos) ----------
create table if not exists public.announcements(
  id uuid primary key default gen_random_uuid(),
  author_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  kind text not null default 'info' check (kind in ('event','meetup','info')),
  title text not null check (char_length(title) between 1 and 80),
  body text not null default '' check (char_length(body) <= 1500),
  event_at timestamptz,
  place text check (place is null or char_length(place) <= 120),
  created_at timestamptz not null default now()
);
alter table public.announcements enable row level security;
drop policy if exists "annonces lisibles" on public.announcements;
create policy "annonces lisibles" on public.announcements for select using (auth.uid() is not null);
drop policy if exists "annonces admin ajout" on public.announcements;
create policy "annonces admin ajout" on public.announcements for insert with check (public.fs_is_admin() and author_id = auth.uid());
drop policy if exists "annonces admin modif" on public.announcements;
create policy "annonces admin modif" on public.announcements for update using (public.fs_is_admin()) with check (public.fs_is_admin());
drop policy if exists "annonces admin suppr" on public.announcements;
create policy "annonces admin suppr" on public.announcements for delete using (public.fs_is_admin());

-- ---------- Vues & statistiques ----------
create table if not exists public.post_views(
  post_id uuid not null references public.posts(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  n integer not null default 1,
  first_at timestamptz not null default now(),
  last_at timestamptz not null default now(),
  primary key(post_id, user_id)
);
alter table public.post_views enable row level security; -- aucune lecture directe : passe par les fonctions
create index if not exists post_views_first_idx on public.post_views(first_at);

create table if not exists public.post_view_counts(
  post_id uuid primary key references public.posts(id) on delete cascade,
  views integer not null default 0,
  reach integer not null default 0
);
alter table public.post_view_counts enable row level security;
drop policy if exists "compteurs vues lisibles" on public.post_view_counts;
create policy "compteurs vues lisibles" on public.post_view_counts for select using (true);

create table if not exists public.post_shares(
  id bigint generated always as identity primary key,
  post_id uuid not null references public.posts(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.post_shares enable row level security;
create index if not exists post_shares_post_idx on public.post_shares(post_id);

create table if not exists public.profile_visits(
  id bigint generated always as identity primary key,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  visitor_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.profile_visits enable row level security;
create index if not exists profile_visits_idx on public.profile_visits(profile_id, created_at);

create or replace function public.fs_view_posts(ids uuid[]) returns void
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); pid uuid; isnew boolean; again boolean;
begin
  if me is null or ids is null then return; end if;
  foreach pid in array ids[1:40] loop
    if not exists(select 1 from public.posts where id = pid) then continue; end if;
    isnew := false; again := false;
    insert into public.post_views(post_id, user_id) values (pid, me)
      on conflict (post_id, user_id) do nothing returning true into isnew;
    if isnew is null then
      update public.post_views set n = n + 1, last_at = now()
        where post_id = pid and user_id = me and last_at < now() - interval '30 seconds'
        returning true into again;
    end if;
    if coalesce(isnew,false) or coalesce(again,false) then
      insert into public.post_view_counts(post_id, views, reach) values (pid, 1, case when coalesce(isnew,false) then 1 else 0 end)
        on conflict (post_id) do update set views = post_view_counts.views + 1,
          reach = post_view_counts.reach + case when coalesce(isnew,false) then 1 else 0 end;
    end if;
  end loop;
end $$;
grant execute on function public.fs_view_posts(uuid[]) to authenticated;

create or replace function public.fs_share_post(pid uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return; end if;
  if (select count(*) from public.post_shares where user_id = auth.uid() and created_at > now() - interval '1 minute') > 10 then return; end if;
  insert into public.post_shares(post_id, user_id) select pid, auth.uid() where exists(select 1 from public.posts where id = pid);
end $$;
grant execute on function public.fs_share_post(uuid) to authenticated;

create or replace function public.fs_visit_profile(pid uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or pid = auth.uid() then return; end if;
  if exists(select 1 from public.profile_visits where profile_id = pid and visitor_id = auth.uid() and created_at > now() - interval '1 hour') then return; end if;
  insert into public.profile_visits(profile_id, visitor_id) values (pid, auth.uid());
end $$;
grant execute on function public.fs_visit_profile(uuid) to authenticated;

-- Statistiques d'une publication (propriétaire ou admin uniquement)
create or replace function public.fs_post_stats(pid uuid) returns json
language plpgsql stable security definer set search_path = public as $$
declare owner uuid; r json;
begin
  select user_id into owner from public.posts where id = pid;
  if owner is null then return null; end if;
  if owner <> auth.uid() and not public.fs_is_admin() then raise exception 'ACCES_REFUSE'; end if;
  select json_build_object(
    'views', coalesce((select views from public.post_view_counts where post_id = pid), 0),
    'reach', coalesce((select reach from public.post_view_counts where post_id = pid), 0),
    'likes', (select count(*) from public.likes where post_id = pid),
    'comments', (select count(*) from public.comments where post_id = pid),
    'shares', (select count(*) from public.post_shares where post_id = pid),
    'reactions', (select count(*) from public.post_reactions where post_id = pid),
    'reach_followers', (select count(*) from public.post_views v where v.post_id = pid
        and exists(select 1 from public.follows f where f.follower_id = v.user_id and f.following_id = owner)),
    'follows', (select count(*) from public.follows f join public.post_views v on v.user_id = f.follower_id and v.post_id = pid
        where f.following_id = owner and f.created_at >= v.first_at),
    'profile_visits', (select count(distinct pv.visitor_id) from public.profile_visits pv join public.post_views v on v.user_id = pv.visitor_id and v.post_id = pid
        where pv.profile_id = owner and pv.created_at >= v.first_at and pv.created_at < v.first_at + interval '1 day'),
    'created_at', (select created_at from public.posts where id = pid)
  ) into r;
  return r;
end $$;
grant execute on function public.fs_post_stats(uuid) to authenticated;

-- Tableau de bord du compte (soi uniquement)
create or replace function public.fs_account_stats(days integer default 30) returns json
language plpgsql stable security definer set search_path = public as $$
declare me uuid := auth.uid(); since timestamptz; prev timestamptz; r json;
begin
  if me is null then return null; end if;
  days := greatest(1, least(coalesce(days,30), 90));
  since := now() - make_interval(days => days); prev := since - make_interval(days => days);
  with mine as (select id, kind from public.posts where user_id = me),
  v as (select pv.* from public.post_views pv join mine on mine.id = pv.post_id)
  select json_build_object(
    'days', days,
    'reach', (select count(distinct user_id) from v where last_at >= since),
    'reach_prev', (select count(distinct user_id) from v where first_at >= prev and first_at < since),
    'views', (select coalesce(sum(n),0) from v where last_at >= since),
    'reach_followers', (select count(distinct v.user_id) from v where last_at >= since
        and exists(select 1 from public.follows f where f.follower_id = v.user_id and f.following_id = me)),
    'interactions', (select count(*) from public.likes l join mine on mine.id = l.post_id where l.created_at >= since)
        + (select count(*) from public.comments c join mine on mine.id = c.post_id where c.created_at >= since and c.user_id <> me)
        + (select count(*) from public.post_shares s join mine on mine.id = s.post_id where s.created_at >= since)
        + (select count(*) from public.post_reactions x join mine on mine.id = x.post_id where x.created_at >= since),
    'likes', (select count(*) from public.likes l join mine on mine.id = l.post_id where l.created_at >= since),
    'comments', (select count(*) from public.comments c join mine on mine.id = c.post_id where c.created_at >= since and c.user_id <> me),
    'shares', (select count(*) from public.post_shares s join mine on mine.id = s.post_id where s.created_at >= since),
    'new_followers', (select count(*) from public.follows where following_id = me and created_at >= since),
    'followers', (select count(*) from public.follows where following_id = me),
    'profile_visits', (select count(*) from public.profile_visits where profile_id = me and created_at >= since),
    'daily', (select coalesce(json_agg(json_build_object('d', to_char(d,'YYYY-MM-DD'), 'v', coalesce(c,0)) order by d), '[]'::json) from (
        select gs::date d, (select count(*) from v where v.first_at::date = gs::date) c
        from generate_series(since::date, now()::date, interval '1 day') gs) t),
    'top', (select coalesce(json_agg(t order by t.views desc), '[]'::json) from (
        select p.id, p.kind, p.media, p.sport, coalesce(c.views,0) views, coalesce(c.reach,0) reach,
          (select count(*) from public.likes l where l.post_id = p.id) likes
        from public.posts p left join public.post_view_counts c on c.post_id = p.id
        where p.user_id = me and p.created_at >= since order by coalesce(c.views,0) desc, p.created_at desc limit 6) t)
  ) into r;
  return r;
end $$;
grant execute on function public.fs_account_stats(integer) to authenticated;

-- Le propriétaire d'une story voit qui l'a vue (comme Instagram)
drop policy if exists "vues de mes stories" on public.story_views;
create policy "vues de mes stories" on public.story_views for select
  using (exists(select 1 from public.stories s where s.id = story_views.story_id and s.user_id = auth.uid()));
alter table public.story_views add column if not exists created_at timestamptz not null default now();

-- Fil : ajoute le nombre de vues
create or replace view public.feed with (security_invoker = true) as
 select x.id, x.user_id, x.kind, x.sport, x.caption, x.perf, x.media, x.stickers, x.created_at,
   (select count(*) from public.likes l where l.post_id = x.id)::integer as like_count,
   (select count(*) from public.comments c where c.post_id = x.id)::integer as comment_count,
   (exists (select 1 from public.likes l where l.post_id = x.id and l.user_id = auth.uid())) as liked,
   coalesce((select vc.views from public.post_view_counts vc where vc.post_id = x.id), 0)::integer as view_count
 from public.posts x;

-- ---------- Notifications : tout passe par fs_push (préférences respectées) ----------
create or replace function public.fs_notify() returns trigger
language plpgsql security definer set search_path = public as $$
declare owner uuid; powner uuid;
begin
  if TG_TABLE_NAME = 'story_likes' then
    select user_id into owner from public.stories where id = new.story_id;
    perform public.fs_push(owner, new.user_id, 'story_like', null, null, 'likes');
  elsif TG_TABLE_NAME = 'likes' then
    select user_id into owner from public.posts where id = new.post_id;
    perform public.fs_push(owner, new.user_id, 'like', new.post_id, null, 'likes', true);
  elsif TG_TABLE_NAME = 'comments' then
    select user_id into powner from public.posts where id = new.post_id;
    if new.parent_id is not null then
      select user_id into owner from public.comments where id = new.parent_id;
      perform public.fs_push(owner, new.user_id, 'reply', new.post_id, left(new.text, 80), 'comments');
      if powner is distinct from owner then
        perform public.fs_push(powner, new.user_id, 'comment', new.post_id, left(new.text, 80), 'comments');
      end if;
    else
      perform public.fs_push(powner, new.user_id, 'comment', new.post_id, left(new.text, 80), 'comments');
    end if;
  elsif TG_TABLE_NAME = 'comment_likes' then
    select user_id, post_id into owner, powner from public.comments where id = new.comment_id;
    perform public.fs_push(owner, new.user_id, 'comment_like', powner,
      (select left(text, 60) from public.comments where id = new.comment_id), 'likes', true);
  elsif TG_TABLE_NAME = 'post_reactions' then
    select user_id into owner from public.posts where id = new.post_id;
    perform public.fs_push(owner, new.user_id, 'reaction', new.post_id, new.word, 'likes', true);
  elsif TG_TABLE_NAME = 'follows' then
    perform public.fs_push(new.following_id, new.follower_id, 'follow', null, null, 'follows', true);
  elsif TG_TABLE_NAME = 'messages' then
    perform public.fs_push(new.recipient_id, new.sender_id, 'message', null, left(new.text, 80), 'messages', true);
  end if;
  return new;
end $$;

drop trigger if exists fs_notify_trg on public.comment_likes;
create trigger fs_notify_trg after insert on public.comment_likes for each row execute function public.fs_notify();
drop trigger if exists fs_notify_trg on public.messages;
create trigger fs_notify_trg after insert on public.messages for each row execute function public.fs_notify();
drop trigger if exists fs_notify_trg on public.story_likes;
create trigger fs_notify_trg after insert on public.story_likes for each row execute function public.fs_notify();

-- Annonce publiée par l'admin -> notification pour tout le monde (sauf ceux qui l'ont désactivée)
create or replace function public.fs_notify_announcement() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.notifications(user_id, actor_id, type, text)
  select p.id, new.author_id, 'announcement', left(new.title, 80)
  from public.profiles p
  where p.id <> new.author_id and coalesce(p.onboarded, false)
    and public.fs_notif_on(p.id, 'announcements') and not public.fs_is_banned(p.id);
  return new;
end $$;
drop trigger if exists fs_announce_trg on public.announcements;
create trigger fs_announce_trg after insert on public.announcements for each row execute function public.fs_notify_announcement();

-- Modération du texte des annonces et commentaires (déjà en place sur comments)
-- Temps réel pour les annonces
do $$ begin
  if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and tablename='announcements') then
    alter publication supabase_realtime add table public.announcements;
  end if;
end $$;

-- Types de notifications autorisés
alter table public.notifications drop constraint if exists notifications_type_check;
alter table public.notifications add constraint notifications_type_check check (type = any (array['story_like','like','comment','follow','reaction','reply','comment_like','message','announcement']));
create index if not exists notifications_user_idx on public.notifications(user_id, created_at desc);
