-- ===== Freestyle : l'administrateur peut checker sans restriction (ni 7 jours, ni post, ni limite) =====
create or replace function public.fs_respect_block(uid uuid) returns text
language sql stable security definer set search_path = public, auth as $$
  select case
    when uid is null then 'invalid'
    when uid = auth.uid() and public.fs_is_admin() then null
    when public.fs_is_banned(uid) then 'banned'
    when coalesce((select created_at from auth.users where id = uid),
                  (select created_at from public.profiles where id = uid), now()) > now() - interval '7 days' then 'too_new'
    when not exists(select 1 from public.posts where user_id = uid)
     and not exists(select 1 from public.fs_activity_days where user_id = uid and kind = 'post') then 'no_post'
    else null end
$$;
revoke execute on function public.fs_respect_block(uuid) from public, anon, authenticated;

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
    if not public.fs_is_admin() then
      if public.fs_blocked(me, target) or public.fs_blocked(target, me) then
        return jsonb_build_object('status', 'blocked');
      end if;
      if (select count(*) from public.respects where giver = me and created_at > now() - interval '1 hour') >= 30 then
        return jsonb_build_object('status', 'slow');
      end if;
    end if;
    insert into public.respects(giver, receiver) values (me, target);
    perform public.fs_push(target, me, 'respect', null, null, 'follows', true);
  end if;
  return jsonb_build_object('status', 'ok') || public.fs_respect_info(target);
end $$;
revoke execute on function public.fs_toggle_respect(uuid) from public, anon;
grant execute on function public.fs_toggle_respect(uuid) to authenticated;
