-- Safe additive migration for Fee Management, RFID Attendance and admin-only demo data.
-- Does not modify or delete existing student, staff, attendance or payment rows.
begin;

create table if not exists public.fee_class_rates (
  id uuid primary key default gen_random_uuid(),
  class_name text not null unique,
  tuition_fee numeric(12,2) not null default 0 check (tuition_fee >= 0),
  other_fee numeric(12,2) not null default 0 check (other_fee >= 0),
  default_pay_mode text not null default 'Monthly Pay'
    check (default_pay_mode in ('Monthly Pay','Yearly Pay')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

insert into public.fee_class_rates(class_name,tuition_fee,other_fee,default_pay_mode) values
('III CBSE',10000,2000,'Monthly Pay'),
('IV CBSE',11000,2000,'Monthly Pay'),
('V CBSE',12000,2500,'Monthly Pay'),
('VI CBSE',13000,2500,'Monthly Pay'),
('VII CBSE',14000,3000,'Yearly Pay'),
('VIII CBSE',15000,3000,'Yearly Pay'),
('IX CBSE',16000,3500,'Yearly Pay'),
('III M.ST',9000,1500,'Monthly Pay'),
('IV M.ST',10000,1500,'Monthly Pay'),
('V M.ST',11000,2000,'Monthly Pay'),
('VI M.ST',12000,2000,'Monthly Pay'),
('VII M.ST',13000,2500,'Yearly Pay'),
('VIII M.ST',14000,2500,'Yearly Pay'),
('IX M.ST',15000,3000,'Yearly Pay')
on conflict(class_name) do nothing;

create table if not exists public.student_fee_accounts (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null unique references public.students(id) on delete restrict,
  fee_class_id uuid not null references public.fee_class_rates(id) on delete restrict,
  pay_mode text not null check(pay_mode in ('Monthly Pay','Yearly Pay')),
  discount numeric(12,2) not null default 0 check(discount >= 0),
  due_date date,
  updated_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists student_fee_accounts_class_idx
  on public.student_fee_accounts(fee_class_id);

create table if not exists public.fee_payments (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references public.student_fee_accounts(id) on delete restrict,
  receipt_no text not null unique default ('FSA-' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,10))),
  payment_date date not null default current_date,
  amount numeric(12,2) not null check(amount > 0),
  payment_mode text not null check(payment_mode in ('Cash','UPI','Bank Transfer','Card','Other')),
  reference text not null default '',
  status text not null default 'Cleared' check(status in ('Cleared','Pending','Reversed')),
  recorded_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists fee_payments_account_date_idx
  on public.fee_payments(account_id,payment_date desc);

create table if not exists public.rfid_card_assignments (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null unique references public.students(id) on delete cascade,
  card_uid text not null unique check (length(trim(card_uid)) > 0),
  assigned_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists rfid_card_assignments_uid_idx
  on public.rfid_card_assignments(card_uid);

create table if not exists public.rfid_attendance_events (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references public.students(id) on delete restrict,
  event_type text not null check (event_type in ('IN','OUT')),
  method text not null default 'RFID' check (method in ('RFID','Manual')),
  scanned_by uuid references auth.users(id) on delete set null,
  scanned_at timestamptz not null default now()
);
create index if not exists rfid_attendance_student_time_idx
  on public.rfid_attendance_events(student_id,scanned_at desc);
create index if not exists rfid_attendance_time_idx
  on public.rfid_attendance_events(scanned_at desc);

-- Keep imported example records separate from real student accounts and payment ledger.
-- Contact numbers are deliberately not copied into the demo tables.
create table if not exists public.fee_demo_students (
  student_code text primary key,
  display_name text not null,
  class_name text not null,
  pay_mode text not null check(pay_mode in ('Monthly Pay','Yearly Pay')),
  discount numeric(12,2) not null default 0 check(discount >= 0),
  due_date date,
  reminder_status text not null default '',
  created_at timestamptz not null default now()
);

create table if not exists public.fee_demo_payments (
  id uuid primary key default gen_random_uuid(),
  receipt_no text not null unique,
  student_code text not null references public.fee_demo_students(student_code) on delete cascade,
  payment_date date not null,
  amount numeric(12,2) not null check(amount > 0),
  payment_mode text not null,
  reference text not null default '',
  status text not null
);

insert into public.fee_demo_students
  (student_code,display_name,class_name,pay_mode,discount,due_date,reminder_status)
values
  ('STU-101','Arjun Kumar','V CBSE','Monthly Pay',1000,'2026-10-15','WhatsApp sent (sample)'),
  ('STU-102','Priya Dharshini','IX CBSE','Yearly Pay',0,'2026-09-10','WhatsApp sent (sample)'),
  ('STU-103','Karthik Raja','V M.ST','Monthly Pay',500,'2026-11-05','WhatsApp sent (sample)'),
  ('STU-124','Milan','IX CBSE','Monthly Pay',1500,'2026-11-13','WhatsApp sent (sample)'),
  ('STU-133','Mas','III CBSE','Monthly Pay',1000,'2026-11-13','Pending (sample)')
on conflict(student_code) do nothing;

insert into public.fee_demo_payments
  (receipt_no,student_code,payment_date,amount,payment_mode,reference,status)
values
  ('REC-001','STU-101','2026-06-15',10000,'UPI','First instalment (sample)','Cleared'),
  ('REC-002','STU-102','2026-07-10',15000,'Cash','First instalment (sample)','Cleared'),
  ('REC-003','STU-103','2026-08-20',10000,'UPI','First instalment (sample)','Cleared'),
  ('REC-11495','STU-124','2026-11-13',3000,'Cash','','Cleared'),
  ('REC-81158','STU-133','2026-11-13',5000,'Cash','Admission instalment (sample)','Cleared')
on conflict(receipt_no) do nothing;

alter table public.fee_class_rates enable row level security;
alter table public.student_fee_accounts enable row level security;
alter table public.fee_payments enable row level security;
alter table public.rfid_card_assignments enable row level security;
alter table public.rfid_attendance_events enable row level security;
alter table public.fee_demo_students enable row level security;
alter table public.fee_demo_payments enable row level security;

drop policy if exists fee_class_rates_admin_only on public.fee_class_rates;
create policy fee_class_rates_admin_only on public.fee_class_rates
for all to authenticated using(private.is_academy_admin())
with check(private.is_academy_admin());

drop policy if exists student_fee_accounts_admin_only on public.student_fee_accounts;
create policy student_fee_accounts_admin_only on public.student_fee_accounts
for all to authenticated using(private.is_academy_admin())
with check(private.is_academy_admin());

drop policy if exists fee_payments_admin_only on public.fee_payments;
create policy fee_payments_admin_only on public.fee_payments
for all to authenticated using(private.is_academy_admin())
with check(private.is_academy_admin());

drop policy if exists rfid_cards_admin_all on public.rfid_card_assignments;
create policy rfid_cards_admin_all on public.rfid_card_assignments
for all to authenticated using(private.is_academy_admin())
with check(private.is_academy_admin());

drop policy if exists rfid_events_admin_all on public.rfid_attendance_events;
create policy rfid_events_admin_all on public.rfid_attendance_events
for all to authenticated using(private.is_academy_admin())
with check(private.is_academy_admin());

drop policy if exists fee_demo_students_admin_only on public.fee_demo_students;
create policy fee_demo_students_admin_only on public.fee_demo_students
for all to authenticated using(private.is_academy_admin())
with check(private.is_academy_admin());

drop policy if exists fee_demo_payments_admin_only on public.fee_demo_payments;
create policy fee_demo_payments_admin_only on public.fee_demo_payments
for all to authenticated using(private.is_academy_admin())
with check(private.is_academy_admin());

revoke all on public.fee_class_rates,public.student_fee_accounts,public.fee_payments,
  public.rfid_card_assignments,public.rfid_attendance_events,
  public.fee_demo_students,public.fee_demo_payments from anon;
grant select,insert,update,delete on public.fee_class_rates,public.student_fee_accounts,
  public.fee_payments,public.rfid_card_assignments,public.rfid_attendance_events,
  public.fee_demo_students,public.fee_demo_payments to authenticated;

notify pgrst, 'reload schema';
commit;