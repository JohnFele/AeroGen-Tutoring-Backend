# Live tutor directory and management

Applied migrations: `20261028152900_live_tutor_discovery_and_management.sql` and `20261028155253_tutor_edit_conflicts_without_transaction_retries.sql`.

## Publication

`public.tutor_directory` is a security-invoker view with explicit public read grants. It projects approved tutors accepting students, assigned active subjects and actual published-review aggregates. It contains no profile emails, phones or application documents. The four approved seeded tutors are intentionally public and visibly labelled as demo accounts. The fifth seeded profile awaits approval. `is_featured` controls homepage placement; pausing or unapproving a tutor automatically clears it. `avatar_url` is optional and must use HTTPS.

## Administrator API

All routes require a verified Supabase access token and the protected `profiles.role` value `admin` or `superUser`. Normal students/tutors receive 403. No service-role key is used.

- `GET /api/v1/admin/tutors`: all tutor profiles with account contacts and subject assignments, including pending profiles.
- `PATCH /api/v1/admin/tutors/:uuid`: `{ changes, subjectIds?, expectedUpdatedAt }`. Explicit editable field allowlist; subject IDs reference the active catalogue. Pass the original database timestamp unchanged, preserving microseconds. Stale saves return 409. Roles, account ownership and demo markers are not editable here.
- `GET /api/v1/admin/tutors/:uuid/audit`: latest 20 profile edits and actor names.
- `GET /api/v1/admin/data`: live users, profiles, bookings, payments and application summaries for admin pages. Demo payments must never be reported as real revenue.

`admin_update_tutor` is an invoker function. RLS independently checks the protected profile role using `private.is_platform_admin()`. The edit locks the profile, checks its timestamp, updates fields and subject links atomically, synchronizes the latest application's approval status and appends before/after values to `tutor_profile_audit`. Only admins can read the audit; ordinary callers cannot modify tutors. The audit records API edits; direct privileged SQL maintenance must maintain its own change records.

Use `PT409` for application-level edit conflicts. SQLSTATE `40001` causes retry loops on affected PostgREST versions; see the [Supabase troubleshooting article](https://supabase.com/kb/troubleshooting/high-cpu-and-infinite-transaction-retries-when-using-custom-error-codes-in-rpc-functions).

## Account workspace

`GET /api/v1/workspace` returns only the caller's bookings, payments, member conversations and notifications. Counterpart names come from joined database profiles, without exposing private email or phone values. Responses currently cap bookings at 1,000, conversations at 200 and messages per conversation at the latest 200. Extend with paginated history endpoints before users exceed those limits.

`POST /workspace/conversations/:uuid/messages` persists a message with the caller as sender, requires membership, and creates in-app notifications for other members. `PATCH /workspace/conversations/:uuid/read`, `PATCH /workspace/notifications/read` (`{ids}` up to 500), and `DELETE /workspace/notifications/:uuid` operate only on the caller's rows. Clients poll while visible; this is not a Realtime subscription. These operations do not send emails.

The two workspace RPCs use definer access to project counterpart names hidden by profile RLS. They explicitly check `auth.uid()` and membership for every operation and are executable only by authenticated callers. Supabase declined the optional follow-up migration moving their implementations into a private schema, without returning a reason. That migration was not applied. The existing authorization guards passed cross-account tests; the public definer RPC advisory remains for later review. The pre-existing leaked-password-protection setting was not changed.

## Verification

`node --test --test-isolation=none tests/*.test.mjs` checks field validation, forbidden ownership/role edits and HTTP conflict mapping. `node scripts/verify-demo-accounts.mjs` signs in all 11 private-manifest accounts, checks account-scoped data and workspace API access, verifies admin denial and confirms four public approved demo tutors. It prints no passwords or tokens.

Run `supabase/tests/tutor_management.sql` and `supabase/tests/live_demo.sql` inside `BEGIN ... ROLLBACK` using the SQL connector. Checks cover admin edits reflected in the public view, audit history, stale edits, invalid subjects, approval/unapproval, private workspace scopes and denied cross-conversation sends. The browser checks used real public directory reads and mocked admin transport; a separate real admin HTTP check verified listing, profile joins, saved featured state, anonymous visibility, conflict rejection and audit reads, then restored the demo tutor's original featured flag.

Deploy backend and frontend together. The connected Supabase migrations are already applied. New project setups must apply all migrations in timestamp order. No new environment variables or dependencies are required.

For the new application-review and student management pages, see [pending application-review activation](APPLICATION_REVIEW.md). The existing tutor directory migrations above remain applied; the separate application-review SQL was declined and is not applied.
