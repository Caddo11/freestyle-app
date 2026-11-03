-- ===== Freestyle : accueil des nouveaux + parrainage =====
alter table public.profiles add column if not exists referred_by uuid references public.profiles(id) on delete set null;

alter table public.notifications drop constraint if exists notifications_type_check;
alter table public.notifications add constraint notifications_type_check check (type = any (array[
  'story_like','like','comment','follow','reaction','reply','comment_like','message','announcement',
  'partner_request','partner_accept','respect','ann_request','ann_accept','ann_refuse','referral']));

-- Le parrain ne peut pas être modifié par le membre lui-même (seulement via fs_set_referrer)
create or replace function public.fs_protect_referrer() returns trigger
language plpgsql set search_path = public as $$
begin
  if current_setting('fs.referral', true) is distinct from '1' then
    if tg_op = 'INSERT' then new.referred_by := null; else new.referred_by := old.referred_by; end if;
  end if;
  return new;
end $$;
drop trigger if exists fs_protect_referrer_trg on public.profiles;
create trigger fs_protect_referrer_trg before insert or update on public.profiles
  for each row execute function public.fs_protect_referrer();

-- Enregistre le parrain une seule fois, dans les 48 h après la création du compte
create or replace function public.fs_set_referrer(ref text) returns text
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); rid uuid; p public.profiles;
begin
  select * into p from public.profiles where id = me;
  if p.id is null or p.referred_by is not null then return 'skip'; end if;
  if p.created_at < now() - interval '48 hours' then return 'too_late'; end if;
  select id into rid from public.profiles where handle = lower(btrim(ref));
  if rid is null or rid = me then return 'invalid'; end if;
  perform set_config('fs.referral', '1', true);
  update public.profiles set referred_by = rid where id = me;
  insert into public.notifications(user_id, actor_id, type) values (rid, me, 'referral');
  insert into public.follows(follower_id, following_id) values (me, rid) on conflict do nothing;
  return 'ok';
end $$;
revoke execute on function public.fs_set_referrer(text) from public, anon;
grant execute on function public.fs_set_referrer(text) to authenticated;

-- Nombre de potes invités (affiché dans les paramètres ; 3 = badge Ambassadeur)
create or replace function public.fs_referral_count(pid uuid) returns int
language sql stable security definer set search_path = public as $$
  select count(*)::int from public.profiles where referred_by = pid and onboarded
$$;
revoke execute on function public.fs_referral_count(uuid) from public, anon;
grant execute on function public.fs_referral_count(uuid) to authenticated;

-- Suggestions de comptes pour un nouveau membre : même sport, même ville, actifs, validés
create or replace function public.fs_suggest_accounts(lim int default 12) returns table(id uuid, why text)
language sql stable security definer set search_path = public as $$
  with me as (select p.* from public.profiles p where p.id = auth.uid())
  select p.id,
    case when p.id in (select user_id from public.admins) then 'Créateur de Freestyle'
         when p.city is not null and p.city <> '' and lower(p.city) = lower((select city from me)) then 'Près de chez toi'
         when p.sport = (select sport from me) then 'Même sport'
         else 'Populaire' end as why
  from public.profiles p
  where p.onboarded and p.id <> auth.uid() and not public.fs_is_banned(p.id)
    and not exists(select 1 from public.follows f where f.follower_id = auth.uid() and f.following_id = p.id)
    and not public.fs_blocked(auth.uid(), p.id) and not public.fs_blocked(p.id, auth.uid())
  order by
    (p.id in (select user_id from public.admins))::int * 60
    + (p.city is not null and p.city <> '' and lower(p.city) = lower((select city from me)))::int * 40
    + (p.sport = (select sport from me))::int * 30
    + least(30, (select count(*) from public.follows f where f.following_id = p.id))
    + least(20, (select count(*) from public.respects r where r.receiver = p.id) / 5)
    + (exists(select 1 from public.posts x where x.user_id = p.id and x.created_at > now() - interval '14 days'))::int * 20
    desc
  limit greatest(1, least(coalesce(lim, 12), 30))
$$;
revoke execute on function public.fs_suggest_accounts(int) from public, anon;
grant execute on function public.fs_suggest_accounts(int) to authenticated;
