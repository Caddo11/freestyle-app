-- ===== Freestyle : « Validé par la communauté » à 100 checks de membres différents =====
create or replace function public.fs_respect_info(pid uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare me uuid := auth.uid(); n int;
begin
  select count(*) into n from public.respects where receiver = pid;
  return jsonb_build_object('count', n, 'validated', n >= 100, 'threshold', 100,
    'given', exists(select 1 from public.respects where giver = me and receiver = pid),
    'block', public.fs_respect_block(me));
end $$;
revoke execute on function public.fs_respect_info(uuid) from public, anon;
grant execute on function public.fs_respect_info(uuid) to authenticated;
