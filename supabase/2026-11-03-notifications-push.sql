-- ===== Freestyle : notifications push sur le téléphone =====
-- Chaque ping inséré déclenche la fonction « push » qui l'envoie sur les téléphones du membre.
-- Les clés VAPID sont générées et stockées par la fonction elle-même (table fermée à tout le monde).
create table if not exists public.push_config(
  id int primary key check (id = 1),
  public_key text not null,
  private_key text not null,
  created_at timestamptz not null default now()
);
alter table public.push_config enable row level security;   -- aucune règle : illisible par les membres

create table if not exists public.push_subscriptions(
  endpoint text primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  p256dh text not null,
  auth text not null,
  created_at timestamptz not null default now()
);
create index if not exists push_subscriptions_user_idx on public.push_subscriptions(user_id);
alter table public.push_subscriptions enable row level security;

alter table public.notifications add column if not exists pushed_at timestamptz;

create or replace function public.fs_push_public_key() returns text
language sql stable security definer set search_path = public as $$
  select public_key from public.push_config where id = 1
$$;
revoke execute on function public.fs_push_public_key() from public, anon;
grant execute on function public.fs_push_public_key() to authenticated;

create or replace function public.fs_save_push(ep text, k text, a text) returns text
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or ep is null or ep !~ '^https://' or length(ep) > 1000 then return 'invalid'; end if;
  insert into public.push_subscriptions(endpoint, user_id, p256dh, auth) values (ep, auth.uid(), k, a)
    on conflict (endpoint) do update set user_id = excluded.user_id, p256dh = excluded.p256dh, auth = excluded.auth;
  -- 10 appareils maximum par compte
  delete from public.push_subscriptions where user_id = auth.uid() and endpoint in (
    select endpoint from public.push_subscriptions where user_id = auth.uid() order by created_at desc offset 10);
  return 'ok';
end $$;
revoke execute on function public.fs_save_push(text, text, text) from public, anon;
grant execute on function public.fs_save_push(text, text, text) to authenticated;

create or replace function public.fs_remove_push(ep text) returns void
language sql security definer set search_path = public as $$
  delete from public.push_subscriptions where endpoint = ep and user_id = auth.uid()
$$;
revoke execute on function public.fs_remove_push(text) from public, anon;
grant execute on function public.fs_remove_push(text) to authenticated;

create or replace function public.fs_push_trigger() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if exists(select 1 from public.push_subscriptions where user_id = new.user_id) then
    perform net.http_post(
      url := 'https://pamndgrrqpgqblrogznq.supabase.co/functions/v1/push',
      headers := jsonb_build_object('Content-Type', 'application/json', 'apikey', 'sb_publishable_B4j5dHdTI6_YKhYkeVu9iA_n2kZs7tM'),
      body := jsonb_build_object('id', new.id),
      timeout_milliseconds := 8000);
  end if;
  return new;
end $$;
drop trigger if exists fs_push_trg on public.notifications;
create trigger fs_push_trg after insert on public.notifications
  for each row execute function public.fs_push_trigger();
