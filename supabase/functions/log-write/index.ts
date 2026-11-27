import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { handleProgressPhoto, isProgressPhotoAction } from "../_shared/progress_photos.ts";
import { adminClient, failDelay, resolveCaller, userParam } from "../_shared/auth.ts";

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
  "meal_log",
  "account_setup",
  "regimen_set",
  "regimen_end",
]);

function json(status: number, body: unknown) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
    },
  });
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
    compound: ["tirzepatide", "retatrutide", "semaglutide", "tesamorelin"],
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
  if (action === "meal_log") {
    const items = payload.items;
    if (!Array.isArray(items) || items.length === 0 || items.length > 30) return reject("items", "invalid_list");
    for (const it of items) {
      if (!isPlainObject(it)) return reject("items", "invalid_entry");
      const name = (asString(it.item) ?? "").trim();
      if (!name || name.length > 200) return reject("items", "invalid_entry");
      for (const [k, max] of [["calories", 5000], ["protein_g", 500], ["carbs_g", 1000], ["fat_g", 500], ["fiber_g", 200]] as const) {
        const raw = asString(it[k]);
        if (raw === undefined || raw === "") continue;
        const n = Number(raw);
        if (!Number.isFinite(n) || n < 0 || n > max) return reject("items", "out_of_range");
      }
    }
    const type = asString(payload.meal_type);
    if (type && !["breakfast", "lunch", "dinner", "snack"].includes(type)) return reject("meal_type", "invalid_enum");
    const at = asString(payload.eaten_at);
    if (at && Number.isNaN(Date.parse(at))) return reject("eaten_at", "invalid_timestamp");
    return null;
  }
  if (action === "account_setup") {
    const name = asString(payload.display_name);
    if (name && name.length > 80) return reject("display_name", "too_long");
    const tz = asString(payload.time_zone);
    if (tz && !/^[A-Za-z_]+(\/[A-Za-z0-9_+-]+){0,2}$/.test(tz)) return reject("time_zone", "invalid_time_zone");
    if (payload.settings !== undefined && !isPlainObject(payload.settings)) return reject("settings", "invalid_entry");
    if (payload.settings !== undefined && JSON.stringify(payload.settings).length > 8000) return reject("settings", "too_long");
    return checkRange("start_weight_lb", 50, 600) ||
      checkRange("goal_weight_lb", 50, 600) ||
      checkRange("height_in", 48, 90);
  }
  if (action === "regimen_set") {
    if (!asString(payload.compound)) return reject("compound", "required");
    if (asString(payload.dose_mg) === undefined || asString(payload.dose_mg) === "") return reject("dose_mg", "required");
    return checkEnum("compound") ||
      checkRange("dose_mg", 0.05, 50) ||
      checkRange("units", 0, 1000) ||
      checkRange("every_days", 1, 28, true) ||
      checkRange("days_on", 1, 28, true) ||
      checkRange("days_off", 1, 28, true) ||
      checkRange("concentration_mg_per_ml", 0, 1000) ||
      checkDate("start_on") ||
      checkDate("end_on");
  }
  if (action === "regimen_end") {
    const id = asString(payload.id) ?? "";
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id)) return reject("id", "invalid_id");
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
  if (req.method !== "POST") {
    return json(405, { error: "method_not_allowed" });
  }

  const admin = adminClient();
  if (!admin) return json(500, { error: "server_misconfigured" });

  const caller = await resolveCaller(req, admin).catch(() => null);
  if (!caller) {
    await failDelay();
    return json(401, { error: "unauthorized" });
  }
  const user = userParam(caller);

  const rawLen = Number(req.headers.get("content-length") ?? "0");
  if (rawLen > MAX_BODY_BYTES) {
    return json(413, { ok: false, error: "payload_too_large" });
  }

  let body: unknown;
  try {
    const text = await req.text();
    if (text.length > MAX_BODY_BYTES) {
      return json(413, { ok: false, error: "payload_too_large" });
    }
    body = text ? JSON.parse(text) : {};
  } catch {
    return json(400, { ok: false, error: "invalid_json" });
  }

  if (!isPlainObject(body)) {
    return json(400, { ok: false, error: "invalid_json" });
  }

  const action = asString(body.action)?.trim() ?? "";
  if (!ACTIONS.has(action)) {
    return json(400, { ok: false, error: "invalid_action", field: "action" });
  }

  const payload = isPlainObject(body.payload) ? body.payload : {};
  const failed = validate(action, payload);
  if (failed) return json(400, failed);

  try {
    // Each action runs as the caller (p_user; null is the owner).
    let result: unknown;
    if (isProgressPhotoAction(action)) {
      const tz = typeof payload.time_zone === "string" ? payload.time_zone : "America/Chicago";
      result = await handleProgressPhoto(admin, action, payload, Deno.env.get("SUPABASE_URL") ?? "", user, tz);
    } else {
      const call = action === "health_metrics"
        ? admin.rpc("log_health_metrics_for", { p_user: user, p_payload: payload })
        : action === "meal_log"
        ? admin.rpc("log_meal_for", { p_user: user, p_payload: payload })
        : action === "account_setup"
        ? admin.rpc("log_account_setup_for", { p_user: user, p_payload: payload })
        : action === "regimen_set"
        ? admin.rpc("log_regimen_set_for", { p_user: user, p_payload: payload })
        : action === "regimen_end"
        ? admin.rpc("log_regimen_end_for", { p_user: user, p_payload: payload })
        : admin.rpc("log_write_for", { p_user: user, p_action: action, p_payload: payload });
      const { data, error } = await call;
      if (error) {
        console.error("log_write", action, error.message);
        return json(500, { ok: false, error: "query_failed" });
      }
      result = data ?? { ok: false, error: "empty_result" };
    }
    const ok = !!(result as { ok?: boolean }).ok;
    return json(ok ? 200 : 400, result);
  } catch (err) {
    console.error("log-write", err);
    return json(500, { ok: false, error: "server_error" });
  }
});
