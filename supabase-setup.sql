-- First Step Academy: secure starter database
-- Run this whole file in Supabase SQL Editor as the project owner.
create extension if not exists pgcrypto;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  login_id text unique not null,
  full_name text not null,
  role text not null check (role in ('admin','staff','student')),
  class_name text,
  created_at timestamptz not null default now()
);

create table if not exists public.students (
  id uuid primary key default gen_random_uuid(),
  auth_user_id uuid unique references auth.users(id) on delete set null,
  student_code text unique not null,
  full_name text not null,
  date_of_birth date,
  guardian_name text,
  guardian_phone text,
  address text,
  class_name text not null,
  subjects text[] not null default '{}',
  admission_date date not null default current_date,
  previous_school text,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.staff_class_assignments (
  staff_id uuid not null references public.profiles(id) on delete cascade,
  class_name text not null,
  primary key (staff_id, class_name)
);

create table if not exists public.student_roster (
  student_id uuid primary key references public.students(id) on delete cascade,
  full_name text not null,
  class_name text not null,
  active boolean not null default true
);

create table if not exists public.attendance (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references public.students(id) on delete cascade,
  class_name text not null,
  attendance_date date not null,
  status text not null check (status in ('Present','Absent','Leave')),
  marked_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  unique(student_id, attendance_date)
);

create table if not exists public.staff_attendance (
  id uuid primary key default gen_random_uuid(),
  staff_id uuid not null references public.profiles(id) on delete cascade,
  attendance_date date not null,
  status text not null check (status in ('Present','Absent','Leave')),
  marked_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  unique(staff_id, attendance_date)
);

create or replace function public.is_academy_admin()
returns boolean language sql stable security definer set search_path = public
as $$ select exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin') $$;

create or replace function public.is_assigned_to(target_class text)
returns boolean language sql stable security definer set search_path = public
as $$ select exists (select 1 from public.staff_class_assignments a where a.staff_id = auth.uid() and a.class_name = target_class) $$;

create or replace function public.sync_student_roster()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  if tg_op = 'DELETE' then
    delete from public.student_roster where student_id = old.id;
    return old;
  end if;
  insert into public.student_roster(student_id, full_name, class_name, active)
  values (new.id, new.full_name, new.class_name, new.active)
  on conflict (student_id) do update
    set full_name = excluded.full_name, class_name = excluded.class_name, active = excluded.active;
  return new;
end;
$$;

drop trigger if exists students_roster_sync on public.students;
create trigger students_roster_sync
after insert or update of full_name, class_name, active or delete on public.students
for each row execute function public.sync_student_roster();

alter table public.profiles enable row level security;
alter table public.students enable row level security;
alter table public.staff_class_assignments enable row level security;
alter table public.student_roster enable row level security;
alter table public.attendance enable row level security;
alter table public.staff_attendance enable row level security;

drop policy if exists "profiles self or admin read" on public.profiles;
create policy "profiles self or admin read" on public.profiles for select to authenticated
using (id = auth.uid() or public.is_academy_admin());
drop policy if exists "admin manage profiles" on public.profiles;
create policy "admin manage profiles" on public.profiles for all to authenticated
using (public.is_academy_admin()) with check (public.is_academy_admin());

drop policy if exists "admin manage students" on public.students;
create policy "admin manage students" on public.students for all to authenticated
using (public.is_academy_admin()) with check (public.is_academy_admin());
drop policy if exists "student reads own student record" on public.students;
create policy "student reads own student record" on public.students for select to authenticated
using (auth_user_id = auth.uid());

drop policy if exists "admin or assigned staff read roster" on public.student_roster;
create policy "admin or assigned staff read roster" on public.student_roster for select to authenticated
using (public.is_academy_admin() or (active and public.is_assigned_to(class_name)));

drop policy if exists "admin manage class assignments" on public.staff_class_assignments;
create policy "admin manage class assignments" on public.staff_class_assignments for all to authenticated
using (public.is_academy_admin()) with check (public.is_academy_admin());
drop policy if exists "staff read own assignments" on public.staff_class_assignments;
create policy "staff read own assignments" on public.staff_class_assignments for select to authenticated
using (staff_id = auth.uid());

drop policy if exists "admin manage student attendance" on public.attendance;
create policy "admin manage student attendance" on public.attendance for all to authenticated
using (public.is_academy_admin()) with check (public.is_academy_admin());
drop policy if exists "staff mark assigned class attendance" on public.attendance;
create policy "staff mark assigned class attendance" on public.attendance for insert to authenticated
with check (
  public.is_assigned_to(class_name)
  and marked_by = auth.uid()
  and exists (select 1 from public.student_roster r where r.student_id = attendance.student_id and r.class_name = attendance.class_name and r.active)
);
drop policy if exists "student read own attendance" on public.attendance;
create policy "student read own attendance" on public.attendance for select to authenticated
using (exists (select 1 from public.students s where s.id = attendance.student_id and s.auth_user_id = auth.uid()));

drop policy if exists "admin manage staff attendance" on public.staff_attendance;
create policy "admin manage staff attendance" on public.staff_attendance for all to authenticated
using (public.is_academy_admin()) with check (public.is_academy_admin());

grant usage on schema public to authenticated;
grant select on public.profiles, public.students, public.staff_class_assignments, public.student_roster, public.attendance, public.staff_attendance to authenticated;
grant insert, update, delete on public.students, public.profiles, public.staff_class_assignments, public.attendance, public.staff_attendance to authenticated;
grant insert on public.attendance to authenticated;

-- IMPORTANT FIRST-TIME SETUP:
-- 1) Create the first admin account in Supabase Authentication > Users.
-- 2) Copy that user's UUID and run the example below after replacing values:
-- insert into public.profiles (id, login_id, full_name, role)
-- values ('AUTH_USER_UUID', 'admin001', 'Academy Admin', 'admin');
-- 3) Add staff/student Auth users, then create their profiles and student rows.
-- 4) Assign staff to classes using staff_class_assignments.
-- Never expose a service_role/secret key in a website.
