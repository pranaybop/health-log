/*
  Apple Health sync. Only does anything inside the Log iPhone app, where Capacitor
  injects the native bridge and the @capgo/capacitor-health plugin ("Health").
  In Safari or any browser, canSyncHealth() is false and nothing here runs.

  What it sends (log-write action health_sync; inserts skip anything already logged):
    days      per-day totals: steps, distance, active calories, exercise minutes,
              stand hours, resting heart rate, HRV, VO2 max, sleep
    weights   weigh-ins
    body      body fat % and lean mass (lean mass = weigh-in at the same time × (1 − body fat))
    workouts  workouts, named like the existing ones ("running", "stair climbing")
*/

const HEALTH_LAST_KEY = "log.healthSync";
const HEALTH_READ = [
  "steps", "distance", "calories", "exerciseTime", "appleStandHour",
  "restingHeartRate", "heartRateVariability", "vo2Max", "sleep",
  "weight", "bodyFat", "workouts",
];
const KG_TO_LB = 2.2046226218;
const M_TO_MI = 1 / 1609.344;

function healthPlugin() {
  const C = window.Capacitor;
  if (!C || typeof C.isNativePlatform !== "function" || !C.isNativePlatform()) return null;
  return (C.Plugins && C.Plugins.Health) || null;
}

function canSyncHealth() {
  return !!healthPlugin();
}

function lastHealthSync() {
  try {
    const v = JSON.parse(localStorage.getItem(HEALTH_LAST_KEY) || "null");
    return v && v.at ? v : null;
  } catch (_) {
    return null;
  }
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

/* Gather what Apple Health has for the last `days` days, shaped for health_sync. */
async function collectHealth(H, days) {
  const today = todayKey();
  const startKey = shiftDay(today, -(days - 1));
  const start = midnightCT(startKey);
  const end = new Date();
  const range = { startDate: start.toISOString(), endDate: end.toISOString() };

  const byDay = new Map();
  const dayRow = (key) => {
    if (!byDay.has(key)) byDay.set(key, { day: key });
    return byDay.get(key);
  };
  const agg = async (dataType, aggregation, field, convert) => {
    try {
      const r = await H.queryAggregated({ ...range, dataType, bucket: "day", aggregation });
      for (const s of r.samples || []) {
        const v = s.values && s.values[aggregation] != null ? s.values[aggregation] : s.value;
        if (v == null || !Number.isFinite(Number(v))) continue;
        const key = dateKeyCT(new Date(s.startDate));
        if (key < startKey || key > today) continue;
        dayRow(key)[field] = convert ? convert(Number(v)) : Number(v);
      }
    } catch (_) { /* a type the user didn't allow just stays empty */ }
  };
  await agg("steps", "sum", "steps", Math.round);
  await agg("distance", "sum", "distance_mi", (m) => Math.round(m * M_TO_MI * 100) / 100);
  await agg("calories", "sum", "active_kcal", Math.round);
  await agg("exerciseTime", "sum", "exercise_min", Math.round);
  await agg("appleStandHour", "sum", "stand_hours", Math.round);
  await agg("restingHeartRate", "average", "resting_hr", Math.round);
  await agg("heartRateVariability", "average", "hrv_ms", Math.round);
  await agg("vo2Max", "max", "vo2max", (v) => Math.round(v * 10) / 10);

  // Sleep: add up asleep segments and credit them to the morning you woke up.
  try {
    const r = await H.readSamples({ dataType: "sleep", startDate: new Date(start.getTime() - 86400000).toISOString(), endDate: end.toISOString(), limit: 5000, ascending: true });
    const asleep = new Set(["asleep", "rem", "deep", "light"]);
    const hours = new Map();
    for (const s of r.samples || []) {
      if (s.sleepState && !asleep.has(s.sleepState)) continue;
      const a = Date.parse(s.startDate);
      const b = Date.parse(s.endDate);
      if (!(b > a)) continue;
      const key = dateKeyCT(new Date(b));
      if (key < startKey || key > today) continue;
      hours.set(key, (hours.get(key) || 0) + (b - a) / 3600000);
    }
    for (const [key, h] of hours) if (h > 0 && h <= 24) dayRow(key).sleep_hours = Math.round(h * 100) / 100;
  } catch (_) { /* no sleep access */ }

  // Weigh-ins and body fat: individual samples, a longer window so a weekly scale still lands.
  const sampleStart = new Date(Math.min(start.getTime(), Date.now() - 60 * 86400000)).toISOString();
  const weights = [];
  try {
    const r = await H.readSamples({ dataType: "weight", startDate: sampleStart, endDate: range.endDate, limit: 500, ascending: true });
    for (const s of r.samples || []) {
      const kg = Number(s.value);
      if (!Number.isFinite(kg)) continue;
      const lb = s.unit === "kilogram" || !s.unit ? kg * KG_TO_LB : kg;
      weights.push({ measured_at: new Date(s.startDate).toISOString(), weight_lb: Math.round(lb * 10) / 10 });
    }
  } catch (_) { /* no weight access */ }
  const body = [];
  try {
    const r = await H.readSamples({ dataType: "bodyFat", startDate: sampleStart, endDate: range.endDate, limit: 500, ascending: true });
    for (const s of r.samples || []) {
      let pct = Number(s.value);
      if (!Number.isFinite(pct)) continue;
      if (pct <= 1) pct *= 100; // HealthKit's percent unit is a fraction
      const at = new Date(s.startDate);
      body.push({ metric: "body_fat_pct", measured_at: at.toISOString(), value: Math.round(pct * 10) / 10 });
      const w = weights.find((x) => Math.abs(Date.parse(x.measured_at) - at.getTime()) <= 120000);
      if (w) body.push({ metric: "lean_mass_lb", measured_at: at.toISOString(), value: Math.round(w.weight_lb * (1 - pct / 100) * 10) / 10 });
    }
  } catch (_) { /* no body fat access */ }

  const workouts = [];
  try {
    const r = await H.queryWorkouts({ ...range, limit: 100, ascending: true });
    for (const k of r.workouts || []) {
      const meta = k.metadata || {};
      const indoor = meta.HKIndoorWorkout != null ? String(meta.HKIndoorWorkout) === "1" || String(meta.HKIndoorWorkout) === "true" : null;
      workouts.push({
        started_at: new Date(k.startDate).toISOString(),
        ended_at: k.endDate ? new Date(k.endDate).toISOString() : null,
        activity: words(k.workoutType),
        duration_min: k.duration != null ? Math.round((k.duration / 60) * 10) / 10 : null,
        distance_mi: k.totalDistance != null ? Math.round(k.totalDistance * M_TO_MI * 100) / 100 : null,
        active_kcal: k.totalEnergyBurned != null ? Math.round(k.totalEnergyBurned) : null,
        indoor,
      });
    }
  } catch (_) { /* no workout access */ }

  const daysOut = [...byDay.values()].filter((d) => Object.keys(d).length > 1).sort((a, b) => (a.day < b.day ? -1 : 1));
  return { days: daysOut, weights, body, workouts };
}

/* Ask for access (first time only, iOS remembers), read, and send in small batches. */
async function syncAppleHealth(opts) {
  const H = healthPlugin();
  if (!H) return { ok: false, reason: "Apple Health sync works in the Log iPhone app." };
  const o = opts || {};
  try {
    const avail = await H.isAvailable();
    if (!avail || !avail.available) return { ok: false, reason: "Apple Health isn't available on this device." };
    await H.requestAuthorization({ read: HEALTH_READ });
    const data = await collectHealth(H, o.days || 14);
    const totals = { days: 0, weights: 0, body: 0, workouts: 0 };
    const send = async (payload) => {
      const r = await writeLog("health_sync", payload);
      for (const k of Object.keys(totals)) totals[k] += Number(r[k] || 0);
    };
    for (const part of chunk(data.days, 31)) await send({ days: part });
    for (const part of chunk(data.weights, 150)) await send({ weights: part });
    for (const part of chunk(data.body, 150)) await send({ body: part });
    for (const part of chunk(data.workouts, 80)) await send({ workouts: part });
    const record = { at: new Date().toISOString(), ...totals };
    try { localStorage.setItem(HEALTH_LAST_KEY, JSON.stringify(record)); } catch (_) { /* ignore */ }
    return { ok: true, ...record };
  } catch (err) {
    return { ok: false, reason: err && err.message === "unauthorized" ? "Passcode was rejected. Lock and unlock again." : `Couldn’t sync: ${(err && err.message) || "unknown error"}` };
  }
}

/* Quiet catch-up when the app opens: the last 3 days, at most every 30 minutes. */
async function autoSyncHealth() {
  if (!canSyncHealth() || state.healthBusy) return;
  const last = lastHealthSync();
  if (last && Date.now() - Date.parse(last.at) < 30 * 60000) return;
  state.healthBusy = true;
  const r = await syncAppleHealth({ days: 3 });
  state.healthBusy = false;
  state.healthMsg = r.ok ? null : { ok: false, text: r.reason };
  if (r.ok && (r.days || r.weights || r.body || r.workouts)) await load(true, true);
}
