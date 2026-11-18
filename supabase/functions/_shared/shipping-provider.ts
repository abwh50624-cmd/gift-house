export interface ShippingQuoteRequest {
  regionCode: string;
  totalWeightGrams: number;
  configuredAmountMinor: string;
}

export interface ShippingQuote {
  provider: string;
  regionCode: string;
  amountMinor: string;
  currencyCode: "EGP";
  expiresAt: string;
}

export interface ShippingProviderAdapter {
  readonly provider: string;
  quote(request: ShippingQuoteRequest): Promise<ShippingQuote>;
  createShipment(request: ShippingShipmentRequest): Promise<ShippingShipment>;
}

export interface ShippingShipmentRequest {
  orderId: string;
  regionCode: string;
  idempotencyKey: string;
}

export interface ShippingShipment {
  provider: string;
  providerShipmentId: string;
  trackingNumber: null;
  status: "REQUESTED";
  sandboxOnly: true;
}

const uuidPattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const minorAmountPattern = /^[0-9]{1,19}$/;
const regionCodePattern = /^[A-Za-z0-9._:-]{1,100}$/;

async function sandboxReference(value: string): Promise<string> {
  const digest = new Uint8Array(
    await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value)),
  );
  const hex = Array.from(digest, (byte) => byte.toString(16).padStart(2, "0"))
    .join("")
    .slice(0, 24)
    .toUpperCase();
  return `SANDBOX-${hex}`;
}

export class SandboxShippingProviderAdapter implements ShippingProviderAdapter {
  readonly provider: "BOSTA" | "EGYPTIAN_POST";

  constructor(provider: "BOSTA" | "EGYPTIAN_POST") {
    this.provider = provider;
  }

  async quote(
    request: ShippingQuoteRequest,
    nowMilliseconds = Date.now(),
  ): Promise<ShippingQuote> {
    if (
      !regionCodePattern.test(request.regionCode) ||
      !Number.isSafeInteger(request.totalWeightGrams) ||
      request.totalWeightGrams <= 0 ||
      request.totalWeightGrams > 100_000 ||
      !minorAmountPattern.test(request.configuredAmountMinor) ||
      BigInt(request.configuredAmountMinor) > 9_223_372_036_854_775_807n ||
      !Number.isSafeInteger(nowMilliseconds) ||
      Math.abs(nowMilliseconds) > 8_639_999_700_000_000
    ) {
      throw new TypeError("invalid sandbox shipping quote request");
    }

    return {
      provider: this.provider,
      regionCode: request.regionCode,
      amountMinor: request.configuredAmountMinor,
      currencyCode: "EGP",
      expiresAt: new Date(nowMilliseconds + 5 * 60 * 1000).toISOString(),
    };
  }

  async createShipment(request: ShippingShipmentRequest): Promise<ShippingShipment> {
    if (
      !uuidPattern.test(request.orderId) ||
      !uuidPattern.test(request.idempotencyKey) ||
      !regionCodePattern.test(request.regionCode)
    ) {
      throw new TypeError("invalid sandbox shipping shipment request");
    }

    return {
      provider: this.provider,
      providerShipmentId: await sandboxReference(
        `${this.provider}:${request.orderId}:${request.idempotencyKey}`,
      ),
      trackingNumber: null,
      status: "REQUESTED",
      sandboxOnly: true,
    };
  }
}
