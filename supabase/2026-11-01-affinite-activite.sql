-- ===== Freestyle : affinité des partenaires calculée sur leur activité commune =====
-- Score sur 100, calculé sur les 30 derniers jours (heure de Paris) :
--   étoiles (jours d'affilée où les deux se sont écrit) .... 30 pts  (3 pts par jour, max 10 jours)
--   jours où les deux se sont écrit ...................... 20 pts  (1 pt par jour)
--   likes sur les publications de l'autre ................ 15 pts  (1,5 pt par like)
--   commentaires sur les publications de l'autre ......... 15 pts  (3 pts par commentaire)
--   stickers + likes de stories de l'autre ............... 10 pts  (2 pts chacun)
--   abonnement mutuel (5) ou à sens unique (2) ............ 5 pts
--   ancienneté du duo ..................................... 5 pts  (1 pt tous les 6 jours)
create or replace function public.fs_partner_affinity(a uuid, b uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  since timestamptz := now() - interval '30 days';
  tz text := 'Europe/Paris';
  d date; streak int := 0; both_days int := 0;
  n_likes int := 0; n_cmts int := 0; n_react int := 0; n_story int := 0; n_follow int := 0;
  duo_days int := 0; acc timestamptz;
  s_streak numeric; s_days numeric; s_likes numeric; s_cmts numeric; s_misc numeric; s_follow numeric; s_age numeric; total int;
begin
  if a is null or b is null or a = b then return null; end if;
  -- seuls les partenaires acceptés ont une affinité
  select accepted_at into acc from training_partners
   where status = 'accepted' and least(requester, addressee) = least(a, b) and greatest(requester, addressee) = greatest(a, b);
  if acc is null then return null; end if;

  -- jours où les deux se sont écrit
  create temporary table if not exists _fs_days(day date primary key) on commit drop;
  delete from _fs_days;
  insert into _fs_days
    select (created_at at time zone tz)::date from messages where sender_id = a and recipient_id = b
    intersect
    select (created_at at time zone tz)::date from messages where sender_id = b and recipient_id = a;
  select count(*) into both_days from _fs_days where day > (since at time zone tz)::date;
  -- série d'étoiles : jours consécutifs jusqu'à aujourd'hui (ou hier si aujourd'hui n'est pas encore complété)
  d := (now() at time zone tz)::date;
  if not exists(select 1 from _fs_days where day = d) then d := d - 1; end if;
  while exists(select 1 from _fs_days where day = d) loop streak := streak + 1; d := d - 1; end loop;

  select count(*) into n_likes from likes l join posts p on p.id = l.post_id
   where l.created_at > since and ((l.user_id = a and p.user_id = b) or (l.user_id = b and p.user_id = a));
  select count(*) into n_cmts from comments c join posts p on p.id = c.post_id
   where c.created_at > since and ((c.user_id = a and p.user_id = b) or (c.user_id = b and p.user_id = a));
  select count(*) into n_react from post_reactions r join posts p on p.id = r.post_id
   where r.created_at > since and ((r.user_id = a and p.user_id = b) or (r.user_id = b and p.user_id = a));
  select count(*) into n_story from story_likes sl join stories s on s.id = sl.story_id
   where (sl.user_id = a and s.user_id = b) or (sl.user_id = b and s.user_id = a);
  select count(*) into n_follow from follows
   where (follower_id = a and following_id = b) or (follower_id = b and following_id = a);
  duo_days := greatest(0, floor(extract(epoch from now() - acc) / 86400))::int;

  s_streak := least(30, streak * 3);
  s_days   := least(20, both_days);
  s_likes  := least(15, n_likes * 1.5);
  s_cmts   := least(15, n_cmts * 3);
  s_misc   := least(10, (n_react + n_story) * 2);
  s_follow := case when n_follow >= 2 then 5 when n_follow = 1 then 2 else 0 end;
  s_age    := least(5, floor(duo_days / 6.0));
  total := least(100, round(s_streak + s_days + s_likes + s_cmts + s_misc + s_follow + s_age))::int;

  return jsonb_build_object('score', total,
    'streak', streak, 'days', both_days, 'likes', n_likes, 'comments', n_cmts,
    'reactions', n_react + n_story, 'follow', n_follow, 'duo_days', duo_days,
    'parts', jsonb_build_object('streak', s_streak, 'days', s_days, 'likes', s_likes, 'comments', s_cmts,
      'reactions', s_misc, 'follow', s_follow, 'age', s_age));
end $$;
revoke execute on function public.fs_partner_affinity(uuid, uuid) from public, anon;
grant execute on function public.fs_partner_affinity(uuid, uuid) to authenticated;
