import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";
import { handleProgressPhoto, isProgressPhotoAction } from "../_shared/progress_photos.ts";

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
const MAX_BODY_BYTES = 32_768;
const ACTIONS = new Set([
  "checkin_upsert",
  "earn_it",
  "weigh_in",
  "dose_log",
  "side_effect_upsert",
  "measurement",
  "vial_start",
  "profile_update",
  "goal_set",
  "food_thought",
  "health_sync",
  "health_metrics",
  "progress_photo_sign",
  "progress_photo_save",
  "progress_photo_delete",
]);

function corsHeaders(origin: string | null): Record<string, string> {
  const allow = origin && ALLOWED_ORIGINS.includes(origin)
    ? origin
    : ALLOWED_ORIGINS[0];
  return {
    "Access-Control-Allow-Origin": allow,
    "Access-Control-Allow-Headers": "x-log-token, x-log-passcode, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Max-Age": "86400",
    Vary: "Origin",
  };
}

function json(cors: Record<string, string>, status: number, body: unknown) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...cors,
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
    },
  });
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

function isPlainObject(v: unknown): v is Record<string, unknown> {
  return !!v && typeof v === "object" && !Array.isArray(v);
}

function asString(v: unknown): string | undefined {
  if (v === undefined || v === null) return undefined;
  if (typeof v === "string") return v;
  if (typeof v === "number" || typeof v === "boolean") return String(v);
  return undefined;
}

function reject(field: string, error: string) {
  return { ok: false as const, error, field };
}

function validate(action: string, payload: Record<string, unknown>) {
  const dayRe = /^\d{4}-\d{2}-\d{2}$/;
  const enums = {
    ate_vs_usual: ["less", "usual", "more"],
    moved_vs_usual: ["less", "usual", "more"],
    dose_feel: ["strong", "fading", "not_feeling_it"],
    compound: ["tirzepatide", "retatrutide", "tesamorelin"],
    site: ["Abd LR", "Abd LL", "Abd UR", "Abd UL", "Love L", "Love R"],
    unit: ["in", "cm", "%", "lb", "kg", "mm"],
  };

  const checkEnum = (field: keyof typeof enums) => {
    const raw = asString(payload[field]);
    if (raw === undefined || raw === "") return null;
    if (!enums[field].includes(raw)) return reject(field, "invalid_enum");
    return null;
  };

  const checkRange = (field: string, min: number, max: number, integer = false) => {
    const raw = asString(payload[field]);
    if (raw === undefined || raw === "") return null;
    const n = Number(raw);
    if (!Number.isFinite(n)) return reject(field, "invalid_number");
    if (integer && !Number.isInteger(n)) return reject(field, "invalid_number");
    if (n < min || n > max) return reject(field, "out_of_range");
    return null;
  };

  const checkDate = (field: string) => {
    const raw = asString(payload[field]);
    if (raw === undefined || raw === "") return null;
    if (!dayRe.test(raw) || Number.isNaN(Date.parse(raw + "T12:00:00Z"))) {
      return reject(field, "invalid_date");
    }
    return null;
  };

  if (action === "checkin_upsert") {
    return checkDate("day") ||
      checkEnum("ate_vs_usual") ||
      checkEnum("moved_vs_usual") ||
      checkEnum("dose_feel") ||
      checkRange("mood", 1, 10, true) ||
      checkRange("food_noise", 1, 10, true) ||
      checkRange("energy", 1, 10, true) ||
      checkRange("sleep_quality", 1, 10, true) ||
      checkRange("sleep_hours", 0, 24) ||
      checkRange("exercise_minutes", 0, 1440, true) ||
      checkRange("steps", 0, 200000, true) ||
      checkRange("resting_hr", 20, 220, true) ||
      checkRange("active_calories", 0, 20000, true) ||
      null;
  }
  if (action === "earn_it") {
    if (payload.earned === undefined || payload.earned === null || asString(payload.earned) === "") {
      return reject("earned", "required");
    }
    const v = payload.earned;
    if (typeof v !== "boolean" && v !== "true" && v !== "false") {
      return reject("earned", "invalid_enum");
    }
    return checkDate("day");
  }
  if (action === "weigh_in") {
    if (asString(payload.weight_lb) === undefined || asString(payload.weight_lb) === "") {
      return reject("weight_lb", "required");
    }
    return checkRange("weight_lb", 50, 600);
  }
  if (action === "dose_log") {
    const skipped = payload.skipped === true || asString(payload.skipped) === "true";
    if (checkEnum("compound")) return checkEnum("compound");
    if (!asString(payload.compound)) return reject("compound", "required");
    if (!skipped) {
      if (asString(payload.dose_mg) === undefined || asString(payload.dose_mg) === "") {
        return reject("dose_mg", "required");
      }
      const r = checkRange("dose_mg", 0.05, 50);
      if (r) return r;
    } else if (asString(payload.dose_mg)) {
      const r = checkRange("dose_mg", 0.05, 50);
      if (r) return r;
    }
    const u = checkRange("units", 0, 1000);
    if (u) return u;
    return checkEnum("site");
  }
  if (action === "side_effect_upsert") {
    const effect = (asString(payload.effect) ?? "").trim();
    if (!effect || effect.length > 80) return reject("effect", "invalid_text");
    if (asString(payload.severity) === undefined || asString(payload.severity) === "") {
      return reject("severity", "required");
    }
    return checkRange("severity", 1, 10, true) || checkDate("recorded_on");
  }
  if (action === "measurement") {
    const metric = (asString(payload.metric) ?? "").trim();
    if (!metric || metric.length > 40) return reject("metric", "invalid_text");
    if (asString(payload.value) === undefined || asString(payload.value) === "") {
      return reject("value", "required");
    }
    return checkRange("value", 0, 1000) ||
      (asString(payload.unit) ? checkEnum("unit") : null);
  }
  if (action === "vial_start") {
    if (checkEnum("compound")) return checkEnum("compound");
    if (!asString(payload.compound)) return reject("compound", "required");
    const hasTotal = !!(asString(payload.total_mg) || asString(payload.total_units));
    if (!hasTotal) return reject("total_mg", "required");
    return checkRange("total_mg", 0, 10000) ||
      checkRange("remaining_mg", 0, 10000) ||
      checkRange("total_units", 0, 100000) ||
      checkRange("remaining_units", 0, 100000) ||
      checkRange("concentration_mg_per_ml", 0, 1000) ||
      checkDate("started_on") ||
      checkDate("expired_on");
  }
  if (action === "profile_update") {
    return checkRange("start_weight_lb", 50, 600) ||
      checkRange("goal_weight_lb", 50, 600) ||
      checkRange("height_in", 48, 90);
  }
  if (action === "food_thought") {
    const at = asString(payload.at);
    if (at && Number.isNaN(Date.parse(at))) return reject("at", "invalid_timestamp");
    const note = asString(payload.note);
    if (note && note.length > 500) return reject("note", "too_long");
    return checkRange("strength", 1, 3, true);
  }
  if (action === "health_sync") {
    const list = (key: string, max: number) => {
      const v = payload[key];
      if (v === undefined || v === null) return [];
      if (!Array.isArray(v) || v.length > max) return null;
      return v;
    };
    const days = list("days", 62);
    const weights = list("weights", 200);
    const body = list("body", 200);
    const workouts = list("workouts", 100);
    if (!days) return reject("days", "invalid_list");
    if (!weights) return reject("weights", "invalid_list");
    if (!body) return reject("body", "invalid_list");
    if (!workouts) return reject("workouts", "invalid_list");
    const inRange = (o: Record<string, unknown>, k: string, min: number, max: number) => {
      const raw = asString(o[k]);
      if (raw === undefined || raw === "") return true;
      const n = Number(raw);
      return Number.isFinite(n) && n >= min && n <= max;
    };
    const isTime = (o: Record<string, unknown>, k: string) => {
      const raw = asString(o[k]);
      return !!raw && !Number.isNaN(Date.parse(raw));
    };
    for (const d of days) {
      if (!isPlainObject(d) || !dayRe.test(asString(d.day) ?? "")) return reject("days.day", "invalid_date");
      const ok = inRange(d, "steps", 0, 200000) && inRange(d, "distance_mi", 0, 200) &&
        inRange(d, "active_kcal", 0, 20000) && inRange(d, "exercise_min", 0, 1440) &&
        inRange(d, "stand_hours", 0, 24) && inRange(d, "resting_hr", 20, 220) &&
        inRange(d, "hrv_ms", 1, 400) && inRange(d, "vo2max", 5, 100) && inRange(d, "sleep_hours", 0, 24);
      if (!ok) return reject("days", "out_of_range");
    }
    for (const w of weights) {
      if (!isPlainObject(w) || !isTime(w, "measured_at") || !inRange(w, "weight_lb", 50, 600)) return reject("weights", "invalid_entry");
    }
    for (const b of body) {
      const metric = isPlainObject(b) ? asString(b.metric) : undefined;
      if (!isPlainObject(b) || (metric !== "body_fat_pct" && metric !== "lean_mass_lb") || !isTime(b, "measured_at") || !inRange(b, "value", 0, 400)) {
        return reject("body", "invalid_entry");
      }
    }
    for (const k of workouts) {
      if (!isPlainObject(k) || !isTime(k, "started_at") || (asString(k.activity) ?? "").length > 60 ||
        !inRange(k, "duration_min", 0, 1440) || !inRange(k, "distance_mi", 0, 200) || !inRange(k, "active_kcal", 0, 20000) ||
        !inRange(k, "avg_hr", 20, 250) || !inRange(k, "max_hr", 20, 250)) {
        return reject("workouts", "invalid_entry");
      }
    }
    return null;
  }
  if (action === "health_metrics") {
    const v = payload.metrics;
    if (!Array.isArray(v) || v.length === 0 || v.length > 800) return reject("metrics", "invalid_list");
    for (const m of v) {
      if (!isPlainObject(m)) return reject("metrics", "invalid_entry");
      const day = asString(m.day) ?? "";
      const metric = asString(m.metric) ?? "";
      const value = Number(asString(m.value));
      const unit = asString(m.unit) ?? "";
      if (!dayRe.test(day) || !/^[a-z0-9_]{2,40}$/.test(metric) || !Number.isFinite(value) || Math.abs(value) > 100000 || unit.length > 12) {
        return reject("metrics", "invalid_entry");
      }
    }
    return null;
  }
  if (action === "progress_photo_sign" || action === "progress_photo_save") {
    const at = asString(payload.taken_at);
    if (at && Number.isNaN(Date.parse(at))) return reject("taken_at", "invalid_timestamp");
    if (asString(payload.weight_lb) === undefined || asString(payload.weight_lb) === "") {
      return reject("weight_lb", "required");
    }
    const range = checkRange("weight_lb", 50, 600);
    if (range) return range;
    const id = asString(payload.weight_id);
    if (id && !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id)) {
      return reject("weight_id", "invalid_id");
    }
    if (action === "progress_photo_save") {
      const path = asString(payload.path) ?? "";
      if (!/^[0-9]{4}\/[0-9]{2}\/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jpg$/.test(path)) {
        return reject("path", "invalid_path");
      }
      return checkRange("byte_size", 1, 2097152, true);
    }
    return null;
  }
  if (action === "progress_photo_delete") {
    const id = asString(payload.id) ?? "";
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id)) {
      return reject("id", "invalid_id");
    }
    return null;
  }
  if (action === "goal_set") {
    const kind = (asString(payload.kind) ?? "").trim().toLowerCase();
    if (kind !== "calories" && kind !== "protein") return reject("kind", "invalid_enum");
    if (asString(payload.target) === undefined || asString(payload.target) === "") {
      return reject("target", "required");
    }
    return kind === "calories"
      ? checkRange("target", 800, 6000, true)
      : checkRange("target", 20, 400, true);
  }
  return reject("action", "invalid_action");
}

Deno.serve(async (req: Request) => {
  const origin = req.headers.get("Origin");
  const cors = corsHeaders(origin);

  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: cors });
  }

  if (req.method !== "POST") {
    return json(cors, 405, { error: "method_not_allowed" });
  }

  if (!await isAuthorized(req)) {
    await new Promise((resolve) => setTimeout(resolve, FAIL_DELAY_MS));
    return json(cors, 401, { error: "unauthorized" });
  }

  const rawLen = Number(req.headers.get("content-length") ?? "0");
  if (rawLen > MAX_BODY_BYTES) {
    return json(cors, 413, { ok: false, error: "payload_too_large" });
  }

  let body: unknown;
  try {
    const text = await req.text();
    if (text.length > MAX_BODY_BYTES) {
      return json(cors, 413, { ok: false, error: "payload_too_large" });
    }
    body = text ? JSON.parse(text) : {};
  } catch {
    return json(cors, 400, { ok: false, error: "invalid_json" });
  }

  if (!isPlainObject(body)) {
    return json(cors, 400, { ok: false, error: "invalid_json" });
  }

  const action = asString(body.action)?.trim() ?? "";
  if (!ACTIONS.has(action)) {
    return json(cors, 400, { ok: false, error: "invalid_action", field: "action" });
  }

  const payload = isPlainObject(body.payload) ? body.payload : {};
  const failed = validate(action, payload);
  if (failed) return json(cors, 400, failed);

  const url = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !serviceKey) {
    return json(cors, 500, { error: "server_misconfigured" });
  }

  try {
    const admin = createClient(url, serviceKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    // Apple Health daily metrics and progress photos have their own functions.
    // Everything else goes through log_write.
    let result: unknown;
    if (isProgressPhotoAction(action)) {
      result = await handleProgressPhoto(admin, action, payload, url);
    } else {
      const { data, error } = action === "health_metrics"
        ? await admin.rpc("log_health_metrics", { p_payload: payload })
        : await admin.rpc("log_write", { p_action: action, p_payload: payload });
      if (error) {
        console.error("log_write", error.message);
        return json(cors, 500, { ok: false, error: "query_failed" });
      }
      result = data ?? { ok: false, error: "empty_result" };
    }
    const ok = !!(result as { ok?: boolean }).ok;
    return json(cors, ok ? 200 : 400, result);
  } catch (err) {
    console.error("log-write", err);
    return json(cors, 500, { ok: false, error: "server_error" });
  }
});
