# Application identities and account actions

The application identity and staff actions, privilege isolation and universal account support migrations must be applied before deploying this backend. All three have been applied to the connected project. They add the profile correction flag, format-specific application prices, public invoker wrappers around private privileged operations and support access for every account role. Existing clients that submit only `hourlyRate` remain supported; new clients collect the rate for every selected teaching format.

## Tutor identities

Identity/passport values are normalised to uppercase letters and digits and SHA-256 hashed for a private, unique claim. The database trigger serialises concurrent claims, permits revisions by the same owner and rejects claims by a second account. Claims are not exposed through the Data API. This prevents duplicate declared identities; document review is still necessary to establish that the document belongs to its applicant.

Existing application identity values are preserved. Historical identities shared by multiple owners are quarantined, and their owners receive `identityCorrectionRequired` in their own profile response. Those accounts are excluded from discovery and bookings and redirected from dashboards to the application. The application restores their previously submitted fields and private documents. They must enter the number on their own document; a legitimate shared-number conflict needs support investigation, not an invented replacement. A corrected submission clears the correction flag but pauses tutor approval and acceptance until an administrator approves it again. Old application history remains unchanged.

## Administrator access

Admins and superusers can use the explicit **Make admin** action in student/tutor management, with confirmation and current profile-version checking. `promote_platform_admin` requires a verified staff MFA session, locks the target profile, prevents self/superuser changes, rejects demo and identity-blocked accounts, and records a private audit entry. It only grants `admin`. Promoting a tutor pauses their public listing. Administrators are listed under Settings → Administrators; their authenticator requirement remains in force.

## Support, trust calls and logout

The global Support dialog is available outside the dashboard and MFA gates. Guests submit an email enquiry through the existing rate-limited public enquiry endpoint; signed-in users create an account ticket. The universal account support migration separates support ownership from billing roles: students, tutors, admins and superusers can create, read, reply to and resolve their own general tickets. Staff have a separate **My support tickets** dashboard page. This does not expand billing permissions. Required fields use shared form validation, and a task spinner indicates submission. No password or identity number should be entered in support text.

Lesson acceptance, rejection and cancellation update the affected booking immediately after the existing confirmation dialog. Success reconciles with the response; failure restores only that booking, shows an error alert, and queues an owner-scoped notification. Failed-notification delivery retries when the browser returns online or regains focus. Database participant checks, deduplication and daily limits apply. Successful self-actions still do not generate redundant notifications.

`my_logout_summary` returns only the caller's completed lessons, hours and counterpart counts, or the staff member's assigned-ticket counts. The logout screen receives this snapshot through navigation state. If the endpoint is unavailable, logout still works and the statistics are omitted. No platform totals are substituted.

## Verification

`supabase/tests/application_identity_and_staff.sql` rolls back its test users and changes. It checks normalised identity uniqueness, same-owner revisions, preserved identity history, reapproval after correction, unauthorised promotion, audited/idempotent promotion, stale versions, personal logout data and deduplicated booking-failure notifications. `supabase/tests/application_review.sql` also checks that independent format rates survive submission and approval. Browser checks use isolated mock HTTP responses and do not send support emails or modify real bookings.
