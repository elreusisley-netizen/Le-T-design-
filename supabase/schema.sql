-- =====================================================================
--  VIRAL Design — schéma Supabase
--  À exécuter UNE fois dans Supabase : SQL Editor > New query > coller > Run.
--  Le script peut être relancé sans danger (il recrée les fonctions).
--
--  Contenu :
--    1. admins   : liste des comptes administrateurs (invisible pour l'appli)
--    2. events   : statistiques anonymes envoyées par l'appli (écriture seule)
--    3. designs  : sauvegardes en ligne des utilisateurs connectés
--    4. fonctions admin_* : statistiques et liste des comptes, réservées aux admins
--
--  Sécurité :
--    - RLS activée sur toutes les tables.
--    - Personne ne peut s'ajouter dans `admins` depuis l'appli : aucune
--      politique ni aucun droit pour les rôles anon / authenticated.
--      Seul le propriétaire du projet (SQL Editor) peut y écrire.
--    - Les fonctions admin vérifient le rôle côté serveur à chaque appel.
--    - Aucune donnée personnelle dans `events` : identifiant aléatoire,
--      nom d'événement, type de vêtement, mode d'ouverture, plateforme.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Administrateurs
-- ---------------------------------------------------------------------
create table if not exists public.admins (
  user_id  uuid primary key references auth.users(id) on delete cascade,
  added_at timestamptz not null default now()
);
alter table public.admins enable row level security;
revoke all on table public.admins from anon, authenticated;

create or replace function public.is_admin()
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (select 1 from public.admins a where a.user_id = auth.uid());
$$;
revoke all on function public.is_admin() from public, anon;
grant execute on function public.is_admin() to authenticated;

-- ---------------------------------------------------------------------
-- 2. Événements (statistiques)
-- ---------------------------------------------------------------------
create table if not exists public.events (
  id         bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  anon_id    uuid not null,
  user_id    uuid references auth.users(id) on delete set null,
  name       text not null check (name in (
               'app_open',            -- l'appli est ouverte (accueil)
               'return_visit',        -- ouverture un autre jour que la précédente
               'editor_open',         -- l'utilisateur entre dans l'éditeur
               'garment_select',      -- choix d'un vêtement
               'garment_customized',  -- 1er élément posé sur ce vêtement (1 fois par appareil)
               'design_save',         -- « Enregistrer » sur l'appareil
               'design_cloud_save',   -- sauvegarde en ligne (compte)
               'export_png',          -- « Télécharger en PNG »
               'export_file',         -- « Exporter fichier »
               'pwa_installed',       -- événement navigateur appinstalled (pas sur iOS)
               'signup',              -- création de compte
               'login'                -- connexion
             )),
  garment    text check (garment is null or garment in ('tshirt','sweat','hoodie','puffer','track','cap')),
  standalone boolean not null default false,   -- lancée depuis l'écran d'accueil
  platform   text check (platform is null or platform in ('ios','android','desktop','other'))
);
create index if not exists events_created_at_idx on public.events (created_at);
create index if not exists events_anon_idx       on public.events (anon_id, created_at);
create index if not exists events_user_idx       on public.events (user_id) where user_id is not null;

alter table public.events enable row level security;
revoke all on table public.events from anon, authenticated;
-- écriture seule, colonnes limitées : la date est toujours celle du serveur
grant insert (anon_id, user_id, name, garment, standalone, platform) on table public.events to anon, authenticated;

drop policy if exists events_insert on public.events;
create policy events_insert on public.events
  for insert to anon, authenticated
  with check (user_id is null or user_id = auth.uid());
-- aucune politique SELECT / UPDATE / DELETE : l'appli ne peut ni lire ni modifier

-- garde-fou contre l'envoi massif : 120 événements / minute / appareil maximum
create or replace function public.events_guard()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  new.created_at := now();
  if (select count(*) from public.events e
       where e.anon_id = new.anon_id and e.created_at > now() - interval '1 minute') >= 120 then
    raise exception 'rate limit' using errcode = '54000';
  end if;
  return new;
end;
$$;
revoke all on function public.events_guard() from public, anon, authenticated;
drop trigger if exists events_guard on public.events;
create trigger events_guard before insert on public.events
  for each row execute function public.events_guard();

-- ---------------------------------------------------------------------
-- 3. Designs sauvegardés en ligne (comptes facultatifs)
-- ---------------------------------------------------------------------
create table if not exists public.designs (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null default auth.uid() references auth.users(id) on delete cascade,
  name       text not null check (char_length(name) between 1 and 80),
  garment    text check (garment is null or garment in ('tshirt','sweat','hoodie','puffer','track','cap')),
  data       jsonb not null check (pg_column_size(data) < 4000000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, name)
);
alter table public.designs enable row level security;
revoke all on table public.designs from anon, authenticated;
grant select, insert, update, delete on table public.designs to authenticated;

drop policy if exists designs_owner_select on public.designs;
drop policy if exists designs_owner_insert on public.designs;
drop policy if exists designs_owner_update on public.designs;
drop policy if exists designs_owner_delete on public.designs;
create policy designs_owner_select on public.designs for select to authenticated using (user_id = auth.uid());
create policy designs_owner_insert on public.designs for insert to authenticated with check (user_id = auth.uid());
create policy designs_owner_update on public.designs for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy designs_owner_delete on public.designs for delete to authenticated using (user_id = auth.uid());

create or replace function public.designs_touch()
returns trigger language plpgsql set search_path = '' as $$
begin new.updated_at := now(); return new; end; $$;
drop trigger if exists designs_touch on public.designs;
create trigger designs_touch before update on public.designs
  for each row execute function public.designs_touch();

-- ---------------------------------------------------------------------
-- 4. Fonctions administrateur (lecture seule)
--    Définitions :
--    - « personne » : un compte (user_id) ; un appareil sans compte compte
--      comme une personne distincte (anon_id). Un appareil qui s'est
--      connecté au moins une fois est rattaché à son compte, pour ne pas
--      compter deux fois la même personne.
--    - « visiteur » : personne ayant ouvert l'appli dans la période.
--    - « utilisateur actif » : personne ayant fait au moins une action dans
--      l'éditeur (ouverture de l'éditeur, choix de vêtement, sauvegarde,
--      export) dans la période. Chaque personne n'est comptée qu'une fois.
--    - Jours calculés à l'heure de Paris.
-- ---------------------------------------------------------------------
create or replace function public.admin_overview(p_days integer default 30)
returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  d      integer := greatest(1, least(coalesce(p_days, 30), 365));
  tz     text := 'Europe/Paris';
  today0 timestamptz := (date_trunc('day', now() at time zone 'Europe/Paris')) at time zone 'Europe/Paris';
  since  timestamptz := today0 - make_interval(days => d - 1);   -- période = d jours calendaires, aujourd'hui inclus
  res    jsonb;
begin
  if not public.is_admin() then
    raise exception 'Accès réservé à l''administrateur' using errcode = '42501';
  end if;

  with link as (       -- appareil -> compte (dernier compte connecté sur l'appareil)
    select distinct on (anon_id) anon_id, user_id
    from public.events where user_id is not null
    order by anon_id, created_at desc
  ),
  ev as (
    select e.*, coalesce(e.user_id, l.user_id)::text as uid_link,
           coalesce(e.user_id::text, l.user_id::text, 'a:' || e.anon_id::text) as person
    from public.events e left join link l on l.anon_id = e.anon_id
  ),
  act as (select * from ev where name in ('editor_open','garment_select','garment_customized','design_save','design_cloud_save','export_png','export_file')),
  u as (select * from auth.users where deleted_at is null),
  days as (
    select g::date as day
    from generate_series((since at time zone tz)::date, (now() at time zone tz)::date, interval '1 day') g
  )
  select jsonb_build_object(
    'period_days', d,
    'generated_at', now(),
    'users', jsonb_build_object(
      'total',   (select count(*) from u),
      'today',   (select count(*) from u where created_at >= today0),
      'd7',      (select count(*) from u where created_at >= today0 - interval '6 days'),
      'd30',     (select count(*) from u where created_at >= today0 - interval '29 days'),
      'period',  (select count(*) from u where created_at >= since),
      'before_period', (select count(*) from u where created_at < since)
    ),
    'activity', jsonb_build_object(
      'active_24h', (select count(distinct person) from act where created_at >= now() - interval '24 hours'),
      'active_7d',  (select count(distinct person) from act where created_at >= today0 - interval '6 days'),
      'active_30d', (select count(distinct person) from act where created_at >= today0 - interval '29 days'),
      'active_period',   (select count(distinct person) from act where created_at >= since),
      'visitors_period', (select count(distinct person) from ev  where created_at >= since),
      'returning_period',(select count(distinct person) from ev  where created_at >= since and name = 'return_visit'),
      'logins_period',   (select count(*) from ev where created_at >= since and name = 'login')
    ),
    'installs', jsonb_build_object(
      'installed_events_total',  (select count(distinct anon_id) from ev where name = 'pwa_installed'),
      'standalone_devices_total',(select count(distinct anon_id) from ev where standalone),
      'standalone_devices_period',(select count(distinct anon_id) from ev where standalone and created_at >= since),
      'standalone_launches_period',(select count(*) from ev where standalone and name = 'app_open' and created_at >= since),
      'browser_launches_period', (select count(*) from ev where not standalone and name = 'app_open' and created_at >= since),
      'detected_devices_total',  (select count(distinct anon_id) from ev where standalone or name = 'pwa_installed'),
      'by_platform', coalesce((select jsonb_object_agg(p, n) from (
           select coalesce(platform,'other') p, count(distinct anon_id) n
           from ev where standalone or name = 'pwa_installed' group by 1) x), '{}'::jsonb)
    ),
    'creations', jsonb_build_object(
      'saves_total',        (select count(*) from ev where name = 'design_save'),
      'saves_period',       (select count(*) from ev where name = 'design_save' and created_at >= since),
      'cloud_designs_total',(select count(*) from public.designs),
      'cloud_saves_period', (select count(*) from ev where name = 'design_cloud_save' and created_at >= since),
      'customized_total',   (select count(*) from (select distinct person, garment from ev where name = 'garment_customized' and garment is not null) x),
      'customized_period',  (select count(*) from (select distinct person, garment from ev where name = 'garment_customized' and garment is not null and created_at >= since) x),
      'exports_total',      (select count(*) from ev where name in ('export_png','export_file')),
      'exports_period',     (select count(*) from ev where name in ('export_png','export_file') and created_at >= since),
      'exports_png_period', (select count(*) from ev where name = 'export_png' and created_at >= since),
      'exports_file_period',(select count(*) from ev where name = 'export_file' and created_at >= since),
      'by_garment', coalesce((select jsonb_agg(jsonb_build_object('garment', g.garment, 'customized', g.c, 'selected', g.s) order by g.c desc, g.s desc)
         from (select v.garment,
                      count(distinct (case when v.name = 'garment_customized' then v.person end)) c,
                      count(*) filter (where v.name = 'garment_select') s
               from ev v where v.garment is not null and v.created_at >= since
               group by v.garment) g), '[]'::jsonb)
    ),
    'series', (select jsonb_agg(jsonb_build_object(
        'day', dd.day,
        'signups',   (select count(*) from u where (created_at at time zone tz)::date = dd.day),
        'visitors',  (select count(distinct person) from ev where (created_at at time zone tz)::date = dd.day),
        'active',    (select count(distinct person) from act where (created_at at time zone tz)::date = dd.day),
        'creations', (select count(*) from ev where name in ('design_save','design_cloud_save') and (created_at at time zone tz)::date = dd.day),
        'customized',(select count(*) from ev where name = 'garment_customized' and (created_at at time zone tz)::date = dd.day),
        'exports',   (select count(*) from ev where name in ('export_png','export_file') and (created_at at time zone tz)::date = dd.day)
      ) order by dd.day) from days dd)
  ) into res;
  return res;
end;
$$;

create or replace function public.admin_users(p_limit integer default 50, p_offset integer default 0)
returns table (
  user_ref       text,
  email_masked   text,
  created_at     timestamptz,
  last_sign_in   timestamptz,
  last_activity  timestamptz,
  creations      bigint,
  cloud_designs  bigint,
  status         text,
  is_admin       boolean,
  total_count    bigint
)
language plpgsql stable security definer
set search_path = ''
as $$
begin
  if not public.is_admin() then
    raise exception 'Accès réservé à l''administrateur' using errcode = '42501';
  end if;
  return query
  select left(u.id::text, 8),
         case when u.email is null then null
              else left(split_part(u.email, '@', 1), 2) || '•••@' || split_part(u.email, '@', 2) end,
         u.created_at,
         u.last_sign_in_at,
         (select max(e.created_at) from public.events e where e.user_id = u.id),
         (select count(*) from public.events e where e.user_id = u.id and e.name in ('design_save','design_cloud_save')),
         (select count(*) from public.designs d where d.user_id = u.id),
         case when u.banned_until is not null and u.banned_until > now() then 'suspendu'
              when u.email_confirmed_at is null then 'non confirmé'
              else 'actif' end,
         exists (select 1 from public.admins a where a.user_id = u.id),
         count(*) over ()
  from auth.users u
  where u.deleted_at is null
  order by u.created_at desc
  limit greatest(1, least(coalesce(p_limit, 50), 200)) offset greatest(0, coalesce(p_offset, 0));
end;
$$;

revoke all on function public.admin_overview(integer) from public, anon;
revoke all on function public.admin_users(integer, integer) from public, anon;
grant execute on function public.admin_overview(integer) to authenticated;
grant execute on function public.admin_users(integer, integer) to authenticated;

-- =====================================================================
--  DONNER LE RÔLE ADMINISTRATEUR À TON COMPTE (à faire une seule fois)
--  1. Crée ton compte depuis l'appli (Réglages > Mon compte) ou depuis
--     viraldsgn.fr/admin/ avec ton e-mail.
--  2. Remplace l'e-mail ci-dessous, sélectionne uniquement ces 2 lignes et Run :
--
--  insert into public.admins (user_id)
--  select id from auth.users where email = 'TON-EMAIL@exemple.com';
--
--  Pour retirer le rôle :
--  delete from public.admins where user_id = (select id from auth.users where email = 'TON-EMAIL@exemple.com');
-- =====================================================================
