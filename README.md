# Gift House

Gift House is an Android application built with Kotlin and Jetpack Compose. Its
initial backend migration establishes private, default-deny ledger and inventory
primitives for Supabase; it does not expose customer or business tables through
the Supabase API.

## Build

Requirements: JDK 17 or newer, Android SDK Platform 37, and the Android SDK
Build Tools installed through Android Studio or `sdkmanager`.

The Android client uses only a Supabase HTTPS URL and a public `sb_publishable_`
key. Supply them through `SUPABASE_URL` and `SUPABASE_PUBLISHABLE_KEY` in the
build environment, or as local Gradle properties `supabaseUrl` and
`supabasePublishableKey`; do not commit local credentials. A publishable key is
intended to be embedded in the APK and is not an authorization boundary—RLS
remains mandatory. The client rejects non-HTTPS URLs and non-publishable keys,
and must never receive a `service_role` or `sb_secret_` key.

```sh
SUPABASE_URL=https://<project-ref>.supabase.co \
SUPABASE_PUBLISHABLE_KEY=<sb_publishable_key> \
./gradlew check assembleDebug lint
```

The Gradle wrapper is pinned to Gradle 9.9.1 and verifies the distribution
SHA-256 before use. Android Gradle Plugin, Kotlin Compose compiler, and AndroidX
dependencies are pinned in `gradle/libs.versions.toml`.

## Database foundations

The migrations target a Supabase PostgreSQL project with its standard `anon`,
`authenticated`, and `service_role` roles. Financial ledger and inventory
tables live in `private`, which is intentionally excluded from PostgREST's
exposed schemas. Those tables have forced RLS, no client-facing policies, and
revoked direct table and sequence grants.

The public identity schema creates customer profiles and application roles.
Customers can read their own role and edit their profile, but only a trusted
operator can assign elevated roles. The catalog schema allows guest reads of
active categories and published products while restricting category changes to
super admins and product/variant changes to admins. These API-facing tables
have forced RLS and explicit grants; supplier, order, and payment data are not
part of this catalog.

The Android app uses Supabase Auth email/password and Google/Facebook OAuth,
with PKCE and an Android Keystore-backed AES-GCM session and verifier store.
Register `baytelhidaya://auth-callback` in Supabase Auth's redirect allow-list,
and configure the Google and Facebook OAuth providers and their provider
credentials in the Supabase dashboard. For mandatory email signup verification
by code, enable email confirmations and configure the confirmation email template
to include `{{ .Token }}`; the client verifies and can resend the signup code.
The catalog repository selects only
active categories, published products, and active variants so anonymous
browsing remains governed by the catalog RLS policies. Provider availability
and remote credentials are environment configuration and are not asserted by
the local build.

The Android client also includes product details, a local cart, shipping-region
and prepaid-method selection, and a call to the server checkout RPC. These are
initial implementations, not phase-acceptance or production-readiness claims:
they still require successful Android and database tests, deployed Auth/RLS
verification, durable cart storage, and the remaining navigation/customer
workflows.

The reconciliation migration removes only the audited, empty legacy profile,
cart, address, catalog, and enum objects. It refuses to proceed if those tables
have unexpected columns, contain rows, or have foreign-key dependents outside
the known legacy relationships. The catalog and commerce migrations then apply
after reconciliation.

The commerce migration adds customer-readable order history with immutable
order/item snapshots, separate order/payment/sourcing states, prepaid-only
payment methods, private payment-event and outbox records, idempotency and
refund-approval tables, append-only loyalty and referral records, private
supplier intake, historical inventory snapshots, contract confirmations, and
shipping regions. Private operational records remain inaccessible to API
roles; privileged transaction workflows still require reviewed server-side
functions and provider integrations.

The checkout migration adds an authenticated, idempotent RPC that rechecks
catalog prices and shipping, atomically reserves inventory for 15 minutes,
records prepaid-only orders with immutable JSON snapshots and SHA-256 digests,
and queues a payment-request event. It does not integrate a payment provider.
Orders remain `PAYMENT_PENDING` until a trusted provider webhook confirms
payment. The reservation-expiry function is restricted to `service_role` and
still needs a scheduled trusted worker. The migrations do not provision
Supabase, create production credentials, establish provider integrations, or
enable service features in a hosted project. Apply them only after reviewing
the target project's remote migration history and schema; do not use a
destructive reset on a database with unverified contents.

The phase 7 migration adds idempotent sandbox payment intents and processes
verified webhook events atomically with order-state changes, the private
double-entry ledger, and review outbox records. A successful capture debits
`PAYMENT_CLEARING` and credits the customer prepayment liability in integer
EGP minor units. Unknown results remain `UNKNOWN`; duplicate event IDs are
replay-safe, while amount/currency mismatches and late or additional captures
are queued for review. The ledger journal and entries reuse the append-only,
balanced posting engine from the foundation migration.

`supabase/functions/payment-webhook` is a sandbox-only webhook endpoint. It
checks an HMAC-SHA-256 signature over the timestamp and exact raw request body,
rejects timestamps outside a five-minute window, bounds request size, and
normalizes a strict event schema before calling the service-role-only RPC. It
does not accept card data or simulate a successful payment from the Android
client. Configure a random `SANDBOX_WEBHOOK_SECRET` of at least 32 characters
as an Edge Function secret; `SUPABASE_URL` and
`SUPABASE_SERVICE_ROLE_KEY` must remain in the protected Edge Function
environment. The sandbox adapter implements the shared provider contract;
future gateway adapters must independently verify that provider's official
signature and normalize its events to the same schema. No live payment or
shipping provider is configured. The shipping adapter contract is defined
separately; checkout currently uses the server-managed `shipping_regions`
rates. The sandbox must not be used to collect real payments.

Apply and test with the Supabase CLI and Docker installed:

```sh
supabase start
supabase db reset
supabase test db
deno test supabase/functions/_shared/payment-provider_test.ts
```

Never put a Supabase `service_role` key, database password, or provider secret
in the Android project or APK. Use a protected backend environment for
privileged operations.
