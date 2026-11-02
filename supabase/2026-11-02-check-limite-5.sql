-- ===== Freestyle : chaque membre ne peut checker que 5 personnes (l'admin n'a pas de limite) =====
create or replace function public.fs_respect_info(pid uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare me uuid := auth.uid(); n int; adm boolean; mine int;
begin
  select count(*) into n from public.respects where receiver = pid;
  select count(*) into mine from public.respects where giver = me;
  adm := exists(select 1 from public.admins where user_id = pid);
  return jsonb_build_object('count', n, 'validated', adm or n >= 100, 'threshold', 100, 'admin', adm,
    'given', exists(select 1 from public.respects where giver = me and receiver = pid),
    'my_given', mine, 'max', case when public.fs_is_admin() then null else 5 end,
    'block', public.fs_respect_block(me));
end $$;
revoke execute on function public.fs_respect_info(uuid) from public, anon;
grant execute on function public.fs_respect_info(uuid) to authenticated;

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
      if (select count(*) from public.respects where giver = me) >= 5 then
        return jsonb_build_object('status', 'limit');
      end if;
    end if;
    insert into public.respects(giver, receiver) values (me, target);
    perform public.fs_push(target, me, 'respect', null, null, 'follows', true);
  end if;
  return jsonb_build_object('status', 'ok') || public.fs_respect_info(target);
end $$;
revoke execute on function public.fs_toggle_respect(uuid) from public, anon;
grant execute on function public.fs_toggle_respect(uuid) to authenticated;
