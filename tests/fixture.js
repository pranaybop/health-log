/*
  Made-up dashboard payload for the tests. Same shape as log-dashboard returns, none of it real:
  a different start weight, height, meals, workouts and health numbers. Deterministic (seeded),
  so the checks can assert exact values. The calendar matches the app's fixed dates (first
  tirzepatide dose Nov 2, retatrutide planned Dec 6) and the tests' clock, Nov 24 2026, 11:20 PM CT.
*/

const TODAY = "2026-11-24";
const AS_OF = "2026-11-24T23:20:00-06:00";

function rng(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
const rand = rng(20261124);
const jitter = (amp) => (rand() * 2 - 1) * amp;
const r1 = (v) => Math.round(v * 10) / 10;
const r2 = (v) => Math.round(v * 100) / 100;

function shift(key, n) {
  const d = new Date(`${key}T12:00:00Z`);
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
}
function daysBetween(a, b) {
  return Math.round((Date.parse(`${b}T12:00:00Z`) - Date.parse(`${a}T12:00:00Z`)) / 86400000);
}
function range(from, to) {
  const out = [];
  for (let k = from; k <= to; k = shift(k, 1)) out.push(k);
  return out;
}
// US Central: daylight time from the second Sunday of March to the first Sunday of November.
function offsetHours(key) {
  const y = Number(key.slice(0, 4));
  const nthSunday = (month, n) => {
    const d = new Date(Date.UTC(y, month, 1));
    const first = (7 - d.getUTCDay()) % 7;
    return new Date(Date.UTC(y, month, 1 + first + 7 * (n - 1))).toISOString().slice(0, 10);
  };
  return key >= nthSunday(2, 2) && key < nthSunday(10, 1) ? 5 : 6;
}
// An instant at `hour` (Central, may be fractional or past 24) on `key`, as ISO UTC.
function at(key, hour) {
  const ms = Date.parse(`${key}T00:00:00Z`) + (hour + offsetHours(key)) * 3600000;
  return new Date(ms).toISOString().replace(".000Z", "+00:00");
}
function localIso(key, hour) {
  const h = Math.floor(hour);
  const m = Math.round((hour - h) * 60);
  const pad = (n) => String(n).padStart(2, "0");
  return `${key}T${pad(h)}:${pad(m)}:00-0${offsetHours(key)}:00`;
}
const dow = (key) => new Date(`${key}T12:00:00Z`).getUTCDay(); // 0 Sunday
const monday = (key) => shift(key, -((dow(key) + 6) % 7));

/* ---------- medication ---------- */
const DOSES = [
  { key: "2026-11-02", mg: 2, site: "Abd LR" },
  { key: "2026-11-08", mg: 2, site: "Abd LL" },
  { key: "2026-11-15", mg: 2, site: "Abd UR" },
  { key: "2026-11-22", mg: 3, site: "Love L" },
];
// Same model as analytics.js: instant dose, 5-day half-life, as a share of the weekly peak.
function levelShare(ms) {
  let level = 0;
  let last = null;
  for (const d of DOSES) {
    const t = Date.parse(at(d.key, 10));
    if (t > ms) continue;
    level += d.mg * Math.pow(0.5, (ms - t) / 86400000 / 5);
    last = d;
  }
  return last ? level / (last.mg / (1 - Math.pow(0.5, 7 / 5))) : null;
}

function makeFixture() {
  /* ---------- weights: weekly for two years, then most days since the first dose ---------- */
  const weights = [];
  let i = 0;
  for (let k = "2024-11-04"; k < "2026-10-26"; k = shift(k, 7), i++) {
    weights.push({ id: `w${i}`, measured_at: at(k, 7.5), weight_lb: r1(246 + 2 * Math.sin(i / 9) + jitter(0.8)), notes: "Test scale" });
  }
  for (const k of range("2026-10-26", "2026-10-31")) {
    if (k === "2026-10-28") continue;
    weights.push({ id: `w${i++}`, measured_at: at(k, 7.5), weight_lb: r1(248.3 + jitter(0.4)), notes: "Test scale" });
  }
  for (const k of range("2026-11-01", "2026-11-23")) {
    if (["2026-11-04", "2026-11-11", "2026-11-18", "2026-11-21"].includes(k)) continue;
    const d = daysBetween("2026-11-01", k);
    weights.push({ id: `w${i++}`, measured_at: at(k, 7.5), weight_lb: r1(248 - d * 0.4 + jitter(0.5)), notes: "Test scale" });
  }
  weights[weights.length - 1 - 0].notes = "Test scale";
  weights.push({ id: `w${i++}`, measured_at: at(TODAY, 11.5), weight_lb: 238.6, notes: "Test scale" });

  /* ---------- food ---------- */
  const meals = [
    { id: "m1", eaten_at: at(TODAY, 8), meal_type: "breakfast", item: "Oatmeal with berries", quantity: "1 bowl", calories: 420, protein_g: 12, carbs_g: 70, fat_g: 8, fiber_g: 4, source: "test", notes: null },
    { id: "m2", eaten_at: at(TODAY, 12.5), meal_type: "lunch", item: "Chicken burrito bowl", quantity: "1", calories: 780, protein_g: 38, carbs_g: 95, fat_g: 28, fiber_g: 3, source: "test", notes: null },
    { id: "m3", eaten_at: at(TODAY, 15), meal_type: "snack", item: "Iced latte", quantity: "16 oz", calories: 190, protein_g: 9, carbs_g: 20, fat_g: 7, fiber_g: 0, source: "test", notes: null },
    { id: "m4", eaten_at: at(TODAY, 20), meal_type: "snack", item: "Granola bar", quantity: "1", calories: 225, protein_g: 3, carbs_g: 33, fat_g: 4, fiber_g: 1, source: "test", notes: null },
  ];
  const skipFood = ["2026-10-29", "2026-11-01", "2026-11-05", "2026-11-12", "2026-11-19", "2026-11-20", "2026-11-23"];
  const daily_totals = [];
  for (const k of range("2026-10-27", "2026-11-22")) {
    if (skipFood.includes(k)) continue;
    const calories = Math.round(2080 + jitter(220));
    daily_totals.push({ date: k, calories, protein_g: Math.round(130 + jitter(22)), carbs_g: Math.round(calories * 0.11), fat_g: Math.round(calories * 0.035), fiber_g: Math.round(18 + jitter(6)), meal_count: 3 + Math.round(rand()) });
  }
  daily_totals.push({ date: TODAY, calories: 1615, protein_g: 62, carbs_g: 218, fat_g: 47, fiber_g: 8, meal_count: 4 });

  /* ---------- Apple Health daily totals, one year ---------- */
  const runDays = new Set();
  const daily_health = [];
  for (const k of range(shift(TODAY, -365), TODAY)) {
    const onDrug = k >= "2026-11-02";
    const run = k >= "2026-09-15" && [2, 4, 6].includes(dow(k));
    if (run) runDays.add(k);
    const active = Math.round((run ? 980 : 560) + jitter(140));
    const row = {
      day: k,
      source: "test",
      steps: Math.round((run ? 12500 : 7800) + jitter(1500)),
      distance_mi: r2((run ? 6.1 : 3.4) + jitter(0.6)),
      active_kcal: active,
      exercise_min: Math.round((run ? 55 : 22) + jitter(8)),
      stand_hours: Math.round(11 + jitter(2)),
      resting_hr: Math.round((onDrug ? 64 : 61) + jitter(1.6)),
      hrv_ms: Math.round(52 + jitter(6)),
      vo2max: daysBetween(k, TODAY) % 9 === 0 ? r1(38.2 + jitter(0.5)) : null,
      sleep_hours: rand() < 0.06 ? null : r2(7.1 + jitter(0.8)),
    };
    daily_health.push(row);
  }
  const dh = (k) => daily_health.find((r) => r.day === k);
  // A rough day earlier this month, and tonight: heart rate up, HRV down (plus breathing below).
  Object.assign(dh("2026-11-10"), { resting_hr: 71, hrv_ms: 33 });
  Object.assign(dh(TODAY), { resting_hr: 72, hrv_ms: 31, sleep_hours: 6.2 });
  // A day the watch was mostly on the charger.
  Object.assign(dh("2026-11-06"), { steps: 1900, active_kcal: 140, exercise_min: 0, stand_hours: 3 });

  /* ---------- more Apple Health metrics, last 120 days ---------- */
  const hm = {};
  const put = (metric, key, value) => { (hm[metric] = hm[metric] || []).push([key, value]); };
  for (const k of range(shift(TODAY, -119), TODAY)) {
    const row = dh(k);
    const basal = k === "2026-11-06" ? 1350 : Math.round(2150 + jitter(40));
    put("heart_rate_avg", k, r1(76 + jitter(4)));
    put("heart_rate_min", k, Math.round(52 + jitter(3)));
    put("respiratory_rate", k, r1(k === TODAY ? 17.6 : k === "2026-11-10" ? 15.2 : 14.2 + jitter(0.4)));
    put("spo2_avg", k, r1(96.4 + jitter(0.8)));
    put("sleep_deep_min", k, Math.round(55 + jitter(15)));
    put("sleep_rem_min", k, Math.round(88 + jitter(20)));
    put("basal_kcal", k, basal);
    put("total_kcal", k, basal + row.active_kcal);
    if (dow(k) !== 0 && rand() < 0.8) put("flights", k, Math.round(8 + jitter(5)));
    if (k >= shift(TODAY, -39)) put("wrist_temp_f", k, r2(95.6 + jitter(0.25)));
  }

  /* ---------- workouts and running weeks ---------- */
  const workouts = [];
  for (const k of [...runDays].filter((d) => d >= "2026-09-15")) {
    const long = dow(k) === 6;
    const miles = r2(long ? 5.5 + jitter(0.8) : 3.2 + jitter(0.5));
    const minutes = r1(miles * (10.6 + jitter(0.4)));
    workouts.push({ id: `run-${k}`, started_at: localIso(k, 6.5), ended_at: localIso(k, 6.5 + minutes / 60), activity: "running", duration_min: minutes, distance_mi: miles, active_kcal: Math.round(miles * 118), avg_hr: Math.round(148 + jitter(5)), max_hr: Math.round(168 + jitter(5)), indoor: false, source: "Apple Watch" });
  }
  for (const k of range("2026-10-01", TODAY).filter((d) => dow(d) === 1)) {
    workouts.push({ id: `lift-${k}`, started_at: localIso(k, 18), ended_at: localIso(k, 18.75), activity: "traditional strength training", duration_min: 45, distance_mi: null, active_kcal: 210, avg_hr: 118, max_hr: 141, indoor: true, source: "Apple Watch" });
  }
  workouts.sort((a, b) => (a.started_at < b.started_at ? 1 : -1));
  const run_weeks = [];
  const weeks = new Map();
  for (const w of workouts.filter((x) => x.activity === "running")) {
    const wk = monday(w.started_at.slice(0, 10));
    const s = weeks.get(wk) || { week: wk, runs: 0, miles: 0, longest_mi: 0, minutes: 0 };
    s.runs += 1; s.miles += w.distance_mi; s.longest_mi = Math.max(s.longest_mi, w.distance_mi); s.minutes += w.duration_min;
    weeks.set(wk, s);
  }
  for (const s of [...weeks.values()].sort((a, b) => (a.week < b.week ? -1 : 1)).slice(-8)) {
    run_weeks.push({ week: s.week, runs: s.runs, miles: r1(s.miles), longest_mi: r1(s.longest_mi), minutes: Math.round(s.minutes) });
  }

  /* ---------- check-ins: food noise tracks the drug level ---------- */
  const checkins = [];
  for (const k of range("2026-11-02", TODAY)) {
    if (k === "2026-11-23") continue; // yesterday stays empty for the check-in tests
    const share = levelShare(Date.parse(at(k, 20)));
    const noise = Math.max(1, Math.min(10, Math.round(8.6 - 7 * share + jitter(0.6))));
    checkins.push({
      day: k, source: "log-app",
      ate_vs_usual: noise >= 6 ? "more" : noise <= 3 ? "less" : "usual",
      moved_vs_usual: runDays.has(k) ? "more" : "usual",
      dose_feel: share >= 0.6 ? "strong" : share >= 0.4 ? "fading" : "not_feeling_it",
      mood: Math.round(7 + jitter(1.4)), food_noise: noise, energy: Math.round(7 + jitter(1.4)), sleep_quality: Math.round(6 + jitter(1.6)),
      sleep_hours: null, exercise_minutes: null, steps: null, resting_hr: null, active_calories: null, earned: null, notes: null,
    });
  }
  Object.assign(checkins.find((c) => c.day === TODAY), { mood: 9, energy: 8, food_noise: 3, sleep_quality: 4, ate_vs_usual: "more", moved_vs_usual: "usual", dose_feel: "strong" });

  /* ---------- food thoughts since Nov 14, more of them as the level drops ---------- */
  const food_thoughts = [];
  let n = 0;
  for (const k of range("2026-11-14", TODAY)) {
    for (const h of [10.5, 15, 21]) {
      const share = levelShare(Date.parse(at(k, h)));
      if (rand() < 1.1 - share) food_thoughts.push({ id: `ft${n++}`, thought_at: at(k, h + jitter(0.5)), strength: share < 0.45 ? 3 : share < 0.65 ? 2 : 1, note: null });
    }
  }

  /* ---------- body composition, side effects, vials ---------- */
  const lb = (k) => {
    const list = weights.filter((w) => w.measured_at.slice(0, 10) <= k);
    return list[list.length - 1].weight_lb;
  };
  const measurements = [];
  [["2026-11-05", 36.4], ["2026-11-12", 36.0], ["2026-11-19", 35.6], [TODAY, 35.2]].forEach(([k, bf], j) => {
    const when = k === TODAY ? at(TODAY, 11.5) : at(k, 7.5);
    measurements.push({ id: `bf${j}`, measured_at: when, metric: "body_fat_pct", value: bf, unit: "%", notes: "Test scale" });
    measurements.push({ id: `lm${j}`, measured_at: when, metric: "lean_mass_lb", value: r1(lb(k) * (1 - bf / 100)), unit: "lb", notes: "Test scale" });
  });
  measurements.push({ id: "waist0", measured_at: at("2026-11-10", 8), metric: "waist", value: 43.5, unit: "in", notes: null });

  const side_effects = [
    { id: "se1", recorded_on: "2026-11-03", recorded_at: at("2026-11-03", 12), effect: "Nausea", severity: 3, notes: null },
    { id: "se2", recorded_on: "2026-11-09", recorded_at: at("2026-11-09", 12), effect: "Low appetite", severity: 3, notes: null },
    { id: "se3", recorded_on: "2026-11-16", recorded_at: at("2026-11-16", 12), effect: "Fatigue", severity: 2, notes: null },
    { id: "se4", recorded_on: "2026-11-17", recorded_at: at("2026-11-17", 12), effect: "Headache", severity: 2, notes: null },
  ];

  const vial = (id, compound, label, total, remaining, opened) => ({ id, compound, label, started_on: null, opened_at: opened, total_mg: total, remaining_mg: remaining, total_units: null, remaining_units: null, concentration_mg_per_ml: null, expired_on: null, notes: null });
  const vials = [
    vial("v1", "tirzepatide", "Test vial A", 10, 3, at("2026-11-02", 9)),
    vial("v2", "retatrutide", "Test vial B", 10, 10, null),
    vial("v3", "retatrutide", "Test vial C", 12, 12, null),
    vial("v4", "retatrutide", "Test vial D", 12, 12, null),
  ];

  const doses = DOSES.map((d, j) => ({ id: `d${j}`, taken_at: at(d.key, 10), compound: "tirzepatide", dose_mg: d.mg, units: null, site: d.site, skipped: false, notes: null }));
  const protocol = [
    { id: "p1", compound: "tirzepatide", display_name: "Tirzepatide", typical_dose_mg: 3, units: null, frequency: "weekly", status: "active", half_life_hours: 120, started_on: "2026-11-02", next_site: "Love R", notes: "Test protocol." },
    { id: "p2", compound: "retatrutide", display_name: "Retatrutide", typical_dose_mg: null, units: 20, frequency: "weekly", status: "paused", half_life_hours: 144, started_on: "2026-12-06", next_site: null, notes: "Test protocol." },
  ];

  /* ---------- a made-up dose plan: last tirzepatide week, then 12 retatrutide weeks ---------- */
  const dose_plan = [{ planned_on: "2026-11-29", week: null, compound: "tirzepatide", dose_mg: 3, units: null, vial_draw: "Test vial A", notes: null }];
  [2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4].forEach((mg, j) => dose_plan.push({
    planned_on: shift("2026-12-06", 7 * j), week: j + 1, compound: "retatrutide", dose_mg: mg, units: mg * 10,
    vial_draw: `Test vial ${j < 4 ? "B" : "C"} ${mg} mg (${mg * 10} u)`, notes: j === 0 ? "Test note: mix with 1 mL" : null,
  }));

  /* ---------- weekly summary ---------- */
  const weekly = new Map();
  for (const w of weights) {
    const wk = monday(w.measured_at.slice(0, 10));
    const s = weekly.get(wk) || { week: wk, ws: [], cals: [], pros: [] };
    s.ws.push(w.weight_lb);
    weekly.set(wk, s);
  }
  for (const t of daily_totals) {
    const wk = monday(t.date);
    const s = weekly.get(wk) || { week: wk, ws: [], cals: [], pros: [] };
    s.cals.push(t.calories); s.pros.push(t.protein_g);
    weekly.set(wk, s);
  }
  const avg = (v) => (v.length ? v.reduce((a, b) => a + b, 0) / v.length : null);
  const weekly_summary = [...weekly.values()].sort((a, b) => (a.week < b.week ? -1 : 1)).map((s) => ({
    week: s.week,
    avg_daily_calories: s.cals.length ? r1(avg(s.cals)) : null,
    avg_protein_g: s.pros.length ? r1(avg(s.pros)) : null,
    calories: s.cals.length ? s.cals.reduce((a, b) => a + b, 0) : null,
    days_logged: s.cals.length || null,
    min_weight_lb: s.ws.length ? Math.min(...s.ws) : null,
    max_weight_lb: s.ws.length ? Math.max(...s.ws) : null,
    avg_weight_lb: s.ws.length ? r1(avg(s.ws)) : null,
  }));

  return {
    as_of: AS_OF,
    meals,
    weights,
    doses,
    daily_totals,
    weekly_summary,
    daily_health,
    workouts,
    workout_count: workouts.length,
    health_span: { first_day: daily_health[0].day, last_day: TODAY, days: daily_health.length },
    checkins,
    side_effects,
    protocol,
    dose_plan,
    vials,
    measurements,
    profile: { start_weight_lb: 248, goal_weight_lb: 215, height_in: 70, notes: null },
    goals: [{ id: "g1", kind: "weight", target: 215, unit: "lb", due_on: "2027-03-01", notes: null, status: "active" }],
    food_thoughts,
    run_weeks,
    health_metrics: hm,
  };
}

module.exports = { makeFixture, TODAY, AS_OF };

if (require.main === module) process.stdout.write(JSON.stringify(makeFixture(), null, 1));
