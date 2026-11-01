-- =====================================================================
--  VIRAL Design — PHASE 1 : bibliothèque privée VIRAL Admin
--  À exécuter UNE fois dans Supabase : SQL Editor > New query > coller > Run.
--  Prérequis : schema.sql déjà exécuté (fonction public.is_admin()).
--  Ne supprime rien : crée un bucket privé, une table et des règles d'accès.
--  Le script peut être relancé sans danger.
--
--  Règle unique : seuls les comptes présents dans public.admins peuvent
--  lister, lire, ajouter, modifier ou supprimer ces ressources.
--  Les visiteurs et les utilisateurs connectés standards n'ont AUCUN accès,
--  ni à la table, ni aux fichiers (même avec l'URL exacte).
-- =====================================================================

-- 1. Bucket privé (aucune URL publique), formats et taille limités
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('admin-assets', 'admin-assets', false, 5242880,
        array['image/png','image/jpeg','image/webp','image/svg+xml'])
on conflict (id) do update
  set public = false,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- 2. Règles d'accès aux fichiers : administrateurs uniquement
drop policy if exists admin_assets_files_select on storage.objects;
drop policy if exists admin_assets_files_insert on storage.objects;
drop policy if exists admin_assets_files_update on storage.objects;
drop policy if exists admin_assets_files_delete on storage.objects;
create policy admin_assets_files_select on storage.objects for select to authenticated
  using (bucket_id = 'admin-assets' and public.is_admin());
create policy admin_assets_files_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'admin-assets' and public.is_admin());
create policy admin_assets_files_update on storage.objects for update to authenticated
  using (bucket_id = 'admin-assets' and public.is_admin())
  with check (bucket_id = 'admin-assets' and public.is_admin());
create policy admin_assets_files_delete on storage.objects for delete to authenticated
  using (bucket_id = 'admin-assets' and public.is_admin());

-- 3. Catalogue des ressources (nom, catégorie, ordre)
create table if not exists public.admin_assets (
  id         uuid primary key default gen_random_uuid(),
  name       text not null check (char_length(name) between 1 and 80),
  category   text not null default 'Ressources' check (char_length(category) between 1 and 40),
  path       text not null unique check (char_length(path) <= 200 and path ~ '^[a-z0-9_-]+(/[a-z0-9_-]+)*\.(png|jpg|webp|svg)$'),
  mime       text not null check (mime in ('image/png','image/jpeg','image/webp','image/svg+xml')),
  width      integer check (width is null or width between 1 and 10000),
  height     integer check (height is null or height between 1 and 10000),
  bytes      integer check (bytes is null or bytes between 1 and 5242880),
  sort       integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.admin_assets enable row level security;
revoke all on table public.admin_assets from anon, authenticated;
grant select, insert, update, delete on table public.admin_assets to authenticated;

drop policy if exists admin_assets_admin_all on public.admin_assets;
create policy admin_assets_admin_all on public.admin_assets for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

create or replace function public.admin_assets_touch()
returns trigger language plpgsql set search_path = '' as $$
begin new.updated_at := now(); return new; end; $$;
drop trigger if exists admin_assets_touch on public.admin_assets;
create trigger admin_assets_touch before update on public.admin_assets
  for each row execute function public.admin_assets_touch();
