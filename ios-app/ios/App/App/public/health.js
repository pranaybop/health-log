/*
  Apple Health sync. Only does anything inside the Log iPhone app, where Capacitor
  injects the native bridge and the @capgo/capacitor-health plugin ("Health").
  In Safari or any browser, canSyncHealth() is false and nothing here runs.

  What it sends:
    health_sync     days      per-day totals: steps, distance, active calories, exercise minutes,
                              stand hours, resting heart rate, HRV, VO2 max, sleep (upsert by day)
                    weights   weigh-ins (insert only, skips ones already logged)
                    body      body fat % and lean mass (lean = weigh-in at the same time × (1 − fat))
                    workouts  workouts, named like the existing ones ("running", "stair climbing")
    health_metrics  metrics   every other daily number, into log.health_metrics (upsert by day + metric)

  The plugin only aggregates a few types (steps, distance, active energy, water, dietary energy:
  sum; heart rate, resting heart rate, weight: average/min/max). Everything else is read as
  samples and summed here. Cumulative samples can come from both the iPhone and the Watch, so a
  day's total is the larger of the per-source totals, never their sum.

  Backfill walks back through history from yesterday, sending metrics, weigh-ins, body
  composition and workouts. It doesn't send daily totals: older days of those came from the
  Health export and stay as they are. It remembers where it got to and carries on next launch.
*/

const HEALTH_LAST_KEY = "log.healthSync";
const HEALTH_BACKFILL_KEY = "log.healthBackfill";
const BACKFILL_FLOOR = "2015-01-01";
const SAMPLE_LIMIT = 20000;

// Everything this plugin version can read on iPhone (dietaryProtein is Android-only, and
// totalCalories is the same HealthKit type as calories). One permission sheet for all of them.
const HEALTH_CORE = [
  "steps", "distance", "calories", "exerciseTime", "appleStandHour",
  "restingHeartRate", "heartRateVariability", "vo2Max", "sleep",
  "weight", "bodyFat", "workouts",
];
const HEALTH_READ = [
  ...HEALTH_CORE,
  "heartRate", "respiratoryRate", "oxygenSaturation", "bloodPressure", "bloodGlucose",
  "bodyTemperature", "basalBodyTemperature", "appleSleepingWristTemperature", "height",
  "flightsClimbed", "distanceCycling", "basalCalories", "mindfulness", "dietaryWater",
  "dietaryEnergyConsumed", "stateOfMind",
];
const KG_TO_LB = 2.2046226218;
const M_TO_MI = 1 / 1609.344;
const L_TO_FLOZ = 33.814;
const r1 = (v) => Math.round(v * 10) / 10;
const r2 = (v) => Math.round(v * 100) / 100;

function healthPlugin() {
  const C = window.Capacitor;
  if (!C || typeof C.isNativePlatform !== "function" || !C.isNativePlatform()) return null;
  return (C.Plugins && C.Plugins.Health) || null;
}

function canSyncHealth() {
  return !window.LOG_DEMO && !!healthPlugin();
}

function readJSON(key) {
  try { return JSON.parse(localStorage.getItem(key) || "null"); } catch (_) { return null; }
}

function writeJSON(key, value) {
  try { localStorage.setItem(key, JSON.stringify(value)); } catch (_) { /* full or private mode */ }
}

function lastHealthSync() {
  const v = readJSON(HEALTH_LAST_KEY);
  return v && v.at ? v : null;
}

function backfillState() {
  return state.healthBackfill || readJSON(HEALTH_BACKFILL_KEY) || { cursor: null, done: false, values: 0 };
}

function midnightCT(key) {
  // Noon Central minus 12 hours is midnight Central (both offsets are whole hours).
  return new Date(keyToNoon(key).getTime() - 12 * 3600000);
}

function words(camel) {
  return String(camel || "other").replace(/([a-z])([A-Z])/g, "$1 $2").toLowerCase();
}

function chunk(list, size) {
  const out = [];
  for (let i = 0; i < list.length; i += size) out.push(list.slice(i, i + size));
  return out;
}

function finiteMean(list) {
  const v = list.filter((x) => x != null && Number.isFinite(x));
  return v.length ? v.reduce((a, b) => a + b, 0) / v.length : null;
}

/* Total length of a set of [start, end] intervals, overlaps counted once. */
function unionMinutes(intervals) {
  const sorted = intervals.filter(([a, b]) => b > a).sort((x, y) => x[0] - y[0]);
  let total = 0;
  let cur = null;
  for (const [a, b] of sorted) {
    if (!cur || a > cur[1]) {
      if (cur) total += cur[1] - cur[0];
      cur = [a, b];
    } else if (b > cur[1]) cur[1] = b;
  }
  if (cur) total += cur[1] - cur[0];
  return total / 60000;
}

/*
  Read the days [startKey, endKey] from Apple Health.
    opts.days         include the per-day totals for log.daily_health
    opts.weightStart  read weigh-ins and body fat from this Date (a scale may only sync weekly)
    opts.skipWeights  leave weigh-ins and body fat out
  Returns { days, weights, body, workouts, metrics, truncated, maxCount }. `truncated` means a
  type hit the read limit, so the caller should split the window.
*/
async function collectWindow(H, startKey, endKey, opts) {
  const o = opts || {};
  const start = midnightCT(startKey);
  const end = new Date(Math.min(Date.now(), midnightCT(shiftDay(endKey, 1)).getTime()));
  const range = { startDate: start.toISOString(), endDate: end.toISOString() };
  const inWindow = (key) => key >= startKey && key <= endKey;
  let truncated = false;
  let maxCount = 0;

  const agg = (dataType, aggregation) =>
    H.queryAggregated({ ...range, dataType, bucket: "day", aggregation })
      .then((r) => {
        const out = new Map();
        for (const s of r.samples || []) {
          const key = dateKeyCT(new Date(s.startDate));
          if (inWindow(key)) out.set(key, s.values || { [aggregation]: s.value });
        }
        return out;
      })
      .catch(() => new Map()); // a type you didn't allow, or nothing recorded
  const read = (dataType, from, to) =>
    H.readSamples({ dataType, startDate: (from || start).toISOString(), endDate: (to || end).toISOString(), limit: SAMPLE_LIMIT, ascending: true })
      .then((r) => {
        const list = r.samples || [];
        maxCount = Math.max(maxCount, list.length);
        if (list.length >= SAMPLE_LIMIT) truncated = true;
        return list;
      })
      .catch(() => []);
  const workoutsRead = H.queryWorkouts({ ...range, limit: 1000, ascending: true })
    .then((r) => r.workouts || [])
    .catch(() => []);

  const weightFrom = o.weightStart || start;
  // Read sleep a little past both edges so a night is never cut in half: nights that end on
  // startKey began the evening before, and a night that starts on endKey belongs to the next day.
  const sleepFrom = new Date(start.getTime() - 18 * 3600000);
  const sleepTo = new Date(Math.min(Date.now(), end.getTime() + 14 * 3600000));
  const [
    steps, distance, active, restingHr, heartRate, water, dietary,
    exercise, stand, vo2, hrv, sleep, basal, flights, cycling, glucose, bodyTemp, basalTemp, wristTemp,
    resp, spo2, bp, mindful, mood, height, weightS, bodyFatS, workoutList,
  ] = await Promise.all([
    o.days ? agg("steps", "sum") : null,
    o.days ? agg("distance", "sum") : null,
    agg("calories", "sum"),
    o.days ? agg("restingHeartRate", "average") : null,
    agg("heartRate", ["average", "min", "max"]),
    agg("dietaryWater", "sum"),
    agg("dietaryEnergyConsumed", "sum"),
    o.days ? read("exerciseTime") : [],
    o.days ? read("appleStandHour") : [],
    o.days ? read("vo2Max") : [],
    o.days ? read("heartRateVariability") : [],
    read("sleep", sleepFrom, sleepTo),
    read("basalCalories"),
    read("flightsClimbed"),
    read("distanceCycling"),
    read("bloodGlucose"),
    read("bodyTemperature"),
    read("basalBodyTemperature"),
    read("appleSleepingWristTemperature"),
    read("respiratoryRate"),
    read("oxygenSaturation"),
    read("bloodPressure"),
    read("mindfulness"),
    read("stateOfMind"),
    read("height"),
    o.skipWeights ? [] : read("weight", weightFrom),
    o.skipWeights ? [] : read("bodyFat", weightFrom),
    workoutsRead,
  ]);

  // Samples grouped by the Central-time day they started on (inside the window only).
  const byDay = (list) => {
    const groups = new Map();
    for (const s of list) {
      const key = dateKeyCT(new Date(s.startDate));
      if (!inWindow(key)) continue;
      if (!groups.has(key)) groups.set(key, []);
      groups.get(key).push(s);
    }
    return groups;
  };
  // Cumulative samples: sum per source, keep the biggest source (iPhone and Watch overlap).
  const sourceMax = (list, f) => {
    const out = new Map();
    for (const [key, items] of byDay(list)) {
      const per = new Map();
      for (const s of items) {
        const v = f ? f(s) : Number(s.value);
        if (!Number.isFinite(v)) continue;
        const src = s.sourceId || s.sourceName || "?";
        per.set(src, (per.get(src) || 0) + v);
      }
      if (per.size) out.set(key, Math.max(...per.values()));
    }
    return out;
  };
  const dailyMean = (list, f) => {
    const out = new Map();
    for (const [key, items] of byDay(list)) {
      const m = finiteMean(items.map(f || ((s) => Number(s.value))));
      if (m != null) out.set(key, m);
    }
    return out;
  };

  const metrics = new Map();
  const put = (day, metric, value, unit) => {
    if (value == null || !Number.isFinite(value)) return;
    metrics.set(`${day}|${metric}`, { day, metric, value, unit });
  };

  // ---- Sleep: group each source's segments into nights, credit a night to the day you woke up,
  // and use the source with the most sleep that night (what the Health app shows). ----
  const nights = new Map(); // day -> Map(source -> { asleep: [], inBed: [], deep, rem, core, awake })
  const bySource = new Map();
  for (const s of sleep) {
    const src = s.sourceId || s.sourceName || "?";
    if (!bySource.has(src)) bySource.set(src, []);
    bySource.get(src).push(s);
  }
  for (const [src, list] of bySource) {
    list.sort((a, b) => Date.parse(a.startDate) - Date.parse(b.startDate));
    let session = null;
    const sessions = [];
    for (const s of list) {
      const a = Date.parse(s.startDate);
      const b = Date.parse(s.endDate);
      if (!(b > a)) continue;
      if (!session || a - session.end > 2 * 3600000) {
        session = { end: b, segs: [] };
        sessions.push(session);
      }
      session.end = Math.max(session.end, b);
      session.segs.push({ a, b, state: s.sleepState || "asleep" });
    }
    for (const ses of sessions) {
      const key = dateKeyCT(new Date(ses.end));
      if (!inWindow(key)) continue;
      if (!nights.has(key)) nights.set(key, new Map());
      const n = nights.get(key).get(src) || { asleep: [], inBed: [], deep: 0, rem: 0, core: 0, awake: 0 };
      for (const g of ses.segs) {
        const min = (g.b - g.a) / 60000;
        if (g.state === "inBed") n.inBed.push([g.a, g.b]);
        else if (g.state === "awake") n.awake += min;
        else {
          n.asleep.push([g.a, g.b]);
          if (g.state === "deep") n.deep += min;
          else if (g.state === "rem") n.rem += min;
          else if (g.state === "light") n.core += min;
        }
      }
      nights.get(key).set(src, n);
    }
  }
  const sleepHours = new Map();
  for (const [key, perSource] of nights) {
    let best = null;
    let bestMin = 0;
    let inBedMin = 0;
    for (const n of perSource.values()) {
      const m = unionMinutes(n.asleep);
      if (m > bestMin) { bestMin = m; best = n; }
      inBedMin = Math.max(inBedMin, unionMinutes(n.inBed));
    }
    if (best && bestMin > 0 && bestMin <= 24 * 60) {
      sleepHours.set(key, r2(bestMin / 60));
      if (best.deep + best.rem + best.core > 0) {
        put(key, "sleep_deep_min", Math.round(best.deep), "min");
        put(key, "sleep_rem_min", Math.round(best.rem), "min");
        put(key, "sleep_core_min", Math.round(best.core), "min");
        put(key, "sleep_awake_min", Math.round(best.awake), "min");
      }
    }
    if (inBedMin > 0 && inBedMin <= 24 * 60) put(key, "sleep_in_bed_h", r2(inBedMin / 60), "h");
  }

  // ---- Per-day totals for log.daily_health ----
  const days = [];
  if (o.days) {
    const rows = new Map();
    const row = (key) => {
      if (!rows.has(key)) rows.set(key, { day: key });
      return rows.get(key);
    };
    for (const [key, v] of steps) if (v.sum != null) row(key).steps = Math.round(v.sum);
    for (const [key, v] of distance) if (v.sum != null) row(key).distance_mi = r2(v.sum * M_TO_MI);
    for (const [key, v] of active) if (v.sum != null) row(key).active_kcal = Math.round(v.sum);
    for (const [key, v] of restingHr) if (v.average != null) row(key).resting_hr = Math.round(v.average);
    for (const [key, v] of sourceMax(exercise)) row(key).exercise_min = Math.round(v);
    for (const [key, v] of sourceMax(stand)) row(key).stand_hours = Math.round(v);
    for (const [key, items] of byDay(vo2)) {
      const best = Math.max(...items.map((s) => Number(s.value)).filter(Number.isFinite));
      if (Number.isFinite(best)) row(key).vo2max = r1(best);
    }
    for (const [key, v] of dailyMean(hrv)) row(key).hrv_ms = Math.round(v);
    for (const [key, h] of sleepHours) row(key).sleep_hours = h;
    days.push(...[...rows.values()].filter((d) => Object.keys(d).length > 1).sort((a, b) => (a.day < b.day ? -1 : 1)));
  }

  // ---- Everything else, into log.health_metrics ----
  for (const [key, v] of heartRate) {
    put(key, "heart_rate_avg", v.average != null ? r1(v.average) : null, "bpm");
    put(key, "heart_rate_min", v.min != null ? Math.round(v.min) : null, "bpm");
    put(key, "heart_rate_max", v.max != null ? Math.round(v.max) : null, "bpm");
  }
  const basalByDay = sourceMax(basal);
  for (const [key, v] of basalByDay) {
    put(key, "basal_kcal", Math.round(v), "kcal");
    const a = active.get(key);
    if (a && a.sum != null) put(key, "total_kcal", Math.round(v + a.sum), "kcal");
  }
  for (const [key, v] of sourceMax(flights)) put(key, "flights", Math.round(v), "count");
  for (const [key, v] of sourceMax(cycling)) if (v > 0) put(key, "cycling_mi", r2(v * M_TO_MI), "mi");
  for (const [key, v] of water) if (v.sum != null && v.sum > 0) put(key, "water_oz", Math.round(v.sum * L_TO_FLOZ), "fl oz");
  for (const [key, v] of dietary) if (v.sum != null && v.sum > 0) put(key, "dietary_kcal", Math.round(v.sum), "kcal");
  for (const [key, items] of byDay(glucose)) {
    const vals = items.map((s) => Number(s.value)).filter(Number.isFinite);
    if (!vals.length) continue;
    put(key, "glucose_avg", Math.round(finiteMean(vals)), "mg/dL");
    put(key, "glucose_min", Math.round(Math.min(...vals)), "mg/dL");
    put(key, "glucose_max", Math.round(Math.max(...vals)), "mg/dL");
  }
  const toF = (s) => {
    const v = Number(s.value);
    return s.unit === "fahrenheit" ? v : v * 9 / 5 + 32;
  };
  for (const [key, v] of dailyMean(bodyTemp, toF)) put(key, "body_temp_f", r1(v), "°F");
  for (const [key, v] of dailyMean(basalTemp, toF)) put(key, "basal_temp_f", r1(v), "°F");
  for (const [key, v] of dailyMean(wristTemp, toF)) put(key, "wrist_temp_f", r2(v), "°F");
  for (const [key, v] of dailyMean(resp)) put(key, "respiratory_rate", r1(v), "/min");
  const pct = (s) => { const v = Number(s.value); return v <= 1 ? v * 100 : v; };
  for (const [key, items] of byDay(spo2)) {
    const vals = items.map(pct).filter(Number.isFinite);
    if (!vals.length) continue;
    put(key, "spo2_avg", r1(finiteMean(vals)), "%");
    put(key, "spo2_min", Math.round(Math.min(...vals)), "%");
  }
  for (const [key, items] of byDay(bp)) {
    const sys = finiteMean(items.map((s) => (s.systolic != null ? Number(s.systolic) : null)));
    const dia = finiteMean(items.map((s) => (s.diastolic != null ? Number(s.diastolic) : null)));
    if (sys != null) put(key, "bp_systolic", Math.round(sys), "mmHg");
    if (dia != null) put(key, "bp_diastolic", Math.round(dia), "mmHg");
  }
  for (const [key, v] of sourceMax(mindful)) if (v > 0) put(key, "mindful_min", Math.round(v), "min");
  for (const [key, v] of dailyMean(mood)) put(key, "state_of_mind", r2(v), "valence");
  for (const [key, items] of byDay(height)) {
    const last = items[items.length - 1];
    const cm = Number(last.value);
    if (Number.isFinite(cm) && cm > 0) put(key, "height_in", r1(cm / 2.54), "in");
  }

  // ---- Weigh-ins and body fat: individual readings ----
  const weights = [];
  for (const s of weightS) {
    const v = Number(s.value);
    if (!Number.isFinite(v)) continue;
    const lb = s.unit === "kilogram" || !s.unit ? v * KG_TO_LB : v;
    weights.push({ measured_at: new Date(s.startDate).toISOString(), weight_lb: r1(lb) });
  }
  const body = [];
  for (const s of bodyFatS) {
    let p = Number(s.value);
    if (!Number.isFinite(p)) continue;
    if (p <= 1) p *= 100; // HealthKit's percent unit is a fraction
    const at = new Date(s.startDate);
    body.push({ metric: "body_fat_pct", measured_at: at.toISOString(), value: r1(p) });
    const w = weights.find((x) => Math.abs(Date.parse(x.measured_at) - at.getTime()) <= 120000);
    if (w) body.push({ metric: "lean_mass_lb", measured_at: at.toISOString(), value: r1(w.weight_lb * (1 - p / 100)) });
  }

  const workouts = workoutList.map((k) => {
    const meta = k.metadata || {};
    const indoor = meta.HKIndoorWorkout != null ? String(meta.HKIndoorWorkout) === "1" || String(meta.HKIndoorWorkout) === "true" : null;
    return {
      started_at: new Date(k.startDate).toISOString(),
      ended_at: k.endDate ? new Date(k.endDate).toISOString() : null,
      activity: words(k.workoutType),
      duration_min: k.duration != null ? r1(k.duration / 60) : null,
      distance_mi: k.totalDistance != null ? r2(k.totalDistance * M_TO_MI) : null,
      active_kcal: k.totalEnergyBurned != null ? Math.round(k.totalEnergyBurned) : null,
      indoor,
    };
  });
  if (workoutList.length >= 1000) truncated = true;

  return { days, weights, body, workouts, metrics: [...metrics.values()], truncated, maxCount };
}

/* Same as collectWindow, but splits the window in half (down to one day) when a type hits the read limit. */
async function collectSafe(H, startKey, endKey, opts) {
  const data = await collectWindow(H, startKey, endKey, opts);
  const span = dayDiff(endKey, startKey) + 1;
  if (!data.truncated || span <= 1) return data;
  const olderEnd = shiftDay(startKey, Math.floor(span / 2) - 1);
  const newer = await collectSafe(H, shiftDay(olderEnd, 1), endKey, opts);
  const older = await collectSafe(H, startKey, olderEnd, opts);
  const uniq = (list, keyOf) => [...new Map(list.map((x) => [keyOf(x), x])).values()];
  return {
    days: [...older.days, ...newer.days],
    weights: uniq([...older.weights, ...newer.weights], (w) => w.measured_at),
    body: uniq([...older.body, ...newer.body], (b) => `${b.metric}|${b.measured_at}`),
    workouts: uniq([...older.workouts, ...newer.workouts], (w) => `${w.started_at}|${w.activity}`),
    metrics: [...older.metrics, ...newer.metrics],
    truncated: false,
    maxCount: Math.max(older.maxCount, newer.maxCount),
  };
}

/* Send a collected window in small requests; returns how many of each were stored. */
async function sendHealth(data) {
  const totals = { days: 0, weights: 0, body: 0, workouts: 0, metrics: 0 };
  const send = async (action, payload) => {
    const r = await writeLog(action, payload);
    for (const k of Object.keys(totals)) totals[k] += Number(r[k] || 0);
  };
  for (const part of chunk(data.days, 31)) await send("health_sync", { days: part });
  for (const part of chunk(data.weights, 150)) await send("health_sync", { weights: part });
  for (const part of chunk(data.body, 150)) await send("health_sync", { body: part });
  for (const part of chunk(data.workouts, 80)) await send("health_sync", { workouts: part });
  for (const part of chunk(data.metrics, 300)) await send("health_metrics", { metrics: part });
  return totals;
}

function addTotals(a, b) {
  const out = { ...a };
  for (const k of Object.keys(b)) out[k] = (out[k] || 0) + (b[k] || 0);
  return out;
}

async function ensureHealthAccess(H) {
  const avail = await H.isAvailable();
  if (!avail || !avail.available) throw new Error("Apple Health isn't available on this device.");
  // One sheet for every type; if this iOS version doesn't know one of them, ask for the core set.
  try {
    await H.requestAuthorization({ read: HEALTH_READ });
  } catch (_) {
    await H.requestAuthorization({ read: HEALTH_CORE });
  }
}

function healthError(err) {
  const m = (err && err.message) || "unknown error";
  if (m === "unauthorized") return "Passcode was rejected. Lock and unlock again.";
  return m.startsWith("Apple Health") ? m : `Couldn’t sync: ${m}`;
}

/* Sync the last `days` days (newest first, 10 days at a time): daily totals, every metric,
   weigh-ins and body fat from the last 60 days or more, and workouts. */
async function syncAppleHealth(opts) {
  const H = healthPlugin();
  if (!H) return { ok: false, reason: "Apple Health sync works in the Log iPhone app." };
  const o = opts || {};
  try {
    await ensureHealthAccess(H);
    const today = todayKey();
    const firstKey = shiftDay(today, -((o.days || 14) - 1));
    const weightStart = new Date(Math.min(midnightCT(firstKey).getTime(), Date.now() - 60 * 86400000));
    let totals = { days: 0, weights: 0, body: 0, workouts: 0, metrics: 0 };
    let endKey = today;
    let first = true;
    while (endKey >= firstKey) {
      const startKey = shiftDay(endKey, -9) < firstKey ? firstKey : shiftDay(endKey, -9);
      const data = await collectSafe(H, startKey, endKey, first ? { days: true, weightStart } : { days: true, skipWeights: true });
      totals = addTotals(totals, await sendHealth(data));
      first = false;
      endKey = shiftDay(startKey, -1);
    }
    const record = { at: new Date().toISOString(), ...totals };
    writeJSON(HEALTH_LAST_KEY, record);
    return { ok: true, ...record };
  } catch (err) {
    return { ok: false, reason: healthError(err) };
  }
}

function fmtMonthYear(key) {
  return FMT_MONTH_YEAR.format(keyToNoon(key));
}

function backfillText(b) {
  if (!b) return "";
  const n = `${fmtNum(b.values || 0, 0)} value${b.values === 1 ? "" : "s"}`;
  if (b.running) return b.cursor ? `Backfilling history: back to ${fmtMonthYear(b.cursor)} so far, ${n} saved.` : "Backfilling history: starting…";
  if (b.error) return `Backfill stopped${b.cursor ? ` at ${fmtMonthYear(b.cursor)}` : ""}: ${b.error.replace(/^Couldn’t sync: /, "")}. It tries again next time the app opens.`;
  if (b.done) return b.oldest ? `History backfilled: ${n} saved, going back to ${fmtMonthYear(b.oldest)}.` : "History backfilled. Apple Health had nothing older to add.";
  if (b.cursor) return `History backfilled back to ${fmtMonthYear(b.cursor)} so far. It carries on next time the app opens.`;
  return "";
}

/* Update the backfill line in place, without a redraw (so forms and scroll position stay put). */
function paintBackfill() {
  const text = backfillText(backfillState());
  for (const node of document.querySelectorAll(".backfill-status")) {
    node.textContent = text;
    node.hidden = !text;
  }
  for (const btn of document.querySelectorAll(".backfill-btn")) {
    const b = backfillState();
    btn.disabled = !!b.running;
    btn.textContent = backfillButtonLabel(b);
  }
}

function backfillButtonLabel(b) {
  if (b.running) return "Backfilling…";
  if (b.done) return "Backfill again";
  return b.cursor ? "Continue backfill" : "Backfill history";
}

/*
  Walk back through history, newest first, starting from yesterday. Windows start at 10 days and
  grow to 60 while there's little data, shrinking again if a type hits the read limit. The cursor
  is saved after every window, and it stops at 2015 or after a year with nothing in it.
*/
async function backfillHealth(opts) {
  const H = healthPlugin();
  if (!H) return null;
  const o = opts || {};
  let b = backfillState();
  if (b.running) return b;
  if (o.restart) b = { cursor: null, oldest: null, done: false, values: 0 };
  else if (b.done) return b;
  b = { ...b, running: true, error: null };
  state.healthBackfill = b;
  paintBackfill();
  let windows = 0;
  try {
    await ensureHealthAccess(H);
    let size = b.size || 10;
    let empty = b.empty || 0;
    let endKey = b.cursor ? shiftDay(b.cursor, -1) : shiftDay(todayKey(), -1);
    while (endKey >= BACKFILL_FLOOR && empty < 365) {
      const startKey = shiftDay(endKey, -(size - 1)) < BACKFILL_FLOOR ? BACKFILL_FLOOR : shiftDay(endKey, -(size - 1));
      const data = await collectSafe(H, startKey, endKey, { days: false });
      const got = await sendHealth(data);
      const found = data.metrics.length + data.weights.length + data.body.length + data.workouts.length;
      empty = found ? 0 : empty + dayDiff(endKey, startKey) + 1;
      const keys = [
        ...data.metrics.map((m) => m.day),
        ...data.weights.map((x) => dateKeyCT(new Date(x.measured_at))),
        ...data.body.map((x) => dateKeyCT(new Date(x.measured_at))),
        ...data.workouts.map((x) => dateKeyCT(new Date(x.started_at))),
      ].sort();
      const oldest = keys.length && (!b.oldest || keys[0] < b.oldest) ? keys[0] : b.oldest || null;
      size = data.maxCount < SAMPLE_LIMIT / 4 ? Math.min(size * 2, 60) : Math.max(5, Math.floor(size / 2));
      b = { ...b, cursor: startKey, oldest, size, empty, values: (b.values || 0) + got.metrics + got.weights + got.body + got.workouts };
      state.healthBackfill = b;
      writeJSON(HEALTH_BACKFILL_KEY, { ...b, running: false });
      paintBackfill();
      endKey = shiftDay(startKey, -1);
      windows += 1;
      if (o.maxWindows && windows >= o.maxWindows) break;
    }
    b = { ...b, running: false, done: endKey < BACKFILL_FLOOR || empty >= 365 };
  } catch (err) {
    b = { ...b, running: false, error: healthError(err) };
  }
  state.healthBackfill = b;
  writeJSON(HEALTH_BACKFILL_KEY, b);
  paintBackfill();
  return b;
}

/* When the app opens: catch up on recent days (at most every 30 minutes), then keep backfilling. */
async function autoSyncHealth() {
  if (!canSyncHealth() || state.healthBusy) return;
  const last = lastHealthSync();
  if (!last || Date.now() - Date.parse(last.at) >= 30 * 60000) {
    state.healthBusy = true;
    const r = await syncAppleHealth({ days: last ? 3 : 30 });
    state.healthBusy = false;
    state.healthMsg = r.ok ? null : { ok: false, text: r.reason };
    if (r.ok && (r.days || r.weights || r.body || r.workouts || r.metrics)) await load(true, true);
  }
  const b = backfillState();
  if (!b.done && !b.running) {
    const res = await backfillHealth();
    if (res && res.values) await load(true, true);
  }
}
