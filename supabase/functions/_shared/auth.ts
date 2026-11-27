import { createClient } from "npm:@supabase/supabase-js@2";

// Who is calling.
// - A signed-in account sends `Authorization: Bearer <access token>` (from log-auth). The token is
//   checked with Supabase Auth on every request.
// - The owner's passcode (x-log-passcode) and the bot token (x-log-token) keep working, and always
//   mean the owner's data.
// A caller of kind "owner" is passed to the SQL entry points as p_user = null, which the database
// resolves to the owner.

export type Caller =
  | { kind: "owner"; via: "passcode" | "token" }
  | { kind: "user"; id: string; email: string | null };

// The log schema has no generated types here, so RPC arguments are untyped.
// deno-lint-ignore no-explicit-any
export type Admin = ReturnType<typeof createClient<any>>;

const TOKEN_SHA256 =
  "90914af968e4fcf68e45dae85c4a5922e4b3c2107c5b1488e9b5ef47479ad0c1";
const PASSCODE_SHA256 =
  "c6d060a5798679bdf5a95f238ee3305905410818ec1143bf098e3189440cd04f";

export const FAIL_DELAY_MS = 600;

export const ALLOWED_ORIGINS = [
  "https://pranaybop.github.io",
  "http://127.0.0.1:4173",
  "http://localhost:4173",
];

export function corsHeaders(origin: string | null, methods: string): Record<string, string> {
  const allow = origin && ALLOWED_ORIGINS.includes(origin) ? origin : ALLOWED_ORIGINS[0];
  return {
    "Access-Control-Allow-Origin": allow,
    "Access-Control-Allow-Headers": "authorization, x-log-token, x-log-passcode, content-type",
    "Access-Control-Allow-Methods": methods,
    "Access-Control-Max-Age": "86400",
    Vary: "Origin",
  };
}

function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let out = 0;
  for (let i = 0; i < a.length; i++) out |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return out === 0;
}

async function sha256Hex(value: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return Array.from(new Uint8Array(buf)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function matchesSecret(provided: string, envValue: string | undefined, expectedHash: string) {
  if (envValue && envValue.length > 0) {
    if (provided.length !== envValue.length) {
      await sha256Hex(provided);
      return false;
    }
    return timingSafeEqual(provided, envValue);
  }
  return timingSafeEqual(await sha256Hex(provided), expectedHash);
}

export async function passcodeMatches(passcode: string): Promise<boolean> {
  const p = passcode.trim();
  if (!p) return false;
  return await matchesSecret(p, Deno.env.get("LOG_APP_PASSCODE"), PASSCODE_SHA256);
}

export function bearer(req: Request): string {
  const raw = req.headers.get("authorization") ?? "";
  const m = /^Bearer\s+(.+)$/i.exec(raw.trim());
  return m ? m[1].trim() : "";
}

// Signed-in account first, then the bot token, then the passcode. Null means unauthorized.
export async function resolveCaller(req: Request, admin: Admin): Promise<Caller | null> {
  const jwt = bearer(req);
  // The project's own keys are JWTs too; they are never a user session.
  if (jwt && jwt !== Deno.env.get("SUPABASE_ANON_KEY") && jwt.split(".").length === 3) {
    const { data, error } = await admin.auth.getUser(jwt);
    if (!error && data?.user?.id) {
      return { kind: "user", id: data.user.id, email: data.user.email ?? null };
    }
    return null;
  }
  const token = (req.headers.get("x-log-token") ?? "").trim();
  if (token) {
    return await matchesSecret(token, Deno.env.get("LOG_DASHBOARD_TOKEN"), TOKEN_SHA256)
      ? { kind: "owner", via: "token" }
      : null;
  }
  const passcode = (req.headers.get("x-log-passcode") ?? "").trim();
  if (passcode) {
    return await passcodeMatches(passcode) ? { kind: "owner", via: "passcode" } : null;
  }
  return null;
}

// The value for p_user in the SQL entry points.
export function userParam(caller: Caller): string | null {
  return caller.kind === "user" ? caller.id : null;
}

export function adminClient(): Admin | null {
  const url = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !serviceKey) return null;
  // deno-lint-ignore no-explicit-any
  return createClient<any>(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
}

export async function failDelay() {
  await new Promise((resolve) => setTimeout(resolve, FAIL_DELAY_MS));
}
