-- ===== Freestyle : garder un vocal / une photo / une vidéo dans la conversation =====
-- Un message enregistré n'a plus de date d'expiration : il n'est donc plus supprimé.
alter table public.messages add column if not exists kept_by uuid references public.profiles(id) on delete set null;

create or replace function public.fs_dm_keep(mid uuid, keep boolean) returns text
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); m public.messages;
begin
  select * into m from public.messages where id = mid and me in (sender_id, recipient_id);
  if m.id is null or m.media is null then return 'invalid'; end if;
  if keep then
    if m.expires_at is not null and m.expires_at <= now() then return 'expired'; end if;
    update public.messages set expires_at = null, kept_by = me where id = mid;
    return 'kept';
  else
    -- on retire l'enregistrement : le message reprend son délai de 24 h depuis l'envoi
    update public.messages set expires_at = greatest(m.created_at + interval '24 hours', now() + interval '1 minute'), kept_by = null where id = mid;
    return 'unkept';
  end if;
end $$;
revoke execute on function public.fs_dm_keep(uuid, boolean) from public, anon;
grant execute on function public.fs_dm_keep(uuid, boolean) to authenticated;
