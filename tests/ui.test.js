// The whole app on an iPhone-sized screen: lock screen, every tab, the forms, and the cards.
// Usage: node ui.test.js [light|dark]. Data comes from fixture.js (made up); writes are recorded,
// never sent anywhere. Screenshots land in tests/shots.
const { chromium } = require("playwright");
const fs = require("fs");
const path = require("path");
const { serve, makeFixture, BASE, SHOTS, API, CLOCK, PASSCODE: PASS, CORS: cors } = require("./lib");

const OUT = SHOTS;
const SCHEME = process.argv[2] === "dark" ? "dark" : "light";
const LOG_BOT = "grokbot://app/v1/agent?id=81acb34c-2ba4-4bde-aa1b-98e865272965";
const fixture = makeFixture();

const writes = [];
const errors = [];
let passed = 0;
// Dashboard GETs. A save's toast is painted when its reload starts, and Log is
// drawn again when that GET returns, so the counters can wait out the redraw.
let dashStarted = 0;
let dashFinished = 0;

function check(name, ok, detail) {
  console.log(`${ok ? "PASS" : "FAIL"}  ${name}${detail ? "  " + detail : ""}`);
  if (!ok) errors.push(name); else passed += 1;
}

let goalSetLive = false;
(async () => {
  const appjs = fs.readFileSync(path.join(__dirname, "../ios-app/www/app.js"), "utf8");
  const botSwift = fs.readFileSync(path.join(__dirname, "../ios-app/ios/App/LogNative/Sources/LogUI/Shared/LogBot.swift"), "utf8");
  const mealsSwift = fs.readFileSync(path.join(__dirname, "../ios-app/ios/App/LogNative/Sources/LogUI/Today/TodayHealth.swift"), "utf8");
  check("Log bot URL is one constant on web and native",
    appjs.split(LOG_BOT).length === 2 && botSwift.split(LOG_BOT).length === 2
    && !appjs.includes("Ask Log or Claude") && !mealsSwift.includes("Ask Log or Claude"));

  const server = await serve();
  const browser = await chromium.launch();
  const ctx = await browser.newContext({
    serviceWorkers: "block", // the offline shell has its own test (offline.js)
    viewport: { width: 430, height: 932 },
    deviceScaleFactor: 2,
    isMobile: true,
    hasTouch: true,
    colorScheme: SCHEME,
    userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 Mobile/15E148 Safari/604.1",
  });
  const page = await ctx.newPage();
  await page.clock.setFixedTime(CLOCK);
  page.on("console", (m) => { if (m.type() === "error" && !/status of (401|400)/.test(m.text())) errors.push("console: " + m.text()); });
  page.on("pageerror", (e) => errors.push("pageerror: " + e.message));

  await page.route(API, async (route) => {
    const req = route.request();
    if (req.method() === "OPTIONS") return route.fulfill({ status: 204, headers: cors });
    const ok = req.headers()["x-log-passcode"] === PASS;
    if (!ok) return route.fulfill({ status: 401, headers: { ...cors, "content-type": "application/json" }, body: JSON.stringify({ ok: false, error: "unauthorized" }) });
    if (req.url().endsWith("/log-dashboard")) {
      dashStarted += 1;
      await route.fulfill({ status: 200, headers: { ...cors, "content-type": "application/json" }, body: JSON.stringify(fixture) });
      dashFinished += 1;
      return;
    }
    const body = JSON.parse(req.postData() || "{}");
    writes.push(body);
    if (body.action === "food_thought") {
      fixture.food_thoughts.push({ id: "n" + writes.length, thought_at: "2026-11-25T05:20:00Z", strength: body.payload.strength ?? null, note: null });
    }
    if (body.action === "side_effect_upsert") {
      fixture.side_effects.push({ id: "s" + writes.length, recorded_on: "2026-11-24", recorded_at: new Date().toISOString(), effect: body.payload.effect, severity: Number(body.payload.severity), notes: null });
    }
    if (body.action === "checkin_upsert") {
      const d = body.payload.day;
      let c = fixture.checkins.find((x) => x.day === d);
      if (!c) { c = { day: d }; fixture.checkins.push(c); fixture.checkins.sort((a, b) => (a.day < b.day ? -1 : 1)); }
      Object.assign(c, body.payload);
    }
    if (body.action === "goal_set") {
      if (!goalSetLive) return route.fulfill({ status: 400, headers: { ...cors, "content-type": "application/json" }, body: JSON.stringify({ ok: false, error: "invalid_action", field: "action" }) });
      for (const g of fixture.goals) if (g.kind === body.payload.kind && g.status === "active") g.status = "retired";
      fixture.goals.push({ id: "g" + fixture.goals.length, kind: body.payload.kind, target: body.payload.target, unit: body.payload.kind === "calories" ? "kcal" : "g", due_on: null, notes: null, status: "active" });
    }
    if (body.action === "weigh_in") fixture.weights.push({ id: "new", measured_at: "2026-11-25T05:19:00+00:00", weight_lb: Number(body.payload.weight_lb), notes: body.payload.notes || null });
    if (body.action === "dose_log" && body.payload.skipped) {
      fixture.doses.push({
        id: "skip" + writes.length,
        taken_at: body.payload.taken_at,
        compound: body.payload.compound,
        dose_mg: body.payload.dose_mg ?? null,
        units: body.payload.units ?? null,
        site: null,
        skipped: true,
        notes: body.payload.notes || null,
      });
    }
    return route.fulfill({ status: 200, headers: { ...cors, "content-type": "application/json" }, body: JSON.stringify({ ok: true }) });
  });

  // Freeze the app's 60-second background refresh during the test; it's exercised by hand below.
  await page.addInitScript(() => {
    const si = window.setInterval;
    window.setInterval = (fn, ms, ...a) => (ms >= 60000 ? 0 : si(fn, ms, ...a));
  });

  // Full-page captures briefly change the emulated viewport, which fires resize; let any redraw settle.
  const shot = async (name, full = true) => { await page.screenshot({ path: path.join(OUT, `${SCHEME}-${name}.png`), fullPage: full }); if (full) await page.waitForTimeout(300); };

  // Tap a save and wait until its toast is up and the follow-up dashboard reload
  // has redrawn Log. The toast appears at the start of that reload, so waiting
  // only for it lets the next fill land in a form the redraw then throws away
  // (the light-mode "Saved measurement." timeout). A real missed save still
  // fails: the success toast never shows, or the recorded payload is wrong.
  const save = async (button, toast) => {
    const before = dashStarted;
    await page.tap(button);
    await page.waitForSelector(toast);
    const deadline = Date.now() + 15000;
    while (dashFinished < before + 1 || dashStarted !== dashFinished) {
      if (Date.now() > deadline) throw new Error(`dashboard reload did not finish after ${toast}`);
      await page.waitForTimeout(20);
    }
    await page.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))));
  };

  // Lock screen
  await page.goto(BASE);
  await page.waitForSelector(".gate");
  const attrs = await page.$eval("#passcode", (i) => ({ type: i.type, inputmode: i.getAttribute("inputmode"), pattern: i.getAttribute("pattern") }));
  check("passcode opens number pad", attrs.inputmode === "numeric" && attrs.pattern === "[0-9]*" && attrs.type === "password", JSON.stringify(attrs));
  await shot("01-gate", false);
  await page.tap(".pin-pad");
  check("tapping the dots focuses the input", await page.evaluate(() => document.activeElement && document.activeElement.id === "passcode"));
  await page.keyboard.type("1111");
  await shot("02-gate-typed", false);
  await page.tap("text=Unlock");
  await page.waitForSelector(".gate-err:not(:empty)");
  check("wrong passcode shows an error", (await page.textContent(".gate-err")).includes("didn’t work"));
  await shot("03-gate-error", false);
  await page.tap("text=Use letters");
  check("letters toggle switches keyboard", (await page.getAttribute("#passcode", "inputmode")) === "text");
  await page.tap("text=Use number pad");
  await page.tap(".pin-pad");
  await page.keyboard.type(PASS);
  await page.keyboard.press("Enter");
  await page.waitForSelector(".hero-num");
  check("unlock stores passcode on device", (await page.evaluate(() => localStorage.getItem("log.passcode"))) === PASS);

  // Today
  await shot("10-today");
  check("hero shows current weight", (await page.textContent(".hero-num")).includes("238.6"), await page.textContent(".hero-num"));
  check("today keeps the switch card and drops the race", (await page.locator("h2:text-is('BMW Dallas Half')").count()) === 0 && (await page.locator(".count-label", { hasText: "Half marathon" }).count()) === 0 && (await page.locator("h2:text-is('Retatrutide switch')").count()) === 1 && (await page.locator(".counts .count").count()) === 2);
  const mealsCard = page.locator("section.card:has(h2:text-is('Meals'))");
  check("today meals link to the Log bot",
    (await mealsCard.locator("a.log-meal").getAttribute("href")) === LOG_BOT
    && (await mealsCard.locator("a.log-meal").innerText()).trim() === "Log a meal");
  await mealsCard.screenshot({ path: path.join(OUT, `${SCHEME}-13-meals.png`) });
  await page.evaluate(() => {
    document.querySelector("a.log-meal").addEventListener("click", (e) => e.preventDefault(), true);
  });
  await page.tap("a.log-meal");
  await page.clock.fastForward(2000);
  await page.waitForSelector(".meal-bot-note");
  check("missing Grok Bot shows a short note", (await page.locator(".meal-bot-note").innerText()).includes("isn’t installed"));
  await mealsCard.screenshot({ path: path.join(OUT, `${SCHEME}-13-meals-unavailable.png`) });
  await page.evaluate(() => {
    state._mealsBackup = state.data.meals.slice();
    const key = todayKey();
    state.data.meals = state.data.meals.filter((m) => {
      const t = parseTs(m.eaten_at);
      return !(t && dateKeyCT(t) === key);
    });
    state.mealBotNote = null;
    render();
  });
  check("empty today offers Log a meal",
    (await mealsCard.locator(".empty").innerText()).trim() === "No meals yet today."
    && (await mealsCard.locator("a.log-meal").count()) === 1
    && (await page.locator("text=Ask Log or Claude").count()) === 0);
  await mealsCard.screenshot({ path: path.join(OUT, `${SCHEME}-13-meals-empty.png`) });
  await page.evaluate(() => { state.data.meals = state._mealsBackup; state.mealBotNote = null; render(); });
  check("food card without targets offers set", await page.isVisible("text=Set targets"));
  await page.tap("text=Set targets");
  await page.fill("[name=t_cal]", "500");
  await page.tap("text=Save targets");
  check("targets editor rejects out-of-range calories", (await page.textContent(".targets-editor .target-msg")).includes("800"));
  // Server doesn't know goal_set yet: falls back to this phone.
  await page.fill("[name=t_cal]", "2000");
  await page.fill("[name=t_pro]", "140");
  await page.tap("text=Save targets");
  await page.waitForSelector(".gauge-status");
  const status = await page.$$eval(".gauge-status", (n) => n.map((x) => x.textContent));
  check("gauges show progress vs target", status[0].includes("385 left") && status[1].includes("78 g to go"), JSON.stringify(status));
  check("falls back to phone when goal_set isn't live", (await page.textContent(".target-msg.ok")).includes("on this phone") && JSON.parse(await page.evaluate(() => localStorage.getItem("log.targets"))).calories === 2000);
  // Server has goal_set: targets save to the log and win over the phone's.
  goalSetLive = true;
  await page.tap("text=Edit targets");
  await page.fill("[name=t_cal]", "2200");
  await page.fill("[name=t_pro]", "150");
  await page.tap("text=Save targets");
  await page.waitForSelector(".target-msg.ok >> text=saved to your log");
  const status2 = await page.$$eval(".gauge-status", (n) => n.map((x) => x.textContent));
  const gw = writes.filter((w) => w.action === "goal_set").slice(-2);
  check("targets save to the log via goal_set", status2[0].includes("585 left") && status2[1].includes("88 g to go")
    && gw[0].payload.kind === "calories" && gw[0].payload.target === 2200 && gw[1].payload.kind === "protein" && gw[1].payload.target === 150, JSON.stringify(status2));
  await shot("11-today-targets");
  await page.waitForTimeout(400);
  const foodBox = page.locator("section.card:has(.gauges)").first();
  await foodBox.screenshot({ path: path.join(OUT, `${SCHEME}-12-food-card.png`) });

  // Background refresh keeps the screen and doesn't throw
  await page.evaluate(() => load(true));
  await page.waitForTimeout(300);
  check("refresh re-renders today", await page.isVisible(".hero"));

  // Check-in opens in place on Today, always the full one, and you stay on Today.
  check("check-in shows as done with Edit", await page.isVisible(".callout.done >> text=Edit"));
  await page.tap(".callout.done >> text=Edit");
  check("check-in opens inline on Today", (await page.locator(".day-body .checkin-form").count()) === 1 && (await page.locator(".day-body .checkin-form input[type=range]").count()) === 4);
  await page.tap(".day-body .checkin-form >> text=Ate less");
  await page.$eval(".day-body [name=mood]", (r) => { r.value = "8"; r.dispatchEvent(new Event("input", { bubbles: true })); });
  await page.fill(".day-body [name=sleep_hours]", "7.5");
  await shot("14-today-checkin-open");
  await page.tap(".day-body >> text=Save check-in");
  await page.waitForSelector(".day-body .callout.done");
  const cw = writes[writes.length - 1];
  check("inline check-in saves the full check-in and stays on Today", cw.action === "checkin_upsert" && cw.payload.day === "2026-11-24" && cw.payload.ate_vs_usual === "less" && cw.payload.mood === 8 && cw.payload.sleep_hours === 7.5 && (await page.textContent("h1")) === "Today" && (await page.textContent(".callout.done")).includes("Mood 8"), JSON.stringify(cw));

  // The "No check-in yet" prompt waits for the evening.
  await page.clock.setFixedTime(new Date("2026-11-24T10:00:00-06:00"));
  await page.evaluate(() => { state.data.checkins = state.data.checkins.filter((c) => c.day !== todayKey()); render(); });
  check("no check-in prompt in the morning", (await page.locator("text=No check-in yet today").count()) === 0);
  await page.clock.setFixedTime(new Date("2026-11-24T18:30:00-06:00"));
  await page.evaluate(() => render());
  check("check-in prompt in the evening", await page.isVisible("text=No check-in yet today"));
  await page.clock.setFixedTime(CLOCK);
  await page.evaluate(() => load(true));
  await page.waitForTimeout(200);

  // Swipe between days.
  const swipe = (fromX, toX) => page.evaluate(([a, b]) => {
    const node = document.querySelector(".day-body .hero") || document.querySelector(".day-body");
    const mk = (x) => new Touch({ identifier: 1, target: node, clientX: x, clientY: 400 });
    node.dispatchEvent(new TouchEvent("touchstart", { touches: [mk(a)], changedTouches: [mk(a)], bubbles: true }));
    node.dispatchEvent(new TouchEvent("touchend", { touches: [], changedTouches: [mk(b)], bubbles: true }));
  }, [fromX, toX]);
  await swipe(320, 100);
  check("can't swipe past today", (await page.textContent("h1")) === "Today");
  await swipe(100, 320);
  await page.waitForTimeout(250);
  check("swipe right shows yesterday", (await page.textContent("h1")) === "Yesterday" && (await page.textContent(".eyebrow-date")).includes("November 23"));
  check("past day shows that day's cards", (await page.isVisible("text=No food logged this day.")) && (await page.isVisible("text=No meals logged this day.")) && (await page.locator("a.log-meal").count()) === 0 && (await page.locator(".counts").count()) === 0 && (await page.locator(".day-body .hero-num").count()) === 1);
  await shot("15-yesterday");
  await page.tap(".day-body .callout >> text=Check in");
  await page.tap(".day-body .checkin-form >> text=Moved more");
  await page.tap(".day-body >> text=Save check-in");
  await page.waitForSelector(".day-body .callout.done");
  check("check-in on a past day saves for that day", writes[writes.length - 1].payload.day === "2026-11-23" && (await page.textContent("h1")) === "Yesterday");
  await swipe(100, 320);
  await page.waitForTimeout(250);
  check("week strip follows into last week", (await page.textContent("h1")) === "Sunday" && (await page.textContent(".week .day.on .dnum")) === "22" && (await page.locator(".week .day:disabled").count()) === 0);
  await shot("16-sunday");
  await page.tap(".weekstrip .pill");
  check("Today pill jumps back", (await page.textContent("h1")) === "Today" && (await page.locator(".weekstrip .pill").count()) === 0 && (await page.locator(".week .day:disabled").count()) === 5);
  await page.keyboard.press("ArrowLeft");
  check("arrow keys move days", (await page.textContent("h1")) === "Yesterday");
  await page.tap(".tabnav >> text=Today");
  check("tapping Today again returns to today", (await page.textContent("h1")) === "Today");
  await page.waitForTimeout(800); // let the smooth scroll to the top finish; a tap mid-scroll only stops the scroll

  // Thinking about food: one tap logs it with a strength.
  const before = await page.textContent(".thoughts + .caption");
  await page.tap(".thought-btn >> text=Strong pull");
  await page.waitForSelector(".toast.ok >> text=Logged a food thought");
  const fw = writes[writes.length - 1];
  check("food thought logs with strength", fw.action === "food_thought" && fw.payload.strength === 2 && (await page.textContent(".thoughts + .caption")) !== before, `${before} -> ${await page.textContent(".thoughts + .caption")}`);
  // Quick side effect from Today.
  await page.tap("text=Side effect?");
  await page.tap(".effect-chips >> text=Nausea");
  await page.tap(".quick-effect >> text=Save side effect");
  await page.waitForSelector(".toast.ok >> text=Logged nausea.");
  const sw = writes[writes.length - 1];
  check("side effect from Today", sw.action === "side_effect_upsert" && sw.payload.effect === "Nausea" && String(sw.payload.severity) === "4" && (await page.locator(".quick-effect").count()) === 0, JSON.stringify(sw));
  check("verdict uses the same start as Today", /from your 248(\.0)? lb start/.test(await page.textContent(".verdict")), await page.textContent(".verdict"));
  check("Today's next dose comes from the plan", /Next dose\s*Tirzepatide 3(\.0)? mg, Sun, Nov 29/.test(await page.locator("section.card:has(h2:text-is('Medication'))").first().innerText()));
  check("hero shows pace as % of body weight", /lb a week \(\d+\.\d%\)/.test(await page.textContent(".hero-chips")), await page.textContent(".hero-chips"));
  const offCard = page.locator("section.card:has(h2:text-is('Off your normal'))");
  check("Today flags a day with 3 of 4 recovery signals off", (await offCard.count()) === 1 && /3 of 4 recovery signals are off your normal/.test(await offCard.innerText()) && (await offCard.locator(".signal-row.off").count()) === 3, (await offCard.count()) ? (await offCard.innerText()).replace(/\n/g, " | ") : "no card");
  await offCard.screenshot({ path: path.join(OUT, `${SCHEME}-18-off-normal.png`) });
  await shot("17-today-feel");


  // Meds
  await page.tap(".tabnav >> text=Meds");
  await page.waitForSelector(".sitemap", { timeout: 5000 }).catch(async (e) => {
    await page.screenshot({ path: path.join(OUT, `${SCHEME}-DEBUG-meds.png`) });
    console.log("DEBUG", JSON.stringify(await page.evaluate(() => ({ tab: state.tab, off: state.dayOffset, open: state.checkinOpen, h1: document.querySelector("h1") && document.querySelector("h1").textContent, y: scrollY }))));
    throw e;
  });
  await shot("20-meds");
  const lvl = page.locator("section.card:has(svg.chart)").first();
  const bb = await lvl.locator("svg.chart").boundingBox();
  await page.touchscreen.tap(bb.x + bb.width * 0.35, bb.y + bb.height / 2);
  await page.waitForTimeout(100);
  check("drug level scrub updates readout", await page.$eval(".readout", (n) => n.classList.contains("live")));
  await lvl.screenshot({ path: path.join(OUT, `${SCHEME}-21-level-scrub.png`) });
  const dp = page.locator("section.card:has(h2:has-text('Dose plan'))");
  const dpText = await dp.innerText();
  check("dose plan shows the next planned dose and the steps", /Next: Tirzepatide 3(\.0)? mg\./.test(dpText) && /When\s*Sun, Nov 29/.test(dpText) && /Retatrutide used\s*0(\.0)? of 36 mg planned/.test(dpText) && (await dp.locator("tbody tr").count()) === 4, dpText.replace(/\n/g, " | "));
  check("a future planned dose is not marked overdue", (await dp.locator("text=Skip this dose").count()) === 0 && (await dp.locator(".badge").count()) === 0);
  await dp.screenshot({ path: path.join(OUT, `${SCHEME}-22-dose-plan.png`) });

  // The day after a planned shot that was never logged: it stays, marked overdue, until skipped.
  await page.clock.setFixedTime(new Date("2026-11-30T09:00:00-06:00"));
  await page.evaluate(() => render());
  const lateLead = await dp.locator(".lead").innerText();
  const lateText = await dp.innerText();
  check("a missed planned dose stays and is marked overdue", /Overdue: Tirzepatide 3(\.0)? mg\./.test(lateLead) && !/Retatrutide/.test(lateLead) && /Was due\s*Sun, Nov 29, 1 day ago/.test(lateText) && (await dp.locator(".badge.watch").innerText()) === "Overdue", lateText.replace(/\n/g, " | "));
  await dp.screenshot({ path: path.join(OUT, `${SCHEME}-23-dose-overdue.png`) });
  await page.tap(".tabnav >> text=Today");
  const medLate = page.locator("section.card:has(h2:text-is('Medication'))").first();
  const medLateText = await medLate.innerText();
  check("Today names the missed dose overdue", /Next dose\s*Overdue: Tirzepatide 3(\.0)? mg, Sun, Nov 29 \(1 day ago\)/.test(medLateText), medLateText.replace(/\n/g, " | "));
  await medLate.screenshot({ path: path.join(OUT, `${SCHEME}-23-today-overdue.png`) });
  await page.tap(".tabnav >> text=Meds");
  await dp.locator("text=Skip this dose").waitFor();
  const skipBtn = dp.locator("button", { hasText: "Skip this dose" });
  await skipBtn.scrollIntoViewIfNeeded();
  const beforeSkip = writes.length;
  const beforeDash = dashStarted;
  await skipBtn.tap();
  const skipBy = Date.now() + 15000;
  while (writes.length === beforeSkip || dashFinished < beforeDash + 1 || dashStarted !== dashFinished) {
    if (Date.now() > skipBy) throw new Error(`skip did not finish (writes ${writes.length - beforeSkip}, dash ${dashStarted}/${dashFinished})`);
    await page.waitForTimeout(20);
  }
  await page.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))));
  const skip = writes[writes.length - 1];
  check("skip writes a skipped dose on the planned day", skip.action === "dose_log" && skip.payload.skipped === true && skip.payload.compound === "tirzepatide" && String(skip.payload.dose_mg) === "3" && String(skip.payload.taken_at).startsWith("2026-11-29"), JSON.stringify(skip));
  const afterSkip = await dp.locator(".lead").innerText();
  check("skipping the missed dose reveals the next week", /Next: Retatrutide 2(\.0)? mg/.test(afterSkip) && /Sun, Dec 6/.test(await dp.innerText()) && (await dp.locator(".badge.watch").count()) === 0, afterSkip);
  fixture.doses = fixture.doses.filter((d) => !(d.id && String(d.id).startsWith("skip")));
  await page.clock.setFixedTime(CLOCK);
  const beforeReload = dashStarted;
  await page.evaluate(() => load(true));
  const reloadBy = Date.now() + 15000;
  while (dashFinished < beforeReload + 1 || dashStarted !== dashFinished) {
    if (Date.now() > reloadBy) throw new Error("dashboard reload did not finish after restoring the clock");
    await page.waitForTimeout(20);
  }
  await page.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))));
  check("dose plan is back to the upcoming Sunday", /Next: Tirzepatide 3(\.0)? mg\./.test(await dp.locator(".lead").innerText()));

  // Trends
  await page.tap(".tabnav >> text=Trends");
  await page.waitForSelector(".seg");
  await shot("30-trends");
  const wcard = page.locator("section.card:has(.seg)").first();
  for (const r of ["1M", "3M", "1Y", "All"]) {
    await page.tap(`.seg >> text=${r}`);
    await page.waitForTimeout(50);
    await wcard.screenshot({ path: path.join(OUT, `${SCHEME}-31-weight-${r}.png`) });
  }
  await page.tap(".seg >> text=3M");
  const wb = await wcard.locator("svg.chart").boundingBox();
  await page.touchscreen.tap(wb.x + wb.width * 0.5, wb.y + wb.height / 2);
  await page.waitForTimeout(100);
  const ro = await wcard.locator(".readout").textContent();
  check("weight scrub shows a dated reading", /lb/.test(ro) && /trend/.test(ro), ro);
  await wcard.screenshot({ path: path.join(OUT, `${SCHEME}-32-weight-scrub.png`) });

  // Compare overlays: a line on the weight chart with its own labeled right scale.
  for (const [name, re] of [["Steps", /steps/], ["Sleep", /h sleep/], ["Cal", /kcal/]]) {
    await page.tap(`.compare >> text=${name}`);
    const rightTicks = await wcard.locator("svg.chart text.tick.right").count();
    const drawn = (await wcard.locator("svg.chart .overlay-line").count()) > 0;
    const legend = await wcard.locator(".legend").innerText();
    const dot = await wcard.locator("svg.chart circle.s1.end").boundingBox();
    await page.touchscreen.tap(dot.x + dot.width / 2, dot.y + 40);
    await page.waitForTimeout(80);
    const txt = await wcard.locator(".readout").textContent();
    check(`${name} overlay line with right scale`, rightTicks >= 2 && drawn && /right scale/.test(legend) && re.test(txt), `${rightTicks} ticks; ${txt}`);
    await wcard.screenshot({ path: path.join(OUT, `${SCHEME}-33-overlay-${name}.png`) });
  }
  await page.tap(".seg >> text=1Y");
  await page.tap(`.compare >> text=Steps`);
  check("1Y overlay uses weekly averages", (await wcard.locator(".legend").innerText()).includes("weekly average"));
  await wcard.screenshot({ path: path.join(OUT, `${SCHEME}-34-overlay-1y.png`) });
  await page.tap(".seg >> text=3M");
  await page.tap(`.compare >> text=RHR`);
  check("resting HR overlay", (await wcard.locator(".legend").innerText()).includes("Resting heart rate"));
  await page.tap(`.compare >> text=Off`);
  check("overlay off removes the line", (await wcard.locator("svg.chart .overlay-line").count()) === 0 && (await wcard.locator("svg.chart text.tick.right").count()) === 0);

  // Trends is in sections now: a summary first, then one section at a time.
  const chips = await page.locator(".trend-chip").allTextContents();
  check("Trends has its section chips", chips.join("|") === "Summary|Weight|Food|Meds|Body|Training|More", chips.join("|"));
  const tiles = page.locator(".sum-tile");
  check("summary shows five tiles", (await tiles.count()) === 5 && /Recovery\s*3 of 4 off/.test(await tiles.nth(4).innerText()) && /Weight\s*2\d\d\.\d lb/.test(await tiles.nth(0).innerText()), (await tiles.allInnerTexts()).map((t) => t.replace(/\n/g, " ")).join(" | "));
  check("summary doesn't draw every card", (await page.locator("section.card h2:text-is('Heart')").count()) === 0 && (await page.locator("section.card").count()) <= 2);
  await page.locator(".trend-nav").screenshot({ path: path.join(OUT, `${SCHEME}-29-trend-nav.png`) });
  await tiles.nth(4).tap();
  await page.waitForTimeout(200);
  check("a summary tile opens its section", (await page.locator(".trend-chip[aria-current=page]").textContent()) === "Body" && (await page.locator("section.card h2:text-is('Off your normal')").count()) === 1 && (await page.evaluate(() => localStorage.getItem("log.trendsSection"))) === "body");
  const go = async (label) => {
    await page.locator(`.trend-chip:text-is("${label}")`).tap();
    await page.waitForTimeout(200);
  };
  const sections = { Food: ["Calories and protein", "Maintenance calories", "Protein target", "Food thoughts"], Meds: ["The week after a shot", "Appetite by drug level", "Retatrutide vs tirzepatide"], Body: ["Off your normal", "Heart", "More from Apple Health"], Weight: ["Weight", "Body composition"], Training: ["Steps", "Workouts"] };
  for (const [label, titles] of Object.entries(sections)) {
    await go(label);
    for (const t of titles) check(`Trends > ${label} shows ${t}`, (await page.locator(`section.card h2:text-is("${t}")`).count()) === 1);
  }

  await go("Body");
  const more = page.locator("section.card:has(h2:text-is('More from Apple Health'))");
  check("More from Apple Health groups its rows", (await more.locator(".hm-group").allInnerTexts()).join("|") === "Heart and breathing|Sleep|Energy and food|Activity" && (await more.locator(".hm-row").count()) === 10, (await more.locator(".hm-group").allInnerTexts()).join("|"));
  const tk = more.locator(".hm-row", { hasText: "Total energy burned" });
  await tk.locator("summary").evaluate((n) => n.scrollIntoView({ block: "center" }));
  await page.waitForTimeout(400);
  await tk.locator("summary").tap();
  await page.waitForTimeout(300);
  check("a metric row opens to a chart", (await tk.locator(".hm-chart svg").count()) >= 1);
  await more.screenshot({ path: path.join(OUT, `${SCHEME}-37-more-health.png`) });
  await tk.locator("summary").tap();
  // Off your normal on Trends
  const on = page.locator("section.card:has(h2:text-is('Off your normal'))");
  const onText = await on.innerText();
  check("off-normal history marks flagged days", (await on.locator(".off-strip span").count()) === 60 && (await on.locator(".off-strip .flag").count()) >= 2 && /Nov 10/.test(onText) && /Today: 3 of 4 signals off/.test(onText), onText.replace(/\n/g, " | "));
  await on.screenshot({ path: path.join(OUT, `${SCHEME}-53-off-normal-trends.png`) });
  await page.locator("section.card:has(h2:text-is('Heart'))").screenshot({ path: path.join(OUT, `${SCHEME}-36-heart.png`) });

  await go("Weight");
  const bc = await page.locator("section.card:has(h2:text-is('Body composition'))").innerText();
  check("body composition tiles", /BMI\s*34\.2/.test(bc) && /Body fat\s*35\.2%/.test(bc) && /Loss that was lean/.test(bc), bc.replace(/\n/g, " | "));
  await page.locator("section.card:has(h2:text-is('Body composition'))").screenshot({ path: path.join(OUT, `${SCHEME}-37-body.png`) });

  await go("Food");
  // Maintenance calories: from food logs + weight trend, and the watch's figure.
  const mc = page.locator("section.card:has(h2:text-is('Maintenance calories'))");
  const mcText = await mc.innerText();
  check("maintenance from food logs and weight", /About 2,[5-9]\d0 kcal a day/.test(mcText) && /From your food logs and weight trend/.test(mcText) && /Apple Watch says\s*2,[5-9]\d\d kcal a day \(2[5-9] days\)/.test(mcText) && /Food logs and weight say\s*2,[5-9]\d\d kcal a day/.test(mcText), mcText.replace(/\n/g, " | "));
  check("maintenance skips the day the watch was off", !/\(28 days\)/.test(mcText));
  check("maintenance compares the target", /Eating 2,200\s*[\d,]+ kcal under the watch, about \d\.\d lb a week/.test(mcText));
  await mc.locator("svg.chart").evaluate((n) => n.scrollIntoView({ block: "center" }));
  await page.waitForTimeout(500);
  const mb = await mc.locator("svg.chart").boundingBox();
  await page.touchscreen.tap(mb.x + mb.width * 0.6, mb.y + mb.height / 2);
  await page.waitForTimeout(100);
  check("maintenance chart scrubs to a day", /kcal burned|Watch day skipped/.test(await mc.locator(".readout").textContent()), await mc.locator(".readout").textContent());
  await mc.screenshot({ path: path.join(OUT, `${SCHEME}-50-maintenance.png`) });
  await page.locator("section.card:has(h2:text-is('Food thoughts'))").screenshot({ path: path.join(OUT, `${SCHEME}-39-thoughts.png`) });

  await go("Meds");
  check("meds keeps the switch comparison and drops long-run timing", (await page.locator("h2:text-is('Long-run timing')").count()) === 0 && (await page.locator("h2:text-is('Retatrutide vs tirzepatide')").count()) === 1 && (await page.locator("h2:text-is('The week after a shot')").count()) === 1);
  // Appetite by drug level
  const ab = page.locator("section.card:has(h2:text-is('Appetite by drug level'))");
  const abText = await ab.innerText();
  check("appetite by level compares low and high", /Food noise runs \d\.\d points lower when the level is high/.test(abText) && /Right now: \d+% of peak/.test(abText) && (await ab.locator(".bar-row").count()) === 6, abText.replace(/\n/g, " | "));
  await ab.screenshot({ path: path.join(OUT, `${SCHEME}-51-appetite-level.png`) });
  // Reta vs tirz: baseline filled before the switch, with heart and energy.
  const rv = page.locator("section.card:has(h2:text-is('Retatrutide vs tirzepatide'))");
  const rvText = await rv.innerText();
  check("reta vs tirz shows the tirzepatide baseline", /tirzepatide baseline/.test(rvText) && /Resting heart rate\s*6\d bpm/.test(rvText) && /Burned a day\s*2,\d{3} kcal/.test(rvText) && /HRV\s*\d+ ms/.test(rvText), rvText.replace(/\n/g, " | "));
  await rv.screenshot({ path: path.join(OUT, `${SCHEME}-52-reta-vs-tirz.png`) });
  const swk = page.locator(".shotweek").first();
  check("week-after-shot table has data", (await swk.locator(".sw-cell:not(.none)").count()) >= 6);
  await page.locator("section.card:has(h2:text-is('The week after a shot'))").screenshot({ path: path.join(OUT, `${SCHEME}-35-shotweek.png`) });

  await go("Training");
  check("training shows steps and workouts, not a running card", (await page.locator("h2:text-is('Running')").count()) === 0 && (await page.locator("h2:text-is('Steps')").count()) === 1 && (await page.locator("h2:text-is('Workouts')").count()) === 1);
  await page.locator("section.card:has(h2:text-is('Steps'))").screenshot({ path: path.join(OUT, `${SCHEME}-38-steps.png`) });
  await go("Summary");

  // Log
  await page.tap(".tabnav >> text=Log");
  await page.waitForSelector(".chips");
  await shot("40-log");
  await page.tap(".checkin-form >> text=Ate less");
  await page.tap(".checkin-form >> text=Moved more");
  await page.tap(".checkin-form >> text=Strong");
  await page.$eval(".checkin-form [name=energy]", (r) => { r.value = "6"; r.dispatchEvent(new Event("input", { bubbles: true })); });
  // A background refresh or a rotate must not wipe a half-filled form.
  await page.evaluate(async () => { await load(true, true); window.dispatchEvent(new Event("resize")); });
  await page.waitForTimeout(250);
  await save("text=Save check-in", ".toast.ok");
  const lw = writes[writes.length - 1];
  check("Log check-in saves the full check-in", lw.action === "checkin_upsert" && lw.payload.day === "2026-11-24" && lw.payload.ate_vs_usual === "less" && lw.payload.moved_vs_usual === "more" && lw.payload.dose_feel === "strong" && lw.payload.energy === 6, JSON.stringify(lw));
  await page.fill("[name=weight_lb]", "256.4");
  await save("text=Save weigh-in", ".toast.ok >> text=Logged 256.4 lb.");
  check("weigh-in writes", writes[writes.length - 1].action === "weigh_in" && writes[writes.length - 1].payload.weight_lb === "256.4");
  await save("text=Yes, earned it", ".toast.ok >> text=Earned it.");
  check("earn it writes", writes[writes.length - 1].action === "earn_it" && writes[writes.length - 1].payload.earned === true);

  for (const t of ["Log a dose", "Side effect", "Measurement", "Start a vial", "Reconstitution calculator"]) {
    const ft = page.locator(`.fold-title >> text=${t}`);
    await ft.evaluate((n) => n.scrollIntoView({ block: "center" }));
    await ft.tap();
  }
  await page.waitForTimeout(100);
  await shot("41-log-open");
  // dose
  check("dose sites use plain names", (await page.locator(".chips[data-name=site] .chip").allTextContents()).join("|") === "Lower right belly|Lower left belly|Upper right belly|Upper left belly|Left love handle|Right love handle");
  await page.tap(".chips[data-name=site] >> text=Right love handle");
  await save("text=Save dose", ".toast.ok >> text=Logged tirzepatide 3 mg.");
  const dw = writes[writes.length - 1];
  check("dose writes with site", dw.action === "dose_log" && dw.payload.site === "Love R" && String(dw.payload.dose_mg) === "3", JSON.stringify(dw));
  check("folds stay open after a save", await page.$eval("details.fold:has(.fold-title:text-is('Side effect'))", (d) => d.open).catch(() => false));
  // side effect
  await page.fill("[name=effect]", "Nausea");
  await save("text=Save side effect", ".toast.ok >> text=Logged Nausea.");
  check("side effect writes", writes[writes.length - 1].action === "side_effect_upsert");
  // measurement
  await page.fill("[name=value]", "44.5");
  await save("text=Save measurement", ".toast.ok >> text=Saved measurement.");
  check("measurement writes", writes[writes.length - 1].payload.metric === "waist" && writes[writes.length - 1].payload.value === "44.5");
  // vial
  await page.fill("[name=total_mg]", "20");
  await save("text=Save vial", ".toast.ok >> text=Vial added.");
  check("vial writes", writes[writes.length - 1].action === "vial_start");
  // recon calc
  await page.fill("[name=vial_mg]", "10");
  await page.fill("[name=want_mg]", "2");
  check("reconstitution calculator", (await page.textContent(".calc-out")).includes("Draw 20.0 units"));
  check("Log shows which build this is", (await page.textContent(".app-version")) === "Log, development copy");
  await page.evaluate(() => { window.LOG_VERSION = { version: "1.1", build: 14, commit: "abc1234", built: "2026-11-25T12:00:00Z" }; render(); });
  check("version reads as version and build", (await page.textContent(".app-version")) === "Log 1.1 (build 14), built Wed, Nov 25", await page.textContent(".app-version"));
  await shot("42-log-after");

  // Lock returns to the gate and clears the passcode
  await page.tap(".tabnav >> text=Today");
  await page.tap("[aria-label=Lock]");
  await page.waitForSelector(".gate");
  check("lock clears passcode", (await page.evaluate(() => localStorage.getItem("log.passcode"))) === null);

  console.log(`writes recorded: ${writes.length}`);
  console.log(errors.length ? `FAILED (${SCHEME}):\n${errors.join("\n")}` : `ALL PASS (${passed} checks, ${SCHEME})`);
  await browser.close();
  server.close();
  process.exit(errors.length ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(2); });
