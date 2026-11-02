-- ===== Freestyle : pseudos sans émoji, affinité équitable, Respect & Validation par la communauté =====

-- =====================================================================
-- 1. PSEUDOS : aucun émoji ni symbole (nom d'utilisateur @ et pseudo affiché)
-- =====================================================================
alter table public.profiles drop constraint if exists profiles_handle_check;
alter table public.profiles add constraint profiles_handle_check
  check (handle ~ '^[a-z0-9][a-z0-9._-]{1,18}[a-z0-9]$') not valid;

-- Pseudo affiché : les lettres « stylisées » (𝖕𝖆𝖎𝖓) sont ramenées à des lettres normales,
-- puis tout émoji ou symbole est refusé.
create or replace function public.fs_clean_name() returns trigger
language plpgsql set search_path = public as $$
begin
  if tg_op = 'INSERT' or new.name is distinct from old.name then
    new.name := btrim(regexp_replace(normalize(coalesce(new.name, ''), NFKC), '\s+', ' ', 'g'));
    if new.name !~ '^[A-Za-z0-9À-ÖØ-öø-ÿŒœ ._-]+$' then
      raise exception 'PSEUDO_INVALIDE' using errcode = 'P0001',
        hint = 'Pas d''émoji : lettres, chiffres, espaces, point, tiret et tiret bas uniquement';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists fs_clean_name_trg on public.profiles;
create trigger fs_clean_name_trg before insert or update on public.profiles
  for each row execute function public.fs_clean_name();

-- Nettoyage des pseudos existants qui contiennent des émojis
-- (sans déclencher le délai de 14 jours entre deux changements de nom).
alter table public.profiles disable trigger fs_name_rule_trg;
update public.profiles p set name = coalesce(nullif(btrim(regexp_replace(
    regexp_replace(normalize(p.name, NFKC), '[^A-Za-z0-9À-ÖØ-öø-ÿŒœ ._-]', '', 'g'), '\s+', ' ', 'g')), ''), p.handle)
  where p.name !~ '^[A-Za-z0-9À-ÖØ-öø-ÿŒœ ._-]+$';
alter table public.profiles enable trigger fs_name_rule_trg;

-- =====================================================================
-- 2. AFFINITÉ ÉQUITABLE
--    On ne perd des points de likes / commentaires / stickers que les jours où
--    l'un des deux a publié quelque chose à aimer. Si personne ne publie, rien ne baisse,
--    et la catégorie n'est pas comptée dans le total (le score reste sur 100 %).
-- =====================================================================

-- Jours où chaque membre a publié (les stories s'effacent après 24 h : on garde juste la date)
create table if not exists public.fs_activity_days(
  user_id uuid not null references public.profiles(id) on delete cascade,
  day date not null,
  kind text not null check (kind in ('post', 'story')),
  primary key (user_id, day, kind)
);
alter table public.fs_activity_days enable row level security;

create or replace function public.fs_log_activity() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.fs_activity_days(user_id, day, kind)
    values (new.user_id, (new.created_at at time zone 'Europe/Paris')::date, tg_argv[0])
    on conflict do nothing;
  delete from public.fs_activity_days where day < current_date - 45;
  return new;
end $$;
drop trigger if exists fs_log_activity_trg on public.posts;
create trigger fs_log_activity_trg after insert on public.posts
  for each row execute function public.fs_log_activity('post');
drop trigger if exists fs_log_activity_trg on public.stories;
create trigger fs_log_activity_trg after insert on public.stories
  for each row execute function public.fs_log_activity('story');

insert into public.fs_activity_days(user_id, day, kind)
  select user_id, (created_at at time zone 'Europe/Paris')::date, 'post' from public.posts
   where created_at > now() - interval '45 days'
  union
  select user_id, (created_at at time zone 'Europe/Paris')::date, 'story' from public.stories
on conflict do nothing;

-- Likes de stories conservés (date seulement) pour que l'affinité ne les perde pas quand la story s'efface
create table if not exists public.fs_story_like_log(
  liker uuid not null references public.profiles(id) on delete cascade,
  owner uuid not null references public.profiles(id) on delete cascade,
  day date not null,
  n int not null default 1,
  primary key (liker, owner, day)
);
alter table public.fs_story_like_log enable row level security;

create or replace function public.fs_log_story_like() returns trigger
language plpgsql security definer set search_path = public as $$
declare o uuid;
begin
  select user_id into o from public.stories where id = new.story_id;
  if o is null or o = new.user_id then return new; end if;
  insert into public.fs_story_like_log(liker, owner, day)
    values (new.user_id, o, (coalesce(new.created_at, now()) at time zone 'Europe/Paris')::date)
    on conflict (liker, owner, day) do update set n = public.fs_story_like_log.n + 1;
  delete from public.fs_story_like_log where day < current_date - 45;
  return new;
end $$;
drop trigger if exists fs_log_story_like_trg on public.story_likes;
create trigger fs_log_story_like_trg after insert on public.story_likes
  for each row execute function public.fs_log_story_like();

insert into public.fs_story_like_log(liker, owner, day, n)
  select sl.user_id, s.user_id, (coalesce(sl.created_at, s.created_at) at time zone 'Europe/Paris')::date, count(*)
    from public.story_likes sl join public.stories s on s.id = sl.story_id
   where sl.user_id <> s.user_id group by 1, 2, 3
on conflict do nothing;

--   étoiles ........ 3 pts par jour de série, retombe à 0 dès qu'un jour passe sans échange (max 30)
--   messages ....... +2 le jour où les deux s'écrivent, -2 sinon                         (max 20)
--   likes .......... +1,5 par like, -1 par jour sans like SEULEMENT si l'un a publié     (max 15)
--   commentaires ... +3 par commentaire, -1 par jour sans SEULEMENT si l'un a publié     (max 15)
--   stickers/stories +2 chacun, -1 par jour sans SEULEMENT si l'un a publié / posté      (max 10)
--   abonnement ..... mutuel 5, à sens unique 2 (fixe)
--   ancienneté ..... 1 pt tous les 6 jours (max 5)
-- Une catégorie sans aucune publication sur 30 jours est « non comptée » : le score est ramené sur 100.
create or replace function public.fs_partner_affinity(a uuid, b uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  tz text := 'Europe/Paris';
  today date := (now() at time zone tz)::date;
  d date; acc timestamptz; start_day date;
  streak int := 0; n_follow int := 0; duo_days int := 0;
  v_msg numeric := 0; v_like numeric := 0; v_cmt numeric := 0; v_misc numeric := 0;
  c_msg boolean; c_like int; c_cmt int; c_misc int; o_post boolean; o_story boolean;
  t_days int := 0; t_likes int := 0; t_cmts int := 0; t_misc int := 0;
  k_post boolean := false; k_misc boolean := false;
  s_streak numeric; s_follow numeric; s_age numeric; earned numeric; maxi numeric; total int;
begin
  if a is null or b is null or a = b then return null; end if;
  select accepted_at into acc from training_partners
   where status = 'accepted' and least(requester, addressee) = least(a, b) and greatest(requester, addressee) = greatest(a, b);
  if acc is null then return null; end if;
  start_day := today - 29;

  create temporary table if not exists _fs_days(day date primary key) on commit drop;
  delete from _fs_days where true;
  insert into _fs_days
    select (created_at at time zone tz)::date from messages where sender_id = a and recipient_id = b
    intersect
    select (created_at at time zone tz)::date from messages where sender_id = b and recipient_id = a;

  create temporary table if not exists _fs_act(day date, kind text, n int) on commit drop;
  delete from _fs_act where true;
  insert into _fs_act
    select (l.created_at at time zone tz)::date, 'like', count(*) from likes l join posts p on p.id = l.post_id
     where l.created_at > now() - interval '31 days' and ((l.user_id = a and p.user_id = b) or (l.user_id = b and p.user_id = a)) group by 1
    union all
    select (c.created_at at time zone tz)::date, 'cmt', count(*) from comments c join posts p on p.id = c.post_id
     where c.created_at > now() - interval '31 days' and ((c.user_id = a and p.user_id = b) or (c.user_id = b and p.user_id = a)) group by 1
    union all
    select (r.created_at at time zone tz)::date, 'misc', count(*) from post_reactions r join posts p on p.id = r.post_id
     where r.created_at > now() - interval '31 days' and ((r.user_id = a and p.user_id = b) or (r.user_id = b and p.user_id = a)) group by 1
    union all
    select day, 'misc', sum(n)::int from fs_story_like_log
     where day >= start_day and ((liker = a and owner = b) or (liker = b and owner = a)) group by 1;

  -- jours où l'un des deux avait quelque chose à aimer (publication du jour ou de la veille, story du jour ou de la veille)
  create temporary table if not exists _fs_opp(day date, kind text) on commit drop;
  delete from _fs_opp where true;
  insert into _fs_opp
    select day, kind from fs_activity_days where user_id in (a, b) and day >= start_day - 1
    union
    select (created_at at time zone tz)::date, 'post' from posts where user_id in (a, b) and created_at > now() - interval '31 days';

  d := start_day;
  while d <= today loop
    c_msg  := exists(select 1 from _fs_days where day = d);
    select coalesce(sum(n),0) into c_like from _fs_act where day = d and kind = 'like';
    select coalesce(sum(n),0) into c_cmt  from _fs_act where day = d and kind = 'cmt';
    select coalesce(sum(n),0) into c_misc from _fs_act where day = d and kind = 'misc';
    o_post  := exists(select 1 from _fs_opp where kind = 'post'  and day between d - 1 and d);
    o_story := exists(select 1 from _fs_opp where kind = 'story' and day between d - 1 and d);
    if o_post or c_like > 0 or c_cmt > 0 then k_post := true; end if;
    if o_post or o_story or c_misc > 0 then k_misc := true; end if;
    -- le jour en cours ne fait jamais perdre de points tant qu'il n'est pas terminé
    if c_msg then v_msg := least(20, v_msg + 2); t_days := t_days + 1; elsif d < today then v_msg := greatest(0, v_msg - 2); end if;
    if c_like > 0 then v_like := least(15, v_like + c_like * 1.5); t_likes := t_likes + c_like;
      elsif d < today and o_post then v_like := greatest(0, v_like - 1); end if;
    if c_cmt > 0 then v_cmt := least(15, v_cmt + c_cmt * 3); t_cmts := t_cmts + c_cmt;
      elsif d < today and o_post then v_cmt := greatest(0, v_cmt - 1); end if;
    if c_misc > 0 then v_misc := least(10, v_misc + c_misc * 2); t_misc := t_misc + c_misc;
      elsif d < today and (o_post or o_story) then v_misc := greatest(0, v_misc - 1); end if;
    d := d + 1;
  end loop;

  d := today;
  if not exists(select 1 from _fs_days where day = d) then d := d - 1; end if;
  while exists(select 1 from _fs_days where day = d) loop streak := streak + 1; d := d - 1; end loop;

  select count(*) into n_follow from follows
   where (follower_id = a and following_id = b) or (follower_id = b and following_id = a);
  duo_days := greatest(0, floor(extract(epoch from now() - acc) / 86400))::int;

  s_streak := least(30, streak * 3);
  s_follow := case when n_follow >= 2 then 5 when n_follow = 1 then 2 else 0 end;
  s_age    := least(5, floor(duo_days / 6.0));
  earned := s_streak + v_msg + v_like + v_cmt + v_misc + s_follow + s_age;
  maxi := 30 + 20 + 5 + 5 + case when k_post then 30 else 0 end + case when k_misc then 10 else 0 end;
  total := least(100, round(earned * 100 / maxi))::int;

  return jsonb_build_object('score', total,
    'streak', streak, 'days', t_days, 'likes', t_likes, 'comments', t_cmts,
    'reactions', t_misc, 'follow', n_follow, 'duo_days', duo_days,
    'counted', jsonb_build_object('likes', k_post, 'comments', k_post, 'reactions', k_misc),
    'today', jsonb_build_object('msg', exists(select 1 from _fs_days where day = today),
      'like', exists(select 1 from _fs_act where day = today and kind = 'like'),
      'cmt', exists(select 1 from _fs_act where day = today and kind = 'cmt'),
      'misc', exists(select 1 from _fs_act where day = today and kind = 'misc'),
      'post', exists(select 1 from _fs_opp where kind = 'post' and day between today - 1 and today),
      'story', exists(select 1 from _fs_opp where kind = 'story' and day between today - 1 and today)),
    'parts', jsonb_build_object('streak', s_streak, 'days', v_msg, 'likes', v_like, 'comments', v_cmt,
      'reactions', v_misc, 'follow', s_follow, 'age', s_age));
end $$;
revoke execute on function public.fs_partner_affinity(uuid, uuid) from public, anon;
grant execute on function public.fs_partner_affinity(uuid, uuid) to authenticated;

-- =====================================================================
-- 3. RESPECT + VALIDATION PAR LA COMMUNAUTÉ
--    Un respect par profil, retirable. Seuls les comptes de plus de 7 jours qui ont déjà publié
--    peuvent en donner. 25 respects de membres différents = « Validé par la communauté ».
-- =====================================================================
create table if not exists public.respects(
  giver uuid not null references public.profiles(id) on delete cascade,
  receiver uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (giver, receiver),
  check (giver <> receiver)
);
create index if not exists respects_receiver_idx on public.respects(receiver);
alter table public.respects enable row level security;
drop policy if exists "respects lisibles" on public.respects;
create policy "respects lisibles" on public.respects for select to authenticated using (true);
-- aucune écriture directe : tout passe par fs_toggle_respect

alter table public.notifications drop constraint if exists notifications_type_check;
alter table public.notifications add constraint notifications_type_check check (type = any (array[
  'story_like','like','comment','follow','reaction','reply','comment_like','message','announcement',
  'partner_request','partner_accept','respect']));

-- Pourquoi un membre ne peut pas (encore) donner son respect : null = il peut
create or replace function public.fs_respect_block(uid uuid) returns text
language sql stable security definer set search_path = public, auth as $$
  select case
    when uid is null then 'invalid'
    when public.fs_is_banned(uid) then 'banned'
    when coalesce((select created_at from auth.users where id = uid),
                  (select created_at from public.profiles where id = uid), now()) > now() - interval '7 days' then 'too_new'
    when not exists(select 1 from public.posts where user_id = uid)
     and not exists(select 1 from public.fs_activity_days where user_id = uid and kind = 'post') then 'no_post'
    else null end
$$;
revoke execute on function public.fs_respect_block(uuid) from public, anon, authenticated;

create or replace function public.fs_respect_info(pid uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare me uuid := auth.uid(); n int;
begin
  select count(*) into n from public.respects where receiver = pid;
  return jsonb_build_object('count', n, 'validated', n >= 25, 'threshold', 25,
    'given', exists(select 1 from public.respects where giver = me and receiver = pid),
    'block', public.fs_respect_block(me));
end $$;
revoke execute on function public.fs_respect_info(uuid) from public, anon;
grant execute on function public.fs_respect_info(uuid) to authenticated;

create or replace function public.fs_toggle_respect(target uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); why text;
begin
  if me is null or target is null or target = me
     or not exists(select 1 from public.profiles where id = target) then
    return jsonb_build_object('status', 'invalid');
  end if;
  if exists(select 1 from public.respects where giver = me and receiver = target) then
    delete from public.respects where giver = me and receiver = target;
    delete from public.notifications where user_id = target and actor_id = me and type = 'respect';
  else
    why := public.fs_respect_block(me);
    if why is not null then return jsonb_build_object('status', why); end if;
    if public.fs_blocked(me, target) or public.fs_blocked(target, me) then
      return jsonb_build_object('status', 'blocked');
    end if;
    if (select count(*) from public.respects where giver = me and created_at > now() - interval '1 hour') >= 30 then
      return jsonb_build_object('status', 'slow');
    end if;
    insert into public.respects(giver, receiver) values (me, target);
    perform public.fs_push(target, me, 'respect', null, null, 'follows', true);
  end if;
  return jsonb_build_object('status', 'ok') || public.fs_respect_info(target);
end $$;
revoke execute on function public.fs_toggle_respect(uuid) from public, anon;
grant execute on function public.fs_toggle_respect(uuid) to authenticated;
