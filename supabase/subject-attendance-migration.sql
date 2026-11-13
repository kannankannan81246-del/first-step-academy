-- Subject-wise attendance and senior subject-based staff access migration.
begin;

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
          and attendance.subject_name=any(coalesce(r.subjects,'{}'::text[]))
          and r.section_name is not null and private.is_assigned_to('Section '||r.section_name))
        or
        (r.class_name in ('Class 11','Class 12') and attendance.subject_name<>''
          and attendance.subject_name=any(coalesce(r.subjects,'{}'::text[]))
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
          and attendance.subject_name=any(coalesce(r.subjects,'{}'::text[]))
          and r.section_name is not null and private.is_assigned_to('Section '||r.section_name))
        or
        (r.class_name in ('Class 11','Class 12') and attendance.subject_name<>''
          and attendance.subject_name=any(coalesce(r.subjects,'{}'::text[]))
          and private.is_assigned_subject(attendance.subject_name))
      )
    )
  )
);
drop policy if exists attendance_delete_admin on public.attendance;
create policy attendance_delete_admin on public.attendance
for delete to authenticated using(private.is_academy_admin());
grant select,insert,update,delete on public.attendance to authenticated;

notify pgrst,'reload schema';
commit;
