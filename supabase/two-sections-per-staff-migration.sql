-- Allow one staff member to be assigned to up to two sections.
-- The portal enforces the maximum of two; this index keeps each section unique.
drop index if exists public.staff_class_assignments_one_section_per_staff_uidx;
create unique index if not exists staff_class_assignments_one_staff_per_section_uidx
  on public.staff_class_assignments(class_name);
