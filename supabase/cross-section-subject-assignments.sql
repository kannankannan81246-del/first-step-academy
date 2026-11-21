-- Cross-section, class-specific subject teaching and weekday timetable assignments.
-- Admin manages assignments; staff can read only their own assignment rows.
begin;

create table if not exists public.staff_teaching_assignments (
  id uuid primary key default gen_random_uuid(),
  staff_id uuid not null references public.profiles(id) on delete cascade,
  board_name text not null check (board_name in ('CBSE','State Board')),
  section_name text not null check (section_name in ('A','B','C','D')),
  class_name text not null check (class_name in ('Class 9','Class 10')),
  subject_name text not null check (length(trim(subject_name)) > 0),
  day_of_week smallint null check (day_of_week between 1 and 7),
  created_at timestamptz not null default now()
);

create unique index if not exists staff_teaching_assignments_slot_uidx
  on public.staff_teaching_assignments
  (board_name, class_name, lower(subject_name), coalesce(day_of_week,0));
create index if not exists staff_teaching_assignments_staff_idx
  on public.staff_teaching_assignments(staff_id);

alter table public.staff_teaching_assignments enable row level security;
revoke all on public.staff_teaching_assignments from anon, authenticated;
grant select, insert, update, delete on public.staff_teaching_assignments to authenticated;

drop policy if exists staff_teaching_assignments_select on public.staff_teaching_assignments;
create policy staff_teaching_assignments_select
  on public.staff_teaching_assignments for select to authenticated
  using (private.is_academy_admin() or staff_id = (select auth.uid()));
drop policy if exists staff_teaching_assignments_admin_insert on public.staff_teaching_assignments;
create policy staff_teaching_assignments_admin_insert
  on public.staff_teaching_assignments for insert to authenticated
  with check (private.is_academy_admin());
drop policy if exists staff_teaching_assignments_admin_update on public.staff_teaching_assignments;
create policy staff_teaching_assignments_admin_update
  on public.staff_teaching_assignments for update to authenticated
  using (private.is_academy_admin()) with check (private.is_academy_admin());
drop policy if exists staff_teaching_assignments_admin_delete on public.staff_teaching_assignments;
create policy staff_teaching_assignments_admin_delete
  on public.staff_teaching_assignments for delete to authenticated
  using (private.is_academy_admin());

create or replace function private.is_assigned_teaching_class(
  target_board text, target_class text, target_section text,
  target_subject text, target_date date default null
)
returns boolean language sql stable set search_path = ''
as $fn$
  select exists (
    select 1 from public.staff_teaching_assignments a
    where a.staff_id = (select auth.uid())
      and lower(a.board_name) = lower(target_board)
      and a.class_name = target_class
      and a.section_name = target_section
      and lower(a.subject_name) = lower(target_subject)
      and (target_date is null or a.day_of_week is null
           or a.day_of_week = extract(isodow from target_date)::smallint)
  );
$fn$;
revoke all on function private.is_assigned_teaching_class(text,text,text,text,date) from public, anon;
grant usage on schema private to authenticated;
grant execute on function private.is_assigned_teaching_class(text,text,text,text,date) to authenticated;

drop policy if exists "admin or assigned staff read roster" on public.student_roster;
create policy "admin or assigned staff read roster"
on public.student_roster for select to authenticated
using (
  private.is_academy_admin()
  or (
    active = true and (
      (section_name is not null and class_name not in ('Class 11','Class 12')
       and private.is_assigned_to('Section ' || section_name))
      or (
        class_name in ('Class 9','Class 10')
        and exists (
          select 1 from unnest(coalesce(student_roster.subjects, '{}'::text[])) as student_subject
          where private.is_assigned_teaching_class(
            student_roster.board_name, student_roster.class_name,
            student_roster.section_name, student_subject
          )
        )
      )
      or (
        class_name in ('Class 11','Class 12')
        and exists (
          select 1 from unnest(coalesce(student_roster.subjects, '{}'::text[])) as student_subject
          where private.is_assigned_subject(student_subject)
        )
      )
    )
  )
);

drop policy if exists attendance_insert_scoped on public.attendance;
create policy attendance_insert_scoped on public.attendance
for insert to authenticated with check (
  private.is_academy_admin()
  or (
    marked_by = (select auth.uid()) and exists (
      select 1 from public.student_roster r
      where r.student_id = attendance.student_id
        and r.class_name = attendance.class_name and r.active = true
        and (
          (r.class_name in ('Class 1','Class 2','Class 3','Class 4','Class 5','Class 6','Class 7','Class 8')
           and attendance.subject_name = '' and r.section_name is not null
           and private.is_assigned_to('Section ' || r.section_name))
          or (
            r.class_name in ('Class 9','Class 10') and attendance.subject_name <> ''
            and exists (
              select 1 from unnest(coalesce(r.subjects, '{}'::text[])) as student_subject
              where lower(student_subject) = lower(attendance.subject_name)
            )
            and r.section_name is not null
            and (
              private.is_assigned_to('Section ' || r.section_name)
              or private.is_assigned_teaching_class(
                r.board_name,r.class_name,r.section_name,
                attendance.subject_name,attendance.attendance_date
              )
            )
          )
          or (
            r.class_name in ('Class 11','Class 12') and attendance.subject_name <> ''
            and exists (
              select 1 from unnest(coalesce(r.subjects, '{}'::text[])) as student_subject
              where lower(student_subject) = lower(attendance.subject_name)
            )
            and private.is_assigned_subject(attendance.subject_name)
          )
        )
    )
  )
);

drop policy if exists attendance_update_scoped on public.attendance;
create policy attendance_update_scoped on public.attendance
for update to authenticated
using (private.is_academy_admin() or marked_by = (select auth.uid()))
with check (
  private.is_academy_admin()
  or (
    marked_by = (select auth.uid()) and exists (
      select 1 from public.student_roster r
      where r.student_id = attendance.student_id
        and r.class_name = attendance.class_name and r.active = true
        and (
          (r.class_name in ('Class 1','Class 2','Class 3','Class 4','Class 5','Class 6','Class 7','Class 8')
           and attendance.subject_name = '' and r.section_name is not null
           and private.is_assigned_to('Section ' || r.section_name))
          or (
            r.class_name in ('Class 9','Class 10') and attendance.subject_name <> ''
            and exists (
              select 1 from unnest(coalesce(r.subjects, '{}'::text[])) as student_subject
              where lower(student_subject) = lower(attendance.subject_name)
            )
            and r.section_name is not null
            and (
              private.is_assigned_to('Section ' || r.section_name)
              or private.is_assigned_teaching_class(
                r.board_name,r.class_name,r.section_name,
                attendance.subject_name,attendance.attendance_date
              )
            )
          )
          or (
            r.class_name in ('Class 11','Class 12') and attendance.subject_name <> ''
            and exists (
              select 1 from unnest(coalesce(r.subjects, '{}'::text[])) as student_subject
              where lower(student_subject) = lower(attendance.subject_name)
            )
            and private.is_assigned_subject(attendance.subject_name)
          )
        )
    )
  )
);

notify pgrst, 'reload schema';
commit;
