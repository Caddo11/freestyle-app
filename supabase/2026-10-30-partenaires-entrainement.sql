-- ===== Freestyle : partenaire d'entraînement (validé par les deux membres) =====
-- Un membre a au plus 1 partenaire d'entraînement accepté et 1 demande envoyée en attente.

create table if not exists public.training_partners(
  id uuid primary key default gen_random_uuid(),
  requester uuid not null references public.profiles(id) on delete cascade,
  addressee uuid not null references public.profiles(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending','accepted')),
  created_at timestamptz not null default now(),
  accepted_at timestamptz,
  check (requester <> addressee)
);
create unique index if not exists training_partners_pair_idx
  on public.training_partners (least(requester, addressee), greatest(requester, addressee));
create index if not exists training_partners_req_idx on public.training_partners(requester);
create index if not exists training_partners_addr_idx on public.training_partners(addressee);

alter table public.training_partners enable row level security;
drop policy if exists "partenaires lisibles" on public.training_partners;
create policy "partenaires lisibles" on public.training_partners for select
  using (status = 'accepted' or auth.uid() in (requester, addressee));
-- aucune écriture directe : tout passe par les fonctions ci-dessous

-- Notifications : deux nouveaux types
alter table public.notifications drop constraint if exists notifications_type_check;
alter table public.notifications add constraint notifications_type_check check (type = any (array[
  'story_like','like','comment','follow','reaction','reply','comment_like','message','announcement',
  'partner_request','partner_accept']));

create or replace function public.fs_has_partner(uid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists(select 1 from public.training_partners
    where status = 'accepted' and uid in (requester, addressee))
$$;

-- Envoyer une demande (si l'autre m'avait déjà fait une demande, ça l'accepte directement)
create or replace function public.fs_partner_request(target uuid) returns text
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); rev uuid;
begin
  if me is null or target is null or target = me then return 'invalid'; end if;
  if not exists(select 1 from public.profiles where id = target) then return 'invalid'; end if;
  if public.fs_is_banned(me) then return 'banned'; end if;
  if public.fs_blocked(me, target) or public.fs_blocked(target, me) then return 'blocked'; end if;
  if public.fs_has_partner(me) then return 'me_taken'; end if;
  if public.fs_has_partner(target) then return 'target_taken'; end if;
  select id into rev from public.training_partners
    where requester = target and addressee = me and status = 'pending';
  if rev is not null then
    return public.fs_partner_respond(rev, true);
  end if;
  if exists(select 1 from public.training_partners
      where least(requester, addressee) = least(me, target) and greatest(requester, addressee) = greatest(me, target)) then
    return 'exists';
  end if;
  -- une seule demande envoyée à la fois : la précédente est remplacée
  delete from public.training_partners where requester = me and status = 'pending';
  insert into public.training_partners(requester, addressee) values (me, target);
  perform public.fs_push(target, me, 'partner_request', null, null, 'follows', true);
  return 'sent';
end $$;

-- Accepter ou refuser une demande reçue
create or replace function public.fs_partner_respond(rid uuid, accept boolean) returns text
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); r public.training_partners;
begin
  select * into r from public.training_partners where id = rid and addressee = me and status = 'pending';
  if r.id is null then return 'invalid'; end if;
  if not accept then
    delete from public.training_partners where id = rid;
    delete from public.notifications where user_id = me and actor_id = r.requester and type = 'partner_request';
    return 'declined';
  end if;
  if public.fs_has_partner(me) or public.fs_has_partner(r.requester) then return 'taken'; end if;
  update public.training_partners set status = 'accepted', accepted_at = now() where id = rid;
  -- les autres demandes en attente des deux membres n'ont plus lieu d'être
  delete from public.training_partners where status = 'pending'
    and (requester in (me, r.requester) or addressee in (me, r.requester));
  delete from public.notifications where user_id = me and actor_id = r.requester and type = 'partner_request';
  perform public.fs_push(r.requester, me, 'partner_accept', null, null, 'follows', true);
  return 'accepted';
end $$;

-- Annuler une demande envoyée ou mettre fin au partenariat
create or replace function public.fs_partner_end(rid uuid) returns text
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); n int;
begin
  delete from public.training_partners where id = rid and me in (requester, addressee);
  get diagnostics n = row_count;
  return case when n > 0 then 'ended' else 'invalid' end;
end $$;

revoke execute on function public.fs_partner_request(uuid) from public, anon;
revoke execute on function public.fs_partner_respond(uuid, boolean) from public, anon;
revoke execute on function public.fs_partner_end(uuid) from public, anon;
grant execute on function public.fs_partner_request(uuid) to authenticated;
grant execute on function public.fs_partner_respond(uuid, boolean) to authenticated;
grant execute on function public.fs_partner_end(uuid) to authenticated;
grant execute on function public.fs_has_partner(uuid) to authenticated;

-- ===== Publications épinglées sur le profil (3 maximum) =====
alter table public.posts add column if not exists pinned_at timestamptz;
create index if not exists posts_pinned_idx on public.posts(user_id, pinned_at) where pinned_at is not null;

create or replace function public.fs_pin_post(pid uuid, pin boolean) returns text
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if not exists(select 1 from public.posts where id = pid and user_id = me) then return 'invalid'; end if;
  if not pin then update public.posts set pinned_at = null where id = pid; return 'unpinned'; end if;
  if (select count(*) from public.posts where user_id = me and pinned_at is not null and id <> pid) >= 3 then return 'full'; end if;
  update public.posts set pinned_at = now() where id = pid;
  return 'pinned';
end $$;
revoke execute on function public.fs_pin_post(uuid, boolean) from public, anon;
grant execute on function public.fs_pin_post(uuid, boolean) to authenticated;
