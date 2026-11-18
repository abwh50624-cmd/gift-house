const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

const encoder = new TextEncoder();
const allowedTypes = new Set(["image/jpeg", "image/png", "image/webp"]);
const maximumBytes = 10 * 1024 * 1024;

function hex(bytes: Uint8Array): string {
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

async function sha256(value: string | Uint8Array): Promise<string> {
  const data = typeof value === "string" ? encoder.encode(value) : value;
  return hex(new Uint8Array(await crypto.subtle.digest("SHA-256", data)));
}

async function hmac(key: Uint8Array, value: string): Promise<Uint8Array> {
  const cryptoKey = await crypto.subtle.importKey(
    "raw",
    key,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  return new Uint8Array(await crypto.subtle.sign("HMAC", cryptoKey, encoder.encode(value)));
}

function encodeRfc3986(value: string): string {
  return encodeURIComponent(value).replace(/[!'()*]/g, (char) =>
    `%${char.charCodeAt(0).toString(16).toUpperCase()}`
  );
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (request.method !== "POST") {
    return new Response("Method not allowed", { status: 405, headers: corsHeaders });
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const accountId = Deno.env.get("R2_ACCOUNT_ID");
  const accessKeyId = Deno.env.get("R2_ACCESS_KEY_ID");
  const secretAccessKey = Deno.env.get("R2_SECRET_ACCESS_KEY");
  const bucket = Deno.env.get("R2_BUCKET_NAME");
  const token = request.headers.get("authorization")?.replace(/^Bearer\s+/i, "");
  if (!supabaseUrl || !serviceRoleKey || !token ||
      !accountId || !accessKeyId || !secretAccessKey || !bucket) {
    return new Response("R2 storage is not configured", { status: 500, headers: corsHeaders });
  }

  const userResponse = await fetch(`${supabaseUrl}/auth/v1/user`, {
    headers: { apikey: serviceRoleKey, Authorization: `Bearer ${token}` },
  });
  if (!userResponse.ok) {
    return new Response("Unauthorized", { status: 401, headers: corsHeaders });
  }
  const user = await userResponse.json();
  if (typeof user?.id !== "string") {
    return new Response("Unauthorized", { status: 401, headers: corsHeaders });
  }

  let payload: Record<string, unknown>;
  try {
    payload = await request.json();
  } catch {
    return new Response("Invalid JSON", { status: 400, headers: corsHeaders });
  }
  const contentType = payload.content_type;
  const size = payload.size;
  if (typeof contentType !== "string" || !allowedTypes.has(contentType) ||
      typeof size !== "number" || !Number.isInteger(size) ||
      size <= 0 || size > maximumBytes) {
    return new Response("Invalid or unsupported image", { status: 400, headers: corsHeaders });
  }

  const purpose = payload.purpose === "catalog" ? "catalog" : "chat";
  const objectKey = `${purpose}/${user.id}/${crypto.randomUUID()}.webp`;
  const host = `${accountId}.r2.cloudflarestorage.com`;
  const canonicalUri = `/${encodeRfc3986(bucket)}/${objectKey.split("/").map(encodeRfc3986).join("/")}`;
  const now = new Date();
  const amzDate = now.toISOString().replace(/[:-]|\.\d{3}/g, "");
  const dateStamp = amzDate.slice(0, 8);
  const credentialScope = `${dateStamp}/auto/s3/aws4_request`;
  const query = new URLSearchParams({
    "X-Amz-Algorithm": "AWS4-HMAC-SHA256",
    "X-Amz-Credential": `${accessKeyId}/${credentialScope}`,
    "X-Amz-Date": amzDate,
    "X-Amz-Expires": "900",
    "X-Amz-SignedHeaders": "content-type;host",
  });
  const canonicalQuery = [...query.entries()].sort(([a], [b]) => a.localeCompare(b))
    .map(([key, value]) => `${encodeRfc3986(key)}=${encodeRfc3986(value)}`)
    .join("&");
  const canonicalHeaders = `content-type:${encodeURIComponent("image/webp")}\nhost:${host}\n`;
  const canonicalRequest = [
    "PUT", canonicalUri, canonicalQuery, canonicalHeaders,
    "content-type;host", "UNSIGNED-PAYLOAD",
  ].join("\n");
  const stringToSign = [
    "AWS4-HMAC-SHA256", amzDate, credentialScope,
    await sha256(canonicalRequest),
  ].join("\n");
  let signingKey = await hmac(encoder.encode(`AWS4${secretAccessKey}`), dateStamp);
  signingKey = await hmac(signingKey, "auto");
  signingKey = await hmac(signingKey, "s3");
  signingKey = await hmac(signingKey, "aws4_request");
  const signature = hex(await hmac(signingKey, stringToSign));

  const uploadUrl = `https://${host}${canonicalUri}?${canonicalQuery}&X-Amz-Signature=${signature}`;
  const publicBase = Deno.env.get("R2_PUBLIC_BASE_URL")?.replace(/\/+$/, "");
  const publicUrl = publicBase ? `${publicBase}/${objectKey}` : null;
  return new Response(JSON.stringify({
    upload_url: uploadUrl,
    object_key: objectKey,
    public_url: publicUrl,
    content_type: "image/webp",
  }), { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } });
});
