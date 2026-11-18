# Booking messaging

Bookings create one canonical conversation per tutor/student pair, including existing eligible bookings. Requests allow limited planning messages; confirmation opens full messaging until three days after the latest applicable accepted lesson. Cancelled bookings do not extend that window. History remains readable when sending is limited or blocked.

Outside the accepted-booking window, each participant can send five messages per pair per Africa/Johannesburg calendar day. The database serialises sends per account, enforces a 30-message/minute burst limit, and accepts a client request UUID for safe retries. A duplicate key returns the original message; reusing a key for different content fails. Direct client message writes are not granted.

The API adds bounded account/IP request limits for chat traffic rather than exhausting the general website limit through polling. These HTTP limits do not replace the database rules.

## API

- `GET /workspace/conversations?page=1&q=...`: 20 private conversation summaries, total and access state.
- `GET /workspace/conversations/:id`: resolve an owned conversation ID or a booking partner's profile ID.
- `GET /workspace/conversations/:id/messages?before=...&beforeId=...`: 50 messages, chronological display order and an opaque timestamp/UUID boundary. Preserve the timestamp's fractional precision.
- `POST /workspace/conversations/:id/messages`: `{ body, requestId }`; returns the saved message and authoritative access state.
- `PATCH /workspace/conversations/:id/read`: monotonic read position, with `lastMessageId`.
- `PATCH /workspace/conversations/:id/block`: `{ blocked }`; either participant's block stops sends in both directions. Each participant can remove only their own block.
- `POST /workspace/messages/:id/report`: `{ description, requestId }`; reports a received message through an idempotent conduct ticket.
- `GET /workspace/notification-summary`: owner-only notification rows/count/revision; excludes bookings, payments and conversations.

The frontend patches pending/saved/failed messages and read positions without remounting the conversation. Retries reuse their original UUID. History uses a composite `(created_at, id)` boundary to handle tied timestamps. Polling, focus and online recovery supplement Realtime; only the active conversation and current conversation-list page are refreshed.

## Realtime and privacy

The shared owner-only `workspace_signals` subscription carries independent activity and message versions. Message events refresh chat and notification summaries; general activity still updates the workspace and can change booking eligibility. Consumers share the channel and release it when the final observer leaves.

Message reports attach only the reported message to the support ticket. The assigned administrator and superusers can inspect that evidence through the ticket endpoint. They do not gain access to the entire conversation. Block and report writes require confirmation in the UI. Reporting does not automatically block a conversation.

The original zero-argument workspace RPC and two-argument send RPC remain compatible for older deployed clients. The updated backend requests the lightweight workspace overload and requires idempotent send keys.

## Verification

Run `node --test tests/*.test.mjs`. The SQL tests `supabase/tests/booking_messaging.sql`, `messaging_signal_routing.sql` and `learning_goal_guidance.sql` run in transactions and end with rollback. They cover authorisation, quotas, retries, reporting, read positions, cancellation, SAST reset, history boundaries, signal routing and isolated tutor training progress. Never remove rollback when testing against the hosted project.
