# Bayt El-Hadaya — Final Readiness Checklist

**Audit date:** 2026-11-19
**Decision:** **NO-GO for production APK approval**

## Executive decision

The repository contains substantial, tested Supabase foundations and a working
Android source implementation for browsing, checkout preparation, chat, and
account/order screens. It is not production-ready: production Auth disables
Google, Facebook, and phone providers; the live catalog has no categories,
products, or variants; production payment and shipping operations are not
verified; the local pgTAP run has a failing checkout test; and Android tests
and APK builds could not run because the Android SDK is unavailable.

The production Supabase review recorded below was read-only before this task.
On 2026-11-19, this task deployed only the sandbox `payment-webhook` Edge
Function to project `wkhbxljqaywprplpadve`; no remote schema, migrations, data,
Auth configuration, or secrets were changed. The function remains fail-closed
until `SANDBOX_WEBHOOK_SECRET` is provisioned. No provider secret values are
included in this report.

## Scope, specification basis, and limits

Documents found and examined:

- [`architecture.md`](architecture.md) — the only document with eight
  numbered functional/security sections; treated as the eight core requirement
  groups below.
- [`README.md`](README.md) — build, deployment, and later-phase implementation
  notes.
- [`docs/security/threat-model.md`](docs/security/threat-model.md) — trust
  boundaries and release controls.
- [`AUDIT_REPORT.md`](AUDIT_REPORT.md) and
  [`UX_INTEGRATION_AUDIT.md`](UX_INTEGRATION_AUDIT.md) — prior audits, but
  several findings are stale against the current source.
- [`.github/workflows/ci.yml`](.github/workflows/ci.yml) — automated checks.

**The repository does not contain an authoritative, enumerated 12-phase
roadmap or acceptance criteria for phases 1–6 and 11–12.** README and
`architecture.md` explicitly label phases 7–10 only. The repository has 13
SQL migration files; mapping those files to the missing phase list would be
guesswork. Consequently, the 12-phase acceptance claim cannot be certified
until the approved phase document is supplied or added. The phase evidence
that does exist is traced separately below.

The earlier audit reports must not be used as current release evidence without
revision. For example, the current tree has a unique migration timestamp for
each file, delivery-address fields/screens, and multiple `LuxuryGoldButton`
call sites; the earlier reports describe a migration collision, no address
flow, and an unused gold button.

## Verified production and repository facts

| Area | Verified result |
|---|---|
| Remote migration history | All 13 local migration versions match the linked production migration history. A read-only schema dump contains the current public/private tables and RLS declarations. |
| Migration timestamps | No duplicate local migration version exists. A fresh local database applied all 13 migrations successfully. |
| Remote Auth | Email is enabled; signup is enabled and email auto-confirm is off. Google, Facebook, and phone providers are disabled. |
| Remote catalog | Guest-visible `categories`, `products`, and `product_variants` each return **0 rows**. The production storefront therefore has no catalog content. |
| Remote shipping data | **12 active** `shipping_regions` rows exist: 6 BOSTA and 6 EGYPTIAN_POST. These are broad seeded regions, not a verified governorate/center/village tariff table. |
| Deployed Supabase Edge Functions | `ai-concierge`, `r2-presign`, `shipping-rates`, and `payment-webhook` are listed active. The sandbox-only `payment-webhook` was deployed by this task and returns 503 until its signing secret is provisioned. |
| External runtime configuration | The remote secret-name inventory does not include Gemini, R2, sandbox payment webhook, Bosta, or Egyptian Post credentials. Their live operation is not configured/verified. |
| Supabase RLS/schema boundary | The remote schema dump shows forced RLS on the reviewed business tables; `private` is not in the local exposed API schemas. This is not a substitute for role-by-role production access tests. |
| Supplier Worker | Source and mocked tests exist. No Cloudflare deployment or Telegram webhook registration was verified. |
| Android | Email/password, email-code verification, Google/Facebook OAuth calls, PKCE callback handling, encrypted Auth session storage, and sign-out exist in source. No Android build/test could run in this environment. |

### Completed and verified (100% within these bounded checks)

- All 13 current migration files apply successfully to a fresh local database,
  and their versions match the linked production migration history.
- The Node Worker/adapter suite passes 13/13 tests; the Deno payment adapter
  suite passes 3/3 tests.
- Production Auth flags, deployed Edge Function names, guest-visible catalog
  row counts, and active shipping-region counts were read directly from the
  linked project.
- `payment-webhook` is active on the linked production project; a GET request
  returned the expected 405 response. The endpoint has no configured sandbox
  signing secret and is intentionally unavailable for event processing.
- The implemented Android email/OAuth call paths, PKCE callback, encrypted
  Auth state, category drill-down, checkout address fields, and order list were
  confirmed in source.

These are component-level confirmations only. **No complete production
requirement or end-to-end customer journey is 100% verified.**

## Traceability matrix — eight numbered architecture sections

Statuses refer to production acceptance, not merely the existence of source.

| Core requirement group | Source and live evidence | Status / gap |
|---|---|---|
| **1. Infrastructure, security, CI/CD, recovery, media, client storage** | Private ledger/inventory foundations, forced RLS, explicit grants, pinned GitHub Actions, and a Gitleaks CI job are present. Auth session and PKCE verifier storage use AES-GCM with an Android Keystore key. | **Partial.** No SQLCipher local database/cart implementation is present. The R2 code supports public media URLs and has no signed read flow; the architecture requires private objects and short-lived authorized reads. Image flows permit up to 10 MB, not the specified 50 KB. PITR, restore drills, APK scanning, and a Gitleaks run were not verified. CI has no OIDC/deployment flow. |
| **2. Identity, access, customer account** | Android has email/password, email signup-code verification/resend, Google/Facebook OAuth calls, PKCE, deep-link callback, encrypted session persistence, order/return shortcuts, and sign-out. Production email is enabled with auto-confirm off. | **Fail for release.** Google and Facebook are disabled in production Auth; phone Auth is disabled and no phone sign-in/OTP flow exists. The app has no profile/phone editing or loyalty dashboard. The configured callback allow-list was not verified. |
| **3. Finance, payments, sourcing window, refunds** | Database has separate order/payment/sourcing states, integer-minor-unit ledger, idempotency/outbox foundations, atomic checkout/reservation, sandbox intents, and a signed sandbox webhook implementation. Database tests cover many authorization/ledger cases. | **Partial; no real collection.** Android creates only a sandbox payment intent; no live payment adapter/capture is wired. The sandbox webhook is deployed but its signing secret is absent, so it fails closed. Reservation expiry has a database function but no verified scheduler. Refund processing is sandbox/database-level; legal timing and same-method gateway refund are not demonstrated. |
| **4. Catalog, navigation, inventory, immutable snapshots** | Guest catalog queries, category/subcategory drill-down, product/variant details, weight/price display, local cart, server-side checkout revalidation, snapshot and inventory foundations exist. DB roles allow authorized admin writes to catalog entities. | **Fail for release.** Production category/product/variant tables are empty. No Android admin catalog-ingestion screen/repository exists. Telegram intake is supplier data, not product publishing. There is no verified secure product-image administration path or stock seed. Cart state is held in Activity state/saved instance state, not a durable encrypted SQLCipher store. |
| **5. Shipping and geographic delivery** | Production has 12 active broad-region rates. Checkout collects governorate, street, landmark, and optional coordinates; the database persists addresses and validates coordinate ranges. Shipping lifecycle and sandbox tracking RPCs exist. | **Partial.** Coordinates are manually typed; manifest permissions exist but there is no location picker/GPS acquisition, geocoder, or governorate hierarchy. Adapter quote methods return configured database rates rather than calling provider quote APIs. Live shipment creation is conditional on credentials that are not configured/verified. No verified live provider callback signatures or labels exist. Android only displays `shipping_status`; it does not call the tracking RPC or display a tracking number. |
| **6. AI concierge, internal messaging, complaints** | Authenticated Android text/image chat calls active `ai-concierge` and `r2-presign` functions; support-thread/message RPCs, polling, AI audit records, and sandbox/Gemini adapters exist. | **Partial / not live.** `GEMINI_API_KEY` and R2 credentials are not configured in the remote secret inventory. The AI entrypoint uses a service-role backend mediation path; this requires explicit review against the spec’s isolation and least-privilege requirements. No admin support console is present. Notification content is static and the badge starts at a hard-coded count rather than tracking unread messages. Return/chat does not require the specified product-and-invoice image evidence. |
| **7. Loyalty, referrals, legal compliance** | Loyalty/referral/legal schema and RPCs are present with a pgTAP suite; return-request screens and repository calls exist. | **Partial.** No Android loyalty balance, referral registration, referral link, phone-OTP qualification, or customer-facing rewards lifecycle is present. Refund amount entry is user-editable in the UI; the label uses “dirhams” rather than EGP. Actual legal terms, statutory timelines, registration documents, and Egyptian legal/privacy review are not evidenced and cannot be certified by code inspection. |
| **8. Telegram supplier pipeline and sourcing** | Cloudflare Worker validates Telegram webhook token/routing, handles availability text, and has a photo path. Supabase has supplier mappings, 48-hour reports, sourcing batches, approval, and gap records; mocked Worker and database tests exist. | **Partial.** Deployment, `setWebhook`, real supplier mappings, bot credentials, and R2 binding are unverified. Worker uses a service-role credential for RPCs rather than a narrowly scoped worker identity. Photo path accepts up to 10 MB and does not enforce the required final 50 KB. Supplier intake does not publish an approved product; no admin UI or outbound supplier aggregation is implemented/verified. Shipping-cost-aware split sourcing is not evidenced. |

### Critical flow trace

| Flow | Present | Missing / release gate |
|---|---|---|
| Email and social authentication | Email/password and code flows; Google/Facebook SDK-level OAuth calls and callback handling are wired in Android. | Production Google/Facebook toggles are false; phone Auth is false and has no Android flow. Configure providers, redirect allow-list and credentials, then test on-device. |
| Product/category/variant/image addition | Database admin policies; Supabase dashboard/API can be used by a correctly authorized operator. Telegram worker records supplier availability/media separately. | No Android admin add/edit workflow is present, and no explicit operational dashboard runbook was found. Telegram does not publish products. Live public catalog is empty. Establish an audited product/variant/image publishing workflow and seed/verify the live catalog. |
| Browse to checkout | Category hierarchy, product details, local cart, shipping-region selection, address form, terms acceptance, and authenticated checkout RPC are wired. | The live catalog is empty. Payment is sandbox-only and remains payment-pending. No durable encrypted cart. Address GPS is manual coordinate entry, not GPS. |
| Shipping and tracking | Region/rate selection and address snapshot are implemented; database has sandbox shipment/tracking lifecycle. | No live quote API, verified provider credentials, signed live callback, label flow, Android shipment creation, or tracking-number UI. |
| AI and support | Authenticated chat, support threads, text and image upload code paths exist. | Missing Gemini/R2 secrets, no admin support UI, static notification badge, and production media privacy/size controls do not meet the written spec. |

## Execution-phase traceability

| Phase(s) | Repository evidence | Finding |
|---|---|---|
| **1–6** | No phase-by-phase requirements or acceptance criteria found in the repository. Relevant database foundations exist, and all migration versions are present remotely. | **Unverifiable as phases.** Do not infer phase completion from migration order. Obtain the approved phase definitions and map each criterion to code, deployed configuration, and tests. |
| **7 — Payment** | Explicitly described in README/architecture; sandbox payment adapter, deployed webhook, ledger RPC, and SQL tests exist. | **Partial.** Sandbox only; the deployed webhook fails closed until its signing secret is provisioned. Production provider configuration and E2E payment/reconciliation are missing. |
| **8 — Supplier sourcing** | Explicitly described; Telegram Worker and supplier/sourcing SQL/RPC/tests exist. | **Partial.** Unit tests use mocks. Cloudflare deployment, Telegram registration, data mappings, media size/policy, and end-to-end maker-checker operation are unverified. |
| **9 — Shipping** | Explicitly described; database lifecycle and provider adapter tests exist. | **Partial.** Sandbox lifecycle is tested. Production rates/credentials/callbacks/labels and customer tracking are incomplete or unverified. |
| **10 — AI messaging** | Explicitly described; Android support, Edge Function, AI adapter, and database tests exist. | **Partial.** Function is deployed, but Gemini/R2 runtime secrets are absent; no admin queue/UI or production image authorization test. |
| **11–12** | No numbered phase definitions found in README, architecture, prior audits, or threat model. | **Unverifiable.** No phase-level pass/fail decision is supportable without the authoritative roadmap. |

## Automated test and QA inventory

| Suite | Inventory | Result |
|---|---|---|
| Supabase pgTAP | 11 SQL files; 224 declared assertions. | Local migrations applied. **FAIL:** 10 files pass; `checkout.test.sql` fails at “cash on delivery is rejected by the server.” The test calls a stale `create_checkout_order` signature and receives SQLSTATE `42883` (function does not exist) instead of expected `22023` (unsupported prepaid method); the remaining assertions in that file do not run. Overall: 217 assertions executed, one failure, planned total not reached. |
| Node Worker/adapter tests | 3 files: supplier Telegram (8), shipping provider (3), AI concierge (2). | **PASS: 13/13.** These use mocked/local behavior, not deployed provider integrations. |
| Deno payment adapter | 1 file, 3 tests. | **PASS: 3/3** using transient Deno tooling. This suite is not included in the repository CI workflow. |
| Android JVM/JUnit | 2 test files, 4 `@Test` cases. | **BLOCKED.** `./gradlew testDebugUnitTest` fails before compilation: no configured Android SDK (`ANDROID_HOME`/`sdk.dir`); SDK Platform 37 is unavailable. |
| Android UI/instrumentation | No `app/src/androidTest` tests found. | **Not implemented.** |
| APK build/lint/release | CI defines `check assembleDebug lint`; no signed release build/E2E job is present. | **Not run locally** for the same missing-SDK blocker. |
| Gitleaks | Pinned Gitleaks job is configured in CI. | **Not run in this audit:** authorization to install/run the scanner was declined. No scan result is asserted. |
| Remote E2E/integration | No automated production/staging E2E suite found. | **Not run.** Read-only production checks covered migration versions, Auth feature flags, deployed function names, and aggregate guest-visible catalog/rate counts only. |

### CI coverage gap

The workflow runs Android checks, local database tests, and the three Node
tests. It does **not** run the Deno payment-provider test or an Android UI/E2E
suite. CI does not deploy or verify provider credentials, production OAuth,
Cloudflare routes, scheduled jobs, or backup restoration.

## Required E2E and integration test matrix

Production approval requires each applicable case below to pass in a
production-like staging project, with evidence captured. Use synthetic
accounts/orders and sandbox provider accounts until live-provider certification.

| ID | Scenario | Required pass evidence |
|---|---|---|
| E1 | Clean install, configuration validation, debug and signed release APK build | CI build, lint, dependency checks, APK inspection; verify no service-role/provider secret is packaged. |
| E2 | Email signup, confirmation code, resend, sign-in, session restore, sign-out | Android device test against configured Auth; valid/invalid/expired code and recovery behavior. |
| E3 | Google and Facebook OAuth | Provider-enabled Auth settings, registered redirect URI, callback round-trip on device, cancellation/error cases. |
| E4 | Phone OTP for the referral/phone-verification requirement | OTP send/verify, expiry/replay/rate-limit cases, verified status persisted and required before reward. |
| E5 | Guest catalog browsing and category/subcategory navigation | Seeded category/product/variant rows visible to anon; inactive/unpublished records hidden by RLS. |
| E6 | Admin create/update category, product, variant, stock, and image | Admin-only authorization, audit trail, validation, image upload/read and publish flow; unauthorized customer rejected. |
| E7 | Supplier Telegram availability and photo ingestion | Real staging webhook registration, authorized/unauthorized supplier, duplicate update replay, expired mapping, bounded WebP output, and separate approval before catalog publication. |
| E8 | Image privacy and processing | Private R2 bucket, short-lived object-scoped upload/read URLs, authorization on every read, WebP/EXIF validation, final image <=50 KB, invalid/oversized media rejected. |
| E9 | Cart recovery and concurrent inventory reservation | Process restart/cart persistence, concurrent checkout for last units, rollback, timeout, idempotent retry, reservation expiry and release. |
| E10 | Region/address selection for Bosta and Egyptian Post | Verified regional mapping/rates, manual address and GPS-consent path, invalid coordinates, address ownership/RLS, server-side frozen rate. |
| E11 | Checkout and real provider payment | Terms version acceptance, server recalculation, no COD, payment intent/capture/refusal/timeout; no order marked paid without verified webhook. |
| E12 | Payment webhook robustness | Valid signature, stale timestamp, malformed payload, duplicate event, unknown state, amount/currency mismatch, late/extra capture, atomic ledger/outbox and reconciliation. |
| E13 | Refund lifecycle | Same-method provider refund, idempotent request, maker/checker separation, legal eligibility windows, reversal ledger entry, customer status update. |
| E14 | Supplier sourcing lifecycle | 48-hour TTL, cost and availability selection, shortage/remapping, maker-checker approval, idempotency, no sourcing-state advance before approval. |
| E15 | Live shipment and tracking | Provider quote/create/label, signed callback verification, duplicate/out-of-order updates, monotonic status, customer-owned tracking only, Android tracking display. |
| E16 | AI concierge and support | Configured Gemini/R2, customer/admin data-scope tests, prompt-injection-resistant mediation, complaint escalation, image evidence, admin reply, dynamic unread count. |
| E17 | Loyalty/referrals/legal | Referral code/phone verification, 5-point eligibility and tier boundaries, expiry/FEFO redemption, qualifying-order/refund window, immutable ledger and legal acceptance. |
| E18 | RLS/grants matrix | Positive and negative tests for anon/customer/admin/super-admin/service operations on every exposed table/RPC; verify no accidental private-schema exposure. |
| E19 | Operations and recovery | Reservation/outbox/expiry schedules, payment reconciliation, alerting, secret rotation, PITR restore drill with recorded RPO/RTO. |
| E20 | Android UX/accessibility | RTL, small/large screens, loading/error/empty states, all navigation items, long labels, accessibility semantics, notification/chat updates, and airplane/network recovery. |

## Definitive pre-APK engineering checklist

### P0 — Release blockers

- [ ] Obtain/add the approved 12-phase acceptance specification; map each
  criterion to code, deployment configuration, and test evidence. Do not certify
  missing phase definitions.
- [ ] Repair `checkout.test.sql` to call the current address-aware
  `create_checkout_order` signature; run all 11 pgTAP files to a clean
  224/224 result.
- [ ] Populate and verify production categories, published products, active
  variants, images, and inventory. Confirm anon reads and admin-only writes.
- [ ] Enable and configure Google and Facebook providers, callback allow-list,
  and real device OAuth tests. Decide whether phone OTP is required for sign-in
  or only referral qualification; implement/configure the required path.
- [ ] Implement and document a restricted admin ingestion path for categories,
  products, variants, stock, and catalog images. Keep supplier submissions
  separate until an authorized maker-checker publication step.
- [ ] Choose/configure the real payment provider, implement its official
  signature verification and event normalization, and add sandbox E2E tests.
  The sandbox-only `payment-webhook` deployment is complete, but it returns
  503 until `SANDBOX_WEBHOOK_SECRET` is provisioned. Do not use the sandbox
  endpoint for real collection.
- [ ] Complete live Bosta/Egyptian Post rate and shipment integrations, validate
  official API contracts/credentials, add signed callbacks and label handling,
  and wire shipment/tracking into Android. Do not treat static seed rates as
  provider quotes.
- [ ] Complete media controls: private R2 access, authorized short-lived read
  URLs, admin authorization for catalog upload, WebP re-encoding/metadata
  removal, and the specified 50 KB maximum.
- [ ] Configure and test production AI/R2 secrets and role scoping, add an
  admin support queue, and replace static notifications/badge values with
  persisted unread state.
- [ ] Install Android SDK Platform 37/build tools in CI and a build environment;
  pass `check`, unit tests, `assembleDebug`, and `lint`. Add device/UI tests
  before signing a production APK.

### P1 — Required production operations and customer workflows

- [ ] Add durable encrypted cart storage (SQLCipher/Keystore as specified) and
  recovery/concurrency tests.
- [ ] Add governorate/region selection and an explicit, optional GPS permission
  and location flow; validate saved-address ownership and user consent.
- [ ] Implement and test reservation expiry, transactional outbox processing,
  payment reconciliation, and scheduled execution.
- [ ] Add customer loyalty/referral/phone verification UI and the complete
  return-evidence/refund workflow; obtain Egyptian legal/privacy review.
- [ ] Verify Telegram Worker deployment, R2 binding, `setWebhook`, supplier
  mappings, rate limits, retries, and secret rotation; replace broad service
  credentials with a narrowly scoped identity where supported.
- [ ] Verify PITR configuration and complete a non-production restore drill;
  scan the APK and repository history with the pinned Gitleaks version.
- [ ] Add the missing Deno payment test to CI and create automated E2E gates
  covering the matrix above.

### P2 — Release hardening

- [ ] Replace localized-label navigation routing with stable route identifiers;
  wire or remove the Favorites destination.
- [ ] Verify shipping-region data at governorate/center/village level and
  document the source, ownership, approval, and update process for rates.
- [ ] Review profile/dashboard fields, customer-visible status freshness,
  accessibility/RTL, retry behavior, privacy retention, monitoring, and
  incident/secret-rotation runbooks.

## Final approval rule

**Do not approve or publish a production APK** until all P0 items are checked,
all 20 applicable E2E/integration cases pass, the 12-phase requirements are
traceable to the authoritative plan, and a signed release build is verified.
