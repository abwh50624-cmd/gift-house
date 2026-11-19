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
  deliveryAddress?: ShippingDeliveryAddress;
}

export interface ShippingDeliveryAddress {
  governorate: string;
  address: string;
  latitude: number | null;
  longitude: number | null;
}

export interface ShippingShipment {
  provider: string;
  providerShipmentId: string;
  trackingNumber: string | null;
  status: "REQUESTED";
  sandboxOnly: boolean;
}

const uuidPattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const minorAmountPattern = /^[0-9]{1,19}$/;
const regionCodePattern = /^[A-Za-z0-9._:-]{1,100}$/;

function getEnv(name: string): string | undefined {
  const runtime = (
    globalThis as typeof globalThis & {
      Deno?: { env: { get(key: string): string | undefined } };
    }
  ).Deno;
  return runtime?.env.get(name);
}

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

export class BostaShippingProviderAdapter implements ShippingProviderAdapter {
  readonly provider = "BOSTA";

  async quote(request: ShippingQuoteRequest): Promise<ShippingQuote> {
    const apiKey = getEnv("BOSTA_API_KEY");
    if (!apiKey) {
      return new SandboxShippingProviderAdapter("BOSTA").quote(request);
    }
    return {
      provider: "BOSTA",
      regionCode: request.regionCode,
      amountMinor: request.configuredAmountMinor,
      currencyCode: "EGP",
      expiresAt: new Date(Date.now() + 5 * 60 * 1000).toISOString(),
    };
  }

  async createShipment(request: ShippingShipmentRequest): Promise<ShippingShipment> {
    const apiKey = getEnv("BOSTA_API_KEY");
    const baseUrl = getEnv("BOSTA_API_BASE_URL");
    if (!apiKey || !baseUrl) {
      return new SandboxShippingProviderAdapter("BOSTA").createShipment(request);
    }
    const response = await fetch(`${baseUrl}/api/v2/deliveries`, {
      method: "POST",
      headers: {
        "authorization": `Bearer ${apiKey}`,
        "content-type": "application/json",
      },
      body: JSON.stringify({
        type: 10,
        spec: {
          package: { description: `Bayt El-Hadaya order ${request.orderId}` },
          dropOffAddress: request.deliveryAddress
            ? {
                address: request.deliveryAddress.address,
                area: request.deliveryAddress.governorate,
                location:
                  request.deliveryAddress.latitude !== null &&
                  request.deliveryAddress.longitude !== null
                    ? {
                        lat: request.deliveryAddress.latitude,
                        lng: request.deliveryAddress.longitude,
                      }
                    : undefined,
              }
            : undefined,
        },
      }),
    });
    if (!response.ok) {
      throw new Error(`Bosta shipment request failed (${response.status})`);
    }
    const payload = await response.json();
    const shipmentId = String(payload?._id ?? payload?.id ?? "");
    const trackingNumber =
      typeof payload?.trackingNumber === "string" ? payload.trackingNumber : null;
    if (!shipmentId) throw new Error("Bosta returned no shipment identifier");
    return {
      provider: "BOSTA",
      providerShipmentId: shipmentId,
      trackingNumber,
      status: "REQUESTED",
      sandboxOnly: false,
    };
  }
}

export class EgyptianPostShippingProviderAdapter implements ShippingProviderAdapter {
  readonly provider = "EGYPTIAN_POST";

  async quote(request: ShippingQuoteRequest): Promise<ShippingQuote> {
    const apiKey = getEnv("EGYPT_POST_API_KEY");
    const baseUrl = getEnv("EGYPT_POST_API_BASE_URL");
    if (!apiKey || !baseUrl) {
      return new SandboxShippingProviderAdapter("EGYPTIAN_POST").quote(request);
    }
    return {
      provider: "EGYPTIAN_POST",
      regionCode: request.regionCode,
      amountMinor: request.configuredAmountMinor,
      currencyCode: "EGP",
      expiresAt: new Date(Date.now() + 5 * 60 * 1000).toISOString(),
    };
  }

  async createShipment(request: ShippingShipmentRequest): Promise<ShippingShipment> {
    const apiKey = getEnv("EGYPT_POST_API_KEY");
    const baseUrl = getEnv("EGYPT_POST_API_BASE_URL");
    if (!apiKey || !baseUrl) {
      return new SandboxShippingProviderAdapter("EGYPTIAN_POST").createShipment(request);
    }
    const response = await fetch(`${baseUrl}/shipments`, {
      method: "POST",
      headers: {
        "x-api-key": apiKey,
        "content-type": "application/json",
      },
      body: JSON.stringify({
        orderId: request.orderId,
        regionCode: request.regionCode,
        idempotencyKey: request.idempotencyKey,
        deliveryAddress: request.deliveryAddress ?? null,
      }),
    });
    if (!response.ok) {
      throw new Error(`Egyptian Post shipment request failed (${response.status})`);
    }
    const payload = await response.json();
    const shipmentId = String(payload?.shipmentId ?? payload?.id ?? "");
    const trackingNumber =
      typeof payload?.trackingNumber === "string" ? payload.trackingNumber : null;
    if (!shipmentId) throw new Error("Egyptian Post returned no shipment identifier");
    return {
      provider: "EGYPTIAN_POST",
      providerShipmentId: shipmentId,
      trackingNumber,
      sandboxOnly: false,
      status: "REQUESTED",
    };
  }
}

export function getShippingProviderAdapter(
  provider: "BOSTA" | "EGYPTIAN_POST",
): ShippingProviderAdapter {
  return provider === "BOSTA"
    ? new BostaShippingProviderAdapter()
    : new EgyptianPostShippingProviderAdapter();
}
