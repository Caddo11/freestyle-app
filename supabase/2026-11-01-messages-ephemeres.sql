-- ===== Freestyle : messages éphémères (vocal 30 s, photo, vidéo) supprimés au bout de 24 h =====

alter table public.messages add column if not exists media jsonb;
alter table public.messages add column if not exists expires_at timestamptz;
create index if not exists messages_expires_idx on public.messages(expires_at) where expires_at is not null;
-- un message avec média peut ne pas avoir de texte
alter table public.messages alter column text set default '';
alter table public.messages drop constraint if exists messages_text_check;
alter table public.messages add constraint messages_text_check check (
  char_length(text) <= 1000 and (char_length(text) >= 1 or media is not null));

-- la date d'expiration est fixée par le serveur : 24 h après l'envoi
create or replace function public.fs_dm_expiry() returns trigger
language plpgsql as $$
begin
  if new.media is not null then
    -- le fichier doit venir du dossier de l'expéditeur dans notre stockage
    if coalesce(new.media->>'type','') not in ('audio','image','video')
       or coalesce(new.media->>'url','') not like 'https://pamndgrrqpgqblrogznq.supabase.co/storage/v1/object/public/media/' || new.sender_id::text || '/%' then
      raise exception 'MEDIA_INVALIDE' using errcode = 'P0001';
    end if;
    new.expires_at := now() + interval '24 hours';
    if new.text is null then new.text := ''; end if;
  else
    new.expires_at := null;
  end if;
  return new;
end $$;
drop trigger if exists fs_dm_expiry_trg on public.messages;
create trigger fs_dm_expiry_trg before insert on public.messages
  for each row execute function public.fs_dm_expiry();

-- les messages vocaux sont acceptés dans le stockage
update storage.buckets
  set allowed_mime_types = (select array(select distinct x from unnest(coalesce(allowed_mime_types,'{}'::text[])
      || array['audio/webm','audio/mp4','audio/mpeg','audio/ogg','audio/aac','audio/x-m4a']) as x))
  where id = 'media';

-- suppression automatique toutes les 15 minutes : la fonction purge-dm efface les fichiers
-- du stockage puis les lignes de la base
select cron.unschedule('purge-dm') where exists (select 1 from cron.job where jobname = 'purge-dm');
select cron.schedule('purge-dm', '*/15 * * * *', $$
  select net.http_post(
    url := 'https://pamndgrrqpgqblrogznq.supabase.co/functions/v1/purge-dm',
    headers := '{"Content-Type":"application/json"}'::jsonb,
    body := '{}'::jsonb)
$$);
