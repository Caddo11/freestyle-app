-- ===== Freestyle : publications enregistrées + stickers libres (7 lettres, 3 derniers gardés) =====

-- ---------- Publications enregistrées ----------
create table if not exists public.saved_posts(
  user_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  post_id uuid not null references public.posts(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, post_id)
);
create index if not exists saved_posts_user_idx on public.saved_posts(user_id, created_at desc);
alter table public.saved_posts enable row level security;
drop policy if exists "enregistrements lus par soi" on public.saved_posts;
create policy "enregistrements lus par soi" on public.saved_posts for select using (user_id = auth.uid());
drop policy if exists "enregistrer pour soi" on public.saved_posts;
create policy "enregistrer pour soi" on public.saved_posts for insert with check (user_id = auth.uid());
drop policy if exists "retirer ses enregistrements" on public.saved_posts;
create policy "retirer ses enregistrements" on public.saved_posts for delete using (user_id = auth.uid());

-- ---------- Stickers de réaction : mot libre de 1 à 7 lettres ----------
alter table public.post_reactions drop constraint if exists post_reactions_word_check;
alter table public.post_reactions add constraint post_reactions_word_check
  check (char_length(word) between 1 and 7 and word ~ '^[A-Za-zÀ-ÖØ-öø-ÿŒœ]+$') not valid;

-- Seuls les 3 stickers les plus récents d'une publication sont conservés : les autres sont supprimés.
create or replace function public.fs_trim_reactions() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  delete from public.post_reactions r
  where r.post_id = new.post_id
    and (r.post_id, r.user_id) not in (
      select k.post_id, k.user_id from public.post_reactions k
      where k.post_id = new.post_id
      order by k.created_at desc limit 3);
  return null;
end $$;
revoke execute on function public.fs_trim_reactions() from public, anon, authenticated;
drop trigger if exists fs_trim_reactions_trg on public.post_reactions;
create trigger fs_trim_reactions_trg after insert or update on public.post_reactions
  for each row execute function public.fs_trim_reactions();
