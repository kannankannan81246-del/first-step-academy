-- First Step Academy: portal features (leave requests, notices, achievements)
-- Run this migration in Supabase SQL Editor before enabling these portal sections.

create table if not exists public.leave_requests (
  id uuid primary key default gen_random_uuid(),
  requester_user_id uuid not null references auth.users(id) on delete cascade,
  requester_role text not null check (requester_role in ('student','staff')),
  student_id uuid references public.students(id) on delete set null,
  start_date date not null,
  end_date date not null,
  reason text not null,
  status text not null default 'Pending' check (status in ('Pending','Approved','Rejected')),
  admin_note text,
  reviewed_by uuid references auth.users(id) on delete set null,
  reviewed_at timestamptz,
  created_at timestamptz not null default now(),
  constraint leave_dates_valid check (end_date >= start_date),
  constraint student_request_has_student check (
    (requester_role = 'student' and student_id is not null) or
    (requester_role = 'staff' and student_id is null)
  )
);

create index if not exists leave_requests_requester_idx
  on public.leave_requests(requester_user_id, created_at desc);
create index if not exists leave_requests_status_idx
  on public.leave_requests(status, created_at desc);

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

create index if not exists student_achievements_date_idx
  on public.student_achievements(achievement_date desc);

alter table public.leave_requests enable row level security;
alter table public.academy_notices enable row level security;
alter table public.student_achievements enable row level security;

-- Leave requests: users see their own; admins see all and may review.
drop policy if exists "leave_select_own_or_admin" on public.leave_requests;
create policy "leave_select_own_or_admin"
on public.leave_requests for select to authenticated
using (
  requester_user_id = auth.uid()
  or exists (
    select 1 from public.profiles p
    where p.id = auth.uid() and p.role = 'admin'
  )
);

drop policy if exists "leave_insert_own" on public.leave_requests;
create policy "leave_insert_own"
on public.leave_requests for insert to authenticated
with check (
  requester_user_id = auth.uid()
  and status = 'Pending'
  and reviewed_by is null
  and exists (
    select 1 from public.profiles p
    where p.id = auth.uid() and p.role = requester_role
      and p.role in ('student','staff')
  )
  and (
    (requester_role = 'staff' and student_id is null)
    or
    (requester_role = 'student' and exists (
      select 1 from public.students s
      where s.id = student_id and s.auth_user_id = auth.uid()
    ))
  )
);

drop policy if exists "leave_admin_review" on public.leave_requests;
create policy "leave_admin_review"
on public.leave_requests for update to authenticated
using (
  exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin')
)
with check (
  exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin')
);

-- Notices: signed-in users see published notices addressed to them; admins manage.
drop policy if exists "notices_read_for_audience" on public.academy_notices;
create policy "notices_read_for_audience"
on public.academy_notices for select to authenticated
using (
  published = true
  and (
    audience = 'all'
    or exists (
      select 1 from public.profiles p
      where p.id = auth.uid() and p.role = audience
    )
    or exists (
      select 1 from public.profiles p
      where p.id = auth.uid() and p.role = 'admin'
    )
  )
);

drop policy if exists "notices_admin_insert" on public.academy_notices;
create policy "notices_admin_insert"
on public.academy_notices for insert to authenticated
with check (
  exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin')
);

drop policy if exists "notices_admin_update" on public.academy_notices;
create policy "notices_admin_update"
on public.academy_notices for update to authenticated
using (exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin'))
with check (exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin'));

drop policy if exists "notices_admin_delete" on public.academy_notices;
create policy "notices_admin_delete"
on public.academy_notices for delete to authenticated
using (exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin'));

-- Achievements: signed-in users can read published entries; admins manage.
drop policy if exists "achievements_read_published" on public.student_achievements;
create policy "achievements_read_published"
on public.student_achievements for select to authenticated
using (
  published = true
  or exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin')
);

drop policy if exists "achievements_admin_insert" on public.student_achievements;
create policy "achievements_admin_insert"
on public.student_achievements for insert to authenticated
with check (exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin'));

drop policy if exists "achievements_admin_update" on public.student_achievements;
create policy "achievements_admin_update"
on public.student_achievements for update to authenticated
using (exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin'))
with check (exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin'));

drop policy if exists "achievements_admin_delete" on public.student_achievements;
create policy "achievements_admin_delete"
on public.student_achievements for delete to authenticated
using (exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin'));

grant select, insert, update on public.leave_requests to authenticated;
grant select, insert, update, delete on public.academy_notices to authenticated;
grant select, insert, update, delete on public.student_achievements to authenticated;
