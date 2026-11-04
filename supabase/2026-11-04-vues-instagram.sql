-- ===== Freestyle : vues comme sur Instagram =====
-- · une vue = le post / message / clip réellement affiché (moitié de l'écran ≥ 1 s, clip lu ≥ 1,5 s)
-- · « vues » compte aussi les revisionnages, mais 1 fois par membre toutes les 30 minutes au plus
-- · « comptes touchés » (reach) = membres différents
-- · les vues de l'auteur sur son propre contenu ne comptent pas
create or replace function public.fs_view_posts(ids uuid[]) returns void
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); pid uuid; isnew boolean; again boolean;
begin
  if me is null or ids is null then return; end if;
  foreach pid in array ids[1:40] loop
    if not exists(select 1 from public.posts where id = pid and user_id <> me) then continue; end if;
    isnew := false; again := false;
    insert into public.post_views(post_id, user_id) values (pid, me)
      on conflict (post_id, user_id) do nothing returning true into isnew;
    if isnew is null then
      update public.post_views set n = n + 1, last_at = now()
        where post_id = pid and user_id = me and last_at < now() - interval '30 minutes'
        returning true into again;
    end if;
    if coalesce(isnew,false) or coalesce(again,false) then
      insert into public.post_view_counts(post_id, views, reach) values (pid, 1, case when coalesce(isnew,false) then 1 else 0 end)
        on conflict (post_id) do update set views = post_view_counts.views + 1,
          reach = post_view_counts.reach + case when coalesce(isnew,false) then 1 else 0 end;
    end if;
  end loop;
end $$;
revoke execute on function public.fs_view_posts(uuid[]) from public, anon;
grant execute on function public.fs_view_posts(uuid[]) to authenticated;
