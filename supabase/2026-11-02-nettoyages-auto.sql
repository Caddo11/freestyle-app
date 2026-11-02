-- ===== Freestyle : nettoyages automatiques + administrateur validé =====

-- 3. Petits nettoyages de la base
create or replace function public.fs_purge_misc() returns json
language plpgsql security definer set search_path = public as $$
declare a int; b int; c int; d int;
begin
  delete from notifications where read_at is not null and created_at < now() - interval '7 days';
  get diagnostics a = row_count;
  delete from partner_cooldowns where until < now();
  get diagnostics b = row_count;
  delete from training_partners where status = 'pending' and created_at < now() - interval '30 days';
  get diagnostics c = row_count;
  delete from reports where status = 'traite' and created_at < now() - interval '90 days';
  get diagnostics d = row_count;
  return json_build_object('pings_lus', a, 'delais_expires', b, 'demandes_duo', c, 'signalements', d);
end $$;
revoke execute on function public.fs_purge_misc() from public, anon, authenticated;

select cron.unschedule('purge-misc') where exists (select 1 from cron.job where jobname = 'purge-misc');
select cron.schedule('purge-misc', '37 3 * * *', $$select public.fs_purge_misc()$$);

-- 4. Le compte administrateur est toujours « Validé par la communauté »
create or replace function public.fs_respect_info(pid uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare me uuid := auth.uid(); n int; adm boolean;
begin
  select count(*) into n from public.respects where receiver = pid;
  adm := exists(select 1 from public.admins where user_id = pid);
  return jsonb_build_object('count', n, 'validated', adm or n >= 100, 'threshold', 100, 'admin', adm,
    'given', exists(select 1 from public.respects where giver = me and receiver = pid),
    'block', public.fs_respect_block(me));
end $$;
revoke execute on function public.fs_respect_info(uuid) from public, anon;
grant execute on function public.fs_respect_info(uuid) to authenticated;
