// Nothing on any tab may be wider than the screen (iOS lets a wider page zoom, so a double tap
// zooms it). Checks every tab at iPhone widths with every fold and the check-in open.
const { chromium } = require("playwright");
const { serve, checker, makeFixture, BASE, SHOTS, API, CLOCK, CORS: cors } = require("./lib");
const fixture = makeFixture();
const check = checker();
(async () => {
  const server = await serve();
  const browser = await chromium.launch();
  for (const width of [320, 375, 390, 430]) {
    const ctx = await browser.newContext({ viewport: { width, height: 900 }, isMobile: true, hasTouch: true, serviceWorkers: "block" });
    const page = await ctx.newPage();
    await page.clock.setFixedTime(CLOCK);
    await page.addInitScript(() => localStorage.setItem("log.passcode", "2468"));
    await page.route(API, (route) => {
      const req = route.request();
      if (req.method() === "OPTIONS") return route.fulfill({ status: 204, headers: cors });
      return route.fulfill({ status: 200, headers: { ...cors, "content-type": "application/json" }, body: req.url().endsWith("/log-dashboard") ? JSON.stringify(fixture) : '{"ok":true}' });
    });
    await page.goto(BASE);
    await page.waitForSelector(".hero-num");
    // Page width with the #app clip guard switched off, so a real overflow still fails here.
    const measure = () => page.evaluate(() => {
      const app = document.getElementById("app");
      app.style.overflowX = "visible";
      const vw = document.documentElement.clientWidth;
      const scrollW = document.documentElement.scrollWidth;
      const wide = [...document.querySelectorAll("#app *")].filter((n) => {
        if (!n.checkVisibility() || getComputedStyle(n).position === "fixed") return false;
        if (n.closest(".table-scroll") && n.closest(".table-scroll").getBoundingClientRect().right <= vw + 0.5) return false;
        return n.getBoundingClientRect().right > vw + 0.5;
      });
      const leaves = wide.filter((n) => !wide.some((m) => m !== n && n.contains(m)));
      app.style.overflowX = "";
      return { vw, scrollW, n: wide.length, leaves: leaves.slice(0, 4).map((n) => `${n.tagName.toLowerCase()}.${String(n.className.baseVal ?? n.className)} →${Math.round(n.getBoundingClientRect().right)}`) };
    });
    const openAll = () => page.evaluate(() => document.querySelectorAll("#app details").forEach((d) => (d.open = true)));
    const views = [];
    views.push(["Today", await measure()]);
    await page.evaluate(() => { state.checkinOpen = true; render(); });
    await page.waitForTimeout(300);
    await openAll();
    views.push(["Today, check-in and folds open", await measure()]);
    await page.evaluate(() => { state.checkinOpen = false; render(); });
    for (const tab of ["Meds", "Trends", "Log"]) {
      await page.tap(`.tabnav >> text=${tab}`);
      await page.waitForTimeout(300);
      await openAll();
      await page.waitForTimeout(200);
      views.push([`${tab}, folds open`, await measure()]);
    }
    for (const [name, m] of views) check(`${width}px ${name}: fits the screen`, m.n === 0 && m.scrollW <= m.vw, m.n ? `${m.n} too wide: ${m.leaves.join(" | ")}` : "");
    if (width === 375) {
      await page.tap(".tabnav >> text=Log");
      const fold = page.locator("details", { has: page.locator("summary", { hasText: "Log a dose" }) });
      await fold.evaluate((d) => { d.open = true; d.scrollIntoView({ block: "start" }); });
      await page.waitForTimeout(300);
      const rows = await fold.locator('.chips[data-name="site"] .chip').evaluateAll((cs) => new Set(cs.map((c) => Math.round(c.getBoundingClientRect().top))).size);
      check("site buttons stay three across", rows === 2, `${rows} rows`);
      await page.screenshot({ path: `${SHOTS}/dose-sites-375.png` });
    }
    await ctx.close();
  }
  await browser.close();
  server.close();
  const failed = check.failed();
  console.log(failed.length ? `FAILED:\n${failed.join("\n")}` : `ALL PASS (${check.count()} checks)`);
  process.exit(failed.length ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(2); });
