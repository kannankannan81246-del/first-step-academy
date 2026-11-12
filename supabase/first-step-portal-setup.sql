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
create index if not exists leave_requests_requester_idx on public.leave_requests(requester_user_id,created_at desc);
create index if not exists leave_requests_status_idx on public.leave_requests(status,created_at desc);
create index if not exists leave_requests_student_id_idx on public.leave_requests(student_id);
create index if not exists leave_requests_reviewed_by_idx on public.leave_requests(reviewed_by);

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

create table if not exists public.portal_notifications (
  id uuid primary key default gen_random_uuid(),
  recipient_user_id uuid not null references auth.users(id) on delete cascade,
  title text not null,
  message text not null,
  related_leave_id uuid references public.leave_requests(id) on delete set null,
  is_read boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists portal_notifications_recipient_created_idx on public.portal_notifications(recipient_user_id,created_at desc);
create index if not exists portal_notifications_related_leave_id_idx on public.portal_notifications(related_leave_id);
create index if not exists attendance_marked_by_idx on public.attendance(marked_by);
create index if not exists staff_attendance_marked_by_idx on public.staff_attendance(marked_by);

alter table public.leave_requests enable row level security;
alter table public.academy_notices enable row level security;
alter table public.student_achievements enable row level security;
alter table public.portal_notifications enable row level security;

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

-- Leave requests: requester reads own, admin reviews; only linked students/staff can submit.
drop policy if exists leave_select_own_or_admin on public.leave_requests;
create policy leave_select_own_or_admin on public.leave_requests
for select to authenticated
using (requester_user_id = (select auth.uid()) or private.is_academy_admin());

drop policy if exists leave_insert_own on public.leave_requests;
create policy leave_insert_own on public.leave_requests
for insert to authenticated
with check (
  requester_user_id = (select auth.uid())
  and status = 'Pending' and reviewed_by is null
  and exists (select 1 from public.profiles p where p.id=(select auth.uid()) and p.role=requester_role and p.role in ('student','staff'))
  and (
    (requester_role='staff' and student_id is null)
    or (requester_role='student' and exists (
      select 1 from public.students s where s.id=student_id and s.auth_user_id=(select auth.uid())
    ))
  )
);

drop policy if exists leave_admin_review on public.leave_requests;
create policy leave_admin_review on public.leave_requests
for update to authenticated using (private.is_academy_admin())
with check (private.is_academy_admin());

-- Notices: published audience-specific reading, admin-only management.
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

-- Notifications are created only by the database trigger; users may only mark their own as read.
drop policy if exists notifications_read_own_or_admin on public.portal_notifications;
create policy notifications_read_own_or_admin on public.portal_notifications
for select to authenticated using (recipient_user_id=(select auth.uid()) or private.is_academy_admin());
drop policy if exists notifications_update_own_read_status on public.portal_notifications;
create policy notifications_update_own_read_status on public.portal_notifications
for update to authenticated using (recipient_user_id=(select auth.uid()))
with check (recipient_user_id=(select auth.uid()));

revoke all on public.leave_requests,public.academy_notices,public.student_achievements,public.portal_notifications from anon;
grant select,insert,update on public.leave_requests to authenticated;
grant select,insert,update,delete on public.academy_notices to authenticated;
grant select,insert,update,delete on public.student_achievements to authenticated;
grant select on public.portal_notifications to authenticated;
revoke insert,update,delete on public.portal_notifications from authenticated;
grant update (is_read) on public.portal_notifications to authenticated;
grant select (id,title,description,achievement_date) on public.student_achievements to anon;

create or replace function public.notify_leave_decision()
returns trigger language plpgsql security definer set search_path=public
as $fn$
declare decision_text text; details text;
begin
  if old.status='Pending' and new.status in ('Approved','Rejected') then
    decision_text := case when new.status='Approved' then 'approved' else 'not approved' end;
    details := 'Your leave request ('||new.start_date::text||' to '||new.end_date::text||') has been '||decision_text||
      case when new.admin_note is not null and length(trim(new.admin_note))>0 then ' Admin note: '||new.admin_note else '' end;
    insert into public.portal_notifications(recipient_user_id,title,message,related_leave_id)
    values(new.requester_user_id,'Leave request '||new.status,details,new.id);
  end if;
  return new;
end;
$fn$;
revoke all on function public.notify_leave_decision() from public,anon,authenticated;
drop trigger if exists leave_decision_notification on public.leave_requests;
create trigger leave_decision_notification after update of status on public.leave_requests
for each row execute function public.notify_leave_decision();


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

-- The public achievements page never receives student names or identifying details.
notify pgrst, 'reload schema';
commit;
