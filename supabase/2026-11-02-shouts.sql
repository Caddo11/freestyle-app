-- ===== Freestyle : les Shouts (posts texte de 280 caractères dans le fil) =====
alter table public.posts drop constraint if exists posts_kind_check;
alter table public.posts add constraint posts_kind_check check (kind = any (array['photo', 'clip', 'shout']));
alter table public.posts drop constraint if exists posts_shout_check;
alter table public.posts add constraint posts_shout_check check (
  kind <> 'shout' or (char_length(btrim(coalesce(caption, ''))) between 1 and 280
                      and (media is null or jsonb_array_length(media) = 0))) not valid;

-- Anti-spam : 10 shouts par heure maximum, pas de lien
create or replace function public.fs_shout_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.kind <> 'shout' then return new; end if;
  if new.caption ~* '(https?://|www\.|\.(com|fr|net|org|io|gg|me|ly)\M)' then
    raise exception 'LIEN_INTERDIT' using errcode = 'P0001';
  end if;
  if not public.fs_is_admin() and (select count(*) from public.posts where user_id = new.user_id and kind = 'shout'
        and created_at > now() - interval '1 hour') >= 10 then
    raise exception 'SHOUT_TROP' using errcode = 'P0001';
  end if;
  new.media := '[]'::jsonb; new.stickers := coalesce(new.stickers, '[]'::jsonb); new.perf := null;
  return new;
end $$;
drop trigger if exists fs_shout_guard_trg on public.posts;
create trigger fs_shout_guard_trg before insert on public.posts
  for each row execute function public.fs_shout_guard();
