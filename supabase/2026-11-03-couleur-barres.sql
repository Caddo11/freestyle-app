-- ===== Freestyle : couleur des barres choisie par chaque membre =====
alter table public.profiles add column if not exists bar_color text;
alter table public.profiles drop constraint if exists profiles_bar_color_check;
alter table public.profiles add constraint profiles_bar_color_check check (bar_color is null or bar_color in ('graphite','acier','sable','bordeaux','foret','nuit','violet','or'));
