# Account notifications

Applied migration: `20261104210932_live_account_notifications.sql`. No extra keys or dependencies are required.

Existing application submission/review RPCs already create admin and applicant alerts. The new database triggers add booking/status/schedule changes, payment status changes, published review updates and new website enquiries. Message alerts still originate from the protected send RPC. Optional message, booking and payment alerts respect saved `push_*` in-app preferences; missing preference rows default to enabled. Changes to preferences affect future alerts, not stored history.

`workspace_signals` publishes only an owner ID, version and timestamp. Owner-only RLS and the maintenance policy apply. Notification inserts, reads and deletes change this record, allowing cross-device refresh without publishing private notification bodies or unfilterable deletion payloads. Messages also invalidate workspaces when their optional alerts are muted. The frontend reconnects, refreshes on focus and polls every 30 seconds as a fallback. Existing live sessions remain subject to database authorization.

`GET /workspace` returns the latest 50 alerts, the complete unread count and a revision. `GET /workspace/notifications?filter=all|unread&cursor=...` pages through older history with a timestamp/UUID cursor that preserves PostgreSQL precision. `PATCH /workspace/notifications/read` accepts either `ids` (at most 500 UUIDs) or `all:true`; it updates only unread rows owned by the caller. Deleting an inaccessible or missing notification returns 404. Raw notification content is not editable by clients.

Chat read acknowledgements carry the last visible message ID. The backend checks conversation membership and message ownership, and read positions cannot move backwards. Reading through a message also acknowledges that conversation's older notification alerts. This prevents a later incoming message being incorrectly marked read by an older browser view.

This is the in-app notification system. Existing company-inbox Brevo notification emails are unchanged; this change does not add browser push or a user email delivery worker. Events have no retrospective backfill or synthetic session/payment creation. Pending bookings remain pending until a real booking change occurs.

Verified with controller/unit tests, rollback-only SQL tests (`supabase/tests/account_notifications.sql`), and live HTTP requests with two authenticated Realtime subscribers. The generated owner-only test notification was marked read and deleted; no test email was sent. SQL tests preserve all saved platform flags, including maintenance, by rolling back their temporary changes.
