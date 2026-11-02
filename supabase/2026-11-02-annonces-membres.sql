-- ===== Freestyle : annonces proposées par les membres (validées par l'admin, visibles 7 jours) =====
--      + fichiers du stockage listables seulement par leur propriétaire et l'admin

-- ---------- Stockage : plus de liste publique de tous les fichiers ----------
-- Les photos restent visibles par leur lien public ; seule la LISTE des fichiers est restreinte.
drop policy if exists "media lisible" on storage.objects;
create policy "media lisible" on storage.objects for select
  using (bucket_id = 'media' and (public.fs_is_admin() or (storage.foldername(name))[1] = auth.uid()::text));

-- ---------- Annonces : statut, expiration ----------
alter table public.announcements add column if not exists status text not null default 'published';
alter table public.announcements drop constraint if exists announcements_status_check;
alter table public.announcements add constraint announcements_status_check check (status in ('pending', 'published'));
alter table public.announcements add column if not exists expires_at timestamptz;
alter table public.announcements add column if not exists published_at timestamptz;
update public.announcements set published_at = created_at where published_at is null and status = 'published';

alter table public.notifications drop constraint if exists notifications_type_check;
alter table public.notifications add constraint notifications_type_check check (type = any (array[
  'story_like','like','comment','follow','reaction','reply','comment_like','message','announcement',
  'partner_request','partner_accept','respect','ann_request','ann_accept','ann_refuse']));

-- Lecture : annonces publiées (non expirées) pour tous ; demandes en attente pour leur auteur et l'admin
drop policy if exists "annonces lisibles" on public.announcements;
create policy "annonces lisibles" on public.announcements for select using (
  auth.uid() is not null and (
    (status = 'published' and (expires_at is null or expires_at > now()))
    or author_id = auth.uid() or public.fs_is_admin()));

-- Écriture : tout membre peut proposer ; l'admin publie directement
drop policy if exists "annonces admin ajout" on public.announcements;
drop policy if exists "annonces ajout" on public.announcements;
create policy "annonces ajout" on public.announcements for insert with check (author_id = auth.uid());
drop policy if exists "annonces admin suppr" on public.announcements;
create policy "annonces admin suppr" on public.announcements for delete
  using (public.fs_is_admin() or (author_id = auth.uid() and status = 'pending'));

create or replace function public.fs_announcement_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if public.fs_is_admin() then
    if tg_op = 'INSERT' then new.status := 'published'; new.published_at := now(); new.expires_at := null; end if;
    return new;
  end if;
  if tg_op = 'UPDATE' then raise exception 'ACCES_REFUSE' using errcode = 'P0001'; end if;
  if public.fs_is_banned(auth.uid()) then raise exception 'COMPTE_BANNI' using errcode = 'P0001'; end if;
  if exists(select 1 from public.announcements where author_id = auth.uid() and status = 'pending') then
    raise exception 'ANNONCES_EN_ATTENTE' using errcode = 'P0001';
  end if;
  new.status := 'pending'; new.published_at := null; new.expires_at := null; new.created_at := now();
  return new;
end $$;
drop trigger if exists fs_announcement_guard_trg on public.announcements;
create trigger fs_announcement_guard_trg before insert or update on public.announcements
  for each row execute function public.fs_announcement_guard();

-- Pings : demande -> admins ; publication -> tout le monde
create or replace function public.fs_notify_announcement() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'pending' then
    insert into public.notifications(user_id, actor_id, type, text)
      select a.user_id, new.author_id, 'ann_request', left(new.title, 80) from public.admins a where a.user_id <> new.author_id;
    return new;
  end if;
  if tg_op = 'INSERT' or (tg_op = 'UPDATE' and old.status = 'pending' and new.status = 'published') then
    insert into public.notifications(user_id, actor_id, type, text)
    select p.id, new.author_id, 'announcement', left(new.title, 80)
    from public.profiles p
    where p.id <> new.author_id and coalesce(p.onboarded, false)
      and public.fs_notif_on(p.id, 'announcements') and not public.fs_is_banned(p.id);
  end if;
  return new;
end $$;
drop trigger if exists fs_announce_trg on public.announcements;
create trigger fs_announce_trg after insert or update of status on public.announcements
  for each row execute function public.fs_notify_announcement();

-- L'admin accepte (publiée 7 jours) ou refuse (supprimée)
create or replace function public.fs_review_announcement(aid uuid, accept boolean) returns text
language plpgsql security definer set search_path = public as $$
declare a public.announcements;
begin
  if not public.fs_is_admin() then return 'denied'; end if;
  select * into a from public.announcements where id = aid and status = 'pending';
  if a.id is null then return 'gone'; end if;
  delete from public.notifications where type = 'ann_request' and actor_id = a.author_id and text = left(a.title, 80);
  if accept then
    update public.announcements set status = 'published', published_at = now(), expires_at = now() + interval '7 days' where id = aid;
    insert into public.notifications(user_id, actor_id, type, text) values (a.author_id, auth.uid(), 'ann_accept', left(a.title, 80));
    return 'published';
  else
    delete from public.announcements where id = aid;
    insert into public.notifications(user_id, actor_id, type, text) values (a.author_id, auth.uid(), 'ann_refuse', left(a.title, 80));
    return 'refused';
  end if;
end $$;
revoke execute on function public.fs_review_announcement(uuid, boolean) from public, anon;
grant execute on function public.fs_review_announcement(uuid, boolean) to authenticated;

-- Annonces expirées effacées toutes les heures
select cron.unschedule('purge-annonces') where exists (select 1 from cron.job where jobname = 'purge-annonces');
select cron.schedule('purge-annonces', '47 * * * *', $$delete from public.announcements where expires_at is not null and expires_at < now()$$);
