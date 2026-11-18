# Security scope and threat model

## Scope and trust boundaries

The system has four primary trust zones:

1. The Android application and its local SQLCipher database are untrusted
   clients. Users control the device, requests, local state, and uploaded files.
2. Supabase PostgreSQL is the authoritative store for identity-linked and
   operational data. PostgREST is an untrusted request boundary; RLS and grants
   must enforce access regardless of client behavior.
3. Cloudflare Workers and R2, payment and logistics providers, and Telegram are
   external service boundaries. Requests, callbacks, media, and provider
   responses require authentication, validation, replay protection, and
   idempotent handling.
4. Gemini is a non-authoritative processor. It receives only scoped context
   through a trusted mediation layer and cannot perform privileged writes.

## Protected assets

- Customer identity, contact details, addresses, order and complaint history.
- Provider credentials, signing keys, access tokens, and database credentials.
- Product and supplier data, inventory reservations, prices, and shipping rates.
- Payment events, refunds, ledger entries, loyalty records, and immutable order
  snapshots.
- Product images, invoices, and complaint attachments stored in private R2
  buckets.

## Threats and required controls

| Threat | Required control |
|---|---|
| Client alters its identity, role, price, quantity, or supplier identifier | Derive authorization from verified claims; recompute price and validate all business state on the server. |
| RLS bypass via elevated key, table grant, function, or exposed schema | Keep privileged credentials server-side; default-deny grants; force RLS; audit `SECURITY DEFINER`; expose only reviewed schemas and RPCs. |
| Forged or replayed payment, shipping, or Telegram callback | Verify provider signature over the raw body, timestamp and replay window; enforce unique event IDs and idempotent effects. |
| Duplicate or concurrent purchase oversells inventory | Lock inventory rows and conditionally reserve within a transaction; serialize idempotency keys and record movements atomically. |
| Duplicate, unbalanced, or altered financial entries | Use integer minor units, database-enforced balanced journals, append-only records, idempotency, and reversal entries. |
| Snapshot hash is recomputed after database tampering | Canonicalize server-derived snapshot data; verify the digest; use an externally protected MAC/signing key when defending against privileged database writes. |
| Public or overbroad media URL leaks private documents | Keep R2 private; authorize each object before issuing a short-lived, object-scoped URL; do not log signed URLs. |
| Malformed media exhausts processing resources or carries metadata | Bound compressed and decoded sizes, dimensions, pixels, processing time and memory; decode and re-encode approved formats and remove EXIF. |
| Prompt injection or cross-role AI data disclosure | Treat messages and retrieved content as untrusted; mediate every retrieval; enforce customer/admin scope outside the model; disallow model-controlled SQL and financial writes. |
| Credential or personal-data exposure in APK, CI logs, or backups | Keep privileged secrets out of client builds; scan repository and APK; restrict CI permissions; encrypt local data and exclude sensitive files from backup. |
| Invalid/stale shipping rate or unauthorized rate change | Validate provider signatures, currency, bounds, region, and quote expiry server-side; gate administrative changes and audit them. |

## Current foundation boundary

The private ledger and inventory tables force RLS, define no client-facing
policies, revoke direct grants, and expose only explicitly granted transaction
functions to `service_role`. The `private` schema is not configured as a
PostgREST-exposed schema.

The public identity tables force RLS: authenticated users can read their own
profile and role, but cannot create or change role assignments. Elevated role
provisioning must be performed by a trusted operator. Catalog reads are
available to guests only for active categories and published products with
active variants. Category writes require `SUPER_ADMIN`; product and variant
writes require `ADMIN` or `SUPER_ADMIN`. Supplier, order, payment-event,
storage, logistics, and AI policies remain out of scope.

## Release gates

- Review data classification and an explicit role/table/action matrix before
  exposing any table or adding an API policy.
- Test authorized and unauthorized access, duplicate requests, transaction
  rollback, concurrent reservations, and ledger imbalance rejection.
- Verify provider signature handling, secret rotation, backup restoration, APK
  contents, and R2 object authorization in a non-production environment.
- Obtain specialist Egyptian legal and privacy review for the actual checkout,
  refund, retention, and complaint workflows.
