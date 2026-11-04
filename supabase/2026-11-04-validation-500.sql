-- Le « check » devient la « validation ». « Validé par la communauté » = 500 validations
-- (même palier que le niveau 3 du badge : 10 Reconnu · 100 Respecté · 500 Validé).
create or replace function public.fs_respect_info(pid uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare me uuid := auth.uid(); n int; adm boolean; mine int;
begin
  select count(*) into n from public.respects where receiver = pid;
  select count(*) into mine from public.respects where giver = me;
  adm := exists(select 1 from public.admins where user_id = pid);
  return jsonb_build_object('count', n, 'validated', adm or n >= 500, 'threshold', 500, 'admin', adm,
    'given', exists(select 1 from public.respects where giver = me and receiver = pid),
    'my_given', mine, 'max', case when public.fs_is_admin() then null else 5 end,
    'block', public.fs_respect_block(me));
end $$;
revoke execute on function public.fs_respect_info(uuid) from public, anon;
grant execute on function public.fs_respect_info(uuid) to authenticated;
