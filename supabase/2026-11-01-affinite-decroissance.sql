-- ===== Freestyle : affinité qui monte avec l'activité quotidienne et baisse chaque jour sans activité =====
-- Calcul jour par jour sur les 30 derniers jours (heure de Paris). Pour chaque catégorie :
--   un jour AVEC activité  -> la catégorie gagne des points (plafonnés)
--   un jour SANS activité  -> la catégorie perd des points (jamais sous 0)
--
--   étoiles ........ 3 pts par jour de série, retombe à 0 dès qu'un jour passe sans échange (max 30)
--   messages ....... +2 le jour où les deux s'écrivent, -2 sinon                         (max 20)
--   likes .......... +1,5 par like sur une publication de l'autre, -1 par jour sans like  (max 15)
--   commentaires ... +3 par commentaire chez l'autre, -1 par jour sans commentaire       (max 15)
--   stickers/stories +2 chacun, -1 par jour sans                                          (max 10)
--   abonnement ..... mutuel 5, à sens unique 2 (fixe)
--   ancienneté ..... 1 pt tous les 6 jours (max 5)
create or replace function public.fs_partner_affinity(a uuid, b uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  tz text := 'Europe/Paris';
  today date := (now() at time zone tz)::date;
  d date; acc timestamptz; start_day date;
  streak int := 0; n_follow int := 0; duo_days int := 0;
  v_msg numeric := 0; v_like numeric := 0; v_cmt numeric := 0; v_misc numeric := 0;
  c_msg boolean; c_like int; c_cmt int; c_misc int;
  t_days int := 0; t_likes int := 0; t_cmts int := 0; t_misc int := 0;
  s_streak numeric; s_follow numeric; s_age numeric; total int;
begin
  if a is null or b is null or a = b then return null; end if;
  select accepted_at into acc from training_partners
   where status = 'accepted' and least(requester, addressee) = least(a, b) and greatest(requester, addressee) = greatest(a, b);
  if acc is null then return null; end if;
  start_day := today - 29;

  -- jours où les deux se sont écrit
  create temporary table if not exists _fs_days(day date primary key) on commit drop;
  delete from _fs_days where true;
  insert into _fs_days
    select (created_at at time zone tz)::date from messages where sender_id = a and recipient_id = b
    intersect
    select (created_at at time zone tz)::date from messages where sender_id = b and recipient_id = a;
  -- activité par jour (likes, commentaires, stickers, likes de stories)
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
    select (s.created_at at time zone tz)::date, 'misc', count(*) from story_likes sl join stories s on s.id = sl.story_id
     where s.created_at > now() - interval '31 days' and ((sl.user_id = a and s.user_id = b) or (sl.user_id = b and s.user_id = a)) group by 1;

  -- jour par jour : on gagne avec l'activité, on perd sans activité
  d := start_day;
  while d <= today loop
    c_msg  := exists(select 1 from _fs_days where day = d);
    select coalesce(sum(n),0) into c_like from _fs_act where day = d and kind = 'like';
    select coalesce(sum(n),0) into c_cmt  from _fs_act where day = d and kind = 'cmt';
    select coalesce(sum(n),0) into c_misc from _fs_act where day = d and kind = 'misc';
    -- le jour en cours ne fait pas perdre de points tant qu'il n'est pas terminé
    if c_msg then v_msg := least(20, v_msg + 2); t_days := t_days + 1; elsif d < today then v_msg := greatest(0, v_msg - 2); end if;
    if c_like > 0 then v_like := least(15, v_like + c_like * 1.5); t_likes := t_likes + c_like; elsif d < today then v_like := greatest(0, v_like - 1); end if;
    if c_cmt > 0 then v_cmt := least(15, v_cmt + c_cmt * 3); t_cmts := t_cmts + c_cmt; elsif d < today then v_cmt := greatest(0, v_cmt - 1); end if;
    if c_misc > 0 then v_misc := least(10, v_misc + c_misc * 2); t_misc := t_misc + c_misc; elsif d < today then v_misc := greatest(0, v_misc - 1); end if;
    d := d + 1;
  end loop;

  -- série d'étoiles
  d := today;
  if not exists(select 1 from _fs_days where day = d) then d := d - 1; end if;
  while exists(select 1 from _fs_days where day = d) loop streak := streak + 1; d := d - 1; end loop;

  select count(*) into n_follow from follows
   where (follower_id = a and following_id = b) or (follower_id = b and following_id = a);
  duo_days := greatest(0, floor(extract(epoch from now() - acc) / 86400))::int;

  s_streak := least(30, streak * 3);
  s_follow := case when n_follow >= 2 then 5 when n_follow = 1 then 2 else 0 end;
  s_age    := least(5, floor(duo_days / 6.0));
  total := least(100, round(s_streak + v_msg + v_like + v_cmt + v_misc + s_follow + s_age))::int;

  return jsonb_build_object('score', total,
    'streak', streak, 'days', t_days, 'likes', t_likes, 'comments', t_cmts,
    'reactions', t_misc, 'follow', n_follow, 'duo_days', duo_days,
    'today', jsonb_build_object('msg', exists(select 1 from _fs_days where day = today),
      'like', exists(select 1 from _fs_act where day = today and kind = 'like'),
      'cmt', exists(select 1 from _fs_act where day = today and kind = 'cmt'),
      'misc', exists(select 1 from _fs_act where day = today and kind = 'misc')),
    'parts', jsonb_build_object('streak', s_streak, 'days', v_msg, 'likes', v_like, 'comments', v_cmt,
      'reactions', v_misc, 'follow', s_follow, 'age', s_age));
end $$;
revoke execute on function public.fs_partner_affinity(uuid, uuid) from public, anon;
grant execute on function public.fs_partner_affinity(uuid, uuid) to authenticated;
