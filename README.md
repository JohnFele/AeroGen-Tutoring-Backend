# AeroGen backend

Express API backed by Supabase Auth and PostgreSQL. Supabase Auth manages sign-in and sessions; the API verifies access tokens and reads each caller's profile under Row Level Security.

## Local setup

1. Copy `.env.example` to `.env` and set `SUPABASE_URL` and `SUPABASE_PUBLISHABLE_KEY` from the Supabase project.
2. Configure Email and Google under Supabase Dashboard → Authentication → Providers. The Google Identity Services button also uses `VITE_GOOGLE_CLIENT_ID` in the frontend environment.
3. Install dependencies and run `npm run dev`.

## Database

The Supabase project has the following migrations applied:

- `20261023162023_profiles_and_auth.sql` — user profiles linked to Supabase Auth, new-user triggers, and a backfill for existing Auth users.
- `20261023162028_marketplace_tables.sql` — tutor applications and profiles, subjects, bookings, reviews, conversations, messages, payments, notifications, private application-document storage, and RLS policies.
- `20261023162155_catalog_indexes_security.sql` — frontend subject catalog seed data, foreign-key indexes, and restricted trigger-function permissions.
- `20261023215848_user_profile_settings_update.sql` — lets authenticated users update only their own editable profile columns under RLS.
- `20261027200804_expanded_subject_catalog.sql` — expands the subject catalogue, adds education-level mappings, category foreign keys, aliases and read-only public catalogue access.
- `20261028150158_demo_account_isolation.sql` — adds trusted demo-data markers and the initial discovery restrictions.
- `20261028152900_live_tutor_discovery_and_management.sql` — intentionally publishes approved demo tutors, adds featured profiles, administrator RLS, audited tutor editing and participant-scoped workspace operations.
- `20261028155253_tutor_edit_conflicts_without_transaction_retries.sql` — returns HTTP 409 for outdated edits without triggering PostgREST serialization retries.

Apply these migrations in timestamp order when setting up another Supabase project. Keep the matching files in `supabase/migrations` synchronized with the remote migration history.

The authenticated API exposes `/users/me` for reading and updating editable profile fields, plus `/users/me/notification-preferences` for managing per-user alert settings. Tutor management and the account workspace APIs are documented in [tutor management](supabase/TUTOR_MANAGEMENT.md). Booking creation and payment processing still use the existing manual request flow.

The subjects page and public subject selectors now read the live Supabase catalogue. See [subject catalogue maintenance](supabase/SUBJECT_CATALOG.md) for the model, generated offline snapshot, validation and future additions.

For persistent test students/tutors and linked bookings, conversations, reviews, notifications and simulated payments, see [live demo account data](supabase/LIVE_DEMO_DATA.md). Credentials stay in the ignored `.local/demo-accounts.md`; demo fixtures never run automatically during app startup.

## Environment variables

Backend: `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY`, `PORT`, `NODE_ENV`, `FRONTEND_ORIGINS_DEV`, and `FRONTEND_ORIGINS_PROD`.

Frontend: `VITE_SUPABASE_URL`, `VITE_SUPABASE_PUBLISHABLE_KEY`, `VITE_BASE_URL_DEV`, `VITE_BASE_URL_PROD`, and `VITE_GOOGLE_CLIENT_ID`.

## Website enquiries and tutor applications

Set `BREVO_API_KEY` to a Brevo API key (not an SMTP key), `BREVO_SENDER_EMAIL` to your verified sender, and optionally `BREVO_SENDER_NAME`. All website requests go to `aerogentutoring@gmail.com`; the visitor's email is the reply-to address.

- `POST /api/v1/site/enquiries` accepts `firstName`, `lastName`, `email`, `category`, and `message` (10–3500 characters). Categories: `general`, `tutoring`, `billing`, `technical`, `partnership`, `careers`, `talent`, `other`. This public endpoint is rate limited to five attempts per 15 minutes per IP.
- `POST /api/v1/site/subject-requests` accepts an unlisted `subjectName`, `educationLevel`, `helpNeeded` (20–2000 characters), `lessonMode` (`online`, `in-person`, `either`), and contact `firstName`, `lastName`, `email`. Optional context includes `moduleCode`, `institution`, `programme`, `studyYear`, and `location`; institution is required for college/university levels and location for in-person lessons. Subject/module names are free text, so they need not exist in the catalogue. The existing enquiry rate limiter and Brevo sender are reused. Requests go to the fixed team inbox for manual review; they do not automatically publish a subject or create a booking.
- `POST /api/v1/site/tutor-applications` requires a Supabase bearer token and accepts `application` fields plus `documents: [{ kind, name, content }]`, where content is base64. ID and qualification documents are required; CV is optional. ID/CV limits are 5 MB each; qualifications allow 10 MB. The endpoint verifies supported file signatures and is limited to three attempts per hour per IP. Authentication runs before the larger JSON parser.

These endpoints return `202` only after Brevo accepts the email. Booking and pricing submissions are requests for manual follow-up; they do not create confirmed bookings, charge users, activate plans, or approve tutors. Tutor applications and missing-subject requests are emailed for review rather than stored as new database records by these endpoints. Browser drafts exclude ID numbers, street addresses, and documents.

Run `node --test --test-isolation=none tests/site-requests.test.mjs tests/subject-requests.test.mjs` for validation, provider-failure, attachment, unlisted-module and HTTP route checks. Provider calls are mocked; these tests do not send email.
