# Proposal: subscription features, paid lessons and a 30-day trial

Status: planning and Linear backlog creation authorised; implementation and commercial decisions remain pending. No charge, account migration or deployment is authorised by a planning document. The previous messaging/support plan was completed before this proposal replaced it.

## Recommended model

Use Free, Pro and Premium names for both students and tutors. Sell software membership separately from lessons. Start with pay-per-lesson checkout; offer optional tutor-specific lesson packs after the funding rules are verified.

The alternative is retaining combined subscriptions and lesson bundles. That is possible, but variable tutor/mode prices require funded allowances, top-ups and tighter margin controls. The separate model gives the clearest feature-only trial and is recommended.

All prices and limits below are hypotheses for approval, not proven willingness to pay. Billing is every 30 days, matching the existing app, rather than ambiguously described as a calendar month. Validate processing/payout costs, refunds, operating costs and applicable taxes before approving production prices. Defer annual billing.

## Findings in the app

- Live student plans: Pay Per Session R0, Learning Package R1,799 with 8 credits, Premium Success R3,499 with 16 credits.
- Live tutor plans: Basic R0/15% commission, Pro R199/10%, Elite R399/5%.
- Legacy credits contribute up to R230 towards a lesson of at most 60 minutes, with a top-up for higher prices.
- Example margin: 16 fully used R230 credits represent R3,680 of lessons. At 5% commission, tutor proceeds are R3,496, leaving R3 of a R3,499 package before other costs. This is an illustrative case using current rules, not every booking's economics.
- Marketing benefits are partly frontend text. Published tutor resources currently reach all approved tutors without subscription-tier filtering. Learning and recurring actions need a common entitlement layer.
- Dedicated managers, broad marketing services and unlimited-change promises should not be launch benefits without a working service and capacity.
- Payments are simulated. Mock credits and mock-success transactions must not become real funded value at gateway cutover.

## Proposed student tiers

Every tier pays separately for lessons.

| Feature | Free | Pro | Premium |
|---|---|---|---|
| Subscription / 30 days | R0 | R79 | R149 |
| Active subject learning plans | 1 | 5 | 15 |
| Active goals across the account | 3 | 20 | 60 |
| Progress tools | Basic recorded results and goal status | Subject baseline/latest/target trends | Pro plus compatible cross-subject/period analysis |
| Performance reports | Basic on-screen summary | On-demand monthly PDF | Flexible reports and scheduled weekly summaries |
| Recurring requests | Individual lessons | Weekly | Daily, weekly and monthly |
| Study organisation | Goal deadlines | Study checklist | Exam planner, reminders and linked reviews |
| General support | Standard | Standard | Priority after severity/category triage |

Matching, curriculum/subject choice, saved tutors, availability, paid bookings, basic records, receipts, privacy controls and safety support stay Free. Active excludes completed/archived/cancelled goals and plans. Learner limits apply to tutor-created proposals too; completing a goal frees a slot. Limits do not restrict subjects a student may study or tutors they may book.

Scheduled reports and the exam planner require implementation; do not sell them as available before verification. Show evidence-based results only, including honest missing-data states, without invented progress or guaranteed exam outcomes.

## Proposed tutor tiers

| Feature | Free | Pro | Premium |
|---|---|---|---|
| Subscription / 30 days | R0 | R149 | R299 |
| Commission on newly funded lessons | 15% | 12% | 10% |
| Approved listing, own rates, availability, students, booking chat | Included | Included | Included |
| Shared learner goals and feedback | Core workflow | Core workflow | Core workflow |
| Training/resources | Essential platform, safety and goal-setting content | Free + Pro guides/courses | All published Premium guides/courses |
| Saved reusable goal/lesson templates | Manual creation | 10 templates | 50 templates + bulk preparation |
| Recurring proposals | Individual lessons | Weekly | Daily, weekly and monthly |
| Analytics | Lessons, earnings and ratings | Monthly trends and learner summaries | Pro + period/cohort/booking comparisons |
| Reports | Income statement and transactions | Individual performance reports | Scheduled/batch performance reports |
| General support | Standard | Standard | Priority after severity/category triage |

Basic bank-style income statements, payouts, disputes, receipts and all safeguarding stay Free. Tutors can always fulfil accepted bookings and provide core feedback. The learner's subscription controls learner plan/goal capacity; the tutor's controls their preparation and analysis tools. A recipient can accept a recurring proposal on Free: the initiator needs permission to create it. Each occurrence still needs acceptance and funding; retain the current 12-occurrence hard cap and normal availability/horizon rules.

Illustrative commission-plus-membership costs on R10,000 of qualifying gross lessons: Free R1,500; Pro R1,349; Premium R1,299. Pro breaks even versus Free on commission savings alone at approximately R4,967 gross per 30 days; Premium versus Pro at R7,500. These exclude refunds and any separately disclosed charges and are not earnings promises.

Do not sell Top rated/New badges or automatic Featured status. Keep Featured curated and preserve matching relevance, saved preferences, curriculum, location and availability. Sponsored placement would need separate labelling and is outside this launch.

## Separate lesson products

- Quote actual tutor + online/physical mode + duration + published rate. No new universal R230 price/coverage assumption.
- No membership grants unlimited or free lessons. Requests spend nothing; acceptance reserves purchased entitlement or awaits separate checkout. Distinguish accepted, awaiting payment and funded states.
- Lock price/commission when funding succeeds; later membership changes cannot rewrite that payment or tutor earnings.
- Keep held/released/refunded funds and dual attendance/dispute handling. Valid cancellations restore original pack entitlement or refund the original payment.
- Optional four/eight packs specify tutor, format and duration. Four one-hour physical lessons at R400 cost R1,600 unless that tutor explicitly approves a discount.
- Preserve legitimately funded legacy credits/bookings and their terms. Preserve simulated status for mock transactions; never relabel legacy credits as a new real-money balance.

## Thirty-day Premium feature trial

1. Explicit activation after verified email and required profile setup. Tutors start after approval, so review does not consume trial days.
2. No card required, no automatic charge. Paid membership requires explicit checkout/renewal consent. Early paid activation ends the trial only after showing cost, effective date and any feature loss.
3. Duration is exactly 30 x 24 hours from server time; display exact local end date/time.
4. Premium software features at normal limits: goals/plans, reports, recurring tools and applicable library content.
5. ZERO lesson credits, cash, prepaid value, free tutor time, payout advances or financial discounts. Tutor trial commission remains Free's 15%; lower commission requires a paid membership.
6. Store paid billing tier separately from effective feature tier. Never implement a trial by assigning a paid plan ID that can mint lesson credits.
7. One trial per eligible account, recorded server-side across logouts, role changes and browser clearing. Use existing verified tutor identity/contact links and rate limits against repeat claims. Do not promise perfect student per-person deduplication or collect new sensitive IDs solely for trials.
8. Confirm activation with an inline/success alert, rather than a redundant stored self-action notification. Send system reminders at seven days remaining, one day remaining and expiry; respect email preferences and maintain an in-app end-date notice. Never imply a charge without consent.
9. Exact expiry returns to Free even if the reminder worker is stopped. Expiry checks occur on protected operations.
10. Preserve history, evidence, completed training and existing reports. User chooses records fitting Free capacity; otherwise retain the most recently active within limits and archive the rest. Excess records are readable, but paid editing, new content and automation stop. Existing downloaded/generated files cannot be remotely revoked.
11. Accepted/funded lessons stay valid. Existing accepted occurrences remain bookings; new paid series creation/extension is denied after expiry.
12. Trials never bypass consent, safeguarding, tutor approval, identity correction, matching or chat relationship rules.

## Visibility across the app

| Area | Visible difference |
|---|---|
| Public/dashboard pricing | Same catalogue, separate student/tutor comparison, explicit membership fee, tuition separate, commission and trial exclusions |
| Dashboard header/overview | Plan or Premium trial badge, exact expiry, real usage and feature-specific shortcuts |
| My Learning | E.g. 3 of 3 goals used, contextual upgrade before extra creation, real tier-specific reports |
| Calendar/booking | Permitted recurrence choices, plan requirement before data entry, separate tuition checkout and mode rate |
| Resources | Admin-set Free/Pro/Premium tags; safe previews for locked items, never locked bodies delivered then blurred |
| Tutor earnings | Actual fee rate, held/released income, real-data savings comparison, Free statements and paid analysis |
| Billing | Separate membership transactions from lessons/packs, next amount/date and scheduled cancellation |
| Upgrade/downgrade | Exact cost/effective date, lost/unlocked tools, over-limit records and future commission impact |
| Admin | Catalogue/resource tier controls, conversion/usage/failed-payment analysis and abuse review; no per-user package assignment |

Keep navigation stable, with concise locks/upgrade actions on unavailable tools. Expiry/upgrades update affected state without page-wide reloads. Financial activation uses a local verification spinner, not an optimistic paid-access trust call.

## Billing lifecycle and access controls

- Upgrade on verified payment of the prorated difference, preserving renewal date. Halfway from Student Pro R79 to Premium R149 costs R35 for the remaining half-cycle. Compute integer cents and idempotent operations on the server.
- Downgrade/cancel at paid-through date. Failed renewal falls back to Free after paid time expires; restoring paid access requires payment. No unannounced access grace period.
- Subscription loss never deletes purchased lessons, stops booking obligations or restricts safety/refunds/privacy/basic personal records.
- Premium non-safety support priority follows severity; urgent safety receives the same escalation for everyone. Bugs have no guaranteed repair deadline.
- Version catalogue contracts and retain historical prices/IDs. No silent repricing or removal of paid existing terms.

One owner-scoped entitlement snapshot supplies paid plan, effective feature tier, source, limits, usage, version and expiry to the frontend. Enforce again in Express and Supabase RPC/RLS paths, including direct Data API calls. Atomic quota checks must cover concurrent devices and tutor-created learner goals.

Guard reads, course lessons, downloads, reports, recurring actions and scheduled jobs. Private assets need authorised delivery; public external source links cannot become exclusive through a UI lock. Key caches by account/entitlement version and expire protected state on time. Never trust local storage, user-editable metadata or payment-success URL parameters for permissions.

Retain a server-controlled sandbox payment adapter for testing. Real operation requires gateway-verified server events, replay protection and reconciliation; an end-user boolean must never fund real lessons, activate real paid access or authorise payouts. This proposal selects no payment provider.

Future parent/company plans should scope entitlements to an account/organisation, with guardian/tenant permissions checked separately. Those dashboards and group-class hosting are outside this launch.

## Linear delivery tracking — single task source

[Project](https://linear.app/leantechlab/project/aerogen-tutoring-memberships-learning-and-tutor-trust-942fb6f0bb80) · [Editable specification](https://linear.app/leantechlab/document/aerogen-membership-featured-and-learning-delivery-specification-b105b7d10644)

The 39 Linear issues below replace the former 18-item local task breakdown. Acceptance criteria, verification and blocking relations live in each issue. All build work is Backlog pending the decision gates; only the three product decisions are assigned to the verified project owner. Engineering ownership and cycle capacity must be confirmed before moving implementation to Todo. No calendar dates are set.

| Milestone | Approximate focused effort | Required issues |
|---|---|---|
| 0. Decision and access readiness | 2–3 person-days | 3 |
| 1. Membership and financial foundation | 13–21 person-days | 7 |
| 2. My Learning core and trustworthy progress | 12–20 person-days | 7 |
| 3. Paid planning, resources and reports | 16–25 person-days | 9 |
| 4. Featured tutor selection and discovery | 6–10 person-days | 4 |
| 5. App-wide plan experience and commercial clarity | 5–9 person-days | 4 |
| 6. Migration, validation and release readiness | 7–11 person-days | 4 |

These are rough engineering/review effort ranges, not deadlines or elapsed delivery forecasts. The full base scope is approximately 60–100 focused person-days before external waiting time and contingency; optional tutor-specific packs add 2–4 days. Re-estimate after the first representative vertical slice. Milestone numbers group work: the actual blocker graph determines readiness, so Featured work need not wait for Premium report implementation.

### 0. Decision and access readiness

- [ONE-86](https://linear.app/leantechlab/issue/ONE-86/approve-membership-pricing-commissions-and-payment-launch-scope) — Approve membership pricing, commissions and payment launch scope. Estimate: 0.5–1 day.
- [ONE-87](https://linear.app/leantechlab/issue/ONE-87/approve-learning-readiness-personal-plan-permissions-and-quota) — Approve learning readiness, personal-plan permissions and quota lifecycle. Estimate: 0.5–1 day.
- [ONE-88](https://linear.app/leantechlab/issue/ONE-88/approve-featured-selection-rubric-expiry-fairness-and-public-meaning) — Approve Featured selection rubric, expiry, fairness and public meaning. Estimate: 0.5–1 day.

### 1. Membership and financial foundation

- [ONE-89](https://linear.app/leantechlab/issue/ONE-89/publish-one-versioned-membership-and-benefit-catalogue) — Publish one versioned membership and benefit catalogue. Estimate: 1–2 days.
- [ONE-90](https://linear.app/leantechlab/issue/ONE-90/enforce-owner-scoped-feature-entitlements-in-api-and-supabase) — Enforce owner-scoped feature entitlements in API and Supabase. Estimate: 2–3 days.
- [ONE-91](https://linear.app/leantechlab/issue/ONE-91/make-learner-quota-activation-and-downgrade-archiving-atomic) — Make learner quota activation and downgrade archiving atomic. Estimate: 1.5–2.5 days.
- [ONE-92](https://linear.app/leantechlab/issue/ONE-92/deliver-a-30-day-software-only-premium-trial-with-exact-expiry) — Deliver a 30-day software-only Premium trial with exact expiry. Estimate: 2–3 days.
- [ONE-93](https://linear.app/leantechlab/issue/ONE-93/implement-verified-upgrade-renewal-downgrade-and-cancellation) — Implement verified upgrade, renewal, downgrade and cancellation transitions. Estimate: 2–3 days.
- [ONE-94](https://linear.app/leantechlab/issue/ONE-94/separate-sandbox-payment-simulation-from-verified-production-payments) — Separate sandbox payment simulation from verified production payments. Estimate: 2–4 days plus provider lead time.
- [ONE-95](https://linear.app/leantechlab/issue/ONE-95/decouple-lesson-quotes-reservations-and-reversals-from-feature) — Decouple lesson quotes, reservations and reversals from feature membership. Estimate: 2–3 days.

### 2. My Learning core and trustworthy progress

- [ONE-96](https://linear.app/leantechlab/issue/ONE-96/provide-resumable-guardian-authorisation-without-a-full-parent) — Provide resumable guardian authorisation without a full parent dashboard. Estimate: 2–4 days.
- [ONE-97](https://linear.app/leantechlab/issue/ONE-97/let-eligible-learners-start-private-personal-plans-before-booking) — Let eligible learners start private personal plans before booking tuition. Estimate: 2–3 days.
- [ONE-98](https://linear.app/leantechlab/issue/ONE-98/organise-my-learning-around-today-plans-and-progressive-detail) — Organise My Learning around Today, plans and progressive detail. Estimate: 2–3 days.
- [ONE-99](https://linear.app/leantechlab/issue/ONE-99/link-personal-plans-to-approved-tutors-with-scoped-learner-consent) — Link personal plans to approved tutors with scoped learner consent. Estimate: 1.5–2.5 days.
- [ONE-100](https://linear.app/leantechlab/issue/ONE-100/unify-progress-calculations-and-separate-score-skill-and-habit) — Unify progress calculations and separate score, skill and habit evidence. Estimate: 2–3 days.
- [ONE-101](https://linear.app/leantechlab/issue/ONE-101/connect-dashboard-learning-summaries-to-the-canonical-plan-data) — Connect dashboard learning summaries to the canonical plan data. Estimate: 1–2 days.
- [ONE-102](https://linear.app/leantechlab/issue/ONE-102/make-learning-tutorials-tier-aware-action-based-and-resumable-across) — Make learning tutorials tier-aware, action-based and resumable across devices. Estimate: 1.5–2.5 days.

### 3. Paid planning, resources and reports

- [ONE-103](https://linear.app/leantechlab/issue/ONE-103/add-a-pro-personal-study-checklist-linked-to-existing-goals) — Add a Pro personal study checklist linked to existing goals. Estimate: 1.5–2.5 days.
- [ONE-104](https://linear.app/leantechlab/issue/ONE-104/add-a-premium-exam-and-topic-planner-with-controlled-reminders) — Add a Premium exam and topic planner with controlled reminders. Estimate: 2–3 days.
- [ONE-105](https://linear.app/leantechlab/issue/ONE-105/provide-tutor-templates-with-pro-and-premium-storage-limits) — Provide tutor templates with Pro and Premium storage limits. Estimate: 1.5–2.5 days.
- [ONE-106](https://linear.app/leantechlab/issue/ONE-106/allow-premium-bulk-preparation-as-reviewable-learner-specific) — Allow Premium bulk preparation as reviewable learner-specific proposals. Estimate: 1.5–2.5 days.
- [ONE-107](https://linear.app/leantechlab/issue/ONE-107/enforce-minimum-tier-access-for-resource-bodies-courses-and-downloads) — Enforce minimum-tier access for resource bodies, courses and downloads. Estimate: 1.5–2.5 days.
- [ONE-108](https://linear.app/leantechlab/issue/ONE-108/let-admins-curate-resource-tiers-and-keep-goal-guidance-connected) — Let admins curate resource tiers and keep goal guidance connected. Estimate: 1.5–2.5 days.
- [ONE-109](https://linear.app/leantechlab/issue/ONE-109/generate-genuine-period-specific-learning-and-performance-pdfs) — Generate genuine period-specific learning and performance PDFs. Estimate: 2–3 days.
- [ONE-110](https://linear.app/leantechlab/issue/ONE-110/schedule-premium-summaries-and-deliver-private-report-links-safely) — Schedule Premium summaries and deliver private report links safely. Estimate: 2–3 days.
- [ONE-111](https://linear.app/leantechlab/issue/ONE-111/deliver-pro-subject-analysis-and-premium-contextual-comparisons) — Deliver Pro subject analysis and Premium contextual comparisons. Estimate: 2–3 days.

### 4. Featured tutor selection and discovery

- [ONE-112](https://linear.app/leantechlab/issue/ONE-112/implement-audited-featured-selection-eligibility-duration-and-expiry) — Implement audited Featured selection eligibility, duration and expiry. Estimate: 1.5–2.5 days.
- [ONE-113](https://linear.app/leantechlab/issue/ONE-113/replace-the-featured-toggle-with-an-admin-editorial-review-workflow) — Replace the Featured toggle with an admin editorial review workflow. Estimate: 1.5–2.5 days.
- [ONE-114](https://linear.app/leantechlab/issue/ONE-114/let-tutors-request-featured-consideration-and-see-eligibility-feedback) — Let tutors request Featured consideration and see eligibility feedback. Estimate: 1–2 days.
- [ONE-115](https://linear.app/leantechlab/issue/ONE-115/apply-active-featured-selections-consistently-to-nearby-discovery-and) — Apply active Featured selections consistently to nearby discovery and badges. Estimate: 1.5–2.5 days.

### 5. App-wide plan experience and commercial clarity

- [ONE-116](https://linear.app/leantechlab/issue/ONE-116/show-consistent-plan-trial-quota-and-downgrade-state-across-dashboards) — Show consistent plan, trial, quota and downgrade state across dashboards. Estimate: 1.5–2.5 days.
- [ONE-117](https://linear.app/leantechlab/issue/ONE-117/gate-recurrence-by-initiator-plan-while-preserving-accepted-bookings) — Gate recurrence by initiator plan while preserving accepted bookings. Estimate: 1–2 days.
- [ONE-118](https://linear.app/leantechlab/issue/ONE-118/make-public-pricing-dashboard-pricing-and-checkout-explain-the-same) — Make public pricing, dashboard pricing and checkout explain the same product. Estimate: 1.5–2.5 days.
- [ONE-119](https://linear.app/leantechlab/issue/ONE-119/show-real-commission-economics-without-paywalling-income-records) — Show real commission economics without paywalling income records. Estimate: 1–2 days.
- [ONE-120](https://linear.app/leantechlab/issue/ONE-120/optional-sell-tutor-specific-foureight-lesson-packs-after-funding) — Optional: sell tutor-specific four/eight lesson packs after funding approval (optional; not a base-launch blocker). Estimate: 2–4 days.

### 6. Migration, validation and release readiness

- [ONE-121](https://linear.app/leantechlab/issue/ONE-121/migrate-legacy-contracts-credits-and-featured-flags-without-inventing) — Migrate legacy contracts, credits and Featured flags without inventing value. Estimate: 1.5–2.5 days.
- [ONE-122](https://linear.app/leantechlab/issue/ONE-122/verify-the-full-plan-consent-payment-and-direct-rpc-access-matrix) — Verify the full plan, consent, payment and direct-RPC access matrix. Estimate: 2–3 days.
- [ONE-123](https://linear.app/leantechlab/issue/ONE-123/instrument-expiry-report-jobs-and-discovery-performance-without) — Instrument expiry, report jobs and discovery performance without leaking learner data. Estimate: 1–2 days.
- [ONE-124](https://linear.app/leantechlab/issue/ONE-124/run-usability-pilots-and-owner-controlled-staged-release-with-rollback) — Run usability pilots and owner-controlled staged release with rollback. Estimate: 2–3 days plus participant availability.


## Assumptions and decisions

Validate student willingness to pay for tools separately from tuition. Track meaningful trial use, conversion, renewals, downgrade reasons and actual contribution margin. Verify published paid content is substantial before charging for it. Adjust prospective limits after observing real primary/high-school/tertiary workloads.

Exclude dedicated managers, guaranteed results/accreditation, paid achievement badges, free tuition, speculative AI, unlimited live support and unbuilt group classes. Preserve under-18 consent rules independently of payments.

Decision needed: approve/revise separate tools and tuition, proposed prices/commissions/limits and no-card/no-auto-charge trial; or retain combined bundles and redesign their funded economics.

## Evidence

App inspection: frontend pricingPlans.js and DashboardPricingPage.jsx; backend billing, credit funding, resources, learning and recurring migrations; read-only live billing catalogue query.

- Feature-access architecture: https://docs.stripe.com/billing/entitlements?dashboard-or-api=api
- Trial lifecycle: https://docs.stripe.com/billing/subscriptions/trials
- Proration examples: https://docs.stripe.com/billing/subscriptions/prorations
- Local example separating subscription and tuition: https://www.superprof.co.za/help/students/finding-a-tutor/contacting-a-tutor/5/

These sources inform architecture and context; they do not validate AeroGen's proposed prices or select its gateway.


## Delivery addendum: Featured, My Learning and progress
Prepared 19 November 2026. Extends the earlier proposal for the same work. Planning and Linear ticket creation are authorised; implementation and commercial settings remain behind the decision gate. Calendar dates remain unset at the owner's request.

### Featured is an editorial selection, not a paid badge
Free, Pro, Premium and feature-trial tutors have the same selection eligibility. Paid membership and trial status never award Featured, Top rated or New. Cancellation does not remove a still-valid editorial selection. Featured says AeroGen selected this profile for a stated purpose; it does not assert a statistically proven learning advantage.

Eligibility: approved tutor; identity clear and required verification complete; published profile with accurate curriculum/phase/subject/mode/rates; accepting learners with genuinely bookable availability; essential platform/goal-setting/safeguarding training complete; no active safeguarding suspension or confirmed disqualifying conduct decision. An untriaged allegation alone must not automatically establish wrongdoing. Reliability metrics are contextual evidence only when there is a sufficient sample; absence of reviews is not itself disqualifying. A new tutor can therefore be Featured after review without being Top rated.

Admin or superuser selects an eligible tutor for up to 30 days, records a public-safe selection reason and private review evidence, and schedules review. Example reasons: strong subject-profile demonstration or relevant support for an underserved curriculum/location. Record reviewer, effective dates, eligibility snapshot, reason and every change. Prevent self-approval and arbitrary raw is_featured writes bypassing policy. No guaranteed sales or bookings. Free requests for consideration use one open request per tutor and a 30-day resubmission cooldown after a decision; staff nominations remain possible.

Use effective status active/expired/suspended/revoked. Expiry is checked at read time, with an idempotent worker for reminders and review queues. Loss of approval/identity clearance, publication or confirmed safeguarding eligibility suspends selection immediately; ordinary availability changes affect discoverability without alleging misconduct. Tutor receives decision/review status and can correct relevant details or request reconsideration. Public copy exposes safe reasons and review date only, never identity documents or private allegations.

Preserve the existing gold banner design, banner dimensions, reserved spacing and badge precedence: Featured banner first; otherwise Top rated or New banner; additional labels below. Use a tap/keyboard-accessible explanation such as “Selected by AeroGen for [safe reason], reviewed [date].” Premium plan badges remain account UI, not academic achievement labels.

All mandatory filters apply before ranking: subject/curriculum/phase, mode, price, chosen distance, exact availability and approval. Preserve saved-tutor preference and existing nearby/relevance rules; within the eligible result group, both Featured+Top rated precede Featured, then Top rated, then others. A Cape Town feature must not jump a Johannesburg radius filter. Nearby homepage picks use only genuinely eligible nearby tutors and rotate selections fairly without promised impressions. Future Sponsored advertising is a separate labelled product, not this badge.

### What the present learning implementation can and cannot deliver
Verified source: LearningWorkspace.jsx, GoalPlanForms.jsx, LearningGoals.jsx, LearningEvidence.jsx, LearningSkillsPractice.jsx, AssessmentChart.jsx, LearningReport.jsx, useLearningProgress.js, LearningOverview.jsx and goalGuidance.js.

Already reusable: one shared subject plan per learner, curriculum/course context, agreed/versioned score/skill/habit goals, tutor access approval, reviewed work, original assessment marks, independent/comparable result charts, practice and reflection, review dates, corrections/history, an interactive tutorial, resource deep links, and a browser-print report.

Missing or requiring changes: server-enforced tier quotas, personal plans before tuition purchase, access-readiness handling for minors, tier-specific analysis, a central Today/Plans workspace, study checklists, exam planning, reusable templates/bulk preparation, private entitlement-filtered library payloads, downloadable period-specific report snapshots, scheduled summaries and cross-device action-based tutorial state. Existing browser Print/Save PDF is not a scheduled PDF delivery service.

Important incompatibility: current plan creation requires a confirmed/completed lesson relationship. A feature-only trial user without a purchased lesson cannot try most learning tools. Add an eligible learner's private personal plan from their curriculum/phase/subject or tertiary module; no tutor or paid lesson required. Self-entered marks/evidence are labelled self-recorded. Linking an approved tutor later requires an eligible relationship and explicit, scoped learner authorisation; historical entries never become tutor-verified automatically. All existing age/consent restrictions remain; no fake tutor or booking is created to bypass this gap.

Under-18 readiness is a launch gate. Plan a minimal secure guardian-authorisation path that can work without a full parent dashboard, with the operator confirming the applicable consent policy and review process. A simple checkbox/email address is not sufficient evidence by itself. Record auditable identity/relationship/consent decisions, expiry/revocation and safe access; do not start trial days or sell unavailable learning benefits while required authorisation is pending. Full parent billing/dashboard remains future scope.

### A usable learning workspace
Keep the student navigation label My Learning and tutor label Learning progress. Reuse existing detail components instead of building competing progress systems. A concise top-level workspace contains Today, Plans & progress, Study planner, and Reports & history. Tutors start with a learner selector and a “Needs review” queue. Plan-level Goals, Skills, Work & results, Practice and History remain progressive detail after a plan is selected.

Today presents the next one or two genuine actions: create a goal, add a baseline, practise, review evidence or attend a scheduled review. Use an empty state with a real next step, not empty charts or a synthetic zero. Show readiness and quota issues before a long form. Advanced fields are disclosed as needed; primary/high-school and tertiary wording comes from saved education context, not separate incompatible workflows. Mobile uses one work surface at a time and clear Back navigation; desktop can retain a plan list beside the detail. Preserve dashboard themes, shared form validation, accessible labels, layout-matching skeletons, task-level pending indicators and stable background state.

Student Free: one active subject plan, three active goals, all three goal types, essential assessment/current/target explanation, a basic single-plan chart, own evidence/history, core practice and tutor feedback. This clarifies that essential progress truth is not withheld. Pro: five plans/20 goals plus deeper date/subject trends, study checklists and on-demand monthly report. Premium: fifteen plans/60 goals plus exam/topic planning, richer separate subject/period comparisons, flexible reports and scheduled summaries. Limits apply account-wide to the learner, including tutor proposals. Pending proposals need an explicit bounded state; atomic activation/resume/restore checks prevent quota bypass. Paid templates never silently create or approve goals/evidence.

Tutor Free can support all authorised learners' core feedback and achievement confirmation; it does not inherit a student's Premium preparation tools. Pro has ten reusable templates, weekly series, Pro library and individual analysis/reports. Premium has fifty templates, bulk preparation, additional recurrence modes, full paid library and scheduled/batch analysis. Bulk apply generates reviewable proposals per learner; each still needs learner approval and available learner quota. The initiating party's recurrence permission controls series creation; Free recipients can accept individual invitations.

Core goal-setting, safeguarding and platform training must remain Free. Admins assign paid resource/course minimum tiers separately from publication. Locked responses return safe metadata only, with no section bodies, quiz content/answers or durable public private-asset URLs. Contextual links return users to the exact learner/plan after a resource or practice exercise. Store training completion separately from learner achievements.

### Progress and accuracy rules
Use one canonical server calculation/read model and contract across student/tutor pages, overview cards, charts and reports. The current frontend fallback model and database goal results must be reconciled; screenshots of differing numbers are a release failure.

Assessment: show original mark/max, verified/self-recorded source, task scope, category, independence and date. A comparable verified independent baseline of 45%, current 60% and target 75% means +15 percentage points and 50% of that agreed gap closed, not “50% academic improvement.” Multiple required checks and minimum time gaps still apply; achievement needs the existing approved-goal/tutor-confirmation rule. Show 0/1/2 observation states honestly. Changes in assessment scope start a new comparable series; corrections retain history and recompute affected summaries.

Skill: count reviewed independent demonstrations meeting the rubric, spacing and repetition requirements. Guided work cannot establish independent mastery. Habit: activity completion measures practice only, not a higher mark or mastered skill. Confidence remains self-reported and separate.

Do not average score/skill/habit progress into one academic score, average unrelated marks across subjects/curricula, rank tutors by learner target completion, or imply platform/tutor causation from an observational chart. Premium comparisons place each subject's own baseline/latest/target and goal evidence side by side with scope/sample size; a multi-subject summary can show explicitly defined counts such as goals achieved, not a fabricated cross-subject mark. Incompatible periods display why a comparison is unavailable. No predictive grade or guaranteed result at launch.

Reports include owner/authorised audience, period, generated-at timestamp, data-as-of, source and verification labels, comparable-series context and missing-data notes. On-demand PDF is a real downloadable snapshot. Scheduled report workers re-check current plan entitlement and recipient consent at execution, then notify through a private authenticated link by default; do not email a child's detailed records to an unverified contact.

### Readiness and end-to-end scenario checks
- Eligible user with no lessons starts personal plan/trial, records self-reported baseline, learns what verification means, and can buy tuition independently.
- Free learner + Premium tutor: no learner-capacity bypass; tutor can still give core feedback.
- Premium learner + Free tutor: learner's capacity works; feedback/goal confirmation works; tutor bulk tools stay locked.
- Pending consent/approval/identity correction: explain and resolve before access or a trial timer; no paid route bypass.
- One account in two tabs or tutor+learner accepting two proposals: quota cannot exceed the agreed limit.
- Trial expiry while a modal/job is open: preserve entries and historical records; deny a new paid action; permit already funded lesson obligations.
- Downgrade while over limit: show affected records before confirmation, allow an owner choice, archive read-only excess with deterministic fallback; no data/credit loss.
- Free/Premium Featured tutors: equal editorial eligibility; billing changes do not award/remove editorial status.
- Forged API calls, guessed private IDs, stale caches, delayed jobs/webhooks and payment-success booleans cannot grant paid access or funding.

### Delivery management in Linear
Project uses the existing Onedev team, seven milestones, explicit blocking relations, high/normal priorities and effort ranges in issue descriptions. Do not guess point estimates, calendar dates or engineer assignments. Commercial/readiness/policy approval is the first gate; all build work stays Backlog until approved. Estimated phases are engineering effort ranges, not promised deadlines, and exclude external gateway/consent policy turnaround.

Existing statuses remain Backlog -> Todo -> In Progress -> Done. A blocked relation identifies prerequisites; do not change global workspace workflows. Use one active build item per developer, finish a working vertical slice before starting another, review blockers twice weekly and milestone evidence weekly. Re-estimate after the first representative learning/billing slice. Do not mark Done from implementation alone: focused unit/SQL/direct-RPC checks, required browser/mobile checks, reviewed PR and evidence links must satisfy acceptance criteria.

Release has separate switches for catalogue display, paid entitlements, trial, scheduled delivery and Featured selection. No real charge/payout until server-verified provider integration, settlement/reconciliation and rollout approval pass. Old paid contracts/legitimately funded credits survive; mock value stays sandbox. Record operational checks, rollback path and metrics for meaningful learning use, trial conversion, blocked access, job failures and visibility fairness without sending assessment text or children’s details to analytics.

Sources informing the design:
- EEF formative assessment/feedback guidance: https://educationendowmentfoundation.org.uk/education-evidence/guidance-reports/feedback
- NAEP illustrates why separately developed subject scales cannot simply be compared: https://nces.ed.gov/nationsreportcard/scale_scores/default.aspx . This informs our conservative design; it does not validate AeroGen assessments.
- South African Information Regulator guidance on children's information, for the consent policy review: https://www.inforegulator.org.za/wp-content/uploads/2020/07/GuidanceNote-Processing-PersonalInformation-Children-20210628-1.pdf

## Additional audit clarifications

- ONE-87: Quota decision detail: proposed default is that active and paused/in-progress records consume capacity; completed/archived records release it. Pending proposals are bounded separately and activation is atomic. Final wording and limits require this decision. Preserve curriculum, grade/year, institution/module and assessment-scope history across profile changes.
- ONE-97: Personal-plan scope detail: the learner can self-close/archive personal goals, but these remain self-reported, never tutor-verified achievements. A self-recorded chart must be usable without a tutor and clearly labelled. Save structured subject/curriculum/grade/year or tertiary-module context and snapshots; changing the profile must not rewrite historic evidence.
- ONE-100: Calculation boundary detail: personal self-recorded series and tutor-reviewed comparable series remain distinct. Preserve academic-context/version snapshots across curriculum, grade or module changes. Baseline already meeting target, negative progress, different maximum marks and multiple qualifying checks require explicit fixtures; an apparently full progress bar does not itself confirm achievement.
- ONE-112: Training evidence detail: imported or client-claimed course completion alone cannot satisfy Featured eligibility. Use the approved server-validated content-version completion rules and audited review evidence.
