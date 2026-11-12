-- First Step Academy: in-portal notifications
-- Run only after the existing portal-features-migration.sql has been reviewed
-- and applied successfully in the Supabase project.

create table if not exists public.portal_notifications (
  id uuid primary key default gen_random_uuid(),
  recipient_user_id uuid not null references auth.users(id) on delete cascade,
  title text not null,
  message text not null,
  related_leave_id uuid references public.leave_requests(id) on delete set null,
  is_read boolean not null default false,
  created_at timestamptz not null default now()
);

create index if not exists portal_notifications_recipient_created_idx
  on public.portal_notifications(recipient_user_id, created_at desc);

alter table public.portal_notifications enable row level security;

drop policy if exists "notifications_read_own_or_admin" on public.portal_notifications;
create policy "notifications_read_own_or_admin"
on public.portal_notifications for select to authenticated
using (
  recipient_user_id = auth.uid()
  or exists (
    select 1 from public.profiles p
    where p.id = auth.uid() and p.role = 'admin'
  )
);

drop policy if exists "notifications_admin_insert" on public.portal_notifications;
create policy "notifications_admin_insert"
on public.portal_notifications for insert to authenticated
with check (
  exists (
    select 1 from public.profiles p
    where p.id = auth.uid() and p.role = 'admin'
  )
);

drop policy if exists "notifications_update_own_read_status" on public.portal_notifications;
create policy "notifications_update_own_read_status"
on public.portal_notifications for update to authenticated
using (recipient_user_id = auth.uid())
with check (recipient_user_id = auth.uid());

grant select, insert on public.portal_notifications to authenticated;
revoke update on public.portal_notifications from authenticated;
grant update (is_read) on public.portal_notifications to authenticated;
