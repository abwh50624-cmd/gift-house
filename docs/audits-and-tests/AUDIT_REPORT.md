# Bayt El-Hadaya: Principal Systems & Architecture Audit

**Audit date:** 2026-11-19  
**Scope:** Android/Kotlin UI, Supabase migrations/RLS/RPC/Edge Functions, Cloudflare Telegram Worker/R2, and CI configuration  
**Overall verdict:** **NOT 100% PRODUCTION READY**

## Executive Summary

The repository contains a strong, hardened database foundation and substantial Android/Supabase integration. However, the full production workflow is incomplete:

- Supabase checkout, catalog, support, return, supplier, and sandbox logistics foundations are present.
- Live Bosta/Egyptian Post dispatch, tracking callbacks, labels, and zone calculators are not implemented.
- There is no Android map, geocoding, address schema, delivery-address collection, or address-validation flow.
- The AI concierge and R2 presign Edge Functions and Android clients are implemented, but production deployment and secrets are unverified.
- The Telegram text worker is implemented and 11 focused Node/adapter tests pass.
- The Telegram photo path exists in source, but it does not convert images to WebP and Cloudflare/R2 deployment is unverified.
- A fresh local Supabase stack currently fails to apply migrations because two migration files share `20261118100000`.
- Android validation is blocked because no Android SDK is configured in the current environment.
- Remote Supabase, live provider accounts, OAuth providers, webhook registration, and scheduled jobs cannot be verified from source alone.

## Verification Performed

| Check | Result |
|---|---|
| `supabase test db` before stack startup | Blocked: local stack was stopped (`127.0.0.1:54322` refused) |
| `supabase start && supabase test db` | **FAIL:** migration timestamp collision on `20261118100000` |
| Node shipping, AI, and Telegram tests | **PASS: 11/11** |
| Android unit tests/lint/build | **BLOCKED:** no Android SDK / `local.properties` / `ANDROID_HOME` |
| Remote linked Supabase verification | **NOT POSSIBLE FROM SOURCE:** no authenticated remote migration/function/runtime inspection performed |

## 1. Logistics and Shipping

### Database and RPC state

The shipping foundation is substantial:

- Public `shipping_regions` supports `BOSTA` and `EGYPTIAN_POST`, provider zone codes, fixed minor-unit rates, hierarchy, activation, and RLS.
- The checkout RPC snapshots the selected region name/rate and rejects later inactive or changed rates.
- Private shipment and append-only event tables are sandbox-only and default-deny.
- Shipment lifecycle transitions are constrained and replay-protected.
- `create_sandbox_shipment`, `ingest_sandbox_shipping_event`, and `get_my_shipping_status` exist.
- Customer and administrator visibility and role restrictions are enforced.

Relevant implementation:

- [shipping_logistics.sql](/workspaces/gift-house/supabase/migrations/20261118100000_shipping_logistics.sql)
- [commerce.sql](/workspaces/gift-house/supabase/migrations/20261118060000_commerce.sql)
- [shipping-logistics tests](/workspaces/gift-house/supabase/tests/database/shipping_logistics.test.sql)

### Finding: migration collision

These two files have the same migration version prefix:

- [20261118100000_shipping_logistics.sql](/workspaces/gift-house/supabase/migrations/20261118100000_shipping_logistics.sql)
- [20261118100000_supplier_telegram_media.sql](/workspaces/gift-house/supabase/migrations/20261118100000_supplier_telegram_media.sql)

Supabase attempted to apply them and failed with duplicate key `20261118100000`. This must be corrected by renaming one migration to a unique, increasing timestamp before any fresh database reset or production migration run.

### Finding: no live provider implementation

The provider adapter is deterministic and sandbox-only:

- [shipping-provider.ts](/workspaces/gift-house/supabase/functions/_shared/shipping-provider.ts)
- It returns the server-configured fixed amount; it has no weight/distance API or live zone calculator.
- `createShipment` always creates `SANDBOX-*` IDs and `trackingNumber: null`.
- It makes no Bosta/Egyptian Post HTTP requests.
- It has no live label generation, cancellation, address payload, provider callback signature validation, or real tracking ingestion.

The database similarly stores only `SANDBOX` shipment IDs and requires `sandbox_only = true`.

### Finding: no shipping region seed data

No migration inserts active `shipping_regions` rows. A fresh database has the table and RPC support but no checkout-usable regions until a super administrator or SQL deployment process creates and activates them.

### Android status

- Android loads active shipping regions and shows fixed region names/rates.
- Checkout passes the region snapshot through the atomic server RPC.
- It does not call `create_sandbox_shipment`, `get_my_shipping_status`, or any live shipment endpoint.
- Order history exposes `shipping_status`, but there is no tracking or shipment UI.

**Verdict: Partially implemented, sandbox-only.**

## 2. Maps and Address/Location

### Backend

- The reconciliation migration removes legacy `public.addresses`.
- The checkout snapshot contains only `shipping_region` name and region ID.
- There is no latitude/longitude, governorate, city, street, building, flat, phone, landmark, geocode, or normalized address table.
- `create_checkout_order` cannot validate a physical delivery address because no physical address is accepted.
- The legacy address table is explicitly removed; no replacement address model exists.

### Android

There is no:

- Google Maps or Mapbox map dependency
- `MapView`, Compose map, location permission, or FusedLocationProvider
- Places autocomplete or geocoder implementation
- Address form or address picker
- Latitude/longitude state
- Backend address validation
- Map pin or “use current location” flow

**Verdict: Not implemented. This is a blocker for real parcel fulfillment.**

## 3. AI Concierge

### Database support

The support migration provides:

- Customer-owned support threads
- Append-only support messages
- Idempotent open/send operations
- Complaint-kind priority
- Audit trails for AI requests
- Service-role-only AI reply ingestion

Relevant file: [ai_messaging.sql](/workspaces/gift-house/supabase/migrations/20261118110000_ai_messaging.sql)

### Android integration

The Android support repository now:

- Opens support threads
- Sends text messages
- Polls thread messages
- Uploads chat images to `r2-presign`
- Calls `ai-concierge` with the bearer token

Relevant implementation: [SupportRepository.kt](/workspaces/gift-house/app/src/main/java/com/bayt/elhadaya/data/support/SupportRepository.kt)

### Edge Function state

`ai-concierge`:

- Authenticates the bearer token against Supabase Auth.
- Reads catalog context through the service role.
- Calls Gemini when `GEMINI_API_KEY` is configured.
- Persists returned content via `ingest_sandbox_ai_reply`.
- Returns only Gemini or an error; it does not contain an automatic static fallback in the edge entrypoint.

Despite the function name and RPC, live Gemini replies are controlled by `GEMINI_API_KEY`; the service is not operational without deployed secrets.

`r2-presign`:

- Authenticates the user.
- Restricts images to JPEG, PNG, and WebP.
- Enforces a 10 MB limit.
- Generates an AWS SigV4-presigned R2 `PUT` URL.
- Generates a public URL only when `R2_PUBLIC_BASE_URL` is configured.
- Does not provide a read/download presigned URL or server-side image conversion.

Android image handling converts the selected image to WebP before upload, so Android-side conversion is implemented.

**Verdict: Implementation is wired; live operation is configuration/deployment-dependent.**

## 4. Telegram Supplier Pipeline

### Implemented

The Cloudflare Worker:

- Uses POST-only `/telegram` routing.
- Checks a constant-time Telegram secret token.
- Enforces content type and body limits.
- Normalizes `/available ITEM-CODE QUANTITY COST_MINOR`.
- Calls `ingest_supplier_telegram_update`.
- Handles supplier photo uploads and calls `ingest_supplier_telegram_photo`.
- Includes tests covering secret validation, routing, normalization, unsupported updates, and database failures.

Relevant files:

- [Telegram Worker](/workspaces/gift-house/cloudflare/supplier-telegram/index.ts)
- [Wrangler config](/workspaces/gift-house/cloudflare/supplier-telegram/wrangler.toml)

Node verification: **11/11 selected tests passed**.

### Gaps

- Worker deployment and Telegram `setWebhook` registration are unverified.
- The photo path downloads Telegram bytes and stores them in R2 under a `.webp` key, but does not decode and convert source content to WebP.
- It does not implement outbound Telegram supplier notifications.
- It does not implement live supplier catalog synchronization beyond the database mapping/RPC path.
- Supabase mappings and availability reports are database/RPC foundations, but no production supplier mapping data is verified.

**Verdict: Text ingestion is substantially implemented; media and supplier operations are partially implemented.**

## 5. Operations and Remaining Workflows

### Customer and order flows

Fully operational as source/database foundations:

- Catalog hierarchy and active/published filtering
- Product details and local cart
- Authenticated checkout with atomic inventory reservation
- Immutable order snapshots
- Prepaid-only methods and checkout idempotency
- Customer order/return queries and customer support threads

Partially implemented or incomplete:

- Durable/server cart recovery
- Live payment capture
- Customer return UI and attachment flow
- Shipping tracking UI
- Admin/super-admin management UI
- Supplier mapping UI
- Favorites implementation
- Stable navigation identifiers; several routes depend on Arabic labels

### Payment state

Payment checkout and ledger foundations exist, but no live payment gateway is integrated:

- `create_sandbox_payment_intent` is sandbox-only.
- The payment webhook is sandbox/HMAC-only.
- No card data or real capture is processed by Android.
- A trusted reservation-expiry/scheduled worker is still required.

## Fully Operational Components

Subject to deployed/runtime verification, these components are fully coded and locally testable:

- Supabase catalog RLS and hierarchy migrations
- Checkout terms and server-recalculated totals
- Atomic checkout inventory reservation and idempotency
- Order and support database foundations
- Customer and role RLS foundations
- Sandbox payment ledger and webhook normalization
- Sandbox shipping lifecycle and monotonic tracking events
- Telegram text webhook routing and secret validation
- Supplier availability and maker-checker database workflows
- Android support repository call paths
- Android Supabase configuration validation

## Production Secrets and Configuration Checklist

### Android build

| Variable | Required state |
|---|---|
| `SUPABASE_URL` | Required; must be HTTPS |
| `SUPABASE_PUBLISHABLE_KEY` | Required; `sb_publishable_*` only |
| `R2_PUBLIC_BASE_URL` | Optional but required if Android/AI needs direct public media URLs |

OAuth/dashboard configuration is also required:

- Google OAuth provider credentials
- Facebook OAuth provider credentials
- Supabase redirect allow-list entry `baytelhidaya://auth-callback`
- Email confirmation enabled with `{{ .Token }}` if mandatory signup codes are used

Never embed `SUPABASE_SERVICE_ROLE_KEY`, `sb_secret_*`, database passwords, or provider secrets in the APK.

### Supabase Edge Functions

| Secret | Purpose |
|---|---|
| `SUPABASE_URL` | Protected runtime Supabase URL |
| `SUPABASE_SERVICE_ROLE_KEY` | Privileged RPC/Auth access |
| `GEMINI_API_KEY` | Live AI concierge |
| `R2_ACCOUNT_ID` | R2 SigV4 account |
| `R2_ACCESS_KEY_ID` | R2 API credential |
| `R2_SECRET_ACCESS_KEY` | R2 API secret |
| `R2_BUCKET_NAME` | Upload bucket |
| `R2_PUBLIC_BASE_URL` | Optional public CDN/bucket base |
| `SANDBOX_WEBHOOK_SECRET` | Sandbox payment webhook HMAC, >=32 characters |

Live payment requires an additional official provider API key/secret and provider-verifiable webhook signature secret, with provider-specific adapter code and callback allow-listing.

### Cloudflare Telegram Worker

| Secret/binding | Purpose |
|---|---|
| `SUPABASE_URL` | Telegram-to-Supabase RPC target |
| `SUPABASE_SERVICE_ROLE_KEY` | Privileged RPC access |
| `TELEGRAM_WEBHOOK_SECRET` | Telegram `secret_token`, 32–256 characters |
| `TELEGRAM_BOT_TOKEN` | Download supplier photos and future outbound delivery |
| `R2_MEDIA_BUCKET` | Wrangler R2 binding |

### Shipping integration

The repository does not define live Bosta/Egyptian Post environment names. Production integration will require, at minimum:

- Bosta live API base URL and credential (API key/token or account-specific credential)
- Bosta live account/provider zone mapping
- Egyptian Post live API base URL and credential
- Egyptian Post live account/provider zone mapping
- Provider webhook callback secret(s)
- Label-generation/storage credentials
- Shipping-region seed data with verified provider zone codes and rates
- Live provider callbacks ingested through a cryptographically verified endpoint

Names and signing schemes must match the providers’ official APIs and must not be guessed.

### Maps and addresses

No map integration exists. Production requires a decision and implementation of one provider stack, for example:

- Android restricted Google Maps SDK/API key
- Places/Autocomplete API key or Maps SDK configuration
- Geocoding API or Places reverse-geocoding credential
- Address backend schema and RPC validation
- A delivery-address record linked to the order/customer
- Lat/lng or normalized address fields, as appropriate

### Deployment and scheduled operations

Required for production:

- Renamed unique Supabase migrations
- Production migration application and remote migration verification
- Edge Function deployment for `ai-concierge`, `r2-presign`, and `payment-webhook`
- Telegram Worker deployment and Telegram `setWebhook`
- R2 bucket creation/binding and public/private media policy
- Scheduled service-role execution of checkout expiry
- Provider callback endpoint registration
- Protected production secret storage and rotation
- Android SDK Platform 37 / Build Tools 36 installation and full APK test run

## Definitive Gap Matrix

| Area | Status |
|---|---|
| Supabase schema/migrations source | **PASS with one migration timestamp collision** |
| Checkout database | **Operational foundation** |
| Checkout Android | **Wired; build/device verification blocked** |
| Shipping regions/database | **Implemented, no production seed data** |
| Bosta live integration | **NOT IMPLEMENTED** |
| Egyptian Post live integration | **NOT IMPLEMENTED** |
| Shipping tracking Android | **NOT IMPLEMENTED** |
| Live labels/callbacks | **NOT IMPLEMENTED** |
| Maps/geocoding | **NOT IMPLEMENTED** |
| Delivery address backend | **NOT IMPLEMENTED** |
| AI edge function source | **Implemented** |
| AI edge live configuration | **UNVERIFIED** |
| R2 presign source | **Implemented** |
| R2 live configuration | **UNVERIFIED** |
| Android support repository | **Implemented** |
| Telegram text Worker | **Implemented; tests pass** |
| Telegram photo/R2 | **Partially implemented; conversion missing** |
| Supplier database mapping | **Implemented** |
| Supplier live production mappings | **UNVERIFIED** |
| Live payment gateway | **NOT IMPLEMENTED** |
| Android build | **BLOCKED by missing SDK** |
| Remote production runtime | **NOT VERIFIED**
