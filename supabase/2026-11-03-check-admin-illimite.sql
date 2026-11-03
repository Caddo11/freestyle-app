-- ===== Freestyle : check définitif pour les membres, illimité et retirable pour l'administrateur =====
create or replace function public.fs_toggle_respect(target uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); why text;
begin
  if me is null or target is null or target = me
     or not exists(select 1 from public.profiles where id = target) then
    return jsonb_build_object('status', 'invalid');
  end if;
  if exists(select 1 from public.respects where giver = me and receiver = target) then
    -- un check est définitif, sauf pour l'administrateur qui peut le retirer
    if public.fs_is_admin() then
      delete from public.respects where giver = me and receiver = target;
      delete from public.notifications where user_id = target and actor_id = me and type = 'respect';
      return jsonb_build_object('status', 'removed') || public.fs_respect_info(target);
    end if;
    return jsonb_build_object('status', 'already') || public.fs_respect_info(target);
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
-- personne ne peut supprimer un check directement
revoke delete on public.respects from anon, authenticated;
select 'ok' as check_definitif;
