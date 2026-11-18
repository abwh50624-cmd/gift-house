export type AiConciergeScope = "CUSTOMER" | "ADMIN";

export interface AiConciergeRequest {
  scope: AiConciergeScope;
  subject: string;
  message: string;
  complaintKind: string | null;
  orderId: string | null;
}

export interface AiConciergeReply {
  message: string;
  sandboxOnly: true;
  requiresAdmin: boolean;
  sources: readonly ["SANDBOX_POLICY"];
}

const subjectPattern = /^[\s\S]{1,160}$/;
const messagePattern = /^[\s\S]{1,4000}$/;
const uuidPattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export class SandboxAiConciergeAdapter {
  async reply(request: AiConciergeRequest): Promise<AiConciergeReply> {
    if (
      (request.scope !== "CUSTOMER" && request.scope !== "ADMIN") ||
      !subjectPattern.test(request.subject) ||
      !messagePattern.test(request.message) ||
      (request.orderId !== null && !uuidPattern.test(request.orderId))
    ) {
      throw new TypeError("invalid sandbox AI concierge request");
    }

    const requiresAdmin =
      request.complaintKind !== null &&
      ["DAMAGED", "MANUFACTURING_DEFECT", "WRONG_SPECIFICATION", "LATE_DELIVERY", "RETURN"]
        .includes(request.complaintKind);

    const message =
      request.scope === "ADMIN"
        ? "يمكن مراجعة الطلب والتوريد في لوحة الإدارة. لا يُنفذ أي تغيير مالي أو مخزني من هذه المحادثة."
        : requiresAdmin
          ? "تم تسجيل طلبك للمراجعة من فريق الدعم. يجب رفع صورة واضحة للمنتج والفاتورة عند توفرهما."
          : "تم تسجيل رسالتك. سأساعدك بمعلومات المتجر العامة فقط، ولن أصل إلى قاعدة البيانات أو الأسعار التعاقدية.";

    return {
      message,
      sandboxOnly: true,
      requiresAdmin,
      sources: ["SANDBOX_POLICY"],
    };
  }
}
