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
  sandboxOnly: boolean;
  requiresAdmin: boolean;
  sources: readonly ("SANDBOX_POLICY" | "GEMINI")[];
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

export interface GeminiMedia {
  imageUrl?: string;
  imageObjectKey?: string;
  context?: string;
}

export class GeminiAiConciergeAdapter {
  private readonly apiKey: string;
  private readonly publicMediaBaseUrl: string | null;

  constructor(apiKey: string, publicMediaBaseUrl: string | null = null) {
    this.apiKey = apiKey;
    this.publicMediaBaseUrl = publicMediaBaseUrl;
  }

  async reply(
    request: AiConciergeRequest,
    media: GeminiMedia = {},
  ): Promise<AiConciergeReply> {
    if (
      (request.scope !== "CUSTOMER" && request.scope !== "ADMIN") ||
      !subjectPattern.test(request.subject) ||
      !messagePattern.test(request.message)
    ) {
      throw new TypeError("invalid Gemini AI concierge request");
    }

    const prompt = [
      "أنت مستشار هدايا عربي محترف لمتجر Bayt El-Hadaya.",
      "أجب باللغة العربية المصرية الودودة، واستخدم السياق المرسل فقط.",
      "لا تنفذ مدفوعات أو خصومات أو تغييرات مخزنية.",
      `الموضوع: ${request.subject}`,
      `نوع الشكوى: ${request.complaintKind ?? "GENERAL"}`,
      `الرسالة: ${request.message}`,
      media.context ? `سياق المتجر:\n${media.context}` : "",
    ].join("\n");

    const parts: Record<string, unknown>[] = [{ text: prompt }];
    const imageUrl = media.imageUrl ||
      (media.imageObjectKey && this.publicMediaBaseUrl
        ? `${this.publicMediaBaseUrl.replace(/\/+$/, "")}/${media.imageObjectKey.replace(/^\/+/, "")}`
        : null);
    if (imageUrl) {
      const imageResponse = await fetch(imageUrl, { signal: AbortSignal.timeout(10_000) });
      if (!imageResponse.ok) throw new Error("Uploaded image could not be read");
      const contentType = imageResponse.headers.get("content-type")?.split(";")[0] ?? "image/webp";
      if (!["image/jpeg", "image/png", "image/webp"].includes(contentType)) {
        throw new Error("Unsupported uploaded image type");
      }
      const bytes = new Uint8Array(await imageResponse.arrayBuffer());
      if (bytes.byteLength > 10 * 1024 * 1024) throw new Error("Uploaded image is too large");
      let binary = "";
      for (let offset = 0; offset < bytes.length; offset += 0x8000) {
        binary += String.fromCharCode(...bytes.subarray(offset, offset + 0x8000));
      }
      parts.push({
        inlineData: { mimeType: contentType, data: btoa(binary) },
      });
    }

    const response = await fetch(
      `https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=${encodeURIComponent(this.apiKey)}`,
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          systemInstruction: {
            parts: [{ text: "أنت مساعد متجر هدايا. كن واضحاً وآمناً ومباشراً بالعربية." }],
          },
          contents: [{ role: "user", parts }],
          generationConfig: { temperature: 0.4, maxOutputTokens: 700 },
        }),
        signal: AbortSignal.timeout(30_000),
      },
    );
    if (!response.ok) {
      throw new Error("Gemini API request failed");
    }
    const result = await response.json();
    const message =
      result?.candidates?.[0]?.content?.parts
        ?.map((part: { text?: string }) => part.text ?? "")
        .join("")
        .trim();
    if (!message) throw new Error("Gemini returned an empty response");

    return {
      message,
      sandboxOnly: false,
      requiresAdmin: Boolean(request.complaintKind &&
        ["DAMAGED", "MANUFACTURING_DEFECT", "WRONG_SPECIFICATION", "LATE_DELIVERY", "RETURN"]
          .includes(request.complaintKind)),
      sources: ["GEMINI"],
    };
  }
}
