-- ===== Freestyle : nouveau cadre Venom =====
alter table public.profiles drop constraint if exists profiles_frame_check;
alter table public.profiles add constraint profiles_frame_check check (frame is null or frame in ('fin','double','neon','or','chrome','pixel','feu','glace','holo','plasma','foudre','venom'));
select 'ok' as cadre_venom;
