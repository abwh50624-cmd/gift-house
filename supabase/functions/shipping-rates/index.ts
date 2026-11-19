import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

Deno.serve(async (request) => {
  if (request.method !== "GET" && request.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const publishableKey =
      Deno.env.get("SUPABASE_ANON_KEY") ??
      Deno.env.get("SUPABASE_PUBLISHABLE_KEY");
    if (!supabaseUrl || !publishableKey) {
      return Response.json({ error: "shipping service is not configured" }, { status: 503 });
    }

    const url = new URL(request.url);
    const governorate = url.searchParams.get("governorate");
    const provider = url.searchParams.get("provider");
    const supabase = createClient(supabaseUrl, publishableKey, {
      global: {
        headers: {
          authorization: request.headers.get("authorization") ?? "",
        },
      },
    });

    const { data, error } = await supabase.rpc("get_shipping_rates", {
      p_governorate: governorate,
      p_provider: provider,
    });
    if (error) throw error;
    return Response.json({ rates: data ?? [] });
  } catch (error) {
    console.error("shipping rates failed", error);
    return Response.json(
      { error: "Unable to load live shipping rates" },
      { status: 502 },
    );
  }
});
