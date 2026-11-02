-- ===== Freestyle : affinité v4 — les posts comptent aussi, et peuvent faire baisser =====
-- Score sur 100, sur les 30 derniers jours (heure de Paris) :
--   Jours d'échange .. 2 pts par jour où les deux se sont écrit                  (max 50)
--   Étoiles .......... 2 pts par jour de série d'affilée                         (max 30)
--   Posts soutenus ... part des posts et flashs de l'un que l'autre a liké,
--                      commenté ou réagi                                         (max 20)
-- Un post / flash laissé 48 h sans like, commentaire ni réaction est « ignoré » et fait baisser la part.
-- Seuls les posts publiés depuis la formation du duo comptent. S'il n'y a aucun post sur la période,
-- la catégorie n'est pas comptée et le score est ramené sur 100.
create or replace function public.fs_partner_affinity(a uuid, b uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  tz text := 'Europe/Paris';
  today date := (now() at time zone tz)::date;
  start_day date := today - 29;
  d date; acc timestamptz;
  n_days int; streak int := 0; best int := 0; run int := 0; talked_today boolean;
  p_ok int := 0; p_missed int := 0; p_pending int := 0; miss_a int := 0; miss_b int := 0;
  pend_a int := 0; pend_b int := 0; p_total int;
  s_reg numeric; s_streak numeric; s_posts numeric; maxi numeric; total int;
begin
  if a is null or b is null or a = b then return null; end if;
  select accepted_at into acc from training_partners
   where status = 'accepted' and least(requester, addressee) = least(a, b) and greatest(requester, addressee) = greatest(a, b);
  if acc is null then return null; end if;

  create temporary table if not exists _fs_days(day date primary key) on commit drop;
  delete from _fs_days where true;
  insert into _fs_days
    select (created_at at time zone tz)::date from messages where sender_id = a and recipient_id = b and created_at > now() - interval '62 days'
    intersect
    select (created_at at time zone tz)::date from messages where sender_id = b and recipient_id = a and created_at > now() - interval '62 days';

  select count(*) into n_days from _fs_days where day >= start_day;
  talked_today := exists(select 1 from _fs_days where day = today);
  d := case when talked_today then today else today - 1 end;
  while exists(select 1 from _fs_days where day = d) loop streak := streak + 1; d := d - 1; end loop;
  d := today - 59;
  while d <= today loop
    if exists(select 1 from _fs_days where day = d) then run := run + 1; best := greatest(best, run); else run := 0; end if;
    d := d + 1;
  end loop;

  -- posts et flashs de chacun depuis la formation du duo, et réaction de l'autre
  -- owner = auteur ; le « fautif » d'un post ignoré est l'autre membre
  create temporary table if not exists _fs_items(owner uuid, created timestamptz, ok boolean) on commit drop;
  delete from _fs_items where true;
  insert into _fs_items
    select p.user_id, p.created_at,
      exists(select 1 from likes l where l.post_id = p.id and l.user_id = case when p.user_id = a then b else a end)
      or exists(select 1 from comments c where c.post_id = p.id and c.user_id = case when p.user_id = a then b else a end)
      or exists(select 1 from post_reactions r where r.post_id = p.id and r.user_id = case when p.user_id = a then b else a end)
    from posts p
    where p.user_id in (a, b) and p.created_at > now() - interval '30 days' and p.created_at >= acc
    union all
    select f.user_id, (f.day::timestamp + interval '12 hours') at time zone tz,
      exists(select 1 from fs_story_like_log s where s.owner = f.user_id and s.liker = case when f.user_id = a then b else a end and s.day between f.day and f.day + 1)
    from fs_activity_days f
    where f.user_id in (a, b) and f.kind = 'story' and f.day >= start_day and f.day >= (acc at time zone tz)::date;

  select count(*) filter (where ok),
         count(*) filter (where not ok and created < now() - interval '48 hours'),
         count(*) filter (where not ok and created >= now() - interval '48 hours'),
         count(*) filter (where not ok and created < now() - interval '48 hours' and owner = b),
         count(*) filter (where not ok and created < now() - interval '48 hours' and owner = a),
         count(*) filter (where not ok and created >= now() - interval '48 hours' and owner = b),
         count(*) filter (where not ok and created >= now() - interval '48 hours' and owner = a)
    into p_ok, p_missed, p_pending, miss_a, miss_b, pend_a, pend_b
    from _fs_items;
  p_total := p_ok + p_missed;

  s_reg    := least(50, n_days * 2);
  s_streak := least(30, streak * 2);
  s_posts  := case when p_total > 0 then 20.0 * p_ok / p_total else 0 end;
  maxi     := case when p_total > 0 then 100 else 80 end;
  total    := least(100, round((s_reg + s_streak + s_posts) * 100 / maxi))::int;

  return jsonb_build_object('v', 4, 'score', total, 'a', a, 'b', b,
    'days', n_days, 'streak', streak, 'best', best,
    'talked_today', talked_today, 'at_risk', streak > 0 and not talked_today,
    'posts', jsonb_build_object('total', p_total, 'ok', p_ok, 'missed', p_missed, 'pending', p_pending,
       'missed_by', jsonb_build_object(a::text, miss_a, b::text, miss_b),
       'pending_for', jsonb_build_object(a::text, pend_a, b::text, pend_b)),
    'support_counted', p_total > 0,
    'parts', jsonb_build_object('regularity', s_reg, 'streak', s_streak, 'posts', round(s_posts, 1)));
end $$;
revoke execute on function public.fs_partner_affinity(uuid, uuid) from public, anon;
grant execute on function public.fs_partner_affinity(uuid, uuid) to authenticated;
