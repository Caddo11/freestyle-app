-- ===== Freestyle : automodération renforcée =====
-- Bloque partout (posts, shouts, commentaires, messages, flashs, groupes, profils, annonces) :
-- racisme, antisémitisme, homophobie, transphobie, pédocriminalité, insultes graves, harcèlement,
-- menaces, appels au suicide, contenu sexuel et racolage. Le texte est normalisé (accents, l33t, lettres répétées).
create or replace function public.fs_is_hateful(t text) returns boolean
language plpgsql stable set search_path = public, extensions as $$
declare n text := public.fs_norm(t); sq text; w text;
begin
  if t is null or t = '' then return false; end if;
  sq := regexp_replace(n, '[^a-z0-9]', '', 'g');
  w := ' ' || regexp_replace(n, '[^a-z0-9]+', ' ', 'g') || ' ';
  if sq ~ '(14mots|arabedemerde|asiatdemerde|bamboula|bicot|blancdemerde|bougnoul|branlette|camgirl|cheesepizza|childporn|chinetoque|chinoisdemerde|chintok|connard|connasse|crevesalope|dehorslesarabes|dehorslesjuifs|dehorslesnoirs|ejacul|encule|enculedepd|enculee|enfantnu|enfantsnus|envoiedesnudes|envoienudes|envoisnudes|envoistesnudes|faggot|feuj|filsdepu|filsdepute|fiotte|fourcrematoire|gazerles|gitandemerde|gogol|grossesalope|grossetruie|grossevache|heilhitler|hitleravaitraison|jemebranle|jesaisoutuhabites|jesaisoutuvis|jesperequetumeur|jetebute|jetebuterai|jetetue|jetetuerai|jetevio|jevaistebuter|jevaistecrever|jevaistefracasser|jevaistetuer|jevaistevioler|jsaisoutuhabites|juifdemerde|jvaistebuter|jvaistefracasser|jvaistetuer|jvaistevioler|killyourself|lolicon|melonnoir|mongolien|mortauxarabes|mortauxblancs|mortauxgays|mortauxjuifs|mortauxmusulmans|mortauxnoirs|mortauxpedes|musulmandemerde|mymfans|negre|negredemerde|negresse|nigga|nigger|niquetamer|niquetamere|niquetamort|niquetarace|niquetesmorts|niquetonpere|noirdemerde|onlyfans|onvatetrouver|partouze|pedoph|pedophil|pedopor|pendstoi|plancul|pornhub|porno|portosdemerde|raceinferieure|racesuperieure|rebeudemerde|renoidemerde|rentrechezto|rentredanstonpays|retourneaubled|retournedanstonpays|retourneenafrique|retourneentonpays|romdemerde|sacdemerde|salearabe|saleautiste|salebeur|saleblanc|salebougnoule|salechienne|salechinois|salegay|salegitan|salegouine|salegrosse|salehandicape|salehomo|salejuif|salejuive|salelesbienne|salemacaque|salemoche|salemusulman|salenoir|salenoire|salepede|saleportos|salepute|salerebeu|salerenoi|salerom|salesinge|salesjuifs|saletrans|salopard|sandnigger|sendnudes|sexavecunenfant|sexcam|sexeenfant|shoahbidon|siegheil|singenoir|sionard|sodomie|sodomise|sousrace|sucemabite|sucemaqueue|sucemoi|suicidetoi|tafiole|tamerelachienne|tamerelapute|tarlouze|tevioler|tranny|tumeritesdecrever|tumeritesdemourir|vacrever|vatepend|vatesuicider|whitepower|xhamster|xvideos|youpin|youporn|youtre)' then return true; end if;
  if w ~ ' (batard|batarde|batardes|batards|bite|bites|bougnoule|fdp|gouine|gouines|kkk|kys|loli|macaques|nazi|nazis|negro|negros|ntm|ntr|nude|nudes|pd|pedale|pedales|pede|pedes|pedo|pedos|pute|putes|salope|salopes|shota|tapette|tapettes|travelo|travelos|youpins) ' then return true; end if;
  if w ~ ' tue toi ' or w ~ ' tues toi ' or w ~ ' ratons? (?!laveurs?)' then return true; end if;
  return false;
end $$;

-- Annonces : modérées elles aussi
create or replace function public.fs_moderate_ann() returns trigger
language plpgsql set search_path = public as $$
begin
  if public.fs_is_hateful(concat_ws(' ', new.title, new.body, new.place)) then
    raise exception 'CONTENU_INTERDIT' using errcode = 'P0001';
  end if;
  return new;
end $$;
drop trigger if exists fs_moderate_ann_trg on public.announcements;
create trigger fs_moderate_ann_trg before insert or update on public.announcements
  for each row execute function public.fs_moderate_ann();

-- 3 avertissements = 24 h sans pouvoir publier, commenter ni écrire (partout, vérifié par le serveur)
create or replace function public.fs_mute_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid();
begin
  if uid is null or public.fs_is_admin() then return new; end if;
  if exists(select 1 from public.profiles where id = uid and muted_until is not null and muted_until > now()) then
    raise exception 'COMPTE_SUSPENDU' using errcode = 'P0001';
  end if;
  return new;
end $$;
do $$
declare t text;
begin
  foreach t in array array['posts','comments','messages','stories','group_messages','announcements'] loop
    execute format('drop trigger if exists fs_mute_guard_trg on public.%I', t);
    execute format('create trigger fs_mute_guard_trg before insert on public.%I for each row execute function public.fs_mute_guard()', t);
  end loop;
end $$;
