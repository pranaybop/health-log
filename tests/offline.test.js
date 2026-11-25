// Opens with the last data: from the saved copy while refreshing, and offline. In a browser the
// shell comes from the service worker (the iPhone app has its files built in).
const { chromium } = require("playwright");
const { serve, checker, makeFixture, BASE, SHOTS, API, CLOCK, CORS: cors } = require("./lib");
const fixture = makeFixture();
const check = checker();

(async () => {
  const server = await serve();
  const browser = await chromium.launch();
  const ctx = await browser.newContext({ viewport: { width: 430, height: 932 }, isMobile: true, hasTouch: true, serviceWorkers: "allow" });
  const page = await ctx.newPage();
  await page.clock.setFixedTime(CLOCK);
  await page.addInitScript(() => { if (!localStorage.getItem("log.passcode")) localStorage.setItem("log.passcode", "2468"); });
  let mode = "ok";
  await page.route(API, async (route) => {
    if (route.request().method() === "OPTIONS") return route.fulfill({ status: 204, headers: cors });
    if (mode === "slow") await new Promise((r) => setTimeout(r, 4000));
    if (mode === "down") return route.abort("internetdisconnected");
    return route.fulfill({ status: 200, headers: { ...cors, "content-type": "application/json" }, body: JSON.stringify(fixture) });
  });

  await page.goto(BASE);
  await page.waitForSelector(".hero-num");
  check("first load saves the data on the phone", (await page.evaluate(() => (localStorage.getItem("log.cache") || "").length)) > 1000);
  await page.evaluate(() => navigator.serviceWorker.ready.then(() => true));
  await page.reload();
  await page.waitForSelector(".hero-num");
  check("service worker controls the page", await page.evaluate(() => !!navigator.serviceWorker.controller));

  // Slow network: the saved data shows at once, and the header says it's refreshing.
  mode = "slow";
  const t0 = Date.now();
  await page.reload();
  await page.waitForSelector(".hero-num");
  const ms = Date.now() - t0;
  const eyebrow = await page.evaluate(() => { state.tab = "trends"; render(); return document.querySelector(".eyebrow-date").textContent; });
  check("opens with saved data before the refresh finishes", ms < 2500 && /Saved data from/.test(eyebrow), `${ms} ms, "${eyebrow}"`);
  await page.waitForTimeout(4500);
  check("then refreshes in place", /Updated/.test(await page.textContent(".eyebrow-date")));

  // Offline: the shell comes from the service worker and the data from the saved copy.
  mode = "down";
  await ctx.setOffline(true);
  await page.reload();
  await page.waitForSelector(".hero-num", { timeout: 8000 }).catch(() => {});
  const num = await page.textContent(".hero-num").catch(() => "");
  check("opens offline with the last data", num.includes("238.6"), num);
  await page.evaluate(() => { state.tab = "trends"; render(); });
  check("offline says it couldn't refresh", /Couldn’t refresh/.test(await page.textContent(".eyebrow-date")));
  await page.screenshot({ path: `${SHOTS}/offline.png` });
  await ctx.setOffline(false);

  // Lock clears the saved copy.
  await page.tap('[aria-label="Lock"]');
  check("lock removes saved data", (await page.evaluate(() => localStorage.getItem("log.cache"))) === null);
  await browser.close();
  server.close();
  const failed = check.failed();
  console.log(failed.length ? `FAILED:\n${failed.join("\n")}` : `ALL PASS (${check.count()} checks)`);
  process.exit(failed.length ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(2); });
