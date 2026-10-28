# Application review and student management

## Activation status: pending database approval

The initial migration attempts were declined or returned `McpServerError: Invalid or expired requestState`. On an explicitly approved retry, Supabase reached SQL execution and reported `42601: syntax error at end of input`. The prepared script was corrected: PL/pgSQL function bodies now end with `end;`, and the document-size CASE expression is parenthesized. Re-applying the corrected script again returned `Invalid or expired requestState`, including a fresh longer-lived request. Read-only verification confirms that no application-review functions/table/columns were applied. **The SQL in `supabase/application_review.sql` remains pending and has not been executed successfully.**

The UI, backend handlers, validation and tests are ready. Student read endpoints were verified with a real admin account. Submission was verified to return 503 before uploading anything when required schema fields are absent. Full live submission, private-document signing, approval, role promotion, review history and student updates remain unverified and unavailable until the SQL is applied.

Apply the reviewed SQL once through an approved Supabase migration operation or the project's SQL Editor. Then reconcile local/remote migration history using the project's Supabase CLI workflow; do not claim this file is already an applied migration or invent a version number. Run the transaction-only database checks in `supabase/tests/application_review.sql`, check security advisors, then perform the live HTTP/application tests below before deploying both repositories.

## User flow

Admin dashboard → Users groups **Tutor management** and **Student management**, with consistent profile cards and editors. The All users page is removed; its legacy tab opens student management. **Tutor applications** is an independent sidebar page at `/admin/dashboard/applications`, protected by the same admin role guard. Application details are grouped to match the stages of the tutor submission form.

An authenticated student or tutor submits the website form. The backend validates required fields and document signatures, resolves subjects against the active catalogue, uploads files to the existing private bucket, and calls a transaction that saves the application, subject links and document metadata together. Admin accounts receive in-app application notifications. Submission does not depend on Brevo and no longer emails identity documents. Historical email-only applications cannot be reconstructed automatically; they need to be resubmitted or imported separately.

The form checks the applicant's latest application. Submitted or under-review applications show their status instead of a duplicate form; approved applicants see approval and sign-in guidance; rejected applicants see review notes and can apply again. A stable per-form `submissionId` makes retries idempotent. A database uniqueness constraint permits only one open application per account. An interrupted response is checked for a committed application before any unattached files are removed.

Administrators can read all applications and their submitted contact, identity, education, experience and teaching details. Required ID and qualification files must exist before approval. Private download links are issued on demand, last 60 seconds, and require admin authorization. They should be treated as confidential bearer links.

Review decisions are `under_review`, `approved`, or `rejected`; rejection requires a reason. Notes are visible to the applicant. Final decisions cannot be reversed through the review form; use tutor management to pause an already approved tutor. Each decision records reviewer, time, old/new status and notes. Updates use the application version captured when the review opens; polling does not silently advance that version while an admin is editing.

Approval atomically creates or updates the public tutor profile from the submitted details, replaces subject assignments, approves and publishes the profile, changes an ordinary student account's role to tutor, appends a tutor audit event, updates application status and notifies the applicant. It preserves the demo marker and does not automatically feature the tutor. The applicant signs in again to refresh the dashboard role. This app currently has one account role; approval converts a student account to a tutor account rather than adding a second role.

Student management lists actual student profiles, verification status and booking counts. Admins can view their latest 100 bookings and edit first/last name, phone, location and biography. Login emails, verification, roles, demo markers and passwords are not editable here. Student saves also reject outdated versions.

## API contracts

All admin routes verify the Supabase token and protected profile role (`admin` or `superUser`). No service key is exposed or required.

- `POST /api/v1/site/tutor-applications`: existing `{application,documents}` plus optional UUID `submissionId`. Returns 201 with `applicationId,status` after storage and database success; a retry of an existing ID returns 200. Duplicate open applications return 409; invalid input returns 400. Missing activation schema returns 503 before uploading files. The upload limiter applies only to POST; status reads do not exhaust upload attempts.
- `GET /api/v1/site/tutor-applications/me`: authenticated caller's latest status and review notes, or null.
- `GET /api/v1/admin/applications`: all applications, subject links, document metadata and review history, with explicit paging beyond the default API row limit.
- `PATCH /api/v1/admin/applications/:id/review`: `{status,notes,expectedUpdatedAt}`; preserves PostgreSQL timestamp precision. Returns the updated application and associated tutor ID. Outdated reviews return 409 using `PT409`, avoiding PostgREST serialization retry loops.
- `GET /api/v1/admin/applications/:id/documents/:documentId`: `{url,expiresIn:60}` for an authorized private download.
- `GET /api/v1/admin/students`: student profiles with booking counts.
- `GET /api/v1/admin/students/:id`: student profile and latest 100 bookings.
- `PATCH /api/v1/admin/students/:id`: `{changes,expectedUpdatedAt}`; allowed fields are `first_name,last_name,phone,location,bio`.

## Security and verification

New privileged implementations live in `private`, with fixed search paths and explicit caller/admin checks. Public RPC wrappers use invoker security. Raw application/subject/document writes by ordinary clients are revoked; applicants can read their own application and files. Uploaded document paths are bound to caller UUID and application UUID. The submission transaction validates object existence, MIME metadata, byte sizes and required document types. Attached files cannot be deleted or replaced by applicants; cleanup permits only their unattached uploads. RLS restricts review records to admins. Roles and ownership are never taken from submitted JSON or user metadata.

Automated backend checks cover input/role allowlists, idempotent retries, duplicate applications, missing schema, private path construction, cleanup after failure, response loss after commit, outdated reviews and required rejection notes. Browser checks used mocked admin transport and covered grouped navigation, review states, required documents, temporary links, conflict errors, draft preservation, student editing, applicant status/reapplication and 320/768/1440-pixel layouts. No fixture transport is part of production code.

After applying SQL, run `supabase/tests/application_review.sql` as a complete transaction. It intentionally rolls back its application, storage-metadata, review, profile and role changes. It does not prove real file upload/signing: also sign in with a fictional demo student, submit generated test-only PDFs through HTTP, verify admin list/document access, reject and reapply, approve, sign in again to confirm tutor access, check anonymous directory publication, and restore only the explicit test records. Never use real identity documents in automated tests. No new dependency or environment variable is required.

## Stage validation

The frontend uses explicit state validation for every application stage, including whitespace-only values, email/phone format, qualification years, required checkbox groups, rate limits and document metadata. Forward navigation validates all preceding stages. Previously reached stages are clickable; removing required information invalidates them again. Final submission validates the whole application and preserves inputs/files and its idempotency reference after an API failure. Settings, tutor/student editors and booking stages also validate before sending data; authentication, subject requests, enquiries and learning forms retain their existing validators. Search/filter forms intentionally allow empty queries. Backend application validation independently enforces required fields, lengths, types and document signatures.
