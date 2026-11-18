import assert from "node:assert/strict";
import test from "node:test";
import { SandboxShippingProviderAdapter } from "./shipping-provider.ts";

const orderId = "a1000000-0000-0000-0000-000000000001";
const idempotencyKey = "a2000000-0000-0000-0000-000000000001";

test("sandbox quotes preserve the server-configured rate and expire in five minutes", async () => {
  const adapter = new SandboxShippingProviderAdapter("EGYPTIAN_POST");
  const quote = await adapter.quote(
    {
      regionCode: "CAIRO-1",
      totalWeightGrams: 750,
      configuredAmountMinor: "4200",
    },
    1_800_000_000_000,
  );

  assert.deepEqual(quote, {
    provider: "EGYPTIAN_POST",
    regionCode: "CAIRO-1",
    amountMinor: "4200",
    currencyCode: "EGP",
    expiresAt: "2027-01-15T08:05:00.000Z",
  });
});

test("sandbox shipment creation is deterministic and never returns a live tracking number", async () => {
  const adapter = new SandboxShippingProviderAdapter("BOSTA");
  const request = {
    orderId,
    regionCode: "GIZA-2",
    idempotencyKey,
  };

  const first = await adapter.createShipment(request);
  const replay = await adapter.createShipment(request);

  assert.deepEqual(first, replay);
  assert.match(first.providerShipmentId, /^SANDBOX-[0-9A-F]{24}$/);
  assert.equal(first.trackingNumber, null);
  assert.equal(first.status, "REQUESTED");
  assert.equal(first.sandboxOnly, true);
});

test("sandbox adapter rejects invalid quote and shipment inputs", async () => {
  const adapter = new SandboxShippingProviderAdapter("BOSTA");

  await assert.rejects(
    adapter.quote({
      regionCode: "CAIRO/1",
      totalWeightGrams: 100,
      configuredAmountMinor: "500",
    }),
    TypeError,
  );
  await assert.rejects(
    adapter.quote({
      regionCode: "CAIRO-1",
      totalWeightGrams: 0,
      configuredAmountMinor: "500",
    }),
    TypeError,
  );
  await assert.rejects(
    adapter.quote({
      regionCode: "CAIRO-1",
      totalWeightGrams: 100,
      configuredAmountMinor: "9223372036854775808",
    }),
    TypeError,
  );
  await assert.rejects(
    adapter.createShipment({
      orderId: "not-an-order",
      regionCode: "CAIRO-1",
      idempotencyKey,
    }),
    TypeError,
  );
});
