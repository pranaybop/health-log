import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import {
  adminClient,
  bearer,
  corsHeaders,
  failDelay,
  passcodeMatches,
  resolveCaller,
} from "../_shared/auth.ts";

// Sign-in for the app. The app never holds a Supabase key: it posts here, and this
// function talks to Supabase Auth with the project's anon key, server side.
//
// POST { action, ... }
//   signup        { email, password }            -> session
//   signin        { email, password }            -> session
//   refresh       { refresh_token }              -> session
//   google_url    { redirect_to, code_challenge } -> { url } to open in a web auth session
//   google_finish { auth_code, code_verifier }   -> session
//   apple_finish  { id_token, nonce? }           -> session (built, not shown in the app yet)
//   reset         { email }                      -> sends a password reset email
//   signout       (Bearer)                       -> ends the session
//   me            (Bearer)                       -> { user, owner, claimed }
//   claim         (Bearer + x-log-passcode)      -> moves the owner's existing log to this account
//
// A session is { access_token, refresh_token, expires_at, user: { id, email } }.
// After every sign-in the owner check runs: if the email matches the owner's (set in the
// database, never in this repo), the existing log moves to the account the first time.

const MAX_BODY = 4096;
const EMAIL_RE = /^[^\s@]{1,64}@[^\s@]{1,190}\.[^\s@]{2,24}$/;
const REDIRECT_RE = /^com\.pranaybop\.log:\/\/auth-callback(\?.*)?$/;

type Json = Record<string, unknown>;

function str(v: unknown, max = 4096): string {
  return typeof v === "string" ? v.trim().slice(0, max) : "";
}

Deno.serve(async (req: Request) => {
  const cors = corsHeaders(req.headers.get("Origin"), "POST, OPTIONS");
  const json = (status: number, body: unknown) =>
    new Response(JSON.stringify(body), {
      status,
      headers: { ...cors, "Content-Type": "application/json", "Cache-Control": "no-store" },
    });

  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
  if (req.method !== "POST") return json(405, { ok: false, error: "method_not_allowed" });

  const url = Deno.env.get("SUPABASE_URL");
  const anon = Deno.env.get("SUPABASE_ANON_KEY");
  const admin = adminClient();
  if (!url || !anon || !admin) return json(500, { ok: false, error: "server_misconfigured" });

  let body: Json;
  try {
    const text = await req.text();
    if (text.length > MAX_BODY) return json(413, { ok: false, error: "payload_too_large" });
    const parsed = text ? JSON.parse(text) : {};
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) throw new Error("shape");
    body = parsed as Json;
  } catch {
    return json(400, { ok: false, error: "invalid_json" });
  }

  const auth = async (path: string, payload: Json, token?: string) => {
    const res = await fetch(`${url}/auth/v1/${path}`, {
      method: "POST",
      headers: {
        apikey: anon,
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
        "Content-Type": "application/json",
      },
      body: JSON.stringify(payload),
    });
    let data: Json = {};
    try {
      data = await res.json();
    } catch {
      data = {};
    }
    return { status: res.status, data };
  };

  // Supabase Auth's error, as a short code and a sentence the app can show.
  const authError = (status: number, data: Json) => {
    const code = str(data.error_code) || str(data.error) || "auth_failed";
    const msg = str(data.msg) || str(data.error_description) || str(data.message) ||
      "That didn’t work. Try again.";
    return json(status >= 500 ? 502 : 400, { ok: false, error: code, message: msg });
  };

  // Shape a session for the app and run the owner check once.
  const session = async (data: Json) => {
    const user = (data.user ?? {}) as Json;
    const id = str(user.id);
    const email = str(user.email) || null;
    if (!str(data.access_token) || !id) return json(502, { ok: false, error: "no_session" });
    let owner = false;
    try {
      const { data: claim } = await admin.rpc("log_claim_owner", {
        p_user: id,
        p_email: email,
        p_by_passcode: false,
      });
      owner = !!(claim as Json | null)?.owner;
    } catch (err) {
      console.error("log_claim_owner", err);
    }
    return json(200, {
      ok: true,
      session: {
        access_token: data.access_token,
        refresh_token: data.refresh_token,
        expires_at: data.expires_at ??
          Math.floor(Date.now() / 1000) + Number(data.expires_in ?? 3600),
        user: { id, email },
      },
      owner,
    });
  };

  const action = str(body.action, 40);
  try {
    if (action === "signup" || action === "signin") {
      const email = str(body.email, 254).toLowerCase();
      const password = typeof body.password === "string" ? body.password : "";
      if (!EMAIL_RE.test(email)) return json(400, { ok: false, error: "invalid_email", message: "Enter a valid email." });
      if (password.length < 8 || password.length > 128) {
        return json(400, { ok: false, error: "weak_password", message: "Use at least 8 characters." });
      }
      if (action === "signup") {
        // Created confirmed, so a friend can start right away without an email round trip.
        const created = await admin.auth.admin.createUser({ email, password, email_confirm: true });
        if (created.error) {
          const taken = /already|registered|exists/i.test(created.error.message);
          await failDelay();
          return json(400, {
            ok: false,
            error: taken ? "email_taken" : "signup_failed",
            message: taken ? "That email already has an account. Sign in instead." : created.error.message,
          });
        }
      }
      const r = await auth("token?grant_type=password", { email, password });
      if (r.status !== 200) {
        await failDelay();
        return authError(r.status, r.data);
      }
      return await session(r.data);
    }

    if (action === "refresh") {
      const token = str(body.refresh_token, 512);
      if (!token) return json(400, { ok: false, error: "missing_refresh_token" });
      const r = await auth("token?grant_type=refresh_token", { refresh_token: token });
      if (r.status !== 200) return json(401, { ok: false, error: "session_expired", message: "Sign in again." });
      return await session(r.data);
    }

    if (action === "google_url") {
      const redirect = str(body.redirect_to, 300);
      const challenge = str(body.code_challenge, 200);
      if (!REDIRECT_RE.test(redirect) || !/^[A-Za-z0-9_-]{43,128}$/.test(challenge)) {
        return json(400, { ok: false, error: "invalid_request" });
      }
      // Say so in the app if Google isn't turned on in Supabase Auth yet, instead of a raw error page.
      try {
        const res = await fetch(`${url}/auth/v1/settings`, { headers: { apikey: anon } });
        const settings = await res.json() as { external?: Record<string, boolean> };
        if (res.ok && settings.external && settings.external.google !== true) {
          return json(400, { ok: false, error: "google_not_enabled", message: "Google sign-in isn’t set up yet. Use email for now." });
        }
      } catch {
        // Can't tell: let the sign-in page try.
      }
      const q = new URLSearchParams({
        provider: "google",
        redirect_to: redirect,
        code_challenge: challenge,
        code_challenge_method: "s256",
      });
      return json(200, { ok: true, url: `${url}/auth/v1/authorize?${q}` });
    }

    if (action === "google_finish") {
      const code = str(body.auth_code, 512);
      const verifier = str(body.code_verifier, 200);
      if (!code || !verifier) return json(400, { ok: false, error: "invalid_request" });
      const r = await auth("token?grant_type=pkce", { auth_code: code, code_verifier: verifier });
      if (r.status !== 200) return authError(r.status, r.data);
      return await session(r.data);
    }

    if (action === "apple_finish") {
      const idToken = str(body.id_token, 4096);
      if (!idToken) return json(400, { ok: false, error: "invalid_request" });
      const payload: Json = { provider: "apple", id_token: idToken };
      const nonce = str(body.nonce, 200);
      if (nonce) payload.nonce = nonce;
      const r = await auth("token?grant_type=id_token", payload);
      if (r.status !== 200) return authError(r.status, r.data);
      return await session(r.data);
    }

    if (action === "reset") {
      const email = str(body.email, 254).toLowerCase();
      if (!EMAIL_RE.test(email)) return json(400, { ok: false, error: "invalid_email", message: "Enter a valid email." });
      await auth("recover", { email });
      // Same answer whether or not the account exists.
      return json(200, { ok: true, message: "If that email has an account, a reset link is on its way." });
    }

    if (action === "signout") {
      const token = bearer(req);
      if (token) await auth("logout", {}, token);
      return json(200, { ok: true });
    }

    if (action === "me" || action === "claim") {
      const caller = await resolveCaller(req, admin);
      if (!caller || caller.kind !== "user") {
        await failDelay();
        return json(401, { ok: false, error: "unauthorized" });
      }
      if (action === "claim") {
        const passcode = (req.headers.get("x-log-passcode") ?? "").trim();
        if (!await passcodeMatches(passcode)) {
          await failDelay();
          return json(401, { ok: false, error: "wrong_passcode", message: "That passcode didn’t match." });
        }
        const { data, error } = await admin.rpc("log_claim_owner", {
          p_user: caller.id,
          p_email: caller.email,
          p_by_passcode: true,
        });
        if (error) {
          console.error("log_claim_owner", error.message);
          return json(500, { ok: false, error: "query_failed" });
        }
        const r = (data ?? {}) as Json;
        if (r.ok === false) {
          return json(400, {
            ok: false,
            error: r.error,
            message: r.error === "account_has_data"
              ? "This account already has its own log. Link the passcode from a fresh account."
              : "Couldn’t link the log.",
          });
        }
        if (!r.owner) {
          return json(400, { ok: false, error: "already_linked", message: "The log is already linked to another account." });
        }
        return json(200, { ok: true, owner: true, claimed: !!r.claimed });
      }
      const { data } = await admin.rpc("log_claim_owner", {
        p_user: caller.id,
        p_email: caller.email,
        p_by_passcode: false,
      });
      return json(200, {
        ok: true,
        user: { id: caller.id, email: caller.email },
        owner: !!(data as Json | null)?.owner,
      });
    }

    return json(400, { ok: false, error: "invalid_action" });
  } catch (err) {
    console.error("log-auth", action, err);
    return json(500, { ok: false, error: "server_error" });
  }
});
