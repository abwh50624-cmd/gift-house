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
