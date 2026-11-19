import { GeminiAiConciergeAdapter } from "../_shared/ai-concierge.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (request.method !== "POST") {
    return new Response("Method not allowed", {
      status: 405,
      headers: corsHeaders,
    });
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const geminiApiKey = Deno.env.get("GEMINI_API_KEY");
  const token = request.headers.get("authorization")?.replace(/^Bearer\s+/i, "");
  if (!supabaseUrl || !serviceRoleKey || !token || !geminiApiKey) {
    return new Response("AI concierge is not configured", {
      status: 500,
      headers: corsHeaders,
    });
  }

  // Verify auth and get role early
  const userRoleResponse = await fetch(`${supabaseUrl}/rest/v1/rpc/get_my_role`, {
    headers: {
      apikey: serviceRoleKey,
      Authorization: `Bearer ${token}`,
    },
  });
  
  if (!userRoleResponse.ok) {
    return new Response("Unauthorized", { status: 401, headers: corsHeaders });
  }
  
  const userRole = await userRoleResponse.json();
  const isAdmin = userRole === 'ADMIN' || userRole === 'SUPER_ADMIN';
  const scope = isAdmin ? 'ADMIN' : 'CUSTOMER';

  let payload: Record<string, unknown>;
  try {
    payload = await request.json();
  } catch {
    return new Response("Invalid JSON", { status: 400, headers: corsHeaders });
  }

  const uuidPattern =
    /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
  const threadId = payload.thread_id;
  const subject = payload.subject;
  const message = payload.message;
  const complaintKind = payload.complaint_kind ?? null;
  const orderId = payload.order_id ?? null;
  const imageObjectKey = payload.image_object_key;
  const imageUrl = payload.image_url;

  if (
    typeof threadId !== "string" ||
    !uuidPattern.test(threadId) ||
    typeof subject !== "string" ||
    typeof message !== "string"
  ) {
    return new Response("Invalid concierge request", {
      status: 400,
      headers: corsHeaders,
    });
  }

  try {
    const requestContext = {
      scope,
      subject,
      message,
      complaintKind:
        typeof complaintKind === "string" ? complaintKind : null,
      orderId: typeof orderId === "string" ? orderId : null,
    };

    let catalogContext = "";
    if (isAdmin) {
      catalogContext = "Admin session active. Accessing full product context.";
    } else {
      try {
        const catalogResponse = await fetch(
          `${supabaseUrl}/rest/v1/products?select=name,description,image_object_key&status=eq.PUBLISHED&limit=40`,
          { headers: { apikey: serviceRoleKey, Authorization: `Bearer ${serviceRoleKey}` } },
        );
        if (catalogResponse.ok) {
          const products = await catalogResponse.json();
          if (Array.isArray(products)) {
            catalogContext = products
              .map((product) => `${product.name}${product.description ? ` - ${product.description}` : ""}`)
              .join("\n");
          }
        }
      } catch {
        catalogContext = "";
      }
    }
    const adapter = new GeminiAiConciergeAdapter(
      geminiApiKey,
      Deno.env.get("R2_PUBLIC_BASE_URL"),
    );
    const reply = await adapter.reply(requestContext, {
      context: catalogContext,
      imageObjectKey: typeof imageObjectKey === "string" ? imageObjectKey : undefined,
      imageUrl: typeof imageUrl === "string" ? imageUrl : undefined,
    });

    const rpcResponse = await fetch(
      `${supabaseUrl}/rest/v1/rpc/ingest_sandbox_ai_reply`,
      {
        method: "POST",
        headers: {
          apikey: serviceRoleKey,
          Authorization: `Bearer ${serviceRoleKey}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          p_thread_id: threadId,
          p_message: reply.message,
          p_idempotency_key: crypto.randomUUID(),
        }),
      },
    );
    if (!rpcResponse.ok) {
      const detail = await rpcResponse.text();
      return new Response(detail || "Failed to persist AI reply", {
        status: 502,
        headers: corsHeaders,
      });
    }

    return new Response(JSON.stringify(reply), {
      status: 200,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (error) {
    const detail =
      error instanceof Error ? error.message : "AI concierge request failed";
    return new Response(detail, { status: 400, headers: corsHeaders });
  }
});
