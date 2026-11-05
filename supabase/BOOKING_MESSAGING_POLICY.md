# Booking-based messaging policy

Apply this policy in the database message-send operation when booking chat is connected. Creating or confirming a booking currently creates no conversation.

- A proposal records its author's consent in `bookings.proposed_by`. Acceptance by the other participant sets `confirmed_at`. Both actions belong to the student or tutor. Admin safety access grants no chat access.
- The pair qualifies for unrestricted messaging once a booking has both participants' consent. At send time, check for an accepted booking for the same student and tutor with `confirmed_at <= now()` and `ends_at + interval '72 hours' > now()`. Eligible statuses are `confirmed`, `completed` and `no_show`. Each accepted booking extends the window through 72 hours after that session ends. A cancelled or declined booking contributes no window. An unconfirmed or legacy booking with no recorded confirmation contributes no window.
- Outside that window, allow up to three messages per sender, per student–tutor pair, per calendar day in Africa/Johannesburg for pairs with an established booking relationship. A booking-related conversation may be opened by a participant only after mutual acceptance. Give new pairs a booking-request path and use the request notes for context.
- The database must check membership, eligibility and the daily quota when sending. Enforce the quota atomically across tabs and conversations for the same pair, including messages subsequently deleted. Show a reset time in the client when the quota is reached.
- Cover acceptance by either role, cross-pair isolation, cancellation, overlapping bookings, the exact 72-hour boundary, midnight in South Africa and concurrent sends. Messages remain visible only to conversation participants.
