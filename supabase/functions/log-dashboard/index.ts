import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const TOKEN_SHA256 =
  "90914af968e4fcf68e45dae85c4a5922e4b3c2107c5b1488e9b5ef47479ad0c1";
const PASSCODE_SHA256 =
  "c6d060a5798679bdf5a95f238ee3305905410818ec1143bf098e3189440cd04f";

const ALLOWED_ORIGINS = [
  "https://pranaybop.github.io",
  "http://127.0.0.1:4173",
  "http://localhost:4173",
];

const FAIL_DELAY_MS = 600;

function corsHeaders(origin: string | null): Record<string, string> {
  const allow = origin && ALLOWED_ORIGINS.includes(origin)
    ? origin
    : ALLOWED_ORIGINS[0];
  return {
    "Access-Control-Allow-Origin": allow,
    "Access-Control-Allow-Headers": "x-log-token, x-log-passcode, content-type",
    "Access-Control-Allow-Methods": "GET, OPTIONS",
    "Access-Control-Max-Age": "86400",
    Vary: "Origin",
  };
}

function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let out = 0;
  for (let i = 0; i < a.length; i++) {
    out |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return out === 0;
}

async function sha256Hex(value: string): Promise<string> {
  const buf = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(value),
  );
  return Array.from(new Uint8Array(buf))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

async function matchesSecret(
  provided: string,
  envValue: string | undefined,
  expectedHash: string,
): Promise<boolean> {
  if (envValue && envValue.length > 0) {
    if (provided.length !== envValue.length) {
      await sha256Hex(provided);
      return false;
    }
    return timingSafeEqual(provided, envValue);
  }
  const digest = await sha256Hex(provided);
  return timingSafeEqual(digest, expectedHash);
}

async function isAuthorized(req: Request): Promise<boolean> {
  const token = (req.headers.get("x-log-token") ?? "").trim();
  if (token) {
    return await matchesSecret(
      token,
      Deno.env.get("LOG_DASHBOARD_TOKEN"),
      TOKEN_SHA256,
    );
  }
  const passcode = (req.headers.get("x-log-passcode") ?? "").trim();
  if (passcode) {
    return await matchesSecret(
      passcode,
      Deno.env.get("LOG_APP_PASSCODE"),
      PASSCODE_SHA256,
    );
  }
  return false;
}

Deno.serve(async (req: Request) => {
  const origin = req.headers.get("Origin");
  const cors = corsHeaders(origin);

  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: cors });
  }

  if (req.method !== "GET") {
    return new Response(JSON.stringify({ error: "method_not_allowed" }), {
      status: 405,
      headers: { ...cors, "Content-Type": "application/json" },
    });
  }

  if (!await isAuthorized(req)) {
    await new Promise((resolve) => setTimeout(resolve, FAIL_DELAY_MS));
    return new Response(JSON.stringify({ error: "unauthorized" }), {
      status: 401,
      headers: { ...cors, "Content-Type": "application/json" },
    });
  }

  const url = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !serviceKey) {
    return new Response(JSON.stringify({ error: "server_misconfigured" }), {
      status: 500,
      headers: { ...cors, "Content-Type": "application/json" },
    });
  }

  try {
    const admin = createClient(url, serviceKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { data, error } = await admin.rpc("log_dashboard_payload");
    if (error) {
      console.error("log_dashboard_payload", error.message);
      return new Response(JSON.stringify({ error: "query_failed" }), {
        status: 500,
        headers: { ...cors, "Content-Type": "application/json" },
      });
    }
    return new Response(JSON.stringify(data), {
      status: 200,
      headers: {
        ...cors,
        "Content-Type": "application/json",
        "Cache-Control": "no-store",
      },
    });
  } catch (err) {
    console.error("log-dashboard", err);
    return new Response(JSON.stringify({ error: "server_error" }), {
      status: 500,
      headers: { ...cors, "Content-Type": "application/json" },
    });
  }
});
