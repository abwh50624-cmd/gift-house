const maximumBodyBytes = 32_768;
const supplierCommand = /^\/available [A-Z0-9_-]{1,64} [0-9]{1,9} [0-9]{1,18}$/i;

export interface SupplierTelegramEnvironment {
  SUPABASE_URL: string;
  SUPABASE_SERVICE_ROLE_KEY: string;
  TELEGRAM_WEBHOOK_SECRET: string;
}

interface TelegramMessage {
  message_id: number;
  chat: { id: number };
  from?: { id: number };
  text?: string;
}

interface TelegramUpdate {
  update_id: number;
  message?: TelegramMessage;
}

function jsonResponse(status: number, body: Record<string, unknown>): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8" },
  });
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function constantTimeEquals(actual: string, expected: string): boolean {
  let difference = actual.length ^ expected.length;
  const length = Math.max(actual.length, expected.length);
  for (let index = 0; index < length; index += 1) {
    difference |= (actual.charCodeAt(index) || 0) ^ (expected.charCodeAt(index) || 0);
  }
  return difference === 0;
}

function isAllowedBackendUrl(value: string): boolean {
  try {
    const url = new URL(value);
    return (
      url.username === "" &&
      url.password === "" &&
      url.pathname === "/" &&
      url.search === "" &&
      url.hash === "" &&
      (url.protocol === "https:" ||
        (url.protocol === "http:" &&
          (url.hostname === "localhost" || url.hostname === "127.0.0.1")))
    );
  } catch {
    return false;
  }
}

function isSafeTelegramId(value: unknown, allowNegative = false): value is number {
  return (
    typeof value === "number" &&
    Number.isSafeInteger(value) &&
    value !== 0 &&
    (allowNegative || value > 0)
  );
}

async function readLimitedBody(request: Request): Promise<Uint8Array | null> {
  if (request.body === null) return null;
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > maximumBodyBytes) {
      await reader.cancel();
      return null;
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

function decodeUpdate(value: unknown): TelegramUpdate | null {
  if (!isRecord(value) || !isSafeTelegramId(value.update_id)) return null;
  if (!isRecord(value.message)) return null;

  const message = value.message;
  if (
    !isSafeTelegramId(message.message_id) ||
    !isRecord(message.chat) ||
    !isSafeTelegramId(message.chat.id, true) ||
    !isRecord(message.from) ||
    !isSafeTelegramId(message.from.id)
  ) {
    return null;
  }
  if (
    typeof message.text !== "string" ||
    message.text.length === 0 ||
    message.text.length > 256
  ) {
    return {
      update_id: value.update_id,
      message: {
        message_id: message.message_id,
        chat: { id: message.chat.id },
        from: { id: message.from.id },
      },
    };
  }
  return {
    update_id: value.update_id,
    message: {
      message_id: message.message_id,
      chat: { id: message.chat.id },
      from: { id: message.from.id },
      text: message.text,
    },
  };
}

export async function handleSupplierTelegramWebhook(
  request: Request,
  environment: SupplierTelegramEnvironment,
  fetcher: typeof fetch = fetch,
): Promise<Response> {
  if (request.method !== "POST") return jsonResponse(405, { error: "method_not_allowed" });
  if (new URL(request.url).pathname !== "/telegram") {
    return jsonResponse(404, { error: "not_found" });
  }
  const contentType = request.headers.get("content-type");
  if (
    contentType === null ||
    contentType.split(";")[0]?.trim().toLowerCase() !== "application/json"
  ) {
    return jsonResponse(415, { error: "application_json_required" });
  }

  const secret = environment.TELEGRAM_WEBHOOK_SECRET;
  if (typeof secret !== "string" || secret.length < 32 || secret.length > 256) {
    console.error("supplier webhook secret is not configured correctly");
    return jsonResponse(503, { error: "webhook_unavailable" });
  }
  const suppliedSecret =
    request.headers.get("x-telegram-bot-api-secret-token") ?? "";
  if (!constantTimeEquals(suppliedSecret, secret)) {
    return jsonResponse(401, { error: "invalid_webhook_secret" });
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

  let rawBody: Uint8Array | null;
  try {
    rawBody = await readLimitedBody(request);
  } catch {
    return jsonResponse(400, { error: "invalid_request_body" });
  }
  if (rawBody === null) return jsonResponse(413, { error: "payload_too_large" });

  let decoded: unknown;
  try {
    decoded = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(rawBody));
  } catch {
    return jsonResponse(400, { error: "invalid_json" });
  }
  const update = decodeUpdate(decoded);
  if (update === null) return jsonResponse(200, { ok: true, status: "IGNORED" });

  const message = update.message;
  if (message?.from === undefined) {
    return jsonResponse(200, { ok: true, status: "IGNORED" });
  }
  if (message.text === undefined || !supplierCommand.test(message.text)) {
    return jsonResponse(200, { ok: true, status: "IGNORED" });
  }

  if (
    typeof environment.SUPABASE_URL !== "string" ||
    !isAllowedBackendUrl(environment.SUPABASE_URL) ||
    typeof environment.SUPABASE_SERVICE_ROLE_KEY !== "string" ||
    environment.SUPABASE_SERVICE_ROLE_KEY.length === 0
  ) {
    console.error("supplier webhook backend configuration is incomplete");
    return jsonResponse(503, { error: "webhook_unavailable" });
  }

  let databaseResponse: Response;
  try {
    databaseResponse = await fetcher(
      `${environment.SUPABASE_URL.replace(/\/+$/, "")}/rest/v1/rpc/ingest_supplier_telegram_update`,
      {
        method: "POST",
        headers: {
          apikey: environment.SUPABASE_SERVICE_ROLE_KEY,
          authorization: `Bearer ${environment.SUPABASE_SERVICE_ROLE_KEY}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({
          p_update_id: update.update_id,
          p_chat_id: message.chat.id,
          p_user_id: message.from.id,
          p_message_id: message.message_id,
          p_text: message.text,
        }),
        signal: AbortSignal.timeout(10_000),
      },
    );
  } catch {
    console.error("supplier Telegram database request failed");
    return jsonResponse(503, { error: "supplier_update_processing_unavailable" });
  }

  if (!databaseResponse.ok) {
    console.error("supplier Telegram database rejected update", databaseResponse.status);
    return jsonResponse(503, { error: "supplier_update_processing_unavailable" });
  }

  let result: unknown;
  try {
    result = await databaseResponse.json();
  } catch {
    console.error("supplier Telegram database returned an invalid response");
    return jsonResponse(503, { error: "supplier_update_processing_unavailable" });
  }
  if (!isRecord(result) || typeof result.status !== "string") {
    console.error("supplier Telegram database returned an unexpected response");
    return jsonResponse(503, { error: "supplier_update_processing_unavailable" });
  }

  return jsonResponse(200, {
    ok: true,
    status: result.status,
    duplicate: result.duplicate === true,
  });
}

export default {
  fetch(request: Request, environment: SupplierTelegramEnvironment): Promise<Response> {
    return handleSupplierTelegramWebhook(request, environment);
  },
};
