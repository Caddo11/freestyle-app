-- ===== Freestyle : algorithme du fil =====
-- Chaque post reçoit un score personnalisé pour la personne qui regarde :
--   fraîcheur ...... 100 points à la publication, divisé par 2 toutes les 20 h
--   engagement ..... likes, commentaires (x2), réactions, enregistrements (x2), partages (x3), en échelle log
--                    + bonus si beaucoup de gens qui l'ont vu ont interagi (taux d'engagement)
--   lien ........... +70 duo d'entraînement, +45 abonnement, +15 s'il me suit aussi,
--                    jusqu'à +35 selon mes interactions récentes avec cette personne (likes, commentaires, checks)
--   sport .......... +18 si le post est dans mon sport
--   déjà vu ........ score x 0,3 (on ne revoit pas sans cesse la même chose)
--   un peu de hasard (0 à 10) pour garder un fil vivant
-- Mes propres posts de moins d'une heure passent en tête. Comptes bloqués et bannis exclus.
create or replace function public.fs_feed(sports text[] default null, lim int default 80)
returns table(id uuid, score numeric)
language sql volatile security definer set search_path = public as $$
  with me as (select auth.uid() as uid),
  my as (select p.sport from public.profiles p, me where p.id = me.uid),
  cand as (
    select x.* from public.posts x, me
     where (sports is null or x.sport = any(sports))
       and not public.fs_blocked(me.uid, x.user_id) and not public.fs_blocked(x.user_id, me.uid)
       and not public.fs_is_banned(x.user_id)
     order by x.created_at desc limit 400
  ),
  rel as (
    select c.user_id,
      (exists(select 1 from public.follows f, me where f.follower_id = me.uid and f.following_id = c.user_id)) as fol,
      (exists(select 1 from public.follows f, me where f.follower_id = c.user_id and f.following_id = me.uid)) as fol_back,
      (exists(select 1 from public.training_partners t, me where t.status = 'accepted'
          and ((t.requester = me.uid and t.addressee = c.user_id) or (t.addressee = me.uid and t.requester = c.user_id)))) as duo,
      least(35, 3 * (
        (select count(*) from public.likes l join public.posts p on p.id = l.post_id, me
          where l.user_id = me.uid and p.user_id = c.user_id and l.created_at > now() - interval '30 days')
        + 2 * (select count(*) from public.comments k join public.posts p on p.id = k.post_id, me
          where k.user_id = me.uid and p.user_id = c.user_id and k.created_at > now() - interval '30 days')
        + 4 * (select count(*) from public.respects r, me where r.giver = me.uid and r.receiver = c.user_id)
      )) as inter
    from (select distinct user_id from cand) c
  ),
  eng as (
    select c.id,
      (select count(*) from public.likes l where l.post_id = c.id) as lk,
      (select count(*) from public.comments k where k.post_id = c.id) as cm,
      (select count(*) from public.post_reactions r where r.post_id = c.id) as rc,
      (select count(*) from public.saved_posts s where s.post_id = c.id) as sv,
      (select count(*) from public.post_shares s where s.post_id = c.id) as sh,
      coalesce((select reach from public.post_view_counts v where v.post_id = c.id), 0) as reach,
      exists(select 1 from public.post_views v, me where v.post_id = c.id and v.user_id = me.uid) as seen
    from cand c
  )
  select c.id,
    round((case
      when c.user_id = (select uid from me) and c.created_at > now() - interval '1 hour' then 100000
      else (
        100 * power(0.5, extract(epoch from now() - c.created_at) / 72000.0)
        + 14 * ln(1 + e.lk + 2 * e.cm + e.rc + 2 * e.sv + 3 * e.sh)
        + case when e.reach >= 5 then least(20, 60.0 * (e.lk + e.cm) / e.reach) else 0 end
        + case when r.duo then 70 else 0 end
        + case when r.fol then 45 else 0 end
        + case when r.fol and r.fol_back then 15 else 0 end
        + r.inter
        + case when c.sport = (select sport from my) then 18 else 0 end
        + random() * 10
      ) * case when e.seen then 0.3 else 1 end
           * case when c.user_id = (select uid from me) then 0.5 else 1 end
    end)::numeric, 2) as score
  from cand c join eng e on e.id = c.id join rel r on r.user_id = c.user_id
  order by score desc
  limit greatest(1, least(coalesce(lim, 80), 150))
$$;
revoke execute on function public.fs_feed(text[], int) from public, anon;
grant execute on function public.fs_feed(text[], int) to authenticated;
