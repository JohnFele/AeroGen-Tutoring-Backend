# Site administration specification

Build order: public-controls → site-content → enquiries → legal-pages.

| Module | Responsibility | Acceptance |
| --- | --- | --- |
| public-controls | Application stage navigation, call link, unsupported support claims | Stage-number clicks preserve scroll; call link has a full-width visible button; no support live-chat promises remain. |
| site-content | Admin careers and contact settings | No seeded jobs. Admins create/edit/publish/close/delete openings; only published unexpired jobs are public. Contact email, phone, hours and operator details persist and feed public pages. |
| enquiries | Private contact inbox and replies | Validate then save before email notification; duplicate request IDs do not resend; only admins read/update/reply; statuses, notes, reply delivery outcomes and stale edit protection. |
| legal-pages | Privacy, terms and cookies | Public linked readable pages reflect actual app storage/providers, South African rights, minors, documents, requests and service limitations. John Fele is operator; address is intentionally blank; no invented registration/officer. |

Reuse React/Tailwind dashboard panels, Express, Supabase RLS and Brevo; no new dependencies. Backend routes independently validate inputs and role; database checks protect direct API use. Keep application and dashboard layout patterns. Save admin edits against versions and preserve errors/entered values.

Verify with `node --test --test-isolation=none tests/*.test.mjs` in each repository, targeted frontend ESLint, `npm run build`, transaction-only database security checks, live HTTP checks using explicit test records and browser checks at 320/768/1440 px. Email delivery is mocked in tests; never email fictional users. Remove test fixtures/data. No deployment/push is part of this request.

Legal source basis: POPIA (Justice consolidated Act), Electronic Communications and Transactions Act 25 of 2002, Consumer Protection Act 68 of 2008 and the Information Regulator complaints page. Content is operational drafting, not certification of compliance. Publication of a supplier address and confirmation/registration of the Information Officer remain launch responsibilities; cookie text must change if tracking providers change.

## Deployed schema and API

Migration `20261029183257_site_administration_and_enquiries.sql` is applied. It creates public contact settings and published job listings, plus an admin-only enquiry inbox and reply history. There are no seeded vacancies. Public listings exclude expired jobs using South Africa dates, including the closing day. RLS and explicit grants apply to every table; anonymous enquiry insertion is available only through a validated, rate-bounded function that never returns private message data.

- Public `GET /site/contact-details`, `GET /site/openings` return current settings and all current published openings.
- Public `POST /site/enquiries` accepts `{id,firstName,lastName,email,category,message,website}`. `id` is a per-submission UUID (legacy clients without one get a server-generated ID); `website` is a honeypot. Returns 202 with a reference only after persistence. A duplicate identical ID does not create another record or notification. Email notification failure does not erase or reject the stored enquiry. Failed email notifications are logged without the enquiry content.
- Admin `GET/PUT /admin/contact-details`, `GET/POST /admin/openings`, `PATCH/DELETE /admin/openings/:id` manage public data. Updates/deletes require `expectedVersion`; the database increments versions. This setting changes public contact details and enquiry notification routing, not Supabase SMTP credentials or the separate existing dashboard-support recipient.
- Admin `GET /admin/enquiries?status=&email=&page=` returns 25 records with an exact count. Email search and status filtering apply server-side. `GET /admin/enquiries/:id` includes private message, internal notes and replies; `PATCH` accepts only status/notes plus `expectedVersion`.
- `POST /admin/enquiries/:id/replies` accepts `{id,message,expectedVersion}`. A database transaction claims the reply UUID and advances the enquiry before Brevo is called. The recipient comes only from the stored sender email; the contact email is Reply-To, and the configured Brevo sender stays unchanged. Replays return the existing result without another email.

Email outcomes distinguish provider acceptance, definite failure and uncertainty. A server failure between claiming and recording delivery can leave a pending reply; a network timeout can leave delivery unknown. Check Brevo before starting a new reply in either case. Provider acceptance is not a delivery/read receipt. There is no automatic retry worker or inbound email synchronisation; replies sent directly in an external mailbox are not imported. Enquiries that previously existed only as email are not reconstructed into the new inbox.

## Verification results

49 backend and 65 frontend tests pass. The SQL transaction test verifies public/draft/expired visibility, private inbox access, ordinary-user write denial, versions and idempotency, then rolls back. Live HTTP tests used real admin/student sign-ins and proved anonymous/student rejection, enquiry persistence/list/detail/notes, reply idempotency, contact version updates and opening draft → published → closed → deletion. Brevo was intercepted locally, so no real test emails were sent. Generated enquiry and replies were deleted explicitly; no vacancies remain. The contact save reused existing values and did not alter business contact details.

Browser checks cover the three admin pages, form errors, public contact refresh, call-button dimensions, enquiry notes/replies, empty careers, legal routes and 320/768/1440 layouts. Application stage-number clicks preserve scroll position. Temporary browser transport fixtures are removed before commit.

## Legal launch follow-up

Operator: John Fele. Address and registration number remain empty as instructed; no separate Information Officer is invented. Add the actual supplier address and confirm the Information Officer registration/arrangements before launch. Confirm guardian-consent handling, operational retention and any real checkout/cancellation terms before expanding those services; written policies do not implement those controls. No claim of certified legal compliance is made.

Primary references:

- [POPIA consolidated Act](https://www.justice.gov.za/legislation/acts/2013-004.pdf)
- [Electronic Communications and Transactions Act](https://www.gov.za/sites/default/files/gcis_document/201409/a25-02.pdf)
- [Consumer Protection Act](https://www.gov.za/sites/default/files/gcis_document/201409/321864670.pdf)
- [Information Regulator complaints](https://inforegulator.org.za/complaints/)
