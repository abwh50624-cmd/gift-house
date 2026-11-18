import {
  SandboxPaymentProviderAdapter,
  WebhookPayloadError,
} from "./payment-provider.ts";
import type { NormalizedPaymentEvent } from "./payment-provider.ts";

const secret = "local-sandbox-signing-secret-with-at-least-32-characters";
const now = 1_800_000_000_000;

function assertEquals<T>(actual: T, expected: T): void {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(`expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  }
}

async function signedRequest(body: string, timestamp: number): Promise<Headers> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const message = new TextEncoder().encode(`${timestamp}.${body}`);
  const signature = new Uint8Array(await crypto.subtle.sign("HMAC", key, message));
  const hex = Array.from(signature, (byte) => byte.toString(16).padStart(2, "0")).join("");
  return new Headers({
    "x-gift-house-timestamp": timestamp.toString(),
    "x-gift-house-signature": `v1=${hex}`,
  });
}

Deno.test("sandbox webhook validates signature and normalizes safe payment fields", async () => {
  const body = JSON.stringify({
    event_id: "sandbox-event-1",
    event_type: "payment.succeeded",
    payment_reference: "sandbox-reference-1",
    amount_minor: "12500",
    currency_code: "EGP",
  });
  const adapter = new SandboxPaymentProviderAdapter();
  const event: NormalizedPaymentEvent | null = await adapter.verifyAndNormalize(
    await signedRequest(body, now / 1000),
    new TextEncoder().encode(body),
    secret,
    now,
  );

  assertEquals(event, {
    eventId: "sandbox-event-1",
    eventType: "payment.succeeded",
    paymentReference: "sandbox-reference-1",
    amountMinor: "12500",
    currencyCode: "EGP",
  });
});

Deno.test("sandbox webhook rejects stale signatures and altered bodies", async () => {
  const body = JSON.stringify({
    event_id: "sandbox-event-2",
    event_type: "payment.failed",
    payment_reference: "sandbox-reference-2",
    amount_minor: "1",
    currency_code: "EGP",
  });
  const adapter = new SandboxPaymentProviderAdapter();
  const headers = await signedRequest(body, now / 1000 - 301);

  assertEquals(
    await adapter.verifyAndNormalize(headers, new TextEncoder().encode(body), secret, now),
    null,
  );
  assertEquals(
    await adapter.verifyAndNormalize(
      await signedRequest(body, now / 1000),
      new TextEncoder().encode(`${body} `),
      secret,
      now,
    ),
    null,
  );
});

Deno.test("sandbox webhook refuses extra fields that could contain payment data", async () => {
  const body = JSON.stringify({
    event_id: "sandbox-event-3",
    event_type: "payment.succeeded",
    payment_reference: "sandbox-reference-3",
    amount_minor: "12500",
    currency_code: "EGP",
    card_number: "4111111111111111",
  });
  const adapter = new SandboxPaymentProviderAdapter();

  let rejected = false;
  try {
    await adapter.verifyAndNormalize(
      await signedRequest(body, now / 1000),
      new TextEncoder().encode(body),
      secret,
      now,
    );
  } catch (error) {
    rejected = error instanceof WebhookPayloadError;
  }
  if (!rejected) throw new Error("expected an extra payment field to be rejected");
});
