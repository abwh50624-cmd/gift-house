import {
  SandboxPaymentProviderAdapter,
  WebhookPayloadError,
} from "../_shared/payment-provider.ts";
import type { NormalizedPaymentEvent } from "../_shared/payment-provider.ts";

const maximumBodyBytes = 16_384;
const adapter = new SandboxPaymentProviderAdapter();

function jsonResponse(status: number, value: Record<string, unknown>): Response {
  return new Response(JSON.stringify(value), {
    status,
    headers: { "content-type": "application/json; charset=utf-8" },
  });
}

async function readLimitedBody(request: Request): Promise<Uint8Array> {
  if (request.body === null) throw new TypeError("request body is required");

  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > maximumBodyBytes) {
      await reader.cancel();
      throw new RangeError("request body exceeds the allowed size");
    }
    chunks.push(value);
  }

  const body = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    body.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return body;
}

function isAllowedBackendUrl(value: string): boolean {
  try {
    const url = new URL(value);
    return (
      url.username === "" &&
      url.password === "" &&
      (url.protocol === "https:" ||
        (url.protocol === "http:" &&
          (url.hostname === "localhost" || url.hostname === "127.0.0.1")))
    );
  } catch {
    return false;
  }
}

Deno.serve(async (request) => {
  if (request.method !== "POST") return jsonResponse(405, { error: "method_not_allowed" });
  if (!request.headers.get("content-type")?.toLowerCase().startsWith("application/json")) {
    return jsonResponse(415, { error: "application_json_required" });
  }

  const contentLength = request.headers.get("content-length");
  if (contentLength !== null) {
    if (!/^[0-9]+$/.test(contentLength)) {
      return jsonResponse(400, { error: "invalid_content_length" });
    }
    if (Number(contentLength) > maximumBodyBytes) {
      return jsonResponse(413, { error: "payload_too_large" });
    }
  }

  const backendUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  const webhookSecret = Deno.env.get("SANDBOX_WEBHOOK_SECRET") ?? "";
  const isProduction = Deno.env.get("ENVIRONMENT") === "production";
  
  if (isProduction) {
    // Fail-closed for production until production secrets/config are explicitly provided
    console.error("payment webhook: production configuration missing");
    return jsonResponse(503, { error: "webhook_unavailable" });
  }

  if (
    !isAllowedBackendUrl(backendUrl) ||
    serviceRoleKey.length === 0 ||
    webhookSecret.length < 32
  ) {
    console.error("payment webhook backend configuration is incomplete");
    return jsonResponse(503, { error: "webhook_unavailable" });
  }

  let rawBody: Uint8Array;
  try {
    rawBody = await readLimitedBody(request);
  } catch (error) {
    if (error instanceof RangeError) return jsonResponse(413, { error: "payload_too_large" });
    if (error instanceof TypeError) return jsonResponse(400, { error: "invalid_request_body" });
    console.error("payment webhook body read failed", error);
    return jsonResponse(400, { error: "invalid_request_body" });
  }

  let event: NormalizedPaymentEvent | null;
  try {
    event = await adapter.verifyAndNormalize(
      request.headers,
      rawBody,
      webhookSecret,
    );
  } catch (error) {
    if (error instanceof WebhookPayloadError) {
      return jsonResponse(400, { error: "invalid_webhook_payload" });
    }
    console.error("payment webhook verification failed", error);
    return jsonResponse(503, { error: "webhook_unavailable" });
  }
  if (event === null) return jsonResponse(401, { error: "invalid_webhook_signature" });

  let rpcResponse: Response;
  try {
    rpcResponse = await fetch(
      `${backendUrl.replace(/\/+$/, "")}/rest/v1/rpc/process_payment_webhook`,
      {
        method: "POST",
        headers: {
          apikey: serviceRoleKey,
          authorization: `Bearer ${serviceRoleKey}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({
          p_provider: adapter.provider,
          p_provider_event_id: event.eventId,
          p_event_type: event.eventType,
          p_payment_reference: event.paymentReference,
          p_amount_minor: event.amountMinor,
          p_currency_code: event.currencyCode,
        }),
      },
    );
  } catch (error) {
    console.error("payment webhook database request failed", error);
    return jsonResponse(503, { error: "payment_event_processing_unavailable" });
  }

  if (!rpcResponse.ok) {
    console.error("payment webhook database rejected event", rpcResponse.status);
    return jsonResponse(503, { error: "payment_event_processing_unavailable" });
  }

  return new Response(await rpcResponse.text(), {
    status: 200,
    headers: { "content-type": "application/json; charset=utf-8" },
  });
});
