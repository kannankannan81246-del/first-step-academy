-- First Step Academy: board + section grouping migration
-- Run this in Supabase SQL Editor before testing the updated portal.

alter table public.students
  add column if not exists board_name text,
  add column if not exists section_name text;

-- Staff section assignments reuse the existing class_name column and store
-- values such as "Section A", preserving the table's existing unique key.

-- Keep the existing roster view's original columns and append section_name.
-- security_invoker ensures the querying user's table permissions/RLS apply.
create or replace view public.student_roster
  with (security_invoker = true)
as
select
  id as student_id,
  full_name,
  class_name,
  active,
  section_name
from public.students;

-- Section mapping used by the portal:
-- A = Classes 1–5
-- B = Classes 6–7
-- C = State Board Classes 8–10
-- D = CBSE Classes 9–10
--
-- Existing students and staff assignments are intentionally not auto-mapped:
-- the old records do not reliably contain board information for Classes 9–10.
-- Review and update those records after confirming each student's board.
