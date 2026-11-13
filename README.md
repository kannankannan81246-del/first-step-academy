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
- Subject-based attendance for Classes 9–12
- One staff member per section and one section per staff member
- Subject-specific access for Classes 11–12
- Student and staff dashboards, attendance, notices, achievements and gallery
- Notices and student achievements
- Staff gallery submissions with admin approval
- Admin gallery publishing and website content editor

## Deployment
This is a static site. Publish the repository root directory with a static hosting provider. Keep all HTML files and `favicon.svg` in the published root so the relative page links work.

The homepage links to `portal.html` using a relative path. This lets the site move between hosting providers or custom domains without editing the portal URL.

## Supabase setup files

For a new, empty Supabase project:
1. Apply `supabase-setup.sql` to create the base tables and starter policies.
2. Apply `supabase/first-step-portal-setup.sql` to add portal features, section/subject attendance, RLS, CMS and gallery. Leave management and its notification workflow are intentionally excluded.
3. Create Auth users and their matching `profiles` rows. Link student records to their Auth users through `students.auth_user_id`.
4. Assign staff sections and senior subjects through the admin portal.

For an existing project that already has the portal tables:
- Use the relevant migration file only after checking which migrations have already been applied.
- `supabase/cms-gallery-migration.sql` creates the CMS table, gallery table, storage bucket and related policies.
- `supabase/subject-attendance-migration.sql` adds subject-based attendance and senior roster access to an existing portal setup.

The SQL scripts are idempotent where practical, but always take a backup before applying schema or policy changes to a live project.

## Security notes
- The browser uses only the Supabase publishable/anon key.
- Never put a Supabase `service_role` or secret key in HTML, JavaScript, GitHub, or any public client.
- Keep row-level security enabled on exposed tables.
- The gallery bucket is public so approved gallery images can appear on the public website. Review the approval/privacy workflow before uploading identifiable student photos.

## Pending academy-provided content
The phone number, email/address details and any academy story video should be filled in only after the academy provides the final approved content.
