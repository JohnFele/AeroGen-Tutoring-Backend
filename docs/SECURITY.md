# Security deployment and verification

## Administrator authentication

Admins and superusers must enroll a TOTP authenticator. Verification lasts seven
days within the same signed-in session; reopening the browser does not require
another code during that window. Signing out or using a new session requires MFA.
The frontend gate mounts private data providers only after AAL2 verification.
Settings > Security supports adding another authenticator and removing an old
one after a replacement is verified. Do not remove the last working authenticator.
Setup keys live only in the enrollment component's memory, never application storage.

The API checks AAL only after Supabase Auth verifies the exact access token. The
database's `private.is_platform_admin()` also requires AAL2 and a signed TOTP
authentication-method timestamp within seven days,
protecting direct Data API requests and privileged RPCs. Role checks use protected
profile records, never editable user metadata. Learner-clearance administration
and admin resource-library access have the same requirement.

Deploy the matching frontend before applying `require_staff_mfa`, then deploy the
matching backend. An existing admin session may need a fresh page load to show
the enrollment/challenge screen. Students and tutors keep their current sign-in flow.
Do not turn off MFA to work around an old frontend build.

For a lost device, the project owner must independently verify the administrator's
identity, record the recovery decision, revoke existing sessions and remove the
lost factor using Supabase's administrative controls. The administrator then
signs in and enrolls a replacement. Never accept a support message alone as proof
of identity, and never request the person's authenticator secret or password.

## Remembered sessions

Remember me is selected by default and retains credentials for up to 30 days from
the successful sign-in. Unchecking it uses session storage. Refreshing access
tokens does not restart this deadline. Google sign-in follows the same preference;
One Tap away from the login form defaults to a remembered session.

The API's `my_session_security` lookup uses the actual Supabase session ID, owner,
creation time and any earlier `not_after` limit. Missing, removed, mismatched or
30-day-old sessions are rejected. The browser receives the authoritative deadline
and signs out locally on expiry. Access tokens remain short lived and refresh
normally. The client's persistence selection is not itself an authorization rule.
Project-wide Supabase Auth refresh lifetime controls remain a separate setting;
the application API's lifetime guard does not reconfigure the managed Auth service.

Demo records are preserved for historical audit but excluded from public tutor
discovery, booking student search, saved-tutor responses and normal admin lists.

## Production HTTP configuration

Set `NODE_ENV=production` and configure Render's `FRONTEND_ORIGINS_PROD`:

```text
FRONTEND_ORIGINS_PROD=https://aerogen-tut.netlify.app
```

Use comma-separated exact HTTPS origins for additional domains. Bare hostnames
are normalized to HTTPS; wildcards, credentials, paths and query strings are
rejected. An empty list denies browser origins. Requests without an Origin header
still require authorization for protected operations; CORS is not authentication.

Private API responses, including authorization failures, use `no-store` and vary
on Authorization. This does not disable the frontend's account-scoped memory
cache or optimistic updates. Rate limits run before JSON upload parsing. Existing
limits are process-local: use an edge/shared limiter before scaling to multiple
backend instances. Do not enable unconditional `trust proxy` to bypass IP limits.

## Database boundaries

The tutor directory is a security-invoker view. Anonymous discovery remains
available while underlying RLS hides unapproved tutor profiles. SQL tests cover
anonymous access, cross-user reads/edits, role escalation and AAL1/AAL2 staff access.
Each test rolls back its fixtures. Historical workflow fixtures use AAL2 to model
verified administrator sessions; `staff_mfa.sql` separately tests denial cases.

## Outstanding production controls

- Supabase reported leaked-password protection disabled. Enable it in Auth password
  settings when supported by the project's plan; do not claim the password policy
  checks compromised passwords until it is enabled.
- Configure CAPTCHA/abuse controls for direct Supabase Auth signup and recovery.
  Express rate limits cannot govern requests made directly to Supabase Auth.
- Monitor Auth/audit logs and application failures. Test restore procedures and
  secure storage/backup retention before a paid launch.
- This pass is not a complete penetration test or an exhaustive RPC/RLS audit.

References: https://supabase.com/docs/guides/auth/auth-mfa and
https://supabase.com/docs/guides/auth/password-security
