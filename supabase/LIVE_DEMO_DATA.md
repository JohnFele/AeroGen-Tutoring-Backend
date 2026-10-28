# Live demo accounts and integration data

Project: `kthvlatelonjdlhsagcu` (AeroGen-Tutoring Backend). Dataset: `aerogen-live-demo-v1`.

These are real Supabase email/password accounts with fictional application data. They are available for integration testing without modifying existing real users. They have ordinary `student` or `tutor` roles, not administrator privileges. The addresses use the non-deliverable `example.test` domain and are already confirmed. Use password sign-in; Google sign-in, email delivery and password-reset delivery cannot be tested with these fictional addresses.

## Accounts

Passwords are randomly generated and stored only in the Git-ignored `.local/demo-accounts.md` and `.local/demo-accounts.json`. Never copy these credentials into tracked source files or a public frontend bundle. Keep a private copy: rerunning the seed intentionally does not reset existing account passwords.

| Email | Role | Test scenario |
| --- | --- | --- |
| demo.student.primary@example.test | Student | Grade 5, maths and English, completed/upcoming lessons |
| demo.student.school@example.test | Student | Grade 11 sciences, upcoming and cancelled lessons |
| demo.student.university@example.test | Student | Engineering, completed/confirmed/pending lessons, module notes |
| demo.student.college@example.test | Student | Accounting, completed and upcoming lessons |
| demo.student.postgraduate@example.test | Student | Statistics/research, declined lesson and failed simulated payment |
| demo.student.new@example.test | Student | Empty bookings, messages and notifications |
| demo.tutor.maths@example.test | Tutor | Approved maths/accounting tutor with several students |
| demo.tutor.science@example.test | Tutor | Approved science tutor; online and in-person lessons |
| demo.tutor.languages@example.test | Tutor | Approved language tutor; completed lesson and review |
| demo.tutor.engineering@example.test | Tutor | Approved university engineering tutor; module support |
| demo.tutor.pending@example.test | Tutor | Submitted application; unapproved, hidden from discovery |

## Connected data

- 11 Auth users and email identities, with matching verified profiles.
- 5 tutor profiles, 5 applications, and subject assignments referencing the live catalogue.
- 12 bookings across `completed`, `confirmed`, `pending`, `cancelled` and `declined` states.
- 12 **simulated** payment records across paid, authorized, pending, refunded and failed states. Every payment uses `provider = 'demo'`; no gateway request or real transaction occurs.
- 4 published demo reviews attached to completed demo bookings.
- 4 conversations, 8 memberships and 12 messages, including read/unread examples.
- 9 notifications with read/unread examples.
- Notification preferences initially disable all email and push channels for demo users. No real identity documents or private application files are created.

The initial schedule is anchored to **28 October 2026 in Africa/Johannesburg**. Source dates are generated relative to an anchor date. Existing records, passwords and read states are preserved on rerun, so dates and statuses do not automatically move as time passes. An intentional fixture reset/refresh should be a separate reviewed operation, scoped to this dataset; never delete users just by matching an email domain.

## Isolation and frontend integration

`profiles.demo_dataset` and `tutor_profiles.demo_dataset` mark the test cohort. Profile update permissions exclude the marker. The discovery policies allow demo users to see approved tutors in their own dataset while excluding demo tutors from anonymous and non-demo discovery. Pending tutors can read their own tutor profile/subjects but remain undiscoverable to other users. Existing booking/payment/conversation/notification RLS restricts reads to participants/owners.

The `/api/v1/users/me` and profile-update responses now include `isDemo` and `demoDataset`. Use those fields for a future test-account banner and to suppress external side effects. Exclude `profiles.demo_dataset is not null` and `payments.provider = 'demo'` from real business metrics and revenue reporting. Do not route demo payment rows into a live payment provider.

The fixture does not implement missing booking or messaging write endpoints, and it does not replace dashboard localStorage/JavaScript fixtures. The accounts and records are ready to use when those screens are connected. Learning-goal/progress, pricing/subscription, resources and saved-tutor flows still need their own persistent models/API integration where they currently use local mocks.

## Reproduction and checks

The optional seed is separate from schema migrations and never runs during backend startup or deployment. The schema migration is `20261028150158_demo_account_isolation.sql`. Apply normal migrations first when setting up another project.

```powershell
node scripts/generate-demo-fixture.mjs
node --test --test-isolation=none tests/demo-dataset.test.mjs
```

The generator writes:

- `supabase/seeds/live_demo.sql`: tracked, password-free fixture.
- `.local/demo-bootstrap.sql`: private transaction including newly generated passwords.
- `.local/demo-accounts.md` / `.json`: private login credentials.
- `.local/demo-fixture.json`: local expected relationships and counts.

The private bootstrap uses the connected privileged SQL tool to insert only explicitly allowlisted demo users/identities and records. It hashes new passwords with bcrypt, confirms only these fictional emails, refuses non-demo ID/email collisions, and preserves existing accounts/passwords on rerun. It does not require adding a service-role key to the application. This seed is coupled to the inspected Auth schema; inspect current Auth columns and rerun a rollback-only dry run before applying it to a different Supabase/Auth version. Do not put fixture account creation into migrations or ordinary application endpoints.

Run the bootstrap in a single privileged transaction. Then verify through normal published APIs using the existing project URL/publishable key:

```powershell
node scripts/verify-demo-accounts.mjs
```

This signs in each demo account, calls the actual backend `/users/me` handler through a local HTTP server, checks normal RLS-protected reads, and signs out each test session. It prints account keys and counts only—never passwords, API keys, or tokens—and saves `.local/demo-verification.json`.

Run `supabase/tests/live_demo.sql` inside a transaction to verify public/demo/owner isolation. The bootstrap and seed can be rerun safely to fill missing rows; `ON CONFLICT` preserves existing scenario changes. Do not remove `.local` credentials and regenerate expecting existing passwords to change. Reset lost passwords only for explicit demo accounts through a trusted admin operation.

Supabase Auth seeding uses the documented [Auth users/identities model](https://supabase.com/docs/guides/auth/users) and [bcrypt password storage](https://supabase.com/docs/guides/auth/password-security). Where an admin API key is available, the [Auth Admin createUser API](https://supabase.com/docs/reference/javascript/auth-admin-createuser) is also suitable for confirmed test accounts; no privileged key is exposed to the frontend here.
