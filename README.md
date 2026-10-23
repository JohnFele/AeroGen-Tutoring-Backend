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

Apply these migrations in timestamp order when setting up another Supabase project. Keep the matching files in `supabase/migrations` synchronized with the remote migration history.

The authenticated API exposes `/users/me` for reading and updating editable profile fields, plus `/users/me/notification-preferences` for managing per-user alert settings. Tutor, booking, messaging, and payment screens still need their persistent data flows connected.

## Environment variables

Backend: `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY`, `PORT`, `NODE_ENV`, `FRONTEND_ORIGINS_DEV`, and `FRONTEND_ORIGINS_PROD`.

Frontend: `VITE_SUPABASE_URL`, `VITE_SUPABASE_PUBLISHABLE_KEY`, `VITE_BASE_URL_DEV`, `VITE_BASE_URL_PROD`, and `VITE_GOOGLE_CLIENT_ID`.
