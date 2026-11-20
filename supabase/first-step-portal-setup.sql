-- First Step Academy portal setup
-- Apply to the existing First Step Academy base schema.
-- This script is idempotent and preserves existing student and attendance rows.

begin;

-- Board and section metadata. Existing roster is a TABLE, not a view.
alter table public.students
  add column if not exists board_name text,
  add column if not exists section_name text;
alter table public.student_roster
  add column if not exists board_name text,
  add column if not exists section_name text;

create or replace function public.sync_student_roster()
returns trigger
language plpgsql
security definer
set search_path = public
as $fn$
begin
  if tg_op = 'DELETE' then
    delete from public.student_roster where student_id = old.id;
    return old;
  end if;
  insert into public.student_roster
    (student_id, full_name, class_name, active, board_name, section_name)
  values
    (new.id, new.full_name, new.class_name, new.active, new.board_name, new.section_name)
  on conflict (student_id) do update
    set full_name = excluded.full_name,
        class_name = excluded.class_name,
        active = excluded.active,
        board_name = excluded.board_name,
        section_name = excluded.section_name;
  return new;
end;
$fn$;
revoke all on function public.sync_student_roster() from public, anon, authenticated;
drop trigger if exists students_roster_sync on public.students;
create trigger students_roster_sync
after insert or update or delete on public.students
for each row execute function public.sync_student_roster();

-- Backfill the roster table using the existing trigger; no student data is deleted.
update public.students set section_name = section_name;

-- Junior classes have fixed sections. Senior sections need the student's actual board.
update public.students
set section_name = case
  when class_name in ('Class 1','Class 2','Class 3','Class 4','Class 5') then 'A'
  when class_name in ('Class 6','Class 7') then 'B'
  else section_name
end
where section_name is null;

-- Existing staff class assignments can be mapped safely for junior classes.
insert into public.staff_class_assignments (staff_id,class_name)
select staff_id,'Section A'
from public.staff_class_assignments
where class_name in ('Class 1','Class 3')
on conflict (staff_id,class_name) do nothing;
delete from public.staff_class_assignments where class_name in ('Class 1','Class 3');

-- Enforce one section per staff member and one staff member per section.
-- Existing assignments are preserved; legacy class labels must be mapped by an admin.
create unique index if not exists staff_class_assignments_one_section_per_staff_uidx
  on public.staff_class_assignments(staff_id);
create unique index if not exists staff_class_assignments_one_staff_per_section_uidx
  on public.staff_class_assignments(class_name);

-- Portal feature tables.
create table if not exists public.academy_notices (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  body text not null,
  audience text not null default 'all' check (audience in ('all','student','staff')),
  published boolean not null default true,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists academy_notices_created_by_idx on public.academy_notices(created_by);

create table if not exists public.student_achievements (
  id uuid primary key default gen_random_uuid(),
  student_id uuid references public.students(id) on delete set null,
  student_name text not null,
  title text not null,
  description text,
  achievement_date date not null default current_date,
  published boolean not null default true,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists student_achievements_date_idx on public.student_achievements(achievement_date desc);
create index if not exists student_achievements_student_id_idx on public.student_achievements(student_id);
create index if not exists student_achievements_created_by_idx on public.student_achievements(created_by);

create index if not exists attendance_marked_by_idx on public.attendance(marked_by);
create index if not exists staff_attendance_marked_by_idx on public.staff_attendance(marked_by);

alter table public.academy_notices enable row level security;
alter table public.student_achievements enable row level security;

-- Keep SECURITY DEFINER authorization helpers outside the exposed public API schema.
create schema if not exists private;
revoke all on schema private from public,anon;
grant usage on schema private to authenticated;

create or replace function private.is_academy_admin()
returns boolean language sql stable security definer
set search_path=pg_catalog
as $fn$
  select exists(select 1 from public.profiles p where p.id=auth.uid() and p.role='admin');
$fn$;

create or replace function private.is_assigned_to(target_class text)
returns boolean language sql stable security definer
set search_path=pg_catalog
as $fn$
  select exists(select 1 from public.staff_class_assignments a where a.staff_id=auth.uid() and a.class_name=target_class);
$fn$;

revoke all on function private.is_academy_admin() from public,anon;
revoke all on function private.is_assigned_to(text) from public,anon;
grant execute on function private.is_academy_admin() to authenticated;
grant execute on function private.is_assigned_to(text) to authenticated;

-- Migrate existing base-schema policies to the private authorization helpers.
drop policy if exists "admin manage student attendance" on public.attendance;
create policy "admin manage student attendance" on public.attendance
for all to authenticated using (private.is_academy_admin())
with check (private.is_academy_admin());

drop policy if exists "student read own attendance" on public.attendance;
create policy "student read own attendance" on public.attendance
for select to authenticated
using (exists (
  select 1 from public.students s
  where s.id=attendance.student_id and s.auth_user_id=(select auth.uid())
));

drop policy if exists "admin manage profiles" on public.profiles;
create policy "admin manage profiles" on public.profiles
for all to authenticated using (private.is_academy_admin())
with check (private.is_academy_admin());

drop policy if exists "profiles self or admin read" on public.profiles;
create policy "profiles self or admin read" on public.profiles
for select to authenticated
using (id=(select auth.uid()) or private.is_academy_admin());

drop policy if exists "admin manage staff attendance" on public.staff_attendance;
create policy "admin manage staff attendance" on public.staff_attendance
for all to authenticated using (private.is_academy_admin())
with check (private.is_academy_admin());

drop policy if exists "admin manage class assignments" on public.staff_class_assignments;
create policy "admin manage class assignments" on public.staff_class_assignments
for all to authenticated using (private.is_academy_admin())
with check (private.is_academy_admin());

drop policy if exists "staff read own assignments" on public.staff_class_assignments;
create policy "staff read own assignments" on public.staff_class_assignments
for select to authenticated using (staff_id=(select auth.uid()));

drop policy if exists "admin manage students" on public.students;
create policy "admin manage students" on public.students
for all to authenticated using (private.is_academy_admin())
with check (private.is_academy_admin());

drop policy if exists "student reads own student record" on public.students;
create policy "student reads own student record" on public.students
for select to authenticated using (auth_user_id=(select auth.uid()));

revoke all on function public.is_academy_admin() from public,anon,authenticated;
revoke all on function public.is_assigned_to(text) from public,anon,authenticated;

drop policy if exists notices_read_for_audience on public.academy_notices;
create policy notices_read_for_audience on public.academy_notices
for select to authenticated
using (
  private.is_academy_admin()
  or (published=true and (audience='all' or exists (
    select 1 from public.profiles p where p.id=(select auth.uid()) and p.role=audience
  )))
);
drop policy if exists notices_admin_insert on public.academy_notices;
create policy notices_admin_insert on public.academy_notices
for insert to authenticated with check (private.is_academy_admin() and created_by=(select auth.uid()));
drop policy if exists notices_admin_update on public.academy_notices;
create policy notices_admin_update on public.academy_notices
for update to authenticated using (private.is_academy_admin()) with check (private.is_academy_admin());
drop policy if exists notices_admin_delete on public.academy_notices;
create policy notices_admin_delete on public.academy_notices
for delete to authenticated using (private.is_academy_admin());

-- Achievements: authenticated users see published entries; public page gets only non-identifying columns.
drop policy if exists achievements_read_published on public.student_achievements;
create policy achievements_read_published on public.student_achievements
for select to authenticated using (published=true or private.is_academy_admin());
drop policy if exists achievements_public_read_published on public.student_achievements;
create policy achievements_public_read_published on public.student_achievements
for select to anon using (published=true);
drop policy if exists achievements_admin_insert on public.student_achievements;
create policy achievements_admin_insert on public.student_achievements
for insert to authenticated with check (private.is_academy_admin() and created_by=(select auth.uid()));
drop policy if exists achievements_admin_update on public.student_achievements;
create policy achievements_admin_update on public.student_achievements
for update to authenticated using (private.is_academy_admin()) with check (private.is_academy_admin());
drop policy if exists achievements_admin_delete on public.student_achievements;
create policy achievements_admin_delete on public.student_achievements
for delete to authenticated using (private.is_academy_admin());




-- Section-aware roster access and attendance submission.
drop policy if exists "admin or assigned staff read roster" on public.student_roster;
create policy "admin or assigned staff read roster" on public.student_roster
for select to authenticated
using (private.is_academy_admin() or (active=true and section_name is not null and private.is_assigned_to('Section '||section_name)));

drop policy if exists "staff mark assigned class attendance" on public.attendance;
create policy "staff mark assigned class attendance" on public.attendance
for insert to authenticated
with check (
  marked_by=(select auth.uid())
  and exists (
    select 1 from public.student_roster r
    where r.student_id=attendance.student_id and r.class_name=attendance.class_name
      and r.active=true and r.section_name is not null
      and private.is_assigned_to('Section '||r.section_name)
  )
);



-- Subject-wise attendance and senior subject-based staff access.
alter table public.student_roster add column if not exists subjects text[] not null default '{}';
alter table public.attendance add column if not exists subject_name text not null default '';

create or replace function public.sync_student_roster()
returns trigger language plpgsql security definer set search_path=public
as $fn$
begin
  if tg_op='DELETE' then
    delete from public.student_roster where student_id=old.id;
    return old;
  end if;
  insert into public.student_roster(student_id,full_name,class_name,active,board_name,section_name,subjects)
  values(new.id,new.full_name,new.class_name,new.active,new.board_name,new.section_name,coalesce(new.subjects,'{}'::text[]))
  on conflict(student_id) do update set
    full_name=excluded.full_name,class_name=excluded.class_name,active=excluded.active,
    board_name=excluded.board_name,section_name=excluded.section_name,subjects=excluded.subjects;
  return new;
end;
$fn$;
revoke all on function public.sync_student_roster() from public,anon,authenticated;
update public.students set subjects=coalesce(subjects,'{}'::text[]);

create table if not exists public.staff_subject_assignments(
  staff_id uuid not null references public.profiles(id) on delete cascade,
  subject_name text not null check(length(trim(subject_name))>0),
  created_at timestamptz not null default now(),
  primary key(staff_id,subject_name)
);
alter table public.staff_subject_assignments enable row level security;
revoke all on public.staff_subject_assignments from anon;
grant select,insert,update,delete on public.staff_subject_assignments to authenticated;

create or replace function private.is_assigned_subject(target_subject text)
returns boolean language sql stable security definer set search_path=pg_catalog
as $fn$
  select exists(select 1 from public.staff_subject_assignments a
    where a.staff_id=auth.uid() and lower(a.subject_name)=lower(target_subject));
$fn$;
revoke all on function private.is_assigned_subject(text) from public,anon;
grant execute on function private.is_assigned_subject(text) to authenticated;

-- Staff may read senior students only when they are assigned one of that student's subjects.
drop policy if exists "admin or assigned staff read roster" on public.student_roster;
create policy "admin or assigned staff read roster" on public.student_roster
for select to authenticated
using (
  private.is_academy_admin()
  or (
    active = true
    and (
      (
        section_name is not null
        and class_name not in ('Class 11','Class 12')
        and private.is_assigned_to('Section ' || section_name)
      )
      or (
        class_name in ('Class 11','Class 12')
        and exists (
          select 1
          from unnest(coalesce(student_roster.subjects, '{}'::text[])) as student_subject
          where private.is_assigned_subject(student_subject)
        )
      )
    )
  )
);


drop policy if exists staff_subject_assignments_admin_manage on public.staff_subject_assignments;
drop policy if exists staff_subject_assignments_staff_read_own on public.staff_subject_assignments;
drop policy if exists staff_subject_assignments_read on public.staff_subject_assignments;
create policy staff_subject_assignments_read on public.staff_subject_assignments
for select to authenticated using(private.is_academy_admin() or staff_id=(select auth.uid()));
drop policy if exists staff_subject_assignments_admin_insert on public.staff_subject_assignments;
create policy staff_subject_assignments_admin_insert on public.staff_subject_assignments
for insert to authenticated with check(private.is_academy_admin());
drop policy if exists staff_subject_assignments_admin_update on public.staff_subject_assignments;
create policy staff_subject_assignments_admin_update on public.staff_subject_assignments
for update to authenticated using(private.is_academy_admin()) with check(private.is_academy_admin());
drop policy if exists staff_subject_assignments_admin_delete on public.staff_subject_assignments;
create policy staff_subject_assignments_admin_delete on public.staff_subject_assignments
for delete to authenticated using(private.is_academy_admin());

alter table public.attendance alter column subject_name set default '';
alter table public.attendance alter column subject_name set not null;
alter table public.attendance drop constraint if exists attendance_student_id_attendance_date_key;
drop index if exists public.attendance_student_id_attendance_date_key;
create unique index if not exists attendance_student_date_subject_uidx
  on public.attendance(student_id,attendance_date,subject_name);

drop policy if exists "admin manage student attendance" on public.attendance;
drop policy if exists "staff mark assigned class attendance" on public.attendance;
drop policy if exists "student read own attendance" on public.attendance;
drop policy if exists staff_read_own_attendance_for_upsert on public.attendance;
drop policy if exists staff_update_own_assigned_attendance on public.attendance;

drop policy if exists attendance_select_scoped on public.attendance;
create policy attendance_select_scoped on public.attendance
for select to authenticated using (
  private.is_academy_admin()
  or marked_by=(select auth.uid())
  or exists(select 1 from public.students s where s.id=attendance.student_id and s.auth_user_id=(select auth.uid()))
);

drop policy if exists attendance_insert_scoped on public.attendance;
create policy attendance_insert_scoped on public.attendance
for insert to authenticated with check (
  private.is_academy_admin()
  or (
    marked_by=(select auth.uid()) and exists (
      select 1 from public.student_roster r
      where r.student_id=attendance.student_id and r.class_name=attendance.class_name and r.active=true
      and (
        (r.class_name in ('Class 1','Class 2','Class 3','Class 4','Class 5','Class 6','Class 7','Class 8')
          and attendance.subject_name='' and r.section_name is not null
          and private.is_assigned_to('Section '||r.section_name))
        or
        (r.class_name in ('Class 9','Class 10') and attendance.subject_name<>''
          and exists (
            select 1
            from unnest(coalesce(r.subjects,'{}'::text[])) as assigned_student_subject(subject_name)
            where lower(assigned_student_subject.subject_name)=lower(attendance.subject_name)
          )
          and r.section_name is not null and private.is_assigned_to('Section '||r.section_name))
        or
        (r.class_name in ('Class 11','Class 12') and attendance.subject_name<>''
          and exists (
            select 1
            from unnest(coalesce(r.subjects,'{}'::text[])) as assigned_student_subject(subject_name)
            where lower(assigned_student_subject.subject_name)=lower(attendance.subject_name)
          )
          and private.is_assigned_subject(attendance.subject_name))
      )
    )
  )
);

drop policy if exists attendance_update_scoped on public.attendance;
create policy attendance_update_scoped on public.attendance
for update to authenticated
using(private.is_academy_admin() or marked_by=(select auth.uid()))
with check (
  private.is_academy_admin()
  or (
    marked_by=(select auth.uid()) and exists (
      select 1 from public.student_roster r
      where r.student_id=attendance.student_id and r.class_name=attendance.class_name and r.active=true
      and (
        (r.class_name in ('Class 1','Class 2','Class 3','Class 4','Class 5','Class 6','Class 7','Class 8')
          and attendance.subject_name='' and r.section_name is not null
          and private.is_assigned_to('Section '||r.section_name))
        or
        (r.class_name in ('Class 9','Class 10') and attendance.subject_name<>''
          and exists (
            select 1
            from unnest(coalesce(r.subjects,'{}'::text[])) as assigned_student_subject(subject_name)
            where lower(assigned_student_subject.subject_name)=lower(attendance.subject_name)
          )
          and r.section_name is not null and private.is_assigned_to('Section '||r.section_name))
        or
        (r.class_name in ('Class 11','Class 12') and attendance.subject_name<>''
          and exists (
            select 1
            from unnest(coalesce(r.subjects,'{}'::text[])) as assigned_student_subject(subject_name)
            where lower(assigned_student_subject.subject_name)=lower(attendance.subject_name)
          )
          and private.is_assigned_subject(attendance.subject_name))
      )
    )
  )
);
drop policy if exists attendance_delete_admin on public.attendance;
create policy attendance_delete_admin on public.attendance
for delete to authenticated using(private.is_academy_admin());
grant select,insert,update,delete on public.attendance to authenticated;


-- The public achievements page never receives student names or identifying details.
create table if not exists public.website_content (
  content_key text primary key,
  content_value text not null default '',
  updated_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now()
);

create index if not exists website_content_updated_by_idx
  on public.website_content(updated_by);

alter table public.website_content enable row level security;
grant select on public.website_content to anon, authenticated;
grant insert, update, delete on public.website_content to authenticated;

drop policy if exists "public can read website content" on public.website_content;
create policy "public can read website content" on public.website_content
for select to anon, authenticated using (true);

drop policy if exists "admin manage website content" on public.website_content;
create policy "admin manage website content" on public.website_content
for all to authenticated
using (private.is_academy_admin())
with check (private.is_academy_admin());

create table if not exists public.gallery_photos (
  id uuid primary key default gen_random_uuid(),
  caption text not null default '',
  category text not null default 'Academy Activities',
  image_path text not null unique,
  published boolean not null default false,
  created_by uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

create index if not exists gallery_photos_created_by_idx
  on public.gallery_photos(created_by);

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
for insert to authenticated
with check (
  created_by = (select auth.uid())
  and exists (
    select 1 from public.profiles p
    where p.id = (select auth.uid()) and p.role in ('admin','staff')
  )
  and (published = false or private.is_academy_admin())
);

drop policy if exists "gallery photos admin update" on public.gallery_photos;
create policy "gallery photos admin update" on public.gallery_photos
for update to authenticated
using (private.is_academy_admin())
with check (private.is_academy_admin());

drop policy if exists "gallery photos owner or admin delete" on public.gallery_photos;
create policy "gallery photos owner or admin delete" on public.gallery_photos
for delete to authenticated
using (created_by = (select auth.uid()) or private.is_academy_admin());

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'academy-gallery',
  'academy-gallery',
  true,
  8388608,
  array['image/jpeg','image/png','image/webp']::text[]
)
on conflict (id) do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "gallery images public read" on storage.objects;
create policy "gallery images public read" on storage.objects
for select to anon, authenticated
using (bucket_id = 'academy-gallery');

drop policy if exists "gallery images staff admin upload" on storage.objects;
create policy "gallery images staff admin upload" on storage.objects
for insert to authenticated
with check (
  bucket_id = 'academy-gallery'
  and exists (
    select 1 from public.profiles p
    where p.id = (select auth.uid()) and p.role in ('admin','staff')
  )
);

drop policy if exists "gallery images owner or admin delete" on storage.objects;
create policy "gallery images owner or admin delete" on storage.objects
for delete to authenticated
using (
  bucket_id = 'academy-gallery'
  and (owner_id = (select auth.uid())::text or private.is_academy_admin())
);

-- RFID attendance: card mappings and IN/OUT events are private to academy admins.
create table if not exists public.rfid_card_assignments (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null unique references public.students(id) on delete cascade,
  card_uid text not null unique check (length(trim(card_uid)) > 0),
  assigned_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists rfid_card_assignments_uid_idx
  on public.rfid_card_assignments(card_uid);

create table if not exists public.rfid_attendance_events (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references public.students(id) on delete restrict,
  event_type text not null check (event_type in ('IN','OUT')),
  method text not null default 'RFID' check (method in ('RFID','Manual')),
  scanned_by uuid references auth.users(id) on delete set null,
  scanned_at timestamptz not null default now()
);
create index if not exists rfid_attendance_student_time_idx
  on public.rfid_attendance_events(student_id,scanned_at desc);
create index if not exists rfid_attendance_time_idx
  on public.rfid_attendance_events(scanned_at desc);

alter table public.rfid_card_assignments enable row level security;
alter table public.rfid_attendance_events enable row level security;

drop policy if exists rfid_cards_admin_all on public.rfid_card_assignments;
create policy rfid_cards_admin_all on public.rfid_card_assignments
for all to authenticated
using (private.is_academy_admin())
with check (private.is_academy_admin());

drop policy if exists rfid_events_admin_all on public.rfid_attendance_events;
create policy rfid_events_admin_all on public.rfid_attendance_events
for all to authenticated
using (private.is_academy_admin())
with check (private.is_academy_admin());

revoke all on public.rfid_card_assignments,public.rfid_attendance_events from anon;
grant select,insert,update,delete on public.rfid_card_assignments to authenticated;
grant select,insert,update,delete on public.rfid_attendance_events to authenticated;


-- Fee management: fee rates, student fee accounts and payment ledger.
-- All fee data is restricted to authenticated academy admins.
create table if not exists public.fee_class_rates (
  id uuid primary key default gen_random_uuid(),
  class_name text not null unique,
  tuition_fee numeric(12,2) not null default 0 check (tuition_fee >= 0),
  other_fee numeric(12,2) not null default 0 check (other_fee >= 0),
  default_pay_mode text not null default 'Monthly Pay'
    check (default_pay_mode in ('Monthly Pay','Yearly Pay')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

insert into public.fee_class_rates(class_name,tuition_fee,other_fee,default_pay_mode) values
('III CBSE',10000,2000,'Monthly Pay'),
('IV CBSE',11000,2000,'Monthly Pay'),
('V CBSE',12000,2500,'Monthly Pay'),
('VI CBSE',13000,2500,'Monthly Pay'),
('VII CBSE',14000,3000,'Yearly Pay'),
('VIII CBSE',15000,3000,'Yearly Pay'),
('IX CBSE',16000,3500,'Yearly Pay'),
('III M.ST',9000,1500,'Monthly Pay'),
('IV M.ST',10000,1500,'Monthly Pay'),
('V M.ST',11000,2000,'Monthly Pay'),
('VI M.ST',12000,2000,'Monthly Pay'),
('VII M.ST',13000,2500,'Yearly Pay'),
('VIII M.ST',14000,2500,'Yearly Pay'),
('IX M.ST',15000,3000,'Yearly Pay')
on conflict(class_name) do update set
 tuition_fee=excluded.tuition_fee,
 other_fee=excluded.other_fee,
 default_pay_mode=excluded.default_pay_mode,
 updated_at=now();

create table if not exists public.student_fee_accounts (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null unique references public.students(id) on delete restrict,
  fee_class_id uuid not null references public.fee_class_rates(id) on delete restrict,
  pay_mode text not null check(pay_mode in ('Monthly Pay','Yearly Pay')),
  discount numeric(12,2) not null default 0 check(discount >= 0),
  due_date date,
  updated_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists student_fee_accounts_class_idx on public.student_fee_accounts(fee_class_id);

create table if not exists public.fee_payments (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references public.student_fee_accounts(id) on delete restrict,
  receipt_no text not null unique default ('FSA-' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,10))),
  payment_date date not null default current_date,
  amount numeric(12,2) not null check(amount > 0),
  payment_mode text not null check(payment_mode in ('Cash','UPI','Bank Transfer','Card','Other')),
  reference text not null default '',
  status text not null default 'Cleared' check(status in ('Cleared','Pending','Reversed')),
  recorded_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists fee_payments_account_date_idx on public.fee_payments(account_id,payment_date desc);

alter table public.fee_class_rates enable row level security;
alter table public.student_fee_accounts enable row level security;
alter table public.fee_payments enable row level security;

drop policy if exists fee_class_rates_admin_only on public.fee_class_rates;
create policy fee_class_rates_admin_only on public.fee_class_rates
for all to authenticated using(private.is_academy_admin()) with check(private.is_academy_admin());
drop policy if exists student_fee_accounts_admin_only on public.student_fee_accounts;
create policy student_fee_accounts_admin_only on public.student_fee_accounts
for all to authenticated using(private.is_academy_admin()) with check(private.is_academy_admin());
drop policy if exists fee_payments_admin_only on public.fee_payments;
create policy fee_payments_admin_only on public.fee_payments
for all to authenticated using(private.is_academy_admin()) with check(private.is_academy_admin());

revoke all on public.fee_class_rates,public.student_fee_accounts,public.fee_payments from anon;
grant select,insert,update,delete on public.fee_class_rates,public.student_fee_accounts,public.fee_payments to authenticated;

notify pgrst, 'reload schema';
commit;
