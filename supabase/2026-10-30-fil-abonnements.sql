-- ===== Freestyle : fil « abonnements d'abord » =====
-- Renvoie, parmi les publications données, celles que l'utilisateur connecté a déjà vues.
create or replace function public.fs_my_seen(ids uuid[]) returns setof uuid
language sql stable security definer set search_path = public as $$
  select post_id from public.post_views where user_id = auth.uid() and post_id = any(ids)
$$;
revoke execute on function public.fs_my_seen(uuid[]) from public, anon;
grant execute on function public.fs_my_seen(uuid[]) to authenticated;
