# First Step Academy Website

A static HTML/CSS/JavaScript website with a Supabase-backed academy portal.

## Pages
- Home
- Courses
- About
- Achievements
- Gallery
- Contact
- Academy Portal (admin, staff and student login)

## Current portal capabilities
- Admin admissions and student board/section management
- Staff attendance and student attendance
- Attendance sections: CBSE Sections A (Classes 1–5), B (6–8), D (Class 9), E (Class 10); State Board Section C (Classes 6–10)
- Separate Spoken English and Hindi attendance categories
- CBSE Classes 9 and 10 require a subject; CBSE Classes 11 and 12 use class + subject only, without sections
- Admin-controlled staff attendance permissions: assigned sections only or all Sections A–E
- Monthly Excel workbook with separate worksheets for Sections A–E, Spoken English, Hindi and CBSE Classes 11–12
- Additional cross-section class-and-subject assignments for Classes 9–10 with weekday scheduling (e.g. CBSE Section D Class 9 / Section E Class 10 Social Science)
- Subject-specific access for Classes 11–12
- Student and staff dashboards, class attendance, admin-only RFID IN/OUT attendance, achievements and gallery
- Student achievements
- Staff gallery submissions with admin approval
- Admin gallery publishing and website content editor
- Admin-only fee management: class-wise fee rates, student fee accounts, discounts, due dates, payment receipts and payment history
- Separate admin-only sample fee data preview; demo records are isolated from real student accounts and the live payment ledger

## Deployment
This is a static site. Publish the repository root directory with a static hosting provider. Keep all HTML files and `favicon.svg` in the published root so the relative page links work.

The homepage links to `portal.html` using a relative path. This lets the site move between hosting providers or custom domains without editing the portal URL.

The Netlify preview branch for final pre-launch testing is `prelaunch-finalization-20261113`. The production branch remains `main`.

## Supabase setup files

For a new, empty Supabase project:
1. Apply `supabase-setup.sql` to create the base tables and starter policies.
2. Apply `supabase/first-step-portal-setup.sql` to add portal features, section/subject attendance, RLS, CMS and gallery. Leave management and its notification workflow are intentionally excluded. RFID attendance uses the additional admin-only tables `rfid_card_assignments` and `rfid_attendance_events` created by this setup script. Fee management uses the admin-only tables `fee_class_rates`, `student_fee_accounts` and `fee_payments`.
3. Create Auth users and their matching `profiles` rows. Link student records to their Auth users through `students.auth_user_id`.
4. Assign staff sections and senior subjects through the admin portal.

For an existing project that already has the portal tables:
- Use the relevant migration file only after checking which migrations have already been applied.
- `supabase/cms-gallery-migration.sql` creates the CMS table, gallery table, storage bucket and related policies.
- `supabase/subject-attendance-migration.sql` adds subject-based attendance and senior roster access to an existing portal setup.
- `supabase/fee-rfid-admin-migration.sql` safely adds the fee and RFID tables plus isolated admin-only demo fee records to an existing portal project. It does not import sample students into `public.students` or sample payments into the live payment ledger.
- `supabase/cross-section-subject-assignments.sql` adds admin-managed cross-section class/subject timetable assignments and matching staff roster/attendance access rules.
- `supabase/attendance_sections_access_and_reporting.sql` adds Section E, staff attendance access modes, the final section/subject RLS rules and monthly report access.

The SQL scripts are idempotent where practical, but always take a backup before applying schema or policy changes to a live project.

## Security notes
- The browser uses only the Supabase publishable/anon key.
- Never put a Supabase `service_role` or secret key in HTML, JavaScript, GitHub, or any public client.
- Keep row-level security enabled on exposed tables.
- The gallery bucket is public so approved gallery images can appear on the public website. Review the approval/privacy workflow before uploading identifiable student photos.

## Pending academy-provided content
The phone number, email/address details and any academy story video should be filled in only after the academy provides the final approved content.
