// The page inside the native shell (iPhone app 1.2+): LogShell.swift sets window.LOG_NATIVE and
// answers messages on window.webkit.messageHandlers.logShell. Here a stand-in plays the shell,
// with a fake Keychain kept in localStorage under "__keychain" so it survives a reload.
const { chromium } = require("playwright");
const { serve, checker, makeFixture, BASE, SHOTS, API, CLOCK, PASSCODE, CORS: cors } = require("./lib");
const fixture = makeFixture();
const check = checker();

(async () => {
  const server = await serve();
  const browser = await chromium.launch();
  const ctx = await browser.newContext({ viewport: { width: 393, height: 852 }, isMobile: true, hasTouch: true, serviceWorkers: "block" });
  const page = await ctx.newPage();
  await page.clock.setFixedTime(CLOCK);
  const errors = [];
  page.on("pageerror", (e) => errors.push(e.message));
  await page.addInitScript(() => {
    window.__posted = [];
    window.LOG_NATIVE = Object.freeze({ tabs: true, keychain: true, version: "1.2", build: "9" });
    const kc = { get: () => localStorage.getItem("__keychain") || "", set: (v) => localStorage.setItem("__keychain", v), clear: () => localStorage.removeItem("__keychain") };
    window.webkit = { messageHandlers: { logShell: { postMessage: (m) => {
      window.__posted.push(m);
      if (m.type === "getPasscode") return Promise.resolve(kc.get());
      if (m.type === "setPasscode") kc.set(m.passcode);
      if (m.type === "clearPasscode") kc.clear();
      return Promise.resolve(true);
    } } } };
  });
  // 1.1 kept the passcode in the web view's storage.
  await page.addInitScript((code) => { if (!sessionStorage.getItem("__seeded")) { sessionStorage.setItem("__seeded", "1"); localStorage.setItem("log.passcode", code); } }, PASSCODE);
  await page.route(API, (route) => {
    const req = route.request();
    if (req.method() === "OPTIONS") return route.fulfill({ status: 204, headers: cors });
    if (req.headers()["x-log-passcode"] !== PASSCODE) return route.fulfill({ status: 401, headers: { ...cors, "content-type": "application/json" }, body: '{"ok":false,"error":"unauthorized"}' });
    return route.fulfill({ status: 200, headers: { ...cors, "content-type": "application/json" }, body: req.url().endsWith("/log-dashboard") ? JSON.stringify(fixture) : '{"ok":true}' });
  });

  await page.goto(BASE);
  await page.waitForSelector(".hero-num");
  const posted = () => page.evaluate(() => window.__posted.map((m) => ({ ...m })));
  let msgs = await posted();
  check("moves 1.1's passcode into the Keychain", msgs.some((m) => m.type === "getPasscode") && msgs.some((m) => m.type === "setPasscode" && m.passcode === PASSCODE)
    && (await page.evaluate(() => localStorage.getItem("log.passcode"))) === null && (await page.evaluate(() => localStorage.getItem("__keychain"))) === PASSCODE, JSON.stringify(msgs));
  check("the page's own tab bar steps aside", await page.evaluate(() => document.documentElement.classList.contains("native-tabs") && getComputedStyle(document.querySelector(".tabnav")).display === "none"));
  check("tells the shell it's unlocked, on Today", msgs.some((m) => m.type === "locked" && m.locked === false) && msgs.some((m) => m.type === "tab" && m.tab === "today"));
  await page.screenshot({ path: `${SHOTS}/shell-today.png` });

  // The native tab bar picks Trends.
  await page.evaluate(() => window.logShellSelectTab("trends"));
  await page.waitForTimeout(200);
  check("a native tab switches the page", (await page.textContent("h1")) === "Trends");
  // The page switches on its own ("Details" on Today's Medication card): the shell is told.
  await page.evaluate(() => window.logShellSelectTab("today"));
  await page.waitForTimeout(200);
  await page.evaluate(() => { window.__posted.length = 0; });
  await page.locator("section.card:has(h2:text-is('Medication')) button.link").first().tap();
  await page.waitForTimeout(200);
  msgs = await posted();
  check("a page link to Meds moves the native tab too", (await page.textContent("h1")) === "Meds" && msgs.some((m) => m.type === "tab" && m.tab === "meds"), JSON.stringify(msgs));

  // Reload: the passcode now comes from the Keychain alone.
  await page.reload();
  await page.waitForSelector(".hero-num");
  check("opens from the Keychain after a restart", (await page.evaluate(() => localStorage.getItem("log.passcode"))) === null);

  // Lock: clears the Keychain and hides the tab bar.
  await page.evaluate(() => { window.__posted.length = 0; });
  await page.tap("[aria-label=Lock]");
  await page.waitForSelector(".gate");
  msgs = await posted();
  check("Lock clears the Keychain and hides the tabs", msgs.some((m) => m.type === "clearPasscode") && msgs.some((m) => m.type === "locked" && m.locked === true) && (await page.evaluate(() => localStorage.getItem("__keychain"))) === null, JSON.stringify(msgs));

  // Unlock again: saved to the Keychain, not the web view.
  await page.tap(".pin-pad");
  await page.keyboard.type(PASSCODE);
  await page.keyboard.press("Enter");
  await page.waitForSelector(".hero-num");
  check("unlocking saves to the Keychain only", (await page.evaluate(() => localStorage.getItem("__keychain"))) === PASSCODE && (await page.evaluate(() => localStorage.getItem("log.passcode"))) === null);
  // Native screens lock and unlock the page by calling these.
  check("the page has lock() and boot() for the native lock screen", await page.evaluate(() => typeof window.lock === "function" && typeof window.boot === "function"));

  // With the app's native Apple Health sync on, the web sync stays off and pull to refresh asks the app.
  const p2 = await ctx.newPage();
  await p2.addInitScript(() => {
    window.__posted = [];
    window.LOG_NATIVE = Object.freeze({ tabs: true, keychain: true, healthSync: true, version: "2.0", build: "9" });
    window.Capacitor = { isNativePlatform: () => true, Plugins: { Health: { isHealthAvailable: async () => ({ available: true }) } } };
    window.webkit = { messageHandlers: { logShell: { postMessage: (m) => { window.__posted.push(m); return Promise.resolve(m.type === "getPasscode" ? localStorage.getItem("__keychain") || "" : true); } } } };
  });
  p2.on("pageerror", (e) => errors.push(e.message));
  await p2.goto(BASE);
  await p2.waitForSelector(".hero-num");
  check("native Health sync turns the web sync off", await p2.evaluate(() => canSyncHealth() === false && document.documentElement.classList.contains("ptr-on")));
  await p2.close();
  check("no page errors", errors.length === 0, errors.join("; "));

  await browser.close();
  server.close();
  const failed = check.failed();
  console.log(failed.length ? `FAILED:\n${failed.join("\n")}` : `ALL PASS (${check.count()} checks)`);
  process.exit(failed.length ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(2); });
