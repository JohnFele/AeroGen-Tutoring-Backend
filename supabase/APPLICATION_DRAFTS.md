# Cross-device tutor application drafts

Migration `20261029174310_private_cross_device_application_drafts.sql` is applied to the connected project. Deploy the matching backend and frontend together. No new dependency, environment variable or public bucket is required.

## Applicant experience

The first page starts with the account's name, email, phone and recognised profile location. City/suburb and province remain editable. An existing account draft takes precedence over profile defaults.

**Save & Continue Later** explicitly saves incomplete fields, current stage and documents to the signed-in account. Wait for the success message before leaving. Sign in to the same account on another device and reopen the application to restore it. Subsequent changes require another save. A successful submission removes the account draft in the same transaction that creates the application.

Only one draft exists per account. Saves and saved-draft submissions check the current version under a database lock. An outdated save returns 409; the frontend keeps the current entries and offers an explicit reload that replaces them. It never silently overwrites a newer account draft. Previously completed stages remain navigable, but restored progress is clamped to the first incomplete stage.

Legacy browser drafts contain only the previously allowed non-document fields. When no account draft exists, they are offered as the initial form values and uploaded only after an explicit save. New draft identity numbers, addresses and files are not persisted to browser storage.

## API and storage

- `GET /api/v1/site/tutor-application-draft`: authenticated owner draft or null. Responses use `Cache-Control: no-store`.
- `PUT /api/v1/site/tutor-application-draft`: `{accountId,id,saveId,expectedVersion,application,documents,step,furthestStep}`. A new draft uses `expectedVersion:null`; updates use the returned integer version. IDs and save IDs are UUIDs. Replaying a committed save ID returns its saved draft.
- New documents use `{kind,name,content}` with base64 content; existing documents use `{kind,savedId}`. At most one ID, qualification and optional CV document are accepted. Shared signature, MIME and size validation runs before uploads and again for final submission. The authenticated upload parser allows 28 MB JSON, matching the existing application upload limits.
- The draft response exposes document IDs, names, sizes and kinds, never private object paths. `POST /api/v1/site/tutor-applications` accepts `draftVersion` and saved document IDs; the server resolves only the caller's current draft files, then performs the existing complete application validation and atomic submission.

RLS allows only an owner to read their row; raw client writes are revoked. Guarded RPCs enforce ownership, role, version, field allowlists, document metadata and actual object existence. Files use the existing private `tutor-application-documents` bucket under owner/draft UUID paths. Other accounts cannot read either the row or files. Replaced files and submitted draft copies are cleaned up through owner-scoped Storage calls; final submitted copies remain protected by the existing attachment policies. If a write outcome cannot be determined after a network failure, newly uploaded files are retained privately rather than risking deletion of committed draft files.

## Verification

Run `node --test --test-isolation=none tests/*.test.mjs`. Run `supabase/tests/application_drafts.sql` as a complete transaction; its checks roll back.

Live HTTP checks used two independent sign-ins to one fictional demo account: incomplete save with a private PDF, second-device restoration, full save with two PDFs, stale-save rejection, submission using saved document IDs, automatic draft removal and idempotent submission retry. A different account could not read the draft or download its files. Generated application, notifications and files were removed afterward; original demo bookings were preserved.

Browser checks covered profile prefill, equal City/Province heights at 320/768/1440 pixels, manual save/restoration, preservation of edits after a conflict, explicit reload, restored document descriptors and saved-file submission. These UI checks use temporary mocked transport; the separate HTTP checks verify actual database and Storage behavior.
