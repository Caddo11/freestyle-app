-- ===== Freestyle : délai de 7 jours entre deux partenaires d'entraînement =====
-- Quand un partenariat prend fin, les deux membres doivent attendre 7 jours avant
-- d'envoyer ou d'accepter une nouvelle demande.

create table if not exists public.partner_cooldowns(
  user_id uuid primary key references public.profiles(id) on delete cascade,
  until timestamptz not null
);
alter table public.partner_cooldowns enable row level security;
drop policy if exists "delai lu par soi" on public.partner_cooldowns;
create policy "delai lu par soi" on public.partner_cooldowns for select using (user_id = auth.uid());

create or replace function public.fs_in_cooldown(uid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists(select 1 from public.partner_cooldowns where user_id = uid and until > now())
$$;

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
  if public.fs_in_cooldown(me) then return 'cooldown'; end if;
  if public.fs_in_cooldown(target) then return 'target_cooldown'; end if;
  select id into rev from public.training_partners
    where requester = target and addressee = me and status = 'pending';
  if rev is not null then
    return public.fs_partner_respond(rev, true);
  end if;
  if exists(select 1 from public.training_partners
      where least(requester, addressee) = least(me, target) and greatest(requester, addressee) = greatest(me, target)) then
    return 'exists';
  end if;
  delete from public.training_partners where requester = me and status = 'pending';
  insert into public.training_partners(requester, addressee) values (me, target);
  perform public.fs_push(target, me, 'partner_request', null, null, 'follows', true);
  return 'sent';
end $$;

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
  if public.fs_in_cooldown(me) then return 'cooldown'; end if;
  if public.fs_in_cooldown(r.requester) then return 'target_cooldown'; end if;
  update public.training_partners set status = 'accepted', accepted_at = now() where id = rid;
  delete from public.training_partners where status = 'pending'
    and (requester in (me, r.requester) or addressee in (me, r.requester));
  delete from public.notifications where user_id = me and actor_id = r.requester and type = 'partner_request';
  perform public.fs_push(r.requester, me, 'partner_accept', null, null, 'follows', true);
  return 'accepted';
end $$;

create or replace function public.fs_partner_end(rid uuid) returns text
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); r public.training_partners;
begin
  select * into r from public.training_partners where id = rid and me in (requester, addressee);
  if r.id is null then return 'invalid'; end if;
  delete from public.training_partners where id = rid;
  if r.status = 'accepted' then
    insert into public.partner_cooldowns(user_id, until) values
      (r.requester, now() + interval '7 days'), (r.addressee, now() + interval '7 days')
      on conflict (user_id) do update set until = excluded.until;
  end if;
  return 'ended';
end $$;

grant execute on function public.fs_in_cooldown(uuid) to authenticated;
