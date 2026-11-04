# Platform controls specification

Keep the existing Settings → Platform settings layout and persist its four switches in Supabase. Only protected admin/superUser accounts can change them. Saves capture a version and write an audit record atomically; stale saves preserve the form.

| Switch | Backend/database contract | Frontend contract |
| --- | --- | --- |
| Accept tutor applications | Reject new submissions before parsing/uploading files and again on database insertion, including direct RPC calls. Existing reviews and saved drafts remain available outside maintenance. | Mark applications paused, disable final submission/advertised application actions; preserve draft editing and saving. |
| Allow student registration | Block new Supabase Auth users, including new Google accounts. Existing accounts can still sign in/recover access. No user metadata can bypass closure. | Disable registration and sign-up prompts, with a clear message; keep existing-account sign-in available. |
| Maintenance mode | Reject ordinary API activity, restrict direct database and Storage access, and guard user SECURITY DEFINER RPC entry points. Preserve admin operations, current-user identity bootstrap, public status/contact reads and Auth recovery. | Replace public pages/dashboards with a maintenance notice for non-admins. Keep admin sign-in, recovery and legal notices accessible. Admins can turn maintenance off. |
| Admin email notifications | Gate company-inbox emails for new tutor applications and contact enquiries. Keep records and in-app notifications. Do not disable confirmation/reset emails or manually sent enquiry replies. | Explain the affected emails and where they go. |

Defaults preserve normal operation. Public status is no-store and contains only flags/version/time. Backend requests load current settings; database checks cover a change occurring after that read. Visible clients refresh on focus and every 15 seconds, and react to maintenance API errors. Never use the browser state as an authorization boundary. No new dependencies or secrets.

The applied migration is `supabase/migrations/20261104203510_enforced_platform_controls.sql`. It adds the settings singleton, protected update RPC, audit history, restrictive maintenance policies, guards for user definer RPCs, and application/Auth insertion triggers. It requires no additional environment variables. Deploy the backend and frontend changes together; the migration has already been applied to the connected Supabase project.

Operational details:

- Registration closure blocks all newly created Auth users, including first-time Google sign-in and trusted Auth Admin API creation. Existing accounts remain able to sign in and recover passwords. There is no metadata bypass; keep an existing administrator account available.
- Maintenance does not revoke Auth sessions or recall downloaded assets and previously issued signed file URLs. Current identity reads and sign-in/recovery remain available so administrators can recover access. Public legal notices and company contact information remain accessible.
- Each new public table or definer RPC added in future must include the appropriate maintenance policy or entry-point guard. The migration covers the current schema; it does not install an event trigger for future tables.
- Admin notification email is best effort after committing an application/enquiry. Provider failure leaves the record available for admin review, without reporting that email was delivered. There is no delivery worker, automatic retry, or historical replay when the switch is re-enabled. Duplicate submissions do not resend notification email.
- An unavailable settings service blocks ordinary operations. Protected admin routes remain reachable, and the admin form preserves edits on failure or version conflict.

Verification completed with 61 backend tests, 70 frontend tests, targeted frontend lint, live HTTP/Auth integration against the connected project, rollback-only SQL policy tests (`supabase/tests/platform_controls.sql`), and browser checks at 320/768/1440 pixels. HTTP checks covered closed registration (including forged admin metadata), submission rejection before JSON/file parsing, readable drafts, notification on/off and idempotency, maintenance denial, and administrator recovery. Brevo was intercepted; no test email was sent. Original flags were restored and generated enquiries removed. Browser checks covered persisted switches, unchanged account tabs, public/student/tutor maintenance views, sign-in/recovery/legal exceptions, registration closure, disabled final application submission with draft saving available, and explicit reload after a version conflict.
