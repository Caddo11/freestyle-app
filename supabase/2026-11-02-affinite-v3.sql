-- ===== Freestyle : affinité v3 — une seule logique : se parler régulièrement =====
-- Score sur 100, recalculé sur les 30 derniers jours (heure de Paris) :
--   Régularité ...... 2 pts par jour où les deux se sont écrit                     (max 60, soit 30 jours)
--   Étoiles ......... 2 pts par jour de série en cours (jours d'affilée d'échange) (max 30, soit 15 jours)
--   Soutien ......... 1 pt par jour où l'un a liké / commenté / réagi chez l'autre (max 10)
-- Rien d'artificiel : un jour sans échange sort tout seul de la fenêtre de 30 jours et casse la série.
-- Le soutien n'est compté que si l'un des deux a publié quelque chose sur la période ;
-- sinon il est ignoré et le score est ramené sur 100 (personne n'est pénalisé faute de publication).
-- Plus d'abonnement ni d'ancienneté dans le calcul.
create or replace function public.fs_partner_affinity(a uuid, b uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  tz text := 'Europe/Paris';
  today date := (now() at time zone tz)::date;
  start_day date := today - 29;
  d date; acc timestamptz;
  n_days int; n_support int; streak int := 0; best int := 0; run int := 0;
  has_posts boolean; talked_today boolean;
  s_reg numeric; s_streak numeric; s_sup numeric; maxi numeric; total int;
begin
  if a is null or b is null or a = b then return null; end if;
  select accepted_at into acc from training_partners
   where status = 'accepted' and least(requester, addressee) = least(a, b) and greatest(requester, addressee) = greatest(a, b);
  if acc is null then return null; end if;

  -- jours d'échange : les deux se sont écrit le même jour
  create temporary table if not exists _fs_days(day date primary key) on commit drop;
  delete from _fs_days where true;
  insert into _fs_days
    select (created_at at time zone tz)::date from messages where sender_id = a and recipient_id = b and created_at > now() - interval '62 days'
    intersect
    select (created_at at time zone tz)::date from messages where sender_id = b and recipient_id = a and created_at > now() - interval '62 days';

  select count(*) into n_days from _fs_days where day >= start_day;
  talked_today := exists(select 1 from _fs_days where day = today);

  -- série en cours (aujourd'hui n'est pas encore perdu tant qu'il n'est pas fini)
  d := case when talked_today then today else today - 1 end;
  while exists(select 1 from _fs_days where day = d) loop streak := streak + 1; d := d - 1; end loop;
  -- meilleure série sur 60 jours
  d := today - 59;
  while d <= today loop
    if exists(select 1 from _fs_days where day = d) then run := run + 1; best := greatest(best, run); else run := 0; end if;
    d := d + 1;
  end loop;

  -- jours de soutien (likes, commentaires, réactions, likes de story, dans un sens ou dans l'autre)
  select count(distinct day) into n_support from (
    select (l.created_at at time zone tz)::date as day from likes l join posts p on p.id = l.post_id
     where l.created_at > now() - interval '31 days' and ((l.user_id = a and p.user_id = b) or (l.user_id = b and p.user_id = a))
    union
    select (c.created_at at time zone tz)::date from comments c join posts p on p.id = c.post_id
     where c.created_at > now() - interval '31 days' and ((c.user_id = a and p.user_id = b) or (c.user_id = b and p.user_id = a))
    union
    select (r.created_at at time zone tz)::date from post_reactions r join posts p on p.id = r.post_id
     where r.created_at > now() - interval '31 days' and ((r.user_id = a and p.user_id = b) or (r.user_id = b and p.user_id = a))
    union
    select day from fs_story_like_log where (liker = a and owner = b) or (liker = b and owner = a)
  ) x where day >= start_day;

  has_posts := n_support > 0
    or exists(select 1 from fs_activity_days where user_id in (a, b) and day >= start_day)
    or exists(select 1 from posts where user_id in (a, b) and created_at > now() - interval '30 days');

  s_reg    := least(60, n_days * 2);
  s_streak := least(30, streak * 2);
  s_sup    := case when has_posts then least(10, n_support) else 0 end;
  maxi     := case when has_posts then 100 else 90 end;
  total    := least(100, round((s_reg + s_streak + s_sup) * 100 / maxi))::int;

  return jsonb_build_object('v', 3, 'score', total,
    'days', n_days, 'streak', streak, 'best', best, 'support', n_support, 'support_counted', has_posts,
    'talked_today', talked_today, 'at_risk', streak > 0 and not talked_today,
    'duo_days', greatest(0, floor(extract(epoch from now() - acc) / 86400))::int,
    'parts', jsonb_build_object('regularity', s_reg, 'streak', s_streak, 'support', s_sup));
end $$;
revoke execute on function public.fs_partner_affinity(uuid, uuid) from public, anon;
grant execute on function public.fs_partner_affinity(uuid, uuid) to authenticated;
