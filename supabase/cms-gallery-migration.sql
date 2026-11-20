-- First Step Academy CMS and gallery setup
-- Run after first-step-portal-setup.sql.
-- Idempotent: creates the CMS/gallery objects and policies without deleting data.

begin;

create table if not exists public.website_content (
  content_key text primary key,
  content_value text not null default '',
  updated_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now()
);
create index if not exists website_content_updated_by_idx on public.website_content(updated_by);
alter table public.website_content enable row level security;
grant select on public.website_content to anon, authenticated;
grant insert, update, delete on public.website_content to authenticated;

drop policy if exists "public can read website content" on public.website_content;
create policy "public can read website content" on public.website_content
for select to anon, authenticated using (true);
drop policy if exists "admin manage website content" on public.website_content;
create policy "admin manage website content" on public.website_content
for all to authenticated using (private.is_academy_admin()) with check (private.is_academy_admin());

create table if not exists public.gallery_photos (
  id uuid primary key default gen_random_uuid(),
  caption text not null default '',
  category text not null default 'Academy Activities',
  image_path text not null unique,
  published boolean not null default false,
  created_by uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);
create index if not exists gallery_photos_created_by_idx on public.gallery_photos(created_by);
alter table public.gallery_photos enable row level security;
grant select on public.gallery_photos to anon, authenticated;
grant insert, update, delete on public.gallery_photos to authenticated;

drop policy if exists "gallery photos public read published" on public.gallery_photos;
create policy "gallery photos public read published" on public.gallery_photos
for select to anon, authenticated using (published = true);
drop policy if exists "gallery photos admin read all" on public.gallery_photos;
create policy "gallery photos admin read all" on public.gallery_photos
for select to authenticated using (private.is_academy_admin());
drop policy if exists "gallery photos staff read own" on public.gallery_photos;
create policy "gallery photos staff read own" on public.gallery_photos
for select to authenticated using (created_by = (select auth.uid()));
drop policy if exists "gallery photos staff admin insert" on public.gallery_photos;
create policy "gallery photos staff admin insert" on public.gallery_photos
for insert to authenticated with check (
  created_by = (select auth.uid())
  and exists (
    select 1 from public.profiles p
    where p.id = (select auth.uid()) and p.role in ('admin','staff')
  )
  and (published = false or private.is_academy_admin())
);
drop policy if exists "gallery photos admin update" on public.gallery_photos;
create policy "gallery photos admin update" on public.gallery_photos
for update to authenticated using (private.is_academy_admin())
with check (private.is_academy_admin());
drop policy if exists "gallery photos owner or admin delete" on public.gallery_photos;
create policy "gallery photos owner or admin delete" on public.gallery_photos
for delete to authenticated using (
  created_by = (select auth.uid()) or private.is_academy_admin()
);

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('academy-gallery','academy-gallery',true,8388608,array['image/jpeg','image/png','image/webp']::text[])
on conflict (id) do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "gallery images public read" on storage.objects;
create policy "gallery images public read" on storage.objects
for select to anon, authenticated using (bucket_id = 'academy-gallery');
drop policy if exists "gallery images staff admin upload" on storage.objects;
create policy "gallery images staff admin upload" on storage.objects
for insert to authenticated with check (
  bucket_id = 'academy-gallery'
  and exists (
    select 1 from public.profiles p
    where p.id = (select auth.uid()) and p.role in ('admin','staff')
  )
);
drop policy if exists "gallery images owner or admin delete" on storage.objects;
create policy "gallery images owner or admin delete" on storage.objects
for delete to authenticated using (
  bucket_id = 'academy-gallery'
  and (owner_id = (select auth.uid())::text or private.is_academy_admin())
);

notify pgrst, 'reload schema';
commit;
