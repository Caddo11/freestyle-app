-- ===== Freestyle : nettoyages automatiques + administrateur validé =====

-- 1. Clé serveur rangée dans le coffre-fort Supabase (Vault), reprise de la tâche des flashs,
--    pour ne plus l'écrire en clair dans de nouvelles fonctions.
select vault.create_secret(substring(command from 'sb_secret_[A-Za-z0-9_-]+'), 'fs_service_key', 'Clé serveur pour les nettoyages')
  from cron.job where jobname = 'purge-stories-hourly'
   and not exists (select 1 from vault.secrets where name = 'fs_service_key');

-- 2. Fichiers orphelins : présents dans le stockage mais utilisés nulle part (anciens avatars,
--    bannières, médias de contenus supprimés). Délai de grâce de 24 h pour les envois en cours.
create or replace function public.fs_purge_orphans() returns json
language plpgsql security definer set search_path = public, storage, vault as $$
declare names text[]; k text;
begin
  with refs as (
    select media::text as t from public.posts
    union all select media::text from public.stories
    union all select media::text from public.messages where media is not null
    union all select coalesce(avatar_url,'') || ' ' || coalesce(banner_url,'') from public.profiles
    union all select a::text from public.announcements a
    union all select g::text from public.group_messages g
  ), allrefs as (select coalesce(string_agg(t, ' '), '') as big from refs)
  select array_agg(o.name) into names
    from storage.objects o, allrefs r
   where o.bucket_id = 'media' and o.created_at < now() - interval '24 hours'
     and position(o.name in r.big) = 0 and position(replace(o.name, ' ', '%20') in r.big) = 0;
  if names is null then return json_build_object('fichiers', 0); end if;
  select decrypted_secret into k from vault.decrypted_secrets where name = 'fs_service_key';
  if k is null then return json_build_object('erreur', 'cle absente'); end if;
  perform net.http_delete(
    url := 'https://pamndgrrqpgqblrogznq.supabase.co/storage/v1/object/media',
    headers := jsonb_build_object('apikey', k, 'Authorization', 'Bearer ' || k, 'Content-Type', 'application/json'),
    body := jsonb_build_object('prefixes', to_jsonb(names)),
    timeout_milliseconds := 10000);
  return json_build_object('fichiers', array_length(names, 1));
end $$;
revoke execute on function public.fs_purge_orphans() from public, anon, authenticated;

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
select cron.schedule('purge-misc', '37 3 * * *', $$select public.fs_purge_misc(); select public.fs_purge_orphans();$$);

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
