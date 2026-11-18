import assert from "node:assert/strict";
import test from "node:test";
import { SandboxAiConciergeAdapter } from "./ai-concierge.ts";

test("sandbox AI concierge returns a policy-limited Egyptian Arabic response", async () => {
  const adapter = new SandboxAiConciergeAdapter();
  const reply = await adapter.reply({
    scope: "CUSTOMER",
    subject: "تلف في المنتج",
    message: "وصلني المنتج مكسورا",
    complaintKind: "DAMAGED",
    orderId: "a1000000-0000-0000-0000-000000000001",
  });

  assert.equal(reply.sandboxOnly, true);
  assert.equal(reply.requiresAdmin, true);
  assert.deepEqual(reply.sources, ["SANDBOX_POLICY"]);
  assert.match(reply.message, /الفاتورة/);
});

test("sandbox AI concierge rejects untrusted or malformed requests", async () => {
  const adapter = new SandboxAiConciergeAdapter();

  await assert.rejects(
    adapter.reply({
      scope: "CUSTOMER",
      subject: "",
      message: "مرحبا",
      complaintKind: null,
      orderId: null,
    }),
    TypeError,
  );
  await assert.rejects(
    adapter.reply({
      scope: "ADMIN",
      subject: "مراجعة",
      message: "نفذ خصماً من المخزون",
      complaintKind: null,
      orderId: "not-a-uuid",
    }),
    TypeError,
  );
});
