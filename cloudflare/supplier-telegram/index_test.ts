import assert from "node:assert/strict";
import test from "node:test";
import { handleSupplierTelegramWebhook } from "./index.ts";

const environment = {
  SUPABASE_URL: "https://example.supabase.co",
  SUPABASE_SERVICE_ROLE_KEY: "server-only-test-key",
  TELEGRAM_WEBHOOK_SECRET: "a-test-secret-longer-than-thirty-two-characters",
};

function request(
  update: unknown,
  secret = environment.TELEGRAM_WEBHOOK_SECRET,
): Request {
  return new Request("https://worker.example/telegram", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-telegram-bot-api-secret-token": secret,
    },
    body: JSON.stringify(update),
  });
}

function availableUpdate(): unknown {
  return {
    update_id: 987654321,
    message: {
      message_id: 123,
      chat: { id: -10012345 },
      from: { id: 777 },
      text: "/available ITEM-7 12 4500",
    },
  };
}

test("unauthenticated Telegram requests are rejected before database access", async () => {
  let called = false;
  const response = await handleSupplierTelegramWebhook(
    request(availableUpdate(), "incorrect-secret"),
    environment,
    async () => {
      called = true;
      return new Response("{}");
    },
  );

  assert.equal(response.status, 401);
  assert.equal(called, false);
});

test("requests outside the configured Telegram route are rejected", async () => {
  const valid = request(availableUpdate());
  const wrongPath = new Request("https://worker.example/other", {
    method: valid.method,
    headers: valid.headers,
    body: await valid.text(),
  });
  const response = await handleSupplierTelegramWebhook(wrongPath, environment);

  assert.equal(response.status, 404);
});

test("JSON-like but invalid media types are rejected", async () => {
  const invalidMediaType = new Request("https://worker.example/telegram", {
    method: "POST",
    headers: {
      "content-type": "application/jsonp",
      "x-telegram-bot-api-secret-token": environment.TELEGRAM_WEBHOOK_SECRET,
    },
    body: "{}",
  });
  const response = await handleSupplierTelegramWebhook(
    invalidMediaType,
    environment,
  );

  assert.equal(response.status, 415);
});

test("valid supplier commands call only the normalized ingestion RPC", async () => {
  let call: { url: string; init: RequestInit } | undefined;
  const response = await handleSupplierTelegramWebhook(
    request(availableUpdate()),
    environment,
    async (input, init) => {
      call = { url: input.toString(), init: init ?? {} };
      return Response.json({ status: "RECORDED", duplicate: false });
    },
  );

  assert.equal(response.status, 200);
  assert.equal(call?.url, `${environment.SUPABASE_URL}/rest/v1/rpc/ingest_supplier_telegram_update`);
  assert.deepEqual(JSON.parse(String(call?.init.body)), {
    p_update_id: 987654321,
    p_chat_id: -10012345,
    p_user_id: 777,
    p_message_id: 123,
    p_text: "/available ITEM-7 12 4500",
  });
  assert.equal(
    new Headers(call?.init.headers).get("authorization"),
    `Bearer ${environment.SUPABASE_SERVICE_ROLE_KEY}`,
  );
});

test("unsupported Telegram updates are acknowledged without database access", async () => {
  let called = false;
  const update = availableUpdate() as {
    update_id: number;
    message: {
      message_id: number;
      chat: { id: number };
      from: { id: number };
      text: string;
    };
  };
  const response = await handleSupplierTelegramWebhook(
    request({
      update_id: 987654322,
      message: { ...update.message, text: "hello" },
    }),
    environment,
    async () => {
      called = true;
      return new Response("{}");
    },
  );

  assert.equal(response.status, 200);
  assert.equal(called, false);
});

test("database failures return retryable errors without leaking update content", async () => {
  const response = await handleSupplierTelegramWebhook(
    request(availableUpdate()),
    environment,
    async () => new Response("sensitive database body", { status: 500 }),
  );

  assert.equal(response.status, 503);
  assert.deepEqual(await response.json(), {
    error: "supplier_update_processing_unavailable",
  });
});

test("supplier photos are transformed to WebP before being stored and recorded", async () => {
  const imageBytes = new Uint8Array([
    0x52, 0x49, 0x46, 0x46, 0x04, 0x00, 0x00, 0x00, 0x57, 0x45, 0x42, 0x50,
  ]);
  const stored: {
    key: string;
    value: ArrayBuffer | Uint8Array;
    options?: { httpMetadata?: { contentType?: string } };
  }[] = [];
  const calls: { url: string; init?: RequestInit }[] = [];
  const photoUpdate = {
    update_id: 987654321,
    message: {
      message_id: 123,
      chat: { id: -10012345 },
      from: { id: 777 },
      caption: "/available ITEM-7",
      photo: [
        { file_id: "photo-file-id", file_unique_id: "photo-unique-id", width: 640, height: 480 },
      ],
    },
  };
  const response = await handleSupplierTelegramWebhook(
    request(photoUpdate),
    {
      ...environment,
      TELEGRAM_BOT_TOKEN: "test-token",
      R2_MEDIA_BUCKET: {
        put: async (key, value, options) => {
          stored.push({ key, value, options });
        },
      },
    },
    async (input, init) => {
      calls.push({ url: input.toString(), init });
      if (calls.length === 1) {
        return Response.json({ ok: true, result: { file_path: "photos/original.jpg" } });
      }
      if (calls.length === 2) {
        return new Response(imageBytes, {
          headers: { "content-type": "image/webp" },
        });
      }
      return Response.json({ status: "RECORDED" });
    },
  );

  assert.equal(response.status, 200);
  assert.equal(calls[1]?.url, "https://api.telegram.org/file/bottest-token/photos/original.jpg");
  assert.deepEqual(
    (calls[1]?.init as RequestInit & { cf: { image: { format: string } } }).cf,
    { image: { format: "webp" } },
  );
  assert.equal(stored.length, 1);
  assert.equal(
    stored[0]?.key,
    "supplier-photos/-10012345/777/987654321-123.webp",
  );
  assert.deepEqual(stored[0]?.value, imageBytes);
  assert.equal(stored[0]?.options?.httpMetadata?.contentType, "image/webp");
  assert.deepEqual(JSON.parse(String(calls[2]?.init?.body)), {
    p_update_id: 987654321,
    p_chat_id: -10012345,
    p_user_id: 777,
    p_message_id: 123,
    p_supplier_item_code: "ITEM-7",
    p_image_object_key: "supplier-photos/-10012345/777/987654321-123.webp",
  });
  assert.deepEqual(await response.json(), {
    ok: true,
    status: "RECORDED",
    object_key: "supplier-photos/-10012345/777/987654321-123.webp",
  });
});

test("supplier photo responses that are not WebP are not stored", async () => {
  let stored = false;
  let calls = 0;
  const photoUpdate = {
    update_id: 987654321,
    message: {
      message_id: 123,
      chat: { id: -10012345 },
      from: { id: 777 },
      photo: [
        { file_id: "photo-file-id", file_unique_id: "photo-unique-id", width: 640, height: 480 },
      ],
    },
  };
  const response = await handleSupplierTelegramWebhook(
    request(photoUpdate),
    {
      ...environment,
      TELEGRAM_BOT_TOKEN: "test-token",
      R2_MEDIA_BUCKET: {
        put: async () => {
          stored = true;
        },
      },
    },
    async () => {
      calls += 1;
      return calls === 1
        ? Response.json({ ok: true, result: { file_path: "photos/original.jpg" } })
        : new Response(new Uint8Array([1, 2, 3]), {
          headers: { "content-type": "image/jpeg" },
        });
    },
  );

  assert.equal(response.status, 503);
  assert.equal(stored, false);
  assert.equal(calls, 2);
});
