import { createClient } from "npm:@supabase/supabase-js@2";

// Who is calling.
// - A signed-in account sends `Authorization: Bearer <access token>` (from log-auth). The token is
//   checked with Supabase Auth on every request.
// - The owner's passcode (x-log-passcode) and the bot token (x-log-token) keep working, and always
//   mean the owner's data. They match LOG_APP_PASSCODE and LOG_DASHBOARD_TOKEN. If a secret is
//   unset, that check fails.
// A caller of kind "owner" is passed to the SQL entry points as p_user = null, which the database
// resolves to the owner.

export type Caller =
  | { kind: "owner"; via: "passcode" | "token" }
  | { kind: "user"; id: string; email: string | null };

// The log schema has no generated types here, so RPC arguments are untyped.
// deno-lint-ignore no-explicit-any
export type Admin = ReturnType<typeof createClient<any>>;

export const FAIL_DELAY_MS = 600;

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

async function matchesSecret(provided: string, envValue: string | undefined) {
  if (!envValue) return false;
  if (provided.length !== envValue.length) {
    await sha256Hex(provided);
    return false;
  }
  return timingSafeEqual(provided, envValue);
}

export async function passcodeMatches(passcode: string): Promise<boolean> {
  const p = passcode.trim();
  if (!p) return false;
  return await matchesSecret(p, Deno.env.get("LOG_APP_PASSCODE"));
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
    return await matchesSecret(token, Deno.env.get("LOG_DASHBOARD_TOKEN"))
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
