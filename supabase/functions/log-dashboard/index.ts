import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { attachProgressPhotos } from "../_shared/progress_photos.ts";
import { adminClient, corsHeaders, failDelay, resolveCaller, userParam } from "../_shared/auth.ts";

// GET the caller's dashboard: a signed-in account (Bearer token), or the owner
// (x-log-passcode / x-log-token).

Deno.serve(async (req: Request) => {
  const cors = corsHeaders(req.headers.get("Origin"), "GET, OPTIONS");
  const json = (status: number, body: unknown) =>
    new Response(JSON.stringify(body), {
      status,
      headers: { ...cors, "Content-Type": "application/json", "Cache-Control": "no-store" },
    });

  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
  if (req.method !== "GET") return json(405, { error: "method_not_allowed" });

  const admin = adminClient();
  if (!admin) return json(500, { error: "server_misconfigured" });

  try {
    const caller = await resolveCaller(req, admin);
    if (!caller) {
      await failDelay();
      return json(401, { error: "unauthorized" });
    }
    const user = userParam(caller);
    const { data, error } = await admin.rpc("log_dashboard_payload_for", { p_user: user });
    if (error) {
      console.error("log_dashboard_payload", error.message);
      return json(500, { error: "query_failed" });
    }
    if (data && typeof data === "object") {
      (data as Record<string, unknown>).account = caller.kind === "user"
        ? { kind: "user", email: caller.email }
        : { kind: "owner" };
    }
    try {
      await attachProgressPhotos(admin, data, user);
    } catch (err) {
      console.error("progress_photos", err);
    }
    return json(200, data);
  } catch (err) {
    console.error("log-dashboard", err);
    return json(500, { error: "server_error" });
  }
});
