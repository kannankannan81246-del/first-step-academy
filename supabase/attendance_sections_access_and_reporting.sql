-- Attendance model: Sections A-E, separate Spoken English/Hindi categories,
-- subject-specific CBSE Classes 9-12, staff access modes and scoped monthly exports.

alter table public.profiles
  add column if not exists attendance_access text not null default 'assigned';
alter table public.profiles drop constraint if exists profiles_attendance_access_check;
alter table public.profiles add constraint profiles_attendance_access_check
  check (attendance_access in ('assigned','all'));

alter table public.staff_teaching_assignments
  drop constraint if exists staff_teaching_assignments_section_name_check;
alter table public.staff_teaching_assignments
  add constraint staff_teaching_assignments_section_name_check
  check (section_name in ('A','B','C','D','E'));

create or replace function private.staff_can_access_section(target_section text)
returns boolean language sql stable set search_path = ''
as $fn$
  select private.is_academy_admin() or exists (
    select 1 from public.profiles p
    where p.id = (select auth.uid()) and p.role = 'staff'
      and (p.attendance_access = 'all'
        or private.is_assigned_to('Section ' || target_section))
  );
$fn$;
revoke all on function private.staff_can_access_section(text) from public, anon;
grant usage on schema private to authenticated;
grant execute on function private.staff_can_access_section(text) to authenticated;

drop policy if exists "admin or assigned staff read roster" on public.student_roster;
drop policy if exists "admin or permitted staff read roster" on public.student_roster;
create policy "admin or permitted staff read roster"
on public.student_roster for select to authenticated
using (
  private.is_academy_admin()
  or (active = true and (
    (class_name in ('Class 1','Class 2','Class 3','Class 4','Class 5','Class 6','Class 7','Class 8','Class 9','Class 10')
      and section_name is not null and private.staff_can_access_section(section_name))
    or (class_name in ('Class 9','Class 10') and section_name is not null
      and exists (select 1 from unnest(coalesce(student_roster.subjects,'{}'::text[])) s
        where private.is_assigned_teaching_class(student_roster.board_name,student_roster.class_name,student_roster.section_name,s)))
    or (class_name in ('Class 11','Class 12')
      and exists (select 1 from unnest(coalesce(student_roster.subjects,'{}'::text[])) s
        where private.is_assigned_subject(s)))
  ))
);

drop policy if exists attendance_select_scoped on public.attendance;
create policy attendance_select_scoped on public.attendance
for select to authenticated using (
  private.is_academy_admin()
  or marked_by = (select auth.uid())
  or exists (select 1 from public.students s where s.id=attendance.student_id and s.auth_user_id=(select auth.uid()))
  or exists (select 1 from public.student_roster r where r.student_id=attendance.student_id
    and r.class_name=attendance.class_name and r.active=true and r.section_name is not null
    and private.staff_can_access_section(r.section_name))
  or exists (select 1 from public.student_roster r where r.student_id=attendance.student_id
    and r.class_name=attendance.class_name and r.active=true
    and r.class_name in ('Class 11','Class 12') and private.is_assigned_subject(attendance.subject_name))
);

drop policy if exists attendance_insert_scoped on public.attendance;
create policy attendance_insert_scoped on public.attendance
for insert to authenticated with check (
  private.is_academy_admin()
  or (marked_by=(select auth.uid()) and exists (
    select 1 from public.student_roster r
    where r.student_id=attendance.student_id and r.class_name=attendance.class_name and r.active=true
    and (
      (r.section_name is not null and private.staff_can_access_section(r.section_name)
        and ((r.class_name in ('Class 1','Class 2','Class 3','Class 4','Class 5','Class 6','Class 7','Class 8') and attendance.subject_name='')
          or (r.board_name='State Board' and r.class_name in ('Class 9','Class 10') and attendance.subject_name='')))
      or (r.board_name='CBSE' and r.class_name in ('Class 9','Class 10') and attendance.subject_name<>''
        and exists (select 1 from unnest(coalesce(r.subjects,'{}'::text[])) s where lower(s)=lower(attendance.subject_name))
        and r.section_name is not null
        and (private.staff_can_access_section(r.section_name)
          or private.is_assigned_teaching_class(r.board_name,r.class_name,r.section_name,attendance.subject_name,attendance.attendance_date)))
      or (attendance.subject_name in ('Spoken English','Hindi')
        and exists (select 1 from unnest(coalesce(r.subjects,'{}'::text[])) s where lower(s)=lower(attendance.subject_name))
        and r.section_name is not null and private.staff_can_access_section(r.section_name))
      or (r.class_name in ('Class 11','Class 12') and attendance.subject_name<>''
        and exists (select 1 from unnest(coalesce(r.subjects,'{}'::text[])) s where lower(s)=lower(attendance.subject_name))
        and private.is_assigned_subject(attendance.subject_name))
    )
  ))
);

drop policy if exists attendance_update_scoped on public.attendance;
create policy attendance_update_scoped on public.attendance
for update to authenticated
using (private.is_academy_admin() or marked_by=(select auth.uid()))
with check (
 private.is_academy_admin()
 or (marked_by=(select auth.uid()) and exists (
  select 1 from public.student_roster r
  where r.student_id=attendance.student_id and r.class_name=attendance.class_name and r.active=true
  and (
   (r.section_name is not null and private.staff_can_access_section(r.section_name)
    and ((r.class_name in ('Class 1','Class 2','Class 3','Class 4','Class 5','Class 6','Class 7','Class 8') and attendance.subject_name='')
      or (r.board_name='State Board' and r.class_name in ('Class 9','Class 10') and attendance.subject_name='')
      or (attendance.subject_name in ('Spoken English','Hindi')
        and exists(select 1 from unnest(coalesce(r.subjects,'{}'::text[])) s where lower(s)=lower(attendance.subject_name)))))
   or (r.board_name='CBSE' and r.class_name in ('Class 9','Class 10') and attendance.subject_name<>''
    and exists(select 1 from unnest(coalesce(r.subjects,'{}'::text[])) s where lower(s)=lower(attendance.subject_name))
    and r.section_name is not null
    and (private.staff_can_access_section(r.section_name)
      or private.is_assigned_teaching_class(r.board_name,r.class_name,r.section_name,attendance.subject_name,attendance.attendance_date)))
   or (r.class_name in ('Class 11','Class 12') and attendance.subject_name<>''
    and exists(select 1 from unnest(coalesce(r.subjects,'{}'::text[])) s where lower(s)=lower(attendance.subject_name))
    and private.is_assigned_subject(attendance.subject_name))
  )
 ))
);
notify pgrst,'reload schema';
