# Express Auth JWT (project scaffold)

This project scaffold creates a production-oriented Express authentication service with:
- JWT access + rotating refresh tokens
- Refresh tokens persisted hashed in DB (Mongoose)
- DeviceId support for multi-device sessions
- Account lockout after repeated failed logins
- Forgot/reset password flow using secure emailed token (token stored hashed)
- "Remember me" support (longer refresh cookie)
- express-validator input validation
- Rate limiting, helmet, CORS, cookie-parser

## How to use the setup script
1. Copy `.env.example` to `.env` and fill required values.
2. Run `npm install`.
3. Run `node create_auth_project.sh` (if you used the script) or start with `npm run dev`.

## CSRF and cross-site refresh flows (brief)
CSRF (Cross-Site Request Forgery) is an attack where a third-party site causes a user's browser to perform actions on another site where the user is authenticated (via cookies). When refresh tokens are stored in httpOnly cookies, endpoints that rely on cookies (e.g., `/refresh`) can be triggered by cross-site requests unless protected.

Cross-site refresh flow refers to using the browser cookie to automatically send refresh tokens from another origin (e.g., SPA served from `app.example.com` refreshing tokens held by `api.example.com`). To protect these flows:
- Use `SameSite=Lax` or `SameSite=Strict` for cookies where possible to prevent cookies being sent for third-party requests.
- Use double-submit cookie or anti-CSRF tokens (server issues a CSRF token rendered into the SPA and the SPA sends it as a header when calling the refresh endpoint; server validates header matches cookie-bound value).
- Alternatively require the refresh endpoint to read the refresh token from request body (not recommended since it exposes token to JS) or use a custom header and require CORS preflight + same-origin checks.

Benefits of proper CSRF protection: prevents a malicious website from silently performing token refreshes or logouts on behalf of the user, preventing session hijacking or unwanted state changes.

## Access token in JSON vs cookie (which is better?)
- Returning the access token as **JSON** and sending the refresh token as an **httpOnly cookie** is a common, secure approach:
  - Access token is kept in memory on the client (not persisted in localStorage) and attached to `Authorization: Bearer <token>` for API calls.
  - Refresh token lives in httpOnly cookie (not accessible to JS) to reduce XSS risk. Rotation and server-side revocation are used to limit abuse.
- Storing the access token in a cookie is possible but reintroduces CSRF risks for stateful endpoints and makes it harder to follow the `Authorization` header convention. If you place the access token in a cookie, ensure you protect endpoints against CSRF (CSRF tokens or same-site cookies) and accept the trade-offs.

Recommendation: return access token as JSON (in-memory) and store refresh token only as httpOnly cookie with rotation and server-side revocation.

## Security notes
- Use strong, secret environment variables and consider RS256 for high-security needs.
- Ensure HTTPS in production and set `COOKIE_SECURE=true`.
- Use logging and monitoring for suspicious refresh-token activity.

