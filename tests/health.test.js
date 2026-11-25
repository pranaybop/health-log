// Apple Health sync inside the iPhone app, with a stand-in for the native Health plugin that
// behaves like @capgo/capacitor-health 8.13: only a few types aggregate, everything else is
// read as samples (with a source), reads honor the date range and the limit. Also pull to refresh.
const { chromium } = require("playwright");
const { serve, checker, makeFixture, BASE, SHOTS, API, CLOCK, CORS: cors } = require("./lib");
const fixture = makeFixture();
const check = checker();
const theme = process.argv[2] === "dark" ? "dark" : "light";

(async () => {
  const server = await serve();
  const browser = await chromium.launch();
  const ctx = await browser.newContext({ viewport: { width: 430, height: 932 }, isMobile: true, hasTouch: true, serviceWorkers: "block", colorScheme: theme });
  const page = await ctx.newPage();
  await page.clock.setFixedTime(CLOCK);
  const errors = [];
  page.on("pageerror", (e) => errors.push(e.message));
  await page.addInitScript(() => {
    localStorage.setItem("log.passcode", "2468");
    const TODAY = "2026-11-24";
    const HIST = "2026-09-01";
    const calls = [];
    window.__healthCalls = calls;
    // Runs after app.js has loaded, so the app's own Central-time helpers are there.
    const at = (k, h) => new Date(keyToNoon(k).getTime() + (h - 12) * 3600000).toISOString();
    const s = (k, h0, h1, value, src, extra) => ({ startDate: at(k, h0), endDate: at(k, h1), value, unit: "count", sourceId: src, sourceName: src, ...(extra || {}) });
    const hours = (a, b) => Array.from({ length: b - a }, (_, i) => a + i);
    const gen = {
      exerciseTime: (k) => (k >= "2026-11-23" ? [...[9, 12, 18].map((h) => s(k, h, h + 1 / 6, 10, "watch")), s(k, 7, 7.2, 12, "phone")] : []),
      appleStandHour: (k) => (k >= "2026-11-23" ? hours(8, 21).map((h) => s(k, h, h + 1, h < 19 ? 1 : 0, "watch")) : []),
      vo2Max: (k) => (k === TODAY ? [s(k, 15, 15, 38.44, "watch")] : []),
      heartRateVariability: (k) => (k === TODAY ? [s(k, 3, 3, 60, "watch"), s(k, 9, 9, 82, "watch")] : []),
      sleep: (k) => (k === TODAY ? [
        s(k, -1 - 1 / 3, -1, 20, "watch", { sleepState: "light" }), // 10:40–11 pm, ends before midnight
        s(k, -1, 3, 240, "watch", { sleepState: "light" }),
        s(k, 3, 4, 60, "watch", { sleepState: "awake" }),
        s(k, 4, 7, 180, "watch", { sleepState: "deep" }),
        s(k, 0, 6, 360, "autosleep", { sleepState: "asleep" }),
        s(k, -1.5, 7.25, 525, "phone", { sleepState: "inBed" }),
      ] : []),
      basalCalories: (k) => (k >= HIST ? [...hours(0, 24).map((h) => s(k, h, h + 1, 80, "watch")), s(k, 12, 13, 1500, "phone")] : []),
      flightsClimbed: (k) => (k >= HIST ? [s(k, 10, 10.1, 6, "watch"), s(k, 10, 10.1, 8, "phone")] : []),
      respiratoryRate: (k) => (k === TODAY ? [s(k, 2, 2, 14, "watch"), s(k, 4, 4, 16, "watch")] : []),
      oxygenSaturation: (k) => (k === TODAY ? [s(k, 2, 2, 0.97, "watch"), s(k, 4, 4, 0.94, "watch")] : []),
      bloodPressure: (k) => (k === TODAY ? [s(k, 8, 8, 118, "cuff", { systolic: 118, diastolic: 76 })] : []),
      appleSleepingWristTemperature: (k) => (k === TODAY ? [s(k, 3, 3, 35.1, "watch", { unit: "celsius" })] : []),
      stateOfMind: (k) => (k === TODAY ? [s(k, 9, 9, 0.4, "phone"), s(k, 20, 20, -0.2, "phone")] : []),
      mindfulness: (k) => (k === TODAY ? [s(k, 8, 8 + 1 / 6, 10, "watch")] : []),
      height: (k) => (k === TODAY ? [s(k, 8, 8, 185.42, "phone", { unit: "centimeter" })] : []),
      bloodGlucose: (k) => (k === TODAY ? [s(k, 7, 7, 92, "meter"), s(k, 13, 13, 110, "meter")] : []),
      weight: (k) => (k === TODAY ? [s(k, 8, 8, 116.665, "scale", { unit: "kilogram" })] : []),
      bodyFat: (k) => (k === TODAY ? [s(k, 8, 8, 0.368, "scale", { unit: "percent" })] : []),
    };
    const keysIn = (a, b) => {
      const out = [];
      for (let k = dateKeyCT(new Date(a)); k <= dateKeyCT(new Date(b)); k = shiftDay(k, 1)) out.push(k);
      return out;
    };
    const AGG = { steps: ["sum"], distance: ["sum"], calories: ["sum"], dietaryWater: ["sum"], dietaryEnergyConsumed: ["sum"], heartRate: ["average", "min", "max"], weight: ["average", "min", "max"], restingHeartRate: ["average", "min", "max"] };
    const aggVals = { steps: { sum: 9123 }, distance: { sum: 6437.4 }, calories: { sum: 812.4 }, restingHeartRate: { average: 57.6 }, heartRate: { average: 72.44, min: 48, max: 151 }, dietaryWater: { sum: 1.5 } };
    window.Capacitor = {
      isNativePlatform: () => true,
      Plugins: {
        Health: {
          isAvailable: async () => ({ available: true, platform: "ios" }),
          requestAuthorization: async (o) => { calls.push(["auth", o.read.length]); return { readAuthorized: o.read, readDenied: [], writeAuthorized: [], writeDenied: [] }; },
          queryAggregated: async (o) => {
            calls.push(["agg", o.dataType, o.aggregation]);
            const ok = AGG[o.dataType];
            if (!ok) throw new Error(`Aggregated queries are not supported for ${o.dataType}. Use readSamples instead.`);
            const aggs = Array.isArray(o.aggregation) ? o.aggregation : [o.aggregation || ok[0]];
            for (const a of aggs) if (!ok.includes(a)) throw new Error(`Unsupported aggregation '${a}' for ${o.dataType}.`);
            const v = aggVals[o.dataType];
            if (!v) return { samples: [] };
            const first = o.dataType === "heartRate" ? HIST : "2026-11-23";
            const samples = keysIn(o.startDate, Date.parse(o.endDate) - 1).filter((k) => k >= first && k <= TODAY).map((k) => {
              const values = {};
              for (const a of aggs) if (v[a] != null) values[a] = v[a];
              return { startDate: at(k, 0), endDate: at(k, 24), value: values[aggs[0]], values, unit: "count" };
            });
            return { samples };
          },
          readSamples: async (o) => {
            calls.push(["read", o.dataType, o.startDate, o.endDate]);
            const g = gen[o.dataType];
            if (!g) return { samples: [] };
            const a = Date.parse(o.startDate);
            const b = Date.parse(o.endDate);
            const list = keysIn(a - 86400000, b + 86400000).flatMap(g)
              .filter((x) => Date.parse(x.startDate) < b && Date.parse(x.endDate) >= a)
              .sort((x, y) => Date.parse(x.startDate) - Date.parse(y.startDate));
            return { samples: list.slice(0, o.limit != null ? o.limit : 100) };
          },
          queryWorkouts: async (o) => {
            const all = [
              { workoutType: "running", duration: 1860, totalDistance: 4828, totalEnergyBurned: 401, startDate: "2026-11-23T23:00:00.000Z", endDate: "2026-11-23T23:31:00.000Z", metadata: { HKIndoorWorkout: "0" } },
              { workoutType: "traditionalStrengthTraining", duration: 1500, startDate: "2026-11-22T23:00:00.000Z", endDate: "2026-11-22T23:25:00.000Z" },
            ];
            return { workouts: all.filter((w) => Date.parse(w.startDate) >= Date.parse(o.startDate) && Date.parse(w.startDate) < Date.parse(o.endDate)) };
          },
        },
      },
    };
  });

  const writes = [];
  const metrics = new Map();
  let dashboardGets = 0;
  await page.route(API, async (route) => {
    const req = route.request();
    if (req.method() === "OPTIONS") return route.fulfill({ status: 204, headers: cors });
    if (req.url().endsWith("/log-dashboard")) {
      dashboardGets += 1;
      // Like the real payload: {metric: [[day, value], ...]} for the last 120 days.
      const hm = {};
      for (const m of metrics.values()) if (m.day >= "2026-07-27") (hm[m.metric] = hm[m.metric] || []).push([m.day, m.value]);
      for (const k of Object.keys(hm)) hm[k].sort((x, y) => (x[0] < y[0] ? -1 : 1));
      return route.fulfill({ status: 200, headers: { ...cors, "content-type": "application/json" }, body: JSON.stringify({ ...fixture, health_metrics: hm }) });
    }
    const body = JSON.parse(req.postData() || "{}");
    writes.push(body);
    const p = body.payload;
    if (body.action === "health_metrics") {
      for (const m of p.metrics) metrics.set(`${m.day}|${m.metric}`, m);
      return route.fulfill({ status: 200, headers: { ...cors, "content-type": "application/json" }, body: JSON.stringify({ ok: true, action: "health_metrics", metrics: p.metrics.length }) });
    }
    return route.fulfill({ status: 200, headers: { ...cors, "content-type": "application/json" }, body: JSON.stringify({ ok: true, action: "health_sync", days: (p.days || []).length, weights: (p.weights || []).length, body: (p.body || []).length, workouts: (p.workouts || []).length }) });
  });

  await page.goto(BASE);
  await page.waitForSelector(".hero-num");
  await page.waitForFunction(() => { const b = JSON.parse(localStorage.getItem("log.healthBackfill") || "null"); return b && b.done; }, null, { timeout: 20000 }).catch(() => {});
  const sync = writes.filter((w) => w.action === "health_sync");
  const days = sync.flatMap((w) => w.payload.days || []);
  const today = days.find((d) => d.day === "2026-11-24") || {};
  const M = (day, id) => (metrics.get(`${day}|${id}`) || {}).value;
  check("syncs on its own when the app opens", sync.length >= 3 && writes.some((w) => w.action === "health_metrics"), `${writes.length} requests`);
  check("daily totals are converted", today.steps === 9123 && today.distance_mi === 4 && today.active_kcal === 812 && today.resting_hr === 58, JSON.stringify(today));
  check("exercise and stand hours come from samples, biggest source", today.exercise_min === 30 && today.stand_hours === 11, `${today.exercise_min} min, ${today.stand_hours} h`);
  check("VO2 max and HRV come from samples", today.vo2max === 38.4 && today.hrv_ms === 71, `${today.vo2max}, ${today.hrv_ms}`);
  check("sleep: one source, whole night on the wake-up day", today.sleep_hours === 7.33 && !days.some((d) => d.day === "2026-11-23" && d.sleep_hours != null), String(today.sleep_hours));
  check("sleep stages and time in bed", M("2026-11-24", "sleep_deep_min") === 180 && M("2026-11-24", "sleep_core_min") === 260 && M("2026-11-24", "sleep_awake_min") === 60 && M("2026-11-24", "sleep_rem_min") === 0 && M("2026-11-24", "sleep_in_bed_h") === 8.75);
  const auth = await page.evaluate(() => window.__healthCalls.filter((c) => c[0] === "auth").map((c) => c[1]));
  check("asks for every supported Health type", auth[0] === 28, JSON.stringify(auth.slice(0, 3)));
  check("aggregates only what the plugin can", await page.evaluate(() => window.__healthCalls.filter((c) => c[0] === "agg").every((c) => ["steps", "distance", "calories", "dietaryWater", "dietaryEnergyConsumed", "heartRate", "restingHeartRate"].includes(c[1]))));
  check("heart rate average, low and high", M("2026-11-24", "heart_rate_avg") === 72.4 && M("2026-11-24", "heart_rate_min") === 48 && M("2026-11-24", "heart_rate_max") === 151);
  check("energy: resting from the biggest source, total adds active", M("2026-11-24", "basal_kcal") === 1920 && M("2026-11-24", "total_kcal") === 2732, `${M("2026-11-24", "basal_kcal")}, ${M("2026-11-24", "total_kcal")}`);
  check("flights don't double count iPhone + Watch", M("2026-11-24", "flights") === 8, String(M("2026-11-24", "flights")));
  check("breathing, blood oxygen, blood pressure", M("2026-11-24", "respiratory_rate") === 15 && M("2026-11-24", "spo2_avg") === 95.5 && M("2026-11-24", "spo2_min") === 94 && M("2026-11-24", "bp_systolic") === 118 && M("2026-11-24", "bp_diastolic") === 76);
  check("glucose, wrist temp, mood, mindful, water, height", M("2026-11-24", "glucose_avg") === 101 && M("2026-11-24", "glucose_max") === 110 && M("2026-11-24", "wrist_temp_f") === 95.18 && M("2026-11-24", "state_of_mind") === 0.1 && M("2026-11-24", "mindful_min") === 10 && M("2026-11-24", "water_oz") === 51 && M("2026-11-24", "height_in") === 73);
  check("metric names and units fit the server's rules", [...metrics.values()].every((m) => /^[a-z0-9_]{2,40}$/.test(m.metric) && Number.isFinite(m.value) && Math.abs(m.value) <= 100000 && String(m.unit || "").length <= 12));
  const w = sync.flatMap((x) => x.payload.weights || [])[0] || {};
  check("weigh-ins are converted to lb", w.weight_lb === 257.2, JSON.stringify(w));
  const body = sync.flatMap((x) => x.payload.body || []);
  const bf = body.find((b) => b.metric === "body_fat_pct") || {};
  const lean = body.find((b) => b.metric === "lean_mass_lb") || {};
  check("body fat % and lean mass", bf.value === 36.8 && lean.value === 162.6, JSON.stringify(body.slice(0, 2)));
  const wk = sync.flatMap((x) => x.payload.workouts || []);
  check("workouts use the existing names", wk.length >= 2 && wk[0].activity === "running" && wk[0].distance_mi === 3 && wk[0].duration_min === 31 && wk[0].indoor === false && wk.some((x) => x.activity === "traditional strength training"), JSON.stringify(wk.slice(0, 2)));
  check("each request stays small", writes.every((x) => JSON.stringify(x).length < 32000), String(Math.max(...writes.map((x) => JSON.stringify(x).length))));

  // History backfill
  const bfState = await page.evaluate(() => JSON.parse(localStorage.getItem("log.healthBackfill") || "null"));
  check("backfill runs to the end and saves its place", bfState && bfState.done === true && bfState.cursor <= "2025-09-01", JSON.stringify(bfState));
  check("backfill reaches the oldest data", M("2026-09-01", "heart_rate_avg") === 72.4 && M("2026-09-01", "flights") === 8 && M("2026-08-31", "heart_rate_avg") == null);
  check("backfill never rewrites daily totals (only the last 30 days get them)", days.every((d) => d.day >= "2026-10-26"), days.map((d) => d.day).sort()[0]);
  const reads = await page.evaluate(() => window.__healthCalls.filter((c) => c[0] === "read" && c[1] === "flightsClimbed").length);
  check("backfill windows grow when there's little data", reads < 25, `${reads} windows`);

  // Manual sync from the Body card on Today.
  const btn = page.locator(".health-sync button").first();
  check("Body card has a sync button", (await btn.count()) === 1 && /Last synced/.test(await page.textContent(".health-sync .sync-meta")));
  const n = writes.length;
  await btn.evaluate((b) => b.scrollIntoView({ block: "center" }));
  await page.waitForTimeout(300);
  await btn.tap();
  await page.waitForFunction(() => document.querySelector(".health-sync .sync-meta") && /Synced/.test(document.querySelector(".health-sync .sync-meta").textContent), null, { timeout: 8000 }).catch(() => {});
  const msg = await page.textContent(".health-sync .sync-meta");
  check("manual sync runs and reports", writes.length > n && /^Synced 2 days, 1 weigh-in, 2 body readings, 2 workouts and \d+ other values\.$/.test(msg), msg);

  // Pull to refresh
  await page.evaluate(() => window.scrollTo(0, 0));
  await page.waitForTimeout(200);
  const cdp = await ctx.newCDPSession(page);
  const drag = async (x0, y0, x1, y1, holdCheck) => {
    await cdp.send("Input.dispatchTouchEvent", { type: "touchStart", touchPoints: [{ x: x0, y: y0 }] });
    const steps = 10;
    for (let i = 1; i <= steps; i++) {
      await cdp.send("Input.dispatchTouchEvent", { type: "touchMove", touchPoints: [{ x: x0 + ((x1 - x0) * i) / steps, y: y0 + ((y1 - y0) * i) / steps }] });
      await page.waitForTimeout(16);
    }
    const mid = holdCheck ? await holdCheck() : null;
    await cdp.send("Input.dispatchTouchEvent", { type: "touchEnd", touchPoints: [] });
    return mid;
  };
  check("pull to refresh is on in the app", await page.evaluate(() => document.documentElement.classList.contains("ptr-on")));
  let gets = dashboardGets;
  let before = writes.length;
  const ready = await drag(215, 180, 215, 420, () => page.evaluate(() => { const p = document.querySelector(".ptr"); return p && p.classList.contains("on") && p.classList.contains("ready"); }));
  check("pulling down shows the indicator, ready past the threshold", ready === true);
  await page.waitForTimeout(1500);
  const newSync = writes.slice(before).filter((x) => x.action === "health_sync" && x.payload.days);
  check("release syncs the last 2 days and reloads", dashboardGets > gets && newSync.length >= 1 && newSync.every((x) => x.payload.days.every((d) => d.day >= "2026-11-23")), `${dashboardGets - gets} reloads, ${newSync.length} syncs`);
  check("indicator goes away after", await page.evaluate(() => !document.querySelector(".ptr").classList.contains("on") && !document.querySelector(".ptr").classList.contains("spin")));

  gets = dashboardGets;
  before = writes.length;
  await drag(215, 180, 215, 240);
  await page.waitForTimeout(800);
  check("a short pull doesn't refresh", dashboardGets === gets && writes.length === before);
  await drag(330, 400, 150, 430);
  await page.waitForTimeout(800);
  check("a sideways swipe doesn't refresh", dashboardGets === gets && writes.length === before);
  await page.evaluate(() => window.scrollTo(0, 500));
  await page.waitForTimeout(200);
  await drag(215, 300, 215, 600);
  await page.waitForTimeout(800);
  check("pulling mid-page just scrolls", dashboardGets === gets && writes.length === before);

  // Trends card
  await page.tap(".tabnav >> text=Trends");
  await page.waitForTimeout(300);
  const card = page.locator("section.card", { has: page.locator("h2:text-is('More from Apple Health')") });
  check("Trends shows More from Apple Health", (await card.count()) === 1);
  const hr = card.locator(".hm-row", { hasText: "Heart rate, daily average" });
  check("rows show the latest value", /^72\s*bpm$/u.test(await hr.locator(".hm-val").textContent()), await hr.locator(".hm-val").textContent());
  check("blood pressure shows as systolic/diastolic", /118\/76/.test(await card.locator(".hm-row", { hasText: "Blood pressure" }).locator(".hm-val").textContent()));
  check("sleep stages read as hours and minutes", /3 h 0\s*min/.test(await card.locator(".hm-row", { hasText: "Deep sleep" }).locator(".hm-val").textContent()));
  check("30-day average under the label", /^Nov 24\. 30-day average 72\sbpm$/.test(await hr.locator(".hm-sub").textContent()), await hr.locator(".hm-sub").textContent());
  await card.evaluate((c) => c.scrollIntoView({ block: "start" }));
  await page.waitForTimeout(200);
  await page.screenshot({ path: `${SHOTS}/more-health-closed-${theme}.png` });
  await hr.locator("summary").evaluate((s) => s.scrollIntoView({ block: "center" }));
  await page.waitForTimeout(300);
  await hr.locator("summary").tap();
  await page.waitForTimeout(300);
  check("tapping a row opens its 120-day chart", (await hr.locator(".hm-chart svg").count()) >= 1);
  await page.screenshot({ path: `${SHOTS}/more-health-${theme}.png`, fullPage: false });
  // Survives the once-a-minute redraw
  await page.evaluate(() => render());
  check("an open row stays open after a redraw", (await card.locator(".hm-row[open]").count()) === 1);

  await page.tap(".tabnav >> text=Log");
  await page.waitForTimeout(300);
  const logCard = page.locator("section.card", { has: page.locator("h2:text-is('Apple Health')") });
  check("Log tab has an Apple Health card with backfill", (await logCard.count()) === 1 && /History backfilled: [0-9,]+ values saved, going back to Sep 2026\./.test(await logCard.locator(".backfill-status").textContent()) && /Backfill again/.test(await logCard.locator(".backfill-btn").textContent()), await logCard.locator(".backfill-status").textContent());
  await logCard.evaluate((c) => c.scrollIntoView({ block: "center" }));
  await page.screenshot({ path: `${SHOTS}/health-card-${theme}.png` });
  check("no page errors", errors.length === 0, errors.join("; "));
  await browser.close();
  server.close();
  const failed = check.failed();
  console.log(failed.length ? `FAILED:\n${failed.join("\n")}` : `ALL PASS (${check.count()} checks)`);
  process.exit(failed.length ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(2); });
