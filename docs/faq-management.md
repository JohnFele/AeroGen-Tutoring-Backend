# FAQ management

Admins open **Company actions → FAQs** at `/admin/dashboard?tab=faqs`. They can add/edit questions and answers, reuse or create a category, set a display order, save drafts, publish/unpublish, and delete with confirmation. Lower order numbers appear first; categories follow their first question. Content is plain text with preserved answer line breaks. The public page retains the existing design, search, category counts and filters; categories are derived from published questions.

Migration `20261104200432_faq_content_management.sql` is applied. It adds `site_faqs` with UUIDs, bounded category/question/answer text, integer display order, draft/published status and a version trigger. Anonymous and ordinary signed-in readers see only published rows. Inserts, updates and deletes require the protected admin role in both Express and RLS. Case-insensitive duplicate questions within a category are rejected.

The existing 21 questions across six categories are seeded once. Unsupported claims about automatic payouts, blanket refunds, background screening and encryption guarantees were corrected to reflect current functionality. The seed is not used as a runtime fallback, so unpublished/deleted content cannot reappear through hardcoded data.

## API

- `GET /api/v1/site/faqs`: public published fields `{id,category,question,answer,sort_order}` only; `Cache-Control: no-store`. The server forces published status even if an admin supplies credentials. Reads paginate to fetch the complete set; any failed page rejects the whole refresh.
- `GET /api/v1/admin/faqs`: all statuses, versions and timestamps; admin middleware sets no-store.
- `POST /api/v1/admin/faqs`: `{faq:{category,question,answer,sort_order,status}}` → 201 `{faq}`.
- `PATCH /api/v1/admin/faqs/:id`: same FAQ fields plus `expectedVersion` → updated `{faq}`. A stale version returns 409 without overwriting. The editor preserves entries and offers explicit reload.
- `DELETE /api/v1/admin/faqs/:id`: `{expectedVersion}` → `{deleted:true}`; stale deletes return 409.

Limits: category 2–80 characters, question 5–250 on one line, answer 10–8000, order integer 0–10000. All categories is reserved for the public filter. Only known fields/statuses are accepted. Browser and server validators agree; SQL constraints also protect direct database API use.

Public content reloads on page mount, window focus and a same-tab FAQ-change event. This is not a realtime subscription. Failed loads show Retry; a genuinely empty published list shows its own empty state.

## Verification and rollout

54 backend and 68 frontend tests pass. `supabase/tests/faq_management.sql` checks anonymous/student allow/deny for reads and writes, admin publishing, unpublishing, version advancement, stale edits and deletion in a rolled-back transaction. Live HTTP checks used real admin/student sign-ins to create a draft, publish, edit, reject a stale edit, unpublish and delete the generated FAQ. The test record was cleaned up; the original 21 remain. No emails were sent.

Browser checks cover adding/editing/publishing/deleting, cancelled deletion, stale save/reload, public search and dynamic category counts, hidden drafts, line breaks, error/retry state, and the page/editor at 320/768/1440 px. Temporary test fixtures are not committed. New database objects introduced no new security-advisor warnings; the project's earlier warnings are unchanged.

Deploy frontend and backend together; the hosted backend needs the new routes before the public page can load its saved FAQs. No new dependency or environment variable is needed. Do not re-run the seed after editors have changed the content.
