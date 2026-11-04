-- L'effet de pseudo « Néon » est retiré : les profils qui l'avaient repassent en Classique.
update public.profiles set name_style = null where name_style = 'neon';
alter table public.profiles drop constraint if exists profiles_name_style_check;
alter table public.profiles add constraint profiles_name_style_check check (name_style is null or name_style in ('glitch','degrade','or','chrome','vague','feu','script'));
