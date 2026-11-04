-- ===== Freestyle : le badge Shiny ne peut être donné / retiré que par le fondateur (@caddo) =====
create or replace function public.fs_is_founder() returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() = 'a5124ac2-5eba-4c71-b4bd-52e5ca7e7138'::uuid
$$;
grant execute on function public.fs_is_founder() to authenticated;

create or replace function public.fs_admin_set_badge(target uuid, badge text, lvl int) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
#variable_conflict use_variable
begin
  if not public.fs_is_admin() then raise exception 'Réservé aux créateurs'; end if;
  if badge !~ '^[a-z]+$' then raise exception 'Badge inconnu'; end if;
  if badge = 'shiny' and not public.fs_is_founder() then raise exception 'Seul le fondateur peut donner le badge Shiny'; end if;
  if lvl is null then
    delete from public.badge_grants g where g.user_id = target and g.badge = fs_admin_set_badge.badge;
  else
    insert into public.badge_grants(user_id, badge, level, granted_by) values (target, badge, greatest(0, least(3, lvl)), auth.uid())
      on conflict on constraint badge_grants_pkey do update set level = excluded.level, granted_by = excluded.granted_by, created_at = now();
  end if;
  return jsonb_build_object('badges', public.fs_badges(target), 'grants', public.fs_admin_badge_grants(target));
end $$;
select 'ok' as shiny_fondateur;
