# Subject catalogue

The catalogue contains 444 tutoring areas across 16 categories and eight education levels. It includes primary foundations, school subjects and language streams, college/TVET subjects, and undergraduate/postgraduate disciplines. A subject can belong to several levels. These tags describe suitable discovery areas; they do not certify a curriculum, accreditation or institution's module requirements.

No finite list captures every university's module titles. The schema accepts additional subjects, categories and levels as data, so a school-specific subject or university module does not require a schema change. The page provides a contact route for subjects that are not listed.

## Model

| Table | Purpose |
| --- | --- |
| `subject_categories` | Stable category slug, unique display name, emoji, ordering and active flag. |
| `education_levels` | Extensible level code/name, optional grade range, ordering and active flag. Grade R is represented as 0. Tertiary/adult levels have no grade range. |
| `subjects` | Existing stable bigint ID, unique name/slug and active flag, plus aliases, editorial popular flag and ordering. Its existing `category` column now references the unique category name. Renaming a category cascades to its subjects. |
| `subject_education_levels` | Composite `(subject_id, level_code)` primary key maps each subject to one or more levels. Both foreign keys are indexed. |

The original 53 subject names, slugs and IDs are retained. Existing application, tutor and booking foreign keys continue to reference the same IDs. The new catalogue does not create tutors, approve applications or assert tutor availability. Popular flags are editorial discovery picks, not measured booking demand. The old illustrative tutor counts were removed from subject cards.

All catalogue tables use RLS. Anonymous and authenticated clients can read active entries; they cannot insert, update or delete them. Changes must run through trusted, reviewed migrations. Hiding a level also hides its public mappings. The existing tutor subject/application junctions continue to use `subjects.id`.

## Frontend

The subjects page, public tutor-search subject filter, and tutor-application subject picker share `useSubjectCatalog`. It reads Supabase with explicit pagination and normalises nested level mappings. Search matches names, category names and aliases; education-level and category filters combine. Previews show six subjects and expand in batches. Application selections are capped at the existing server limit of 30.

A generated frontend snapshot keeps the catalogue usable during an outage or before environment configuration. A visible fallback notice and retry control distinguish saved data from successful live reads. No service-role key is used in the browser. Supabase remains the live source, so trusted database additions appear on the next page load without a frontend rebuild; regenerate the snapshot before a release so offline data also includes them.

## Maintaining the seed

The canonical seed is `src/data/subjectCatalog.js`. Its compact groups specify category and level membership, and each line can include search aliases. Keep subject names/slugs stable to avoid breaking URLs and references. Change editorial popular picks through `popularNames`.

From the backend repository:

```powershell
node scripts/generate-subject-catalog.mjs
node scripts/generate-subject-catalog.mjs --check
node --test --test-isolation=none tests/subject-catalog.test.mjs
```

For a future catalogue expansion, update the canonical source, regenerate the frontend snapshot, and generate a **data-only** seed:

```powershell
node scripts/generate-subject-catalog.mjs --seed-output expanded-catalog-seed.sql
```

Review that SQL and apply it as a new Supabase migration, then save the matching file/version in migration history. Do not rerun `--sql-output` on an existing database: that option includes the one-time table/column/policy DDL. Do not edit an already-applied migration. The data-only seed is additive and preserves existing IDs, inactive flags and custom level links. Removing a subject/level association or renaming a subject requires an explicit reviewed migration; deactivate retired subjects rather than deleting referenced records.

Run `supabase/tests/subject_catalog.sql` inside a transaction after migration to check coverage, links and anonymous/authenticated access. The frontend tests verify alias/level search, immutable popular-first ordering and pagination beyond 1,000 rows. The backend tests and generator's `--check` option verify that the bundled snapshot matches the canonical seed.

## Reference scope

School-phase and subject coverage was checked against the [DBE CAPS FET subject directory](https://www.education.gov.za/Curriculum/NCSGradesR12/CAPSFET/tabid/570/Default.aspx) and [DBE curriculum guidance](https://www.gov.za/faq/education/what-caps). Broad tertiary discipline coverage was checked against the [UCT faculty handbooks directory](https://www.uct.ac.za/students/study-uct-handbooks/handbooks). This is a tutoring discovery catalogue, not an official universal module list; institution-specific course codes and syllabuses must be supplied by the learner or institution.
