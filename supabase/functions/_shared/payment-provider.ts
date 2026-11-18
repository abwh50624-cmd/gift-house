export interface NormalizedPaymentEvent {
  eventId: string;
  eventType: "payment.succeeded" | "payment.failed" | "payment.unknown";
  paymentReference: string;
  amountMinor: string;
  currencyCode: "EGP";
}

export interface PaymentProviderAdapter {
  readonly provider: string;
  verifyAndNormalize(
    headers: Headers,
    rawBody: Uint8Array,
    secret: string,
    nowMilliseconds?: number,
  ): Promise<NormalizedPaymentEvent | null>;
}

export class WebhookPayloadError extends Error {}

function bytesToHex(bytes: Uint8Array): string {
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

function constantTimeHexEquals(left: string, right: string): boolean {
  if (!/^[0-9a-f]{64}$/.test(left) || !/^[0-9a-f]{64}$/.test(right)) return false;
  let difference = 0;
  for (let index = 0; index < left.length; index += 1) {
    difference |= left.charCodeAt(index) ^ right.charCodeAt(index);
  }
  return difference === 0;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export class SandboxPaymentProviderAdapter implements PaymentProviderAdapter {
  readonly provider = "sandbox";

  async verifyAndNormalize(
    headers: Headers,
    rawBody: Uint8Array,
    secret: string,
    nowMilliseconds = Date.now(),
  ): Promise<NormalizedPaymentEvent | null> {
    const timestamp = headers.get("x-gift-house-timestamp") ?? "";
    const signatureHeader = headers.get("x-gift-house-signature") ?? "";
    if (!/^[0-9]{10}$/.test(timestamp) || secret.length < 32) return null;

    const timestampSeconds = Number(timestamp);
    if (
      !Number.isSafeInteger(timestampSeconds) ||
      Math.abs(Math.floor(nowMilliseconds / 1000) - timestampSeconds) > 300
    ) {
      return null;
    }

    const signatureMatch = /^v1=([0-9a-f]{64})$/.exec(signatureHeader);
    if (signatureMatch === null) return null;

    const key = await crypto.subtle.importKey(
      "raw",
      new TextEncoder().encode(secret),
      { name: "HMAC", hash: "SHA-256" },
      false,
      ["sign"],
    );
    const signedMessage = new Uint8Array(
      new TextEncoder().encode(`${timestamp}.`).length + rawBody.length,
    );
    const prefix = new TextEncoder().encode(`${timestamp}.`);
    signedMessage.set(prefix);
    signedMessage.set(rawBody, prefix.length);
    const expectedSignature = bytesToHex(
      new Uint8Array(await crypto.subtle.sign("HMAC", key, signedMessage)),
    );
    if (!constantTimeHexEquals(signatureMatch[1], expectedSignature)) return null;

    let decoded: unknown;
    try {
      decoded = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(rawBody));
    } catch {
      throw new WebhookPayloadError("webhook body is not valid UTF-8 JSON");
    }

    if (!isRecord(decoded)) throw new WebhookPayloadError("webhook body must be an object");
    const expectedKeys = [
      "amount_minor",
      "currency_code",
      "event_id",
      "event_type",
      "payment_reference",
    ];
    if (
      Object.keys(decoded).length !== expectedKeys.length ||
      !expectedKeys.every((keyName) => Object.hasOwn(decoded, keyName))
    ) {
      throw new WebhookPayloadError("webhook body contains an unexpected field set");
    }

    const eventTypes = new Set([
      "payment.succeeded",
      "payment.failed",
      "payment.unknown",
    ]);
    if (
      typeof decoded.event_id !== "string" ||
      !/^[A-Za-z0-9._:-]{1,200}$/.test(decoded.event_id) ||
      typeof decoded.event_type !== "string" ||
      !eventTypes.has(decoded.event_type) ||
      typeof decoded.payment_reference !== "string" ||
      !/^[A-Za-z0-9._:-]{1,200}$/.test(decoded.payment_reference) ||
      typeof decoded.amount_minor !== "string" ||
      !/^[1-9][0-9]{0,18}$/.test(decoded.amount_minor) ||
      BigInt(decoded.amount_minor) > 9223372036854775807n ||
      decoded.currency_code !== "EGP"
    ) {
      throw new WebhookPayloadError("webhook body contains invalid payment fields");
    }

    return {
      eventId: decoded.event_id,
      eventType: decoded.event_type as NormalizedPaymentEvent["eventType"],
      paymentReference: decoded.payment_reference,
      amountMinor: decoded.amount_minor,
      currencyCode: "EGP",
    };
  }
}
