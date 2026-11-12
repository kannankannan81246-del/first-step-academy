-- Superseded by ../first-step-portal-setup.sql for new installations.
-- Safe incremental section update for the existing First Step Academy schema.
-- student_roster is an existing TABLE; do not replace it with a view.

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
as $$
begin
  if tg_op = 'DELETE' then
    delete from public.student_roster where student_id = old.id;
    return old;
  end if;
  insert into public.student_roster
    (student_id,full_name,class_name,active,board_name,section_name)
  values
    (new.id,new.full_name,new.class_name,new.active,new.board_name,new.section_name)
  on conflict (student_id) do update
    set full_name=excluded.full_name,
        class_name=excluded.class_name,
        active=excluded.active,
        board_name=excluded.board_name,
        section_name=excluded.section_name;
  return new;
end;
$$;

revoke all on function public.sync_student_roster() from public,anon,authenticated;
update public.students set section_name=section_name;
