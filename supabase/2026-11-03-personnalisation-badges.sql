-- ===== Freestyle : cadres & bannières (Freestyle+) + badges =====
alter table public.profiles add column if not exists premium boolean not null default false;
alter table public.profiles add column if not exists frame text;
alter table public.profiles add column if not exists banner_style text;
alter table public.profiles drop constraint if exists profiles_frame_check;
alter table public.profiles add constraint profiles_frame_check check (frame is null or frame in ('fin','double','neon','or','chrome','pixel','feu','glace'));
alter table public.profiles drop constraint if exists profiles_banner_style_check;
alter table public.profiles add constraint profiles_banner_style_check check (banner_style is null or banner_style in ('grille','scan','aurore','carbone','chrome','braise','ocean','damier'));

-- Seuls Freestyle+ et l'admin peuvent porter un cadre ou une bannière ; « premium » n'est modifiable que par l'admin ou le serveur
create or replace function public.fs_protect_premium() returns trigger
language plpgsql set search_path = public as $$
declare ok boolean;
begin
  if current_user in ('postgres', 'service_role', 'supabase_admin') or public.fs_is_admin() then return new; end if;
  if tg_op = 'INSERT' then new.premium := false; else new.premium := old.premium; end if;
  ok := new.premium or exists(select 1 from public.admins where user_id = new.id);
  if not ok then
    if tg_op = 'INSERT' then new.frame := null; new.banner_style := null;
    else new.frame := old.frame; new.banner_style := old.banner_style; end if;
  end if;
  return new;
end $$;
drop trigger if exists fs_protect_premium_trg on public.profiles;
create trigger fs_protect_premium_trg before insert or update on public.profiles
  for each row execute function public.fs_protect_premium();

-- Badges gagnés par un membre (calculés à partir de son activité)
create or replace function public.fs_badges(pid uuid) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  p public.profiles; b text[] := '{}';
  n_posts int; n_clips int; n_shouts int; n_flash int; n_fol int; n_following int; n_cmt int;
  n_likes int; max_views int; n_checks int; n_given int; n_ref int; n_ann int;
  partner uuid; aff jsonb; best int := 0; score int := 0;
begin
  select * into p from public.profiles where id = pid;
  if p.id is null then return '[]'::jsonb; end if;
  select count(*) filter (where kind in ('photo','clip')), count(*) filter (where kind = 'clip'), count(*) filter (where kind = 'shout')
    into n_posts, n_clips, n_shouts from public.posts where user_id = pid;
  select count(*) into n_flash from public.fs_activity_days where user_id = pid and kind = 'story';
  select count(*) into n_fol from public.follows where following_id = pid;
  select count(*) into n_following from public.follows where follower_id = pid;
  select count(*) into n_cmt from public.comments where user_id = pid;
  select count(*) into n_likes from public.likes l join public.posts x on x.id = l.post_id where x.user_id = pid;
  select coalesce(max(c.views), 0) into max_views from public.post_view_counts c join public.posts x on x.id = c.post_id where x.user_id = pid;
  select count(*) into n_checks from public.respects where receiver = pid;
  select count(*) into n_given from public.respects where giver = pid;
  select count(*) into n_ref from public.profiles where referred_by = pid and onboarded;
  select count(*) into n_ann from public.announcements where author_id = pid and status = 'published';
  select case when requester = pid then addressee else requester end into partner
    from public.training_partners where status = 'accepted' and pid in (requester, addressee) limit 1;
  if partner is not null then
    begin aff := public.fs_partner_affinity(pid, partner); best := coalesce((aff->>'best')::int, 0); score := coalesce((aff->>'score')::int, 0);
    exception when others then null; end;
  end if;

  if exists(select 1 from public.admins where user_id = pid) then b := array_append(b, 'fondateur'); end if;
  if p.premium then b := array_append(b, 'plus'); end if;
  if p.verified then b := array_append(b, 'verifie'); end if;
  if n_checks >= 100 or exists(select 1 from public.admins where user_id = pid) then b := array_append(b, 'valide'); end if;
  if p.created_at < '2027-01-01' then b := array_append(b, 'pionnier'); end if;
  if n_posts >= 1 then b := array_append(b, 'premier_post'); end if;
  if n_posts >= 10 then b := array_append(b, 'posts10'); end if;
  if n_posts >= 50 then b := array_append(b, 'posts50'); end if;
  if n_clips >= 1 then b := array_append(b, 'clip'); end if;
  if n_shouts >= 10 then b := array_append(b, 'shout10'); end if;
  if n_flash >= 1 then b := array_append(b, 'flash'); end if;
  if n_checks >= 10 then b := array_append(b, 'checke10'); end if;
  if n_given >= 5 then b := array_append(b, 'genereux'); end if;
  if partner is not null then b := array_append(b, 'duo'); end if;
  if best >= 7 then b := array_append(b, 'serie7'); end if;
  if best >= 30 then b := array_append(b, 'serie30'); end if;
  if score >= 100 then b := array_append(b, 'affinite'); end if;
  if n_fol >= 100 then b := array_append(b, 'populaire'); end if;
  if n_fol >= 1000 then b := array_append(b, 'star'); end if;
  if n_following >= 50 then b := array_append(b, 'sociable'); end if;
  if n_cmt >= 50 then b := array_append(b, 'bavard'); end if;
  if n_likes >= 100 then b := array_append(b, 'aime'); end if;
  if max_views >= 500 then b := array_append(b, 'viral'); end if;
  if n_ref >= 3 then b := array_append(b, 'ambassadeur'); end if;
  if n_ref >= 10 then b := array_append(b, 'recruteur'); end if;
  if n_ann >= 1 and not exists(select 1 from public.admins where user_id = pid) then b := array_append(b, 'organisateur'); end if;
  return to_jsonb(b);
end $$;
revoke execute on function public.fs_badges(uuid) from public, anon;
grant execute on function public.fs_badges(uuid) to authenticated;
