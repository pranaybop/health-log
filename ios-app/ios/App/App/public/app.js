const API_URL = "https://qnbshmenmurdaogslmrj.supabase.co/functions/v1/log-dashboard";
const TZ = "America/Chicago";
// Opens the Log bot in the Grok Bot app. Same value as LogBot.urlString in LogNative.
const LOG_BOT_URL = "grokbot://app/v1/agent?id=81acb34c-2ba4-4bde-aa1b-98e865272965";
const LOG_BOT_UNAVAILABLE = "Grok Bot isn’t installed.";
const HALF_LIFE_DAYS = 5;
const RETA_START = new Date("2026-12-06T12:00:00-06:00");
const CHECKIN_PROMPT_HOUR = 18; // the "No check-in yet" prompt waits until 6 PM Central
const GOAL_LB = 235;
const TIRZ_START = new Date("2026-11-02T12:00:00-06:00");

const SITE_LABELS = {
  "Abd LR": "Lower right belly",
  "Abd LL": "Lower left belly",
  "Abd UR": "Upper right belly",
  "Abd UL": "Upper left belly",
  "Love L": "Left love handle",
  "Love R": "Right love handle",
};

const PASS_KEY = "log.passcode";
const CACHE_KEY = "log.cache"; // last dashboard payload, so the app opens with data while it refreshes
let lastWidth = 0;

const state = {
  token: "",
  passcode: "",
  data: null,
  error: null,
  loading: true,
  updating: false,
  weightRange: "3m",
  tab: "today",
  formMessage: null,
  formBusy: false,
  explorerX: "weight",
  explorerY: "steps",
  overlay: (() => { try { return localStorage.getItem("log.overlay") || "none"; } catch (_) { return "none"; } })(),
  dayOffset: 0,
  daySlide: null,
  checkinOpen: false,
  fromCache: false,
  effectOpen: false,
  healthBusy: false,
  healthMsg: null,
  healthBackfill: null,
  openMetrics: [],
  editTargets: false,
  targetsBusy: false,
  targetsMsg: null,
  mealBotNote: null,
  gateLetters: false,
  openForms: { threetap: true },
};

function readToken() {
  const raw = (location.hash || "").replace(/^#/, "");
  return new URLSearchParams(raw).get("k") || "";
}

function $(sel) {
  return document.querySelector(sel);
}

function el(tag, attrs, ...kids) {
  const node = document.createElement(tag);
  if (attrs) {
    for (const [k, v] of Object.entries(attrs)) {
      if (v == null || v === false) continue;
      if (k === "class") node.className = v;
      else if (k === "style" && typeof v === "object") Object.assign(node.style, v);
      else if (k.startsWith("on") && typeof v === "function") node.addEventListener(k.slice(2).toLowerCase(), v);
      else if (k === "dataset") Object.assign(node.dataset, v);
      else node.setAttribute(k, v === true ? "" : String(v));
    }
  }
  for (const kid of kids) {
    if (kid == null || kid === false) continue;
    node.append(kid.nodeType ? kid : document.createTextNode(String(kid)));
  }
  return node;
}

function num(v) {
  if (v == null || v === "") return null;
  const n = typeof v === "number" ? v : Number(v);
  return Number.isFinite(n) ? n : null;
}

function fmtNum(v, digits) {
  const n = num(v);
  if (n == null) return "—";
  return n.toLocaleString("en-US", {
    maximumFractionDigits: digits == null ? 0 : digits,
    minimumFractionDigits: digits == null ? 0 : digits,
  });
}

function parseTs(v) {
  if (!v) return null;
  const d = new Date(v);
  return Number.isNaN(d.getTime()) ? null : d;
}

/* Central-time formatting. Building an Intl.DateTimeFormat is slow, and these run thousands of
   times per screen, so the formatters are made once and recent answers are remembered. */
const FMT_PARTS = new Intl.DateTimeFormat("en-US", {
  timeZone: TZ,
  year: "numeric",
  month: "short",
  day: "numeric",
  weekday: "short",
  hour: "numeric",
  minute: "2-digit",
  hour12: true,
});
const FMT_KEY = new Intl.DateTimeFormat("en-CA", { timeZone: TZ, year: "numeric", month: "2-digit", day: "2-digit" });
const FMT_HOUR = new Intl.DateTimeFormat("en-US", { timeZone: TZ, hour: "numeric", hourCycle: "h23" });
const FMT_WEEKDAY = new Intl.DateTimeFormat("en-US", { timeZone: TZ, weekday: "long" });
const FMT_LONG = new Intl.DateTimeFormat("en-US", { timeZone: TZ, weekday: "long", month: "long", day: "numeric" });
const FMT_LONG_YEAR = new Intl.DateTimeFormat("en-US", { timeZone: TZ, weekday: "long", month: "long", day: "numeric", year: "numeric" });
const FMT_MONTH_YEAR = new Intl.DateTimeFormat("en-US", { timeZone: TZ, month: "short", year: "numeric" });

function memoByTime(fn, max) {
  const cache = new Map();
  return (date) => {
    const t = date instanceof Date ? date.getTime() : new Date(date).getTime();
    let v = cache.get(t);
    if (v === undefined) {
      v = fn(new Date(t));
      if (cache.size >= max) cache.delete(cache.keys().next().value);
      cache.set(t, v);
    }
    return v;
  };
}

const partsCached = memoByTime((date) => {
  const map = {};
  for (const p of FMT_PARTS.formatToParts(date)) map[p.type] = p.value;
  return Object.freeze(map);
}, 4000);

function partsInTZ(date) {
  return partsCached(date);
}

const dateKeyCached = memoByTime((date) => FMT_KEY.format(date), 20000);

function dateKeyCT(date) {
  return dateKeyCached(date);
}

function hourCT(date) {
  return Number(FMT_HOUR.format(date)) % 24;
}

function fmtTimeCT(date) {
  const p = partsInTZ(date);
  return `${p.hour}:${p.minute} ${p.dayPeriod.toUpperCase()} CT`;
}

function fmtDateCT(date, withWeekday) {
  const p = partsInTZ(date);
  return withWeekday ? `${p.weekday}, ${p.month} ${p.day}` : `${p.month} ${p.day}`;
}

function fmtDateTimeCT(date) {
  const p = partsInTZ(date);
  return `${p.weekday}, ${p.month} ${p.day}, ${p.year}, ${p.hour}:${p.minute} ${p.dayPeriod.toUpperCase()} CT`;
}

function todayKey() {
  return dateKeyCT(new Date());
}

function daysUntil(date) {
  const a = Date.parse(todayKey() + "T00:00:00Z");
  const b = Date.parse(dateKeyCT(date) + "T00:00:00Z");
  return Math.round((b - a) / 86400000);
}

function daysWord(n) {
  if (n === 0) return "today";
  if (n === 1) return "tomorrow";
  if (n < 0) return `${Math.abs(n)} day${n === -1 ? "" : "s"} ago`;
  return `in ${n} days`;
}

function capitalize(s) {
  return s ? s.charAt(0).toUpperCase() + s.slice(1) : "";
}

function siteLabel(doseOrNotes) {
  let key = "";
  if (doseOrNotes && typeof doseOrNotes === "object") {
    key = (doseOrNotes.site || "").trim();
    if (!key && doseOrNotes.notes) {
      const m = String(doseOrNotes.notes).match(/site\s+([^;]+)/i);
      if (m) key = m[1].trim();
    }
  } else if (doseOrNotes) {
    const m = String(doseOrNotes).match(/site\s+([^;]+)/i);
    key = m ? m[1].trim() : String(doseOrNotes).trim();
  }
  if (!key) return "—";
  return SITE_LABELS[key] || key;
}

function authHeaders() {
  const headers = {};
  if (state.token) headers["x-log-token"] = state.token;
  else if (state.passcode) headers["x-log-passcode"] = state.passcode;
  return headers;
}

function hasCredential() {
  return Boolean(state.token || state.passcode);
}

async function fetchData() {
  // Simulator check in CI only (debug builds with "-demo"): made-up data shipped as demo.json.
  if (window.LOG_DEMO) return (await fetch("demo.json", { cache: "no-store" })).json();
  const res = await fetch(API_URL, {
    headers: authHeaders(),
    cache: "no-store",
    referrerPolicy: "no-referrer",
  });
  if (res.status === 401) throw new Error("unauthorized");
  if (!res.ok) throw new Error("Could not load the log.");
  return res.json();
}

async function load(isRefresh, background) {
  if (!hasCredential()) {
    state.loading = false;
    state.data = null;
    render();
    return;
  }
  if (isRefresh) state.updating = true;
  else {
    state.loading = true;
    state.error = null;
  }
  if (!background) render();
  try {
    const data = await fetchData();
    state.data = data;
    state.fromCache = false;
    state.error = null;
    try { localStorage.setItem(CACHE_KEY, JSON.stringify(data)); } catch (_) { /* full or private mode: skip */ }
    if (state.passcode && !state.token) storePasscode(state.passcode);
  } catch (err) {
    const unauthorized = err.message === "unauthorized";
    if (unauthorized && state.passcode && !state.token) {
      state.passcode = "";
      clearPasscode();
      try { localStorage.removeItem(CACHE_KEY); } catch (_) { /* ignore */ }
      state.data = null;
      state.error = "bad-passcode";
    } else if (!state.data) {
      state.error = unauthorized ? "unauthorized" : "load-failed";
    } else {
      state.error = "refresh-failed";
    }
  } finally {
    state.loading = false;
    state.updating = false;
    // A background refresh never redraws the Log tab, so half-filled forms survive.
    if (background && (state.tab === "log" || state.checkinOpen || state.editTargets) && state.data) {
      const btn = document.querySelector('.icon-btn[aria-label="Refresh"]');
      if (btn) btn.disabled = state.formBusy;
    } else {
      render();
    }
  }
}

async function submitPasscode(value) {
  const code = (value || "").trim();
  if (!code) {
    state.error = "empty-passcode";
    render();
    return;
  }
  state.passcode = code;
  state.token = "";
  state.error = null;
  await load(false);
}

function lock() {
  state.passcode = "";
  state.token = "";
  state.data = null;
  state.error = null;
  state.loading = false;
  state.updating = false;
  clearPasscode();
  try { localStorage.removeItem(CACHE_KEY); } catch (_) { /* ignore */ }
  if (location.hash) {
    history.replaceState(null, "", location.pathname + location.search);
  }
  render();
}

/* ---------- small building blocks ---------- */

const ICONS = {
  today: '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="3.5" y="5" width="17" height="15.5" rx="3.5"/><path d="M3.5 10h17M8 3v4M16 3v4"/></svg>',
  meds: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M9 3h6M10 3v4.6L6.4 17.4A2.6 2.6 0 0 0 8.8 21h6.4a2.6 2.6 0 0 0 2.4-3.6L14 7.6V3"/><path d="M7.6 14h8.8"/></svg>',
  trends: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M3.5 19.5h17"/><path d="M5 15.5l4.5-5 3.5 3.5L19.5 7"/></svg>',
  log: '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="4" y="4" width="16" height="16" rx="4.5"/><path d="M12 8.5v7M8.5 12h7"/></svg>',
  refresh: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M19.5 11.5a7.5 7.5 0 1 1-2.2-5.3"/><path d="M19.5 4.5v5h-5"/></svg>',
  lock: '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="5" y="10.5" width="14" height="10" rx="2.8"/><path d="M8.5 10.5V7.8a3.5 3.5 0 0 1 7 0v2.7"/></svg>',
};

function icon(name) {
  const s = el("span", { class: "icon" });
  s.innerHTML = ICONS[name];
  return s;
}

function prop(k, v) {
  return el("div", { class: "prop" },
    el("span", { class: "k" }, k),
    el("span", { class: "v" }, v),
  );
}

function card(title, ...kids) {
  return el("section", { class: "card" }, title ? el("h2", null, title) : null, ...kids);
}

function cardWithAction(title, action, ...kids) {
  return el("section", { class: "card" },
    el("div", { class: "card-head" }, el("h2", null, title), action),
    ...kids,
  );
}

function metric(label, value, detail, feature) {
  return el("div", { class: feature ? "metric feature" : "metric" },
    el("span", { class: "label" }, label),
    el("span", { class: "value" }, value),
    detail ? el("span", { class: "detail" }, detail) : null,
  );
}

/* A line above a chart that shows the latest value, and the scrubbed value while dragging. */
function readout(defaultMain, defaultSub) {
  const main = el("span", { class: "ro-main" }, defaultMain);
  const sub = el("span", { class: "ro-sub" }, defaultSub || "");
  const node = el("div", { class: "readout" }, main, sub);
  return {
    node,
    set(m, s) { main.textContent = m; sub.textContent = s || ""; node.classList.add("live"); },
    reset() { main.textContent = defaultMain; sub.textContent = defaultSub || ""; node.classList.remove("live"); },
  };
}

function signed(v, digits) {
  const n = num(v);
  if (n == null) return "—";
  const s = fmtNum(Math.abs(n), digits == null ? 1 : digits);
  return n > 0 ? `+${s}` : n < 0 ? `−${s}` : s;
}

function isStandalone() {
  return (window.matchMedia && window.matchMedia("(display-mode: standalone)").matches) || window.navigator.standalone === true;
}

/* ---------- data helpers ---------- */

function todayTotals(data) {
  return totalsOn(data, todayKey());
}

function todayMeals(data) {
  return mealsOn(data, todayKey());
}

function totalsOn(data, key) {
  const row = (data.daily_totals || []).find((d) => d.date === key);
  if (row) return row;
  const meals = mealsOn(data, key);
  if (!meals.length) return null;
  const sum = (f) => meals.reduce((a, m) => a + (num(m[f]) || 0), 0);
  return {
    date: key,
    calories: sum("calories"),
    protein_g: sum("protein_g"),
    carbs_g: sum("carbs_g"),
    fat_g: sum("fat_g"),
    fiber_g: sum("fiber_g"),
    meal_count: meals.length,
  };
}

function mealsOn(data, key) {
  return (data.meals || []).filter((m) => {
    const t = parseTs(m.eaten_at);
    return t && dateKeyCT(t) === key;
  });
}

function healthOn(data, key) {
  return (data.daily_health || []).find((r) => r.day === key) || null;
}

function checkinOn(data, key) {
  return (data.checkins || []).find((c) => c.day === key) || null;
}

/* ---------- which day Today is showing ---------- */

function viewKey() {
  return state.dayOffset ? shiftDay(todayKey(), state.dayOffset) : todayKey();
}

function dayDiff(a, b) {
  return Math.round((Date.parse(a + "T00:00:00Z") - Date.parse(b + "T00:00:00Z")) / 86400000);
}

function earliestDayKey(data) {
  const keys = [];
  const w = (data.weights || [])[0];
  if (w && parseTs(w.measured_at)) keys.push(dateKeyCT(parseTs(w.measured_at)));
  const m = (data.meals || [])[0];
  if (m && parseTs(m.eaten_at)) keys.push(dateKeyCT(parseTs(m.eaten_at)));
  const h = (data.daily_health || [])[0];
  if (h) keys.push(h.day);
  const c = (data.checkins || [])[0];
  if (c) keys.push(c.day);
  return keys.filter(Boolean).sort()[0] || todayKey();
}

/* Days that have something logged, for the dots under the week strip. */
function loggedDays(data) {
  const set = new Set();
  for (const w of data.weights || []) { const t = parseTs(w.measured_at); if (t) set.add(dateKeyCT(t)); }
  for (const m of data.meals || []) { const t = parseTs(m.eaten_at); if (t) set.add(dateKeyCT(t)); }
  for (const c of data.checkins || []) if (c.day) set.add(c.day);
  return set;
}

function goToDay(data, offset) {
  const min = dayDiff(earliestDayKey(data), todayKey());
  const next = Math.max(min, Math.min(0, offset));
  const cur = state.dayOffset || 0;
  if (next === cur) return;
  state.daySlide = next > cur ? "next" : "prev";
  state.dayOffset = next;
  state.editTargets = false;
  state.targetsMsg = null;
  state.checkinOpen = false;
  state.formMessage = null;
  render();
}

function dayTitle(key) {
  const off = dayDiff(key, todayKey());
  if (off === 0) return "Today";
  if (off === -1) return "Yesterday";
  const d = keyToNoon(key);
  if (off > -7) return FMT_WEEKDAY.format(d);
  return fmtDateYearCT(d);
}

function latestHealth(data) {
  const rows = (data.daily_health || []).filter((r) => r.steps != null || r.sleep_hours != null || r.resting_hr != null);
  return rows.length ? rows[rows.length - 1] : null;
}

const RANGES = [
  { id: "1m", label: "1M", days: 30 },
  { id: "3m", label: "3M", days: 91 },
  { id: "1y", label: "1Y", days: 365 },
  { id: "all", label: "All", days: null },
  { id: "glp1", label: "GLP-1", startFrom: "glp1" },
];

function rangeStartAt(range, data, end, earliest) {
  if (range.startFrom === "glp1") return firstGlp1At(data) || TIRZ_START;
  if (range.days) return new Date(end.getTime() - range.days * 86400000);
  return earliest;
}

/* Calorie and protein targets: a goals row wins (kind "calories" / "protein"); otherwise this device's setting. */
const TARGET_KEY = "log.targets";
const OVERLAY_KEY = "log.overlay";

function readLocalTargets() {
  try {
    const t = JSON.parse(localStorage.getItem(TARGET_KEY) || "null");
    return t && typeof t === "object" ? t : {};
  } catch (_) {
    return {};
  }
}

function saveLocalTargets(t) {
  try { localStorage.setItem(TARGET_KEY, JSON.stringify(t)); } catch (_) { /* ignore */ }
}

function goalTarget(data, kinds) {
  const g = (data.goals || []).find((x) => kinds.includes(String(x.kind || "").toLowerCase())
    && String(x.status || "active").toLowerCase() === "active" && num(x.target) != null);
  return g ? num(g.target) : null;
}

function getTargets(data) {
  const local = readLocalTargets();
  const cal = goalTarget(data, ["calories", "calorie", "kcal"]);
  const pro = goalTarget(data, ["protein", "protein_g"]);
  return {
    calories: cal != null ? cal : num(local.calories),
    protein: pro != null ? pro : num(local.protein),
    fromGoals: cal != null || pro != null,
  };
}

/* ---------- shell ---------- */

const TABS = [
  { id: "today", label: "Today" },
  { id: "meds", label: "Meds" },
  { id: "trends", label: "Trends" },
  { id: "log", label: "Log" },
];

function tabNav() {
  return el("nav", { class: "tabnav", "aria-label": "Sections" },
    ...TABS.map((t) => el("button", {
      type: "button",
      "aria-current": state.tab === t.id ? "page" : null,
      onClick: () => selectTab(t.id),
    }, icon(t.id), el("span", null, t.label))),
  );
}

function renderTopbar(data) {
  const asOf = parseTs(data.as_of) || new Date();
  const title = state.tab === "today" ? dayTitle(viewKey()) : (TABS.find((t) => t.id === state.tab) || TABS[0]).label;
  const updated = state.error === "refresh-failed"
    ? `Couldn’t refresh. Showing data from ${fmtTimeCT(asOf)}.`
    : state.fromCache ? `Saved data from ${fmtTimeCT(asOf).replace(" CT", "")}, refreshing…`
    : state.updating ? "Refreshing…" : `Updated ${fmtTimeCT(asOf).replace(" CT", "")}`;
  const sub = state.tab === "today" ? fmtLongDateYearCT(keyToNoon(viewKey())) : updated;
  return el("header", { class: "topbar" },
    el("div", { class: "titles" },
      el("div", { class: "eyebrow-date" + (state.error === "refresh-failed" && state.tab !== "today" ? " err" : "") }, sub),
      el("h1", null, title),
    ),
    el("div", { class: "top-actions" },
      el("button", { type: "button", class: "icon-btn", "aria-label": "Refresh", disabled: state.updating || state.formBusy, onClick: () => load(true) }, icon("refresh")),
      el("button", { type: "button", class: "icon-btn", "aria-label": "Lock", disabled: state.updating || state.formBusy, onClick: lock }, icon("lock")),
    ),
  );
}

function fmtLongDateCT(date) {
  return FMT_LONG.format(date);
}

function fmtLongDateYearCT(date) {
  const sameYear = partsInTZ(date).year === partsInTZ(new Date()).year;
  return sameYear ? fmtLongDateCT(date)
    : FMT_LONG_YEAR.format(date);
}

function fmtDateYearCT(date) {
  const p = partsInTZ(date);
  const thisYear = partsInTZ(new Date()).year;
  return p.year === thisYear ? fmtDateCT(date, true) : `${fmtDateCT(date, true)}, ${p.year}`;
}

/* ---------- Today ---------- */

function renderHero(data, key) {
  const parsed = parseWeights(data.weights || []);
  if (!parsed.length) {
    return el("section", { class: "hero" }, el("p", { class: "empty" }, "Log a weigh-in on the Log tab to start your journey."));
  }
  if (key && key !== todayKey()) return renderDayWeight(data, parsed, key);
  const sm = smoothWeights(parsed);
  const cur = parsed[parsed.length - 1];
  const trendNow = sm[sm.length - 1].trend;
  const j = journeyStats(data);
  const start = j.startLb;
  const goal = j.goalLb;
  const lost = start - cur.lb;
  const total = goal != null ? start - goal : null;
  const pct = total && total > 0 ? Math.max(0, Math.min(1, lost / total)) : null;
  const rp = recentPace(parsed, 28);

  let pace;
  if (goal != null && cur.lb <= goal) pace = "You’re at or below your goal weight.";
  else if (goal != null && rp && rp.weekly < -0.1) {
    const weeks = (rp.fittedNow - goal) / -rp.weekly;
    const eta = new Date(Date.now() + weeks * 7 * 86400000);
    pace = `At your pace over the last 4 weeks of weigh-ins, ${fmtNum(goal, 0)} lb lands around ${fmtDateYearCT(eta)}.`;
  } else if (goal != null && rp) pace = "Your last 4 weeks of weigh-ins are flat, so there’s no arrival date yet.";
  else if (goal != null) pace = "A few more weigh-ins over the next week will show your pace.";

  const deltaCls = lost > 0 ? "chip good" : lost < 0 ? "chip watch" : "chip";
  return el("section", { class: "hero", "aria-label": "Weight journey" },
    el("div", { class: "hero-num" }, fmtNum(cur.lb, 1), el("span", { class: "unit" }, "lb")),
    el("div", { class: "hero-meta" }, `Weighed ${fmtDateCT(cur.at, true)}, ${fmtTimeCT(cur.at)}`),
    el("div", { class: "hero-chips" },
      el("span", { class: deltaCls }, `${signed(-lost)} lb since start`),
      rp ? el("span", { class: "chip" + (lossRate(data) && lossRate(data).fast ? " watch" : "") }, `${signed(rp.weekly)} lb a week (${fmtNum(Math.abs(rp.weekly / cur.lb) * 100, 1)}%)`) : null,
    ),
    pct != null ? el("div", { class: "course" },
      el("div", { class: "course-track", role: "img", "aria-label": `${fmtNum(lost, 1)} of ${fmtNum(total, 1)} pounds to goal` },
        el("div", { class: "course-fill", style: { width: `${(pct * 100).toFixed(1)}%` } }),
        el("div", { class: "course-dot", style: { left: `${(pct * 100).toFixed(1)}%` } }),
      ),
      el("div", { class: "course-ends" },
        el("span", null, el("b", null, fmtNum(start, 1)), " start"),
        el("span", { class: "mid" }, `${fmtNum(Math.max(0, lost), 1)} of ${fmtNum(total, 1)} lb, ${Math.round(pct * 100)}%`),
        el("span", null, el("b", null, fmtNum(goal, 0)), " goal"),
      ),
    ) : null,
    pace ? el("p", { class: "hero-pace" }, pace) : null,
  );
}

/* Weight on a past day: that day's weigh-in, or the smoothed trend if there wasn't one. */
function renderDayWeight(data, parsed, key) {
  const sm = smoothWeights(parsed);
  const endOfDay = new Date(keyToNoon(key).getTime() + 12 * 3600000);
  const onDay = parsed.filter((w) => dateKeyCT(w.at) === key);
  const before = parsed.filter((w) => dateKeyCT(w.at) < key);
  const trend = trendAt(sm, endOfDay);
  if (!onDay.length && trend == null) {
    return el("section", { class: "hero" }, el("p", { class: "empty" }, "No weigh-ins yet by this day."));
  }
  const cur = onDay[onDay.length - 1] || null;
  const shown = cur ? cur.lb : trend;
  const prev = before[before.length - 1] || null;
  const j = journeyStats(data);
  const inJourney = keyToNoon(key) >= TIRZ_START && j;
  const lost = inJourney ? j.startLb - shown : null;
  const total = inJourney && j.goalLb != null ? j.startLb - j.goalLb : null;
  const pct = total && total > 0 ? Math.max(0, Math.min(1, lost / total)) : null;
  return el("section", { class: "hero", "aria-label": "Weight that day" },
    el("div", { class: "hero-num" + (cur ? "" : " muted") }, fmtNum(shown, 1), el("span", { class: "unit" }, "lb")),
    el("div", { class: "hero-meta" }, cur
      ? `Weighed ${fmtTimeCT(cur.at)}${onDay.length > 1 ? `, ${onDay.length} weigh-ins that day` : ""}`
      : "No weigh-in this day. Showing the smoothed trend."),
    el("div", { class: "hero-chips" },
      cur && prev ? el("span", { class: cur.lb < prev.lb ? "chip good" : cur.lb > prev.lb ? "chip watch" : "chip" }, `${signed(cur.lb - prev.lb)} lb vs ${fmtDateCT(prev.at, false)}`) : null,
      cur && trend != null ? el("span", { class: "chip" }, `Trend ${fmtNum(trend, 1)}`) : null,
      lost != null ? el("span", { class: lost > 0 ? "chip good" : "chip" }, `${signed(-lost)} lb since start`) : null,
    ),
    pct != null ? el("div", { class: "course" },
      el("div", { class: "course-track", role: "img", "aria-label": `${fmtNum(lost, 1)} of ${fmtNum(total, 1)} pounds to goal by this day` },
        el("div", { class: "course-fill", style: { width: `${(pct * 100).toFixed(1)}%` } }),
        el("div", { class: "course-dot", style: { left: `${(pct * 100).toFixed(1)}%` } }),
      ),
      el("div", { class: "course-ends" },
        el("span", null, el("b", null, fmtNum(j.startLb, 1)), " start"),
        el("span", { class: "mid" }, `${Math.round(pct * 100)}% by this day`),
        el("span", null, el("b", null, fmtNum(j.goalLb, 0)), " goal"),
      ),
    ) : null,
  );
}

function gauge(kind, label, value, target, unit, past) {
  const has = value != null;
  const hasT = target != null && target > 0;
  const pct = has && hasT ? value / target : 0;
  let status = "";
  if (has && hasT) {
    const diff = target - value;
    status = kind === "protein"
      ? (diff > 0 ? `${fmtNum(diff, 0)} ${unit} ${past ? "short" : "to go"}` : `Hit, ${fmtNum(-diff, 0)} ${unit} over`)
      : (diff >= 0 ? `${fmtNum(diff, 0)} ${past ? "under" : "left"}` : `${fmtNum(-diff, 0)} over`);
  }
  return el("div", { class: `gauge ${kind}` },
    el("div", { class: "gauge-row" },
      el("span", { class: "gauge-label" }, el("i", { class: "key", "aria-hidden": "true" }), label),
      el("span", { class: "gauge-status" }, status),
    ),
    el("div", { class: "gauge-num" },
      has ? fmtNum(value, 0) : "0",
      el("span", { class: "of" }, hasT ? ` / ${fmtNum(target, 0)} ${unit}` : ` ${unit}`),
    ),
    el("div", { class: "gauge-track" + (pct > 1 ? " over" : "") },
      el("div", { class: "gauge-fill", style: { width: `${Math.min(100, pct * 100).toFixed(1)}%` } }),
    ),
  );
}

/* Saves targets to log.goals through goal_set. Until that action is live on the
   server, falls back to this phone so the gauges still work. */
async function saveTargets(c, p) {
  // No redraw before the request, so the numbers you typed stay put if it fails.
  state.targetsBusy = true;
  state.targetsMsg = null;
  const jobs = [];
  if (c != null) jobs.push(["calories", c]);
  if (p != null) jobs.push(["protein", p]);
  let notLive = false;
  let failed = null;
  for (const [kind, target] of jobs) {
    try {
      await writeLog("goal_set", { kind, target });
    } catch (err) {
      if (/^invalid_action/.test(err.message)) notLive = true;
      else failed = err.message;
      break;
    }
  }
  if (notLive) {
    const local = readLocalTargets();
    if (c != null) local.calories = c;
    if (p != null) local.protein = p;
    saveLocalTargets(local);
    state.editTargets = false;
    state.targetsMsg = { ok: true, text: "Saved on this phone for now. Saving targets to your log isn't switched on yet." };
  } else if (failed) {
    state.targetsMsg = { ok: false, text: failed === "unauthorized" ? "Passcode was rejected. Lock and unlock again." : `Could not save: ${failed}` };
  } else {
    state.editTargets = false;
    state.targetsMsg = { ok: true, text: "Targets saved to your log." };
    state.targetsBusy = false;
    await load(true);
    return;
  }
  state.targetsBusy = false;
  render();
}

function renderTargetsEditor(data, t) {
  const cal = input({ type: "number", name: "t_cal", min: "800", max: "6000", step: "10", inputmode: "numeric", value: t.calories ?? "", placeholder: "e.g. 2200" });
  const pro = input({ type: "number", name: "t_pro", min: "20", max: "400", step: "5", inputmode: "numeric", value: t.protein ?? "", placeholder: "e.g. 150" });
  const err = el("p", { class: "target-msg err", role: "status" });
  return el("div", { class: "targets-editor" },
    el("div", { class: "grid two tight" }, field("Calories (kcal)", cal), field("Protein (g)", pro)),
    el("p", { class: "caption" }, "Daily targets. Leave a box empty to keep it as it is."),
    err,
    el("div", { class: "form-actions" },
      el("button", {
        type: "button",
        class: "primary",
        disabled: state.targetsBusy,
        onClick: (ev) => {
          const c = cal.value.trim() === "" ? null : num(cal.value);
          const p = pro.value.trim() === "" ? null : num(pro.value);
          if (c == null && p == null) { err.textContent = "Enter a calorie or protein target."; return; }
          if (c != null && (!Number.isInteger(c) || c < 800 || c > 6000)) { err.textContent = "Calories should be a whole number from 800 to 6,000."; return; }
          if (p != null && (!Number.isInteger(p) || p < 20 || p > 400)) { err.textContent = "Protein should be a whole number from 20 to 400 g."; return; }
          err.textContent = "";
          ev.currentTarget.disabled = true;
          ev.currentTarget.textContent = "Saving…";
          saveTargets(c, p);
        },
      }, state.targetsBusy ? "Saving…" : "Save targets"),
      el("button", { type: "button", onClick: () => { state.editTargets = false; render(); } }, "Cancel"),
    ),
  );
}

function renderFood(data, key) {
  const k = key || todayKey();
  const past = k !== todayKey();
  const today = totalsOn(data, k);
  const t = getTargets(data);
  const cal = today ? num(today.calories) : null;
  const pro = today ? num(today.protein_g) : null;
  const action = past ? null : el("button", { type: "button", class: "link", onClick: () => { state.editTargets = !state.editTargets; state.targetsMsg = null; render(); } },
    state.editTargets ? "Close" : (t.calories == null && t.protein == null ? "Set targets" : "Edit targets"));
  if (past && !today) return card("Food", el("p", { class: "empty" }, "No food logged this day."));
  const meals = today ? `${today.meal_count} meal${today.meal_count === 1 ? "" : "s"} logged` : "Nothing logged yet today";
  return cardWithAction(past ? "Food" : "Food today", action,
    el("div", { class: "gauges" },
      gauge("calories", "Calories", cal, t.calories, "kcal", past),
      gauge("protein", "Protein", pro, t.protein, "g", past),
    ),
    state.editTargets ? renderTargetsEditor(data, t) : null,
    state.targetsMsg ? el("p", { class: "target-msg " + (state.targetsMsg.ok ? "ok" : "err"), role: "status" }, state.targetsMsg.text) : null,
    renderProteinLine(data, k),
    el("p", { class: "caption" }, t.calories == null && t.protein == null && !state.editTargets
      ? `${meals}. Set daily targets to track progress toward them.`
      : `${meals}. Macros may be estimates.`),
  );
}

function renderVerdict(data) {
  const v = verdictCard(data);
  const tone = v.tone === "watch" ? "watch" : v.tone === "good" ? "good" : "steady";
  return el("section", { class: `card verdict ${tone}` },
    el("div", { class: "card-head" },
      el("h2", null, "Verdict"),
      el("span", { class: `badge ${tone}` }, v.label),
    ),
    el("ul", { class: "receipts" }, ...v.receipts.map((r) => el("li", null, r))),
  );
}

function checkinSummary(c) {
  const bits = [
    c.ate_vs_usual ? `ate ${String(VS_LABELS[c.ate_vs_usual] || c.ate_vs_usual).toLowerCase()}` : null,
    c.moved_vs_usual ? `moved ${String(VS_LABELS[c.moved_vs_usual] || c.moved_vs_usual).toLowerCase()}` : null,
    c.dose_feel ? `dose feels ${String(FEEL_LABELS[c.dose_feel] || c.dose_feel).toLowerCase()}` : null,
  ].filter(Boolean);
  const scores = [
    c.mood != null ? `mood ${c.mood}` : null,
    c.food_noise != null ? `food noise ${c.food_noise}` : null,
    c.energy != null ? `energy ${c.energy}` : null,
    c.sleep_quality != null ? `sleep ${c.sleep_quality}` : null,
  ].filter(Boolean);
  return [bits.length ? capitalize(bits.join(", ")) + "." : null, scores.length ? capitalize(scores.join(", ")) + " out of 10." : null].filter(Boolean).join(" ");
}

function renderCheckinNudge(data, key) {
  const k = key || todayKey();
  const isToday = k === todayKey();
  const cur = checkinOn(data, k);
  const hasAnswers = cur && (cur.ate_vs_usual || cur.moved_vs_usual || cur.dose_feel || cur.mood != null || cur.energy != null || cur.food_noise != null || cur.sleep_quality != null);
  if (state.checkinOpen) {
    return card(isToday ? "Today’s check-in" : `Check-in for ${fmtShortDate(k)}`,
      renderCheckinForm(data, k, {
        onSaved: () => { state.checkinOpen = false; render(); },
        onCancel: () => { state.checkinOpen = false; state.formMessage = null; render(); },
      }),
    );
  }
  const open = el("button", { type: "button", class: hasAnswers ? "link" : "primary", onClick: () => { state.checkinOpen = true; state.formMessage = null; render(); } }, hasAnswers ? "Edit" : "Check in");
  if (hasAnswers) {
    return el("div", { class: "callout done" },
      el("div", null,
        el("strong", null, isToday ? "Checked in today" : "Checked in"),
        el("span", null, checkinSummary(cur) || "Saved."),
      ),
      open,
    );
  }
  // Today's prompt waits for the evening; past days can be filled in any time.
  if (isToday && hourCT(new Date()) < CHECKIN_PROMPT_HOUR) return null;
  return el("div", { class: "callout" + (isToday ? "" : " quiet") },
    el("div", null,
      el("strong", null, isToday ? "No check-in yet today" : "No check-in this day"),
      el("span", null, "How you ate, moved, felt and slept."),
    ),
    open,
  );
}

function renderCountdowns(data) {
  const doses = data.doses || [];
  const { next } = plannedDoses(doses, data.protocol);
  const tile = (label, date, cls) => {
    const n = daysUntil(date);
    return el("div", { class: `count ${cls || ""}` },
      el("span", { class: "count-label" }, label),
      el("span", { class: "count-num" }, n <= 0 ? (n === 0 ? "Today" : "Done") : String(n), n > 0 ? el("small", null, n === 1 ? " day" : " days") : null),
      el("span", { class: "count-date" }, fmtDateCT(date, true)),
    );
  };
  return el("section", { class: "counts", "aria-label": "Coming up" },
    next ? tile("Next dose", next, "dose") : (daysUntil(retaSwitchAt(data)) >= 0 ? tile("Retatrutide", retaSwitchAt(data), "dose") : null),
    next && daysUntil(RETA_START) >= 0 ? tile("Retatrutide", retaSwitchAt(data), "switch") : null,
  );
}

function renderMedSummary(data) {
  const doses = data.doses || [];
  const { next } = plannedDoses(doses, data.protocol);
  const lastDose = [...doses].reverse().find((d) => !d.skipped) || null;
  const levelNow = remainingAt(new Date(), doses, data.protocol);
  const rot = siteRotation(data);
  return cardWithAction("Medication",
    el("button", { type: "button", class: "link", onClick: () => { state.tab = "meds"; render(); window.scrollTo(0, 0); } }, "Details"),
    el("div", { class: "med-level" },
      el("span", { class: "big" }, fmtNum(levelNow, 2), el("span", { class: "unit" }, "mg")),
      el("span", { class: "detail" }, "Estimated in your system now, from a half-life model"),
    ),
    el("div", { class: "props" },
      prop("Last dose", lastDose ? `${fmtNum(lastDose.dose_mg, 1)} mg ${capitalize(lastDose.compound || "")}, ${fmtDateCT(parseTs(lastDose.taken_at), true)}` : "—"),
      (() => {
        const plan = nextPlanned(data);
        if (plan) return prop("Next dose", `${planDoseText(plan)}, ${fmtDateCT(keyToNoon(plan.planned_on), true)} (${daysWord(daysUntil(keyToNoon(plan.planned_on)))})`);
        return prop("Next dose", next ? `${fmtDateCT(next, true)}, ${daysWord(daysUntil(next))}` : `Retatrutide starts ${fmtDateCT(RETA_START, true)}`);
      })(),
      prop("Next site", rot.next ? (SITE_LABELS[rot.next] || rot.next) : "—"),
    ),
  );
}

function renderDayMeds(data, key) {
  const doses = data.doses || [];
  const firstReal = doses.find((d) => !d.skipped && parseTs(d.taken_at));
  if (!firstReal || dateKeyCT(parseTs(firstReal.taken_at)) > key) return null;
  const that = doses.filter((d) => parseTs(d.taken_at) && dateKeyCT(parseTs(d.taken_at)) === key);
  const at = new Date(Math.min(Date.now(), keyToNoon(key).getTime() + 9 * 3600000));
  const level = remainingAt(at, doses, data.protocol);
  return card("Medication",
    el("div", { class: "med-level" },
      el("span", { class: "big" }, fmtNum(level, 2), el("span", { class: "unit" }, "mg")),
      el("span", { class: "detail" }, "Estimated in your system at 9 PM that day"),
    ),
    el("div", { class: "props" },
      prop("Dose that day", that.length
        ? that.map((d) => d.skipped ? "Skipped" : `${fmtNum(d.dose_mg, 1)} mg ${capitalize(d.compound || "")}${d.site ? `, ${SITE_LABELS[d.site] || d.site}` : ""}`).join("; ")
        : "None"),
    ),
  );
}

/* Apple Health sync button and status. Only inside the Log iPhone app. */
function healthSyncSummary(r) {
  const parts = [
    [r.days, "day"], [r.weights, "weigh-in"], [r.body, "body reading"], [r.workouts, "workout"],
  ].filter(([n]) => n).map(([n, w]) => `${fmtNum(n, 0)} ${w}${n === 1 ? "" : "s"}`);
  if (r.metrics) parts.push(`${fmtNum(r.metrics, 0)} other value${r.metrics === 1 ? "" : "s"}`);
  if (!parts.length) return "Synced. Nothing new in Apple Health.";
  const list = parts.length > 1 ? `${parts.slice(0, -1).join(", ")} and ${parts[parts.length - 1]}` : parts[0];
  return `Synced ${list}.`;
}

function renderHealthSync(full) {
  if (!canSyncHealth()) return null;
  const last = lastHealthSync();
  const msg = state.healthMsg;
  const b = backfillState();
  const bfText = backfillText(b);
  return el("div", { class: "health-sync" },
    el("button", {
      type: "button",
      class: full ? "primary" : "",
      disabled: state.healthBusy,
      onClick: async () => {
        state.healthBusy = true;
        state.healthMsg = null;
        render();
        const r = await syncAppleHealth({ days: full ? 30 : 7 });
        state.healthBusy = false;
        state.healthMsg = r.ok ? { ok: true, text: healthSyncSummary(r) } : { ok: false, text: r.reason };
        if (r.ok) await load(true); else render();
      },
    }, state.healthBusy ? "Syncing…" : full ? "Sync the last 30 days" : "Sync Apple Health"),
    full ? el("button", {
      type: "button",
      class: "backfill-btn",
      disabled: !!b.running,
      onClick: () => {
        const cur = backfillState();
        backfillHealth({ restart: !!cur.done }).then((res) => { if (res && res.values) load(true, true); });
      },
    }, backfillButtonLabel(b)) : null,
    el("span", { class: "sync-meta" + (msg && !msg.ok ? " err" : "") }, msg ? msg.text : last ? `Last synced ${fmtDateCT(new Date(last.at), false)}, ${fmtTimeCT(new Date(last.at)).replace(" CT", "")}` : "Not synced yet"),
    el("span", { class: "sync-meta backfill-status", hidden: !bfText, "aria-live": "polite" }, bfText),
  );
}

function renderSignals(data, key) {
  const past = key && key !== todayKey();
  const h = past ? healthOn(data, key) : latestHealth(data);
  if (!h) return null;
  const isToday = h.day === todayKey();
  return card("Body",
    el("div", { class: "tiles" },
      metric("Steps", h.steps != null ? fmtNum(h.steps, 0) : "—", h.distance_mi != null ? `${fmtNum(h.distance_mi, 1)} mi` : null),
      metric("Sleep", h.sleep_hours != null ? `${fmtNum(h.sleep_hours, 1)} h` : "—", h.sleep_hours != null ? "asleep" : "not recorded"),
      metric("Resting HR", h.resting_hr != null ? fmtNum(h.resting_hr, 0) : "—", "bpm"),
      metric("HRV", h.hrv_ms != null ? fmtNum(h.hrv_ms, 0) : "—", "ms"),
    ),
    el("p", { class: "caption" }, past ? "From Apple Health." : isToday ? "From Apple Health, today so far." : `From Apple Health, ${fmtShortDate(h.day)}. ${canSyncHealth() ? "Sync to bring in newer days." : "Newer days appear after the next sync from the iPhone app."}`),
    !past ? renderHealthSync() : null,
  );
}

function renderMacros(today) {
  if (!today) return null;
  const rows = [
    ["Protein", num(today.protein_g), "protein"],
    ["Carbs", num(today.carbs_g), "rest"],
    ["Fat", num(today.fat_g), "rest"],
    ["Fiber", num(today.fiber_g), "rest"],
  ];
  const max = Math.max(...rows.map((r) => r[1] || 0), 1);
  return card("Macros",
    el("div", { class: "bars" },
      ...rows.map(([label, v, cls]) => el("div", { class: "bar-row" },
        el("span", { class: "bar-name" }, label),
        el("div", { class: "bar-track" }, el("div", { class: `bar-fill ${cls}`, style: { width: `${Math.min(100, ((v || 0) / max) * 100)}%` } })),
        el("span", { class: "bar-val" }, v == null ? "—" : `${fmtNum(v, 0)} g`),
      )),
    ),
  );
}

function renderMeals(meals, past) {
  const body = meals.length
    ? el("ul", { class: "list" },
        ...meals.map((m) => el("li", { class: "meal" },
          el("div", { class: "meal-main" },
            el("span", { class: "meal-item" }, m.item || "—"),
            el("span", { class: "meal-sub" },
              [capitalize(m.meal_type || ""), parseTs(m.eaten_at) ? fmtTimeCT(parseTs(m.eaten_at)) : null, m.quantity || null].filter(Boolean).join(", ")),
          ),
          el("div", { class: "meal-nums" },
            el("span", { class: "kcal" }, fmtNum(m.calories, 0), el("small", null, " kcal")),
            el("span", { class: "pro" }, `${fmtNum(m.protein_g, 0)} g protein`),
          ),
        )),
      )
    : el("p", { class: "empty" }, past ? "No meals logged this day." : "No meals yet today.");
  return card("Meals", body, past ? null : renderLogMeal());
}

/* A real link to the Log bot. If the page is still here shortly after, Grok Bot didn't open. */
function renderLogMeal() {
  return el("div", { class: "log-meal-wrap" },
    el("a", { class: "log-meal", href: LOG_BOT_URL, onClick: noteIfLogBotStays }, "Log a meal"),
    state.mealBotNote ? el("p", { class: "caption meal-bot-note", role: "status" }, state.mealBotNote) : null,
  );
}

function noteIfLogBotStays(event) {
  const note = event.currentTarget.parentNode && event.currentTarget.parentNode.querySelector(".meal-bot-note");
  if (note) note.remove();
  state.mealBotNote = null;
  // Inside the iPhone app the web view stays visible when another app opens, so don't guess.
  // The native Meals button uses openURL's result instead. This note is for a normal browser.
  if (window.LOG_NATIVE) return;
  const started = Date.now();
  let left = false;
  const mark = () => { left = true; };
  const onVis = () => { if (document.hidden) mark(); };
  document.addEventListener("visibilitychange", onVis);
  window.addEventListener("pagehide", mark);
  window.addEventListener("blur", mark);
  setTimeout(() => {
    document.removeEventListener("visibilitychange", onVis);
    window.removeEventListener("pagehide", mark);
    window.removeEventListener("blur", mark);
    if (left || document.hidden || Date.now() - started > 4000) return;
    state.mealBotNote = LOG_BOT_UNAVAILABLE;
    render();
  }, 1500);
}

/* Mon–Sun strip for the week that holds the day showing. Dots mark days with anything logged. */
function renderWeekStrip(data) {
  const key = viewKey();
  const today = todayKey();
  const min = earliestDayKey(data);
  const t = keyToNoon(key);
  const dow = (t.getUTCDay() + 6) % 7;
  const monday = shiftDay(key, -dow);
  const logged = loggedDays(data);
  const picker = el("input", {
    type: "date",
    class: "day-picker",
    value: key,
    min,
    max: today,
    "aria-label": "Jump to a day",
    onChange: (e) => { if (e.target.value) goToDay(data, dayDiff(e.target.value, today)); },
  });
  const month = new Intl.DateTimeFormat("en-US", { timeZone: TZ, month: "long", year: "numeric" }).format(t);
  return el("div", { class: "weekstrip" },
    el("div", { class: "weekstrip-head" },
      el("label", { class: "month-pick" }, el("span", null, month), el("span", { class: "chev", "aria-hidden": "true" }, "⌄"), picker),
      key !== today ? el("button", { type: "button", class: "pill", onClick: () => goToDay(data, 0) }, "Today") : null,
    ),
    el("div", { class: "week", role: "group", "aria-label": "Days of this week" },
      ...Array.from({ length: 7 }, (_, i) => {
        const k = shiftDay(monday, i);
        const d = keyToNoon(k);
        const future = k > today;
        const early = k < min;
        return el("button", {
          type: "button",
          class: "day" + (k === key ? " on" : "") + (k === today ? " is-today" : "") + (logged.has(k) ? " has" : ""),
          disabled: future || early,
          "aria-pressed": k === key ? "true" : "false",
          "aria-label": fmtLongDateYearCT(d),
          onClick: () => goToDay(data, dayDiff(k, today)),
        },
          el("span", { class: "dow" }, "MTWTFSS"[i]),
          el("span", { class: "dnum" }, String(Number(k.slice(8)))),
          el("i", { class: "dot", "aria-hidden": "true" }),
        );
      }),
    ),
  );
}

/* Horizontal swipe on the day's cards: left for the next day, right for the day before. */
function attachDaySwipe(node, data) {
  let sx = 0, sy = 0, st = 0, armed = false;
  node.addEventListener("touchstart", (e) => {
    armed = e.touches.length === 1 && !e.target.closest("input, textarea, select, .checkin-form, .targets-editor, .chart-wrap, .table-scroll");
    if (!armed) return;
    sx = e.touches[0].clientX;
    sy = e.touches[0].clientY;
    st = Date.now();
  }, { passive: true });
  node.addEventListener("touchend", (e) => {
    if (!armed) return;
    armed = false;
    const t = e.changedTouches[0];
    const dx = t.clientX - sx;
    const dy = t.clientY - sy;
    if (Date.now() - st > 700 || Math.abs(dx) < 60 || Math.abs(dx) < Math.abs(dy) * 1.8) return;
    goToDay(data, (state.dayOffset || 0) + (dx < 0 ? 1 : -1));
  }, { passive: true });
}

function renderTodayTab(data) {
  const key = viewKey();
  const isToday = key === todayKey();
  const body = el("div", { class: "stack day-body" + (state.daySlide ? ` slide-${state.daySlide}` : "") },
    state.formMessage && state.formMessage.ok ? renderToast() : null,
    renderHero(data, key),
    renderFood(data, key),
    renderCheckinNudge(data, key),
    renderFeelNow(data, key),
    renderOffNormal(data, key),
    isToday ? renderCountdowns(data) : null,
    isToday ? renderSwitchCard(data) : null,
    isToday ? renderVerdict(data) : null,
    isToday ? renderMedSummary(data) : renderDayMeds(data, key),
    renderSleepNight(data, key),
    renderSignals(data, key),
    renderMacros(totalsOn(data, key)),
    renderMeals(mealsOn(data, key), !isToday),
    isToday ? el("p", { class: "install" + (state.error === "refresh-failed" ? " err" : "") }, state.error === "refresh-failed"
      ? `Couldn’t refresh. Showing data from ${fmtTimeCT(parseTs(data.as_of) || new Date())}.`
      : `Updated ${fmtTimeCT(parseTs(data.as_of) || new Date())}. Refreshes every minute.`) : null,
  );
  state.daySlide = null;
  attachDaySwipe(body, data);
  return el("div", { class: "stack" }, renderWeekStrip(data), body);
}

/* ---------- Meds ---------- */

function renderLevelCard(data) {
  const doses = data.doses || [];
  const lp = levelPoints(doses, data.protocol, 6);
  if (!lp) return card("Drug level", el("p", { class: "empty" }, "No doses to chart yet."));
  const now = new Date();
  const levelNow = remainingAt(now, doses, data.protocol);
  const lastReal = [...doses].reverse().find((d) => !d.skipped && parseTs(d.taken_at));
  const lastT = lastReal ? parseTs(lastReal.taken_at).getTime() : 0;
  const plannedTail = lp.withNext.filter((p) => p.t.getTime() >= lastT);
  const hasPlanned = lp.withNext.some((p, i) => Math.abs(p.v - lp.logged[i].v) > 0.01);
  const ro = readout(`${fmtNum(levelNow, 2)} mg`, `Estimated now, ${fmtTimeCT(now)}`);
  const chart = timeChart({
    t0: lp.start,
    t1: lp.end,
    height: 210,
    yMin: 0,
    yTicks: 3,
    aria: "Estimated tirzepatide level over time",
    fmtY: (v) => fmtNum(v, v < 10 ? 1 : 0),
    series: [
      { id: "logged", label: "Logged doses", cls: "s3", type: "line", fill: true, points: lp.logged },
      hasPlanned ? { id: "planned", label: "With next planned shot", cls: "s3", type: "line", dashed: true, points: plannedTail } : null,
    ].filter(Boolean),
    marks: [{ t: now, label: "Now" }, { t: RETA_START, label: "Retatrutide" }],
    snap: "logged",
    snapToleranceMs: 4 * 3600000,
    onScrub: (r) => {
      if (!r) return ro.reset();
      const p = r.point;
      const planned = r.readings.planned;
      const extra = planned && Math.abs(planned.v - p.v) > 0.01 ? `, ${fmtNum(planned.v, 2)} mg with next shot` : "";
      ro.set(`${fmtNum(p.v, 2)} mg`, `${fmtDateCT(p.t, true)}, ${fmtTimeCT(p.t)}${extra}`);
    },
  });
  return card("Drug level",
    ro.node,
    chart,
    el("div", { class: "legend" },
      el("span", null, el("i", { class: "key line s3" }), "Logged doses"),
      hasPlanned ? el("span", null, el("i", { class: "key line s3 dashed" }), "With next planned shot") : null,
    ),
    el("p", { class: "caption" }, "Half-life model: tirzepatide 5 days, retatrutide 6 days. The dashed line adds the next planned tirzepatide shot if it falls before the Dec 6 switch. No retatrutide mg amount is assumed. An estimate, not a lab value."),
  );
}

function renderSiteMap(data) {
  const rot = siteRotation(data);
  const rows = SITES.map((s) => {
    const used = rot.lastUsed[s];
    const tag = s === rot.next ? el("span", { class: "badge good" }, "Next") : s === rot.lastSite ? el("span", { class: "badge steady" }, "Last") : null;
    return el("li", { class: "site-row" },
      el("span", { class: "site-name" }, SITE_LABELS[s] || s, tag),
      el("span", { class: "site-when" }, used ? fmtDateCT(used, true) : "Not used yet"),
    );
  });
  return card("Injection sites",
    el("div", { class: "sitemap-wrap" }, siteMap(rot)),
    el("div", { class: "legend center" },
      el("span", null, el("i", { class: "key dot next" }), "Suggested next"),
      el("span", null, el("i", { class: "key dot last" }), "Last used"),
      el("span", null, el("i", { class: "key dot used" }), "Used before"),
    ),
    el("ul", { class: "list sites-list" }, ...rows),
    el("p", { class: "caption" }, "Front view: your right side is on the left of the drawing."),
  );
}

function renderTitration(data) {
  const steps = titrationHistory(data.doses || []);
  if (!steps.length) return card("Titration history", el("p", { class: "empty" }, "No doses yet."));
  return card("Titration history",
    el("ol", { class: "timeline" },
      ...steps.map((d) => el("li", { class: d.changed ? "changed" : "" },
        el("span", { class: "t-date" }, fmtDateCT(parseTs(d.taken_at), true)),
        el("span", { class: "t-what" },
          d.skipped ? `Skipped ${capitalize(d.compound || "")}` : `${fmtNum(d.mg, 1)} mg ${capitalize(d.compound || "")}`,
          d.changed && d.mg != null ? el("span", { class: "badge steady" }, "Change") : null,
        ),
        d.site ? el("span", { class: "t-site" }, SITE_LABELS[d.site] || d.site) : null,
      )),
    ),
  );
}

/* Identical unopened vials collapse into one line ("Brand 12 mg, 10 vials"). */
function groupVials(items) {
  const groups = new Map();
  for (const v of items) {
    const unopened = !v.opened_at && !v.started_on;
    const name = String(v.label || "").replace(/\s*#\d+$/, "");
    const key = unopened ? `${v.compound}|${name}|${v.total_mg}|${v.total_units}` : `open|${v.id}`;
    if (!groups.has(key)) groups.set(key, { compound: v.compound, name, unopened, vials: [] });
    groups.get(key).vials.push(v);
  }
  return [...groups.values()];
}

function renderVials(data) {
  const r = vialRunway(data);
  if (!r.ready) return card("Vials", el("p", { class: "empty" }, `${r.summary} Use Start a vial on the Log tab.`));
  const byCompound = {};
  for (const v of r.items) {
    const c = byCompound[v.compound] || (byCompound[v.compound] = { mg: 0, count: 0, unopened: 0 });
    const mg = num(v.remaining_mg != null ? v.remaining_mg : v.total_mg);
    if (mg != null) c.mg += mg;
    c.count += 1;
    if (!v.opened_at && !v.started_on) c.unopened += 1;
  }
  const totals = Object.entries(byCompound).map(([compound, c]) => metric(
    capitalize(compound),
    `${fmtNum(c.mg, c.mg % 1 ? 1 : 0)} mg`,
    `${c.count} vial${c.count === 1 ? "" : "s"}${c.unopened === c.count ? ", all unopened" : c.unopened ? `, ${c.unopened} unopened` : ""}`,
  ));
  const groups = groupVials(r.items);
  return card("Vials",
    el("div", { class: "tiles" }, ...totals),
    el("div", { class: "props" },
      ...groups.map((g) => {
        const n = g.vials.length;
        const v = g.vials[0];
        const label = `${g.name || capitalize(g.compound)}${n > 1 ? `, ${n} vials` : ""}`;
        const sumMg = g.vials.reduce((a, x) => a + (num(x.remaining_mg != null ? x.remaining_mg : x.total_mg) || 0), 0);
        const detail = g.unopened
          ? `Unopened, ${fmtNum(sumMg, sumMg % 1 ? 1 : 0)} mg`
          : [
              v.remaining_mg != null ? `${fmtNum(v.remaining_mg, 1)} of ${fmtNum(v.total_mg, 1)} mg left` : "",
              v.remaining_units != null ? `${fmtNum(v.remaining_units, 0)} units left` : "",
              v.expired_on ? `discard ${fmtShortDate(v.expired_on)}` : "",
            ].filter(Boolean).join(", ") || "Open";
        return prop(label, detail);
      }),
    ),
    r.soonest ? el("p", { class: "caption" }, `At the planned weekly dose, supply lasts until about ${fmtDateCT(r.soonest.until, true)}.`) : null,
    renderCompoundRunway(data),
  );
}

function renderProtocol(data) {
  const rows = data.protocol || [];
  if (!rows.length) return null;
  return card("Protocol",
    ...rows.map((p) => el("div", { class: "cycle" },
      el("h3", null, p.display_name || capitalize(p.compound), el("span", { class: `badge ${p.status === "active" ? "good" : "steady"}` }, capitalize(p.status || ""))),
      el("div", { class: "props" },
        prop("Dose", p.typical_dose_mg != null ? `${fmtNum(p.typical_dose_mg, 1)} mg ${p.frequency || ""}`.trim() : (p.units != null ? `${fmtNum(p.units, 0)} units ${p.frequency || ""}`.trim() : "—")),
        prop("Half-life", p.half_life_hours != null ? `${fmtNum(p.half_life_hours / 24, 1)} days` : "—"),
        prop(p.status === "active" ? "Started" : "Starts", p.started_on ? fmtShortDate(p.started_on) : "—"),
        p.notes ? el("p", { class: "caption" }, p.notes) : null,
      ),
    )),
  );
}

function renderDoseHistory(data) {
  const doses = data.doses || [];
  return card("Dosing history",
    doses.length
      ? el("div", { class: "table-scroll" }, el("table", { class: "data" },
          el("thead", null, el("tr", null, el("th", null, "When"), el("th", null, "Dose"), el("th", null, "Site"))),
          el("tbody", null, ...[...doses].reverse().map((d) => el("tr", null,
            el("td", null, parseTs(d.taken_at) ? fmtDateCT(parseTs(d.taken_at), true) : "—"),
            el("td", null, d.skipped ? "Skipped" : `${fmtNum(d.dose_mg, 1)} mg`, el("span", { class: "sub" }, capitalize(d.compound || ""))),
            el("td", null, siteLabel(d)),
          ))),
        ))
      : el("p", { class: "empty" }, "No doses logged yet."),
  );
}

function renderMedsTab(data) {
  return el("div", { class: "stack" },
    renderLevelCard(data),
    renderSiteMap(data),
    renderDosePlan(data),
    renderTitration(data),
    renderSwitchCard(data),
    renderProtocol(data),
    renderVials(data),
    renderDoseHistory(data),
  );
}

/* ---------- Trends ---------- */

/* Daily series that can sit under the weight chart. Same days, separate scale. */
const OVERLAYS = [
  { id: "none", label: "Off" },
  { id: "calories", label: "Cal", cls: "s2", title: "Calories", fmt: (v) => `${fmtNum(v, 0)} kcal`, field: "calories", zero: true },
  { id: "steps", label: "Steps", cls: "s4", title: "Steps", fmt: (v) => `${fmtNum(v, 0)} steps`, field: "steps", zero: true },
  { id: "sleep", label: "Sleep", cls: "s3", title: "Sleep", fmt: (v) => `${fmtNum(v, 1)} h sleep`, field: "sleep_hours", zero: true },
  { id: "rhr", label: "RHR", cls: "s3", title: "Resting heart rate", fmt: (v) => `${fmtNum(v, 0)} bpm resting`, field: "resting_hr" },
  { id: "hrv", label: "HRV", cls: "s4", title: "HRV", fmt: (v) => `${fmtNum(v, 0)} ms HRV`, field: "hrv_ms" },
  { id: "thoughts", label: "Thoughts", cls: "s2", title: "Food thoughts", fmt: (v) => `${fmtNum(v, 0)} food thought${v === 1 ? "" : "s"}`, from: "thoughts" },
  { id: "noise", label: "Noise", cls: "s3", title: "Food noise", fmt: (v) => `${fmtNum(v, 1)} food noise`, from: "noise" },
];

function overlayDaily(data, id) {
  const o = OVERLAYS.find((x) => x.id === id);
  if (id === "thoughts") return thoughtsByDay(data);
  if (id === "noise") return noiseByDay(data);
  const rows = id === "calories"
    ? (data.daily_totals || []).map((r) => [r.date, num(r.calories)])
    : (data.daily_health || []).map((r) => [r.day, num(r[o.field])]);
  const out = new Map();
  for (const [key, v] of rows) if (key && v != null && v > 0) out.set(key, v);
  return out;
}

function keyToNoon(key) {
  const [y, m, d] = key.split("-").map(Number);
  return ctNoon(y, m, d);
}

/* Overlay line: 7-day average on 1M/3M, weekly averages (Monday weeks) on 1Y and All. */
function overlayPoints(daily, weekly) {
  const keys = [...daily.keys()].sort();
  if (!weekly) {
    return keys.map((k) => {
      const t = keyToNoon(k);
      let sum = 0;
      let n = 0;
      for (let i = 0; i < 7; i++) {
        const v = daily.get(dateKeyCT(new Date(t.getTime() - i * 86400000)));
        if (v != null) { sum += v; n += 1; }
      }
      return { t, v: sum / n, key: k, n, day: daily.get(k) };
    });
  }
  const weeks = new Map();
  for (const k of keys) {
    const t = keyToNoon(k);
    const dow = (t.getUTCDay() + 6) % 7;
    const monday = dateKeyCT(new Date(t.getTime() - dow * 86400000));
    const w = weeks.get(monday) || { sum: 0, n: 0 };
    w.sum += daily.get(k);
    w.n += 1;
    weeks.set(monday, w);
  }
  return [...weeks.entries()].map(([k, w]) => ({ t: new Date(keyToNoon(k).getTime() + 3 * 86400000), v: w.sum / w.n, key: k, n: w.n, week: true }));
}

function renderWeightCard(data) {
  const parsed = parseWeights(data.weights || []);
  if (!parsed.length) return card("Weight", el("p", { class: "empty" }, "No weigh-ins yet. Log one on the Log tab."));
  const sm = smoothWeights(parsed);
  const ranges = RANGES;
  const range = ranges.find((r) => r.id === state.weightRange) || ranges.find((r) => r.id === "3m") || ranges[0];
  const last = sm[sm.length - 1];
  const end = new Date(Math.max(Date.now(), last.at.getTime()));
  const startT = rangeStartAt(range, data, end, sm[0].at) || new Date(end.getTime() - 91 * 86400000);
  const inRange = sm.filter((w) => w.at >= startT);
  const j = journeyStats(data);
  const goal = j ? j.goalLb : null;

  // Straight-line projection from the post-dose trend, drawn only on the short ranges.
  const proj = weightProjection(data, 42);
  const showProj = proj.ready && (range.id === "1m" || range.id === "3m");
  let t1 = end;
  let projPts = [];
  if (showProj) {
    const projEnd = new Date(last.at.getTime() + 42 * 86400000);
    t1 = projEnd;
    const t0p = proj.last.at.getTime();
    const daily = dailyWeight(parseWeights(data.weights).filter((w) => w.at >= TIRZ_START));
    const base = daily[0].at.getTime();
    for (let t = t0p; t <= projEnd.getTime(); t += 86400000) {
      projPts.push({ t: new Date(t), v: proj.fit.intercept + proj.fit.slope * ((t - base) / 86400000) });
    }
  }

  const seg = el("div", { class: "seg wrap", role: "group", "aria-label": "Range" },
    ...ranges.map((r) => el("button", {
      type: "button",
      "aria-pressed": range.id === r.id ? "true" : "false",
      "aria-label": r.id === "glp1" ? "Since GLP-1" : r.label,
      onClick: () => { state.weightRange = r.id; render(); },
    }, r.label)),
  );

  const first = inRange[0] || sm[0];
  const change = last.trend - first.trend;
  const rp = recentPace(parsed, 28);
  const lows = inRange.length ? Math.min(...inRange.map((w) => w.lb)) : null;
  const highs = inRange.length ? Math.max(...inRange.map((w) => w.lb)) : null;
  const ro = readout(`${fmtNum(last.trend, 1)} lb`, `Trend now. Last weigh-in ${fmtNum(last.lb, 1)} lb, ${fmtDateCT(last.at, true)}`);
  const withYear = range.id === "all" || range.id === "1y";
  const ov = OVERLAYS.find((o) => o.id === state.overlay && o.id !== "none") || null;
  const ovDaily = ov ? overlayDaily(data, ov.id) : null;
  const spanDays = (end - startT) / 86400000;
  const ovWeekly = range.id === "1y" || range.id === "all" || spanDays >= 180;
  const ovPts = ov ? overlayPoints(ovDaily, ovWeekly).filter((p) => p.t >= startT && p.t <= end) : null;
  const ovFmtAxis = ov && (ov.id === "sleep" || ov.id === "noise" || ov.id === "thoughts")
    ? (v) => ov.id === "sleep" ? `${fmtNum(v, 0)}h` : fmtNum(v, ov.id === "noise" ? 1 : 0)
    : (v) => (v >= 1000 ? `${fmtNum(v / 1000, v % 1000 ? 1 : 0)}k` : fmtNum(v, 0));

  const chart = inRange.length >= 2
    ? timeChart({
        t0: startT,
        t1,
        height: 220,
        yTicks: 5,
        aria: `Weight, ${range.label} range`,
        fmtY: (v) => fmtNum(v, 0),
        series: [
          { id: "raw", label: "Weigh-ins", cls: "s1 faint", type: "dots", r: range.id === "all" ? 2 : 3, points: inRange.map((w) => ({ t: w.at, v: w.lb, w })) },
          { id: "trend", label: "Trend", cls: "s1", type: "area", endDot: true, points: inRange.map((w) => ({ t: w.at, v: w.trend, w })) },
          showProj ? { id: "proj", label: "Projection", cls: "s1", type: "line", dashed: true, points: projPts } : null,
          ovPts && ovPts.length ? { id: "ov", label: ov.title, cls: `${ov.cls} overlay-line`, type: "line", axis: "right", endDot: true, points: ovPts } : null,
        ].filter(Boolean),
        fmtRight: ov ? ovFmtAxis : undefined,
        rightMin: ov && ov.zero ? 0 : undefined,
        refs: goal != null ? [{ v: goal, label: `Goal ${fmtNum(goal, 0)}`, inDomain: range.id !== "all" ? Math.abs(goal - last.trend) < 30 : true }] : [],
        marks: [
          (firstGlp1At(data) || TIRZ_START) >= startT ? { t: firstGlp1At(data) || TIRZ_START, label: "Tirzepatide" } : null,
          retaSwitchAt(data) >= startT && retaSwitchAt(data) <= t1 ? { t: retaSwitchAt(data), label: "Reta" } : null,
        ].filter(Boolean),
        snap: "trend",
        onScrub: (r) => {
          if (!r) return ro.reset();
          const w = r.point.w;
          const avg = r.readings && r.readings.ov;
          const extra = ovDaily && ovDaily.has(dateKeyCT(w.at))
            ? `, ${ov.fmt(ovDaily.get(dateKeyCT(w.at)))}`
            : avg ? `, ${ov.fmt(avg.v)} ${ovWeekly ? "weekly avg" : "7-day avg"}` : "";
          ro.set(`${fmtNum(w.lb, 1)} lb`, `${fmtDateCT(w.at, true)}${withYear ? `, ${w.at.getFullYear()}` : ""}, trend ${fmtNum(w.trend, 1)}${extra}`);
        },
      })
    : el("p", { class: "empty" }, "Only one weigh-in in this range. Try a longer range.");

  // Note under the chart about what the overlay line covers.
  let ovNote = null;
  if (ov) {
    const logged = ovPts.reduce((a, p) => a + (ovWeekly ? p.n : (p.day != null ? 1 : 0)), 0);
    const firstKey = [...ovDaily.keys()].sort()[0];
    ovNote = !ovPts.length
      ? (ov.id === "calories" ? "No food logged in this range." : `No ${ov.label.toLowerCase()} data in this range.`)
      : ov.id === "calories" && logged < 7
        ? `${logged} day${logged === 1 ? "" : "s"} of food logged in this range, so the line fills in as you log.`
        : firstKey && keyToNoon(firstKey) > startT
          ? `${ov.title} data starts ${fmtShortDate(firstKey)}.`
          : null;
  }
  const compare = el("div", { class: "compare" },
    el("span", null, "Compare with"),
    el("div", { class: "seg", role: "group", "aria-label": "Compare weight with" },
      ...OVERLAYS.map((o) => el("button", {
        type: "button",
        "aria-pressed": (state.overlay || "none") === o.id ? "true" : "false",
        onClick: () => { state.overlay = o.id; try { localStorage.setItem(OVERLAY_KEY, o.id); } catch (_) { /* ignore */ } render(); },
      }, o.label)),
    ),
  );

  const recent = [...parsed].reverse().slice(0, 30);
  return card("Weight",
    seg,
    ro.node,
    chart,
    el("div", { class: "legend" },
      el("span", null, el("i", { class: "key dot s1 faint" }), "Weigh-ins"),
      el("span", null, el("i", { class: "key line s1" }), "Smoothed trend"),
      showProj ? el("span", null, el("i", { class: "key line s1 dashed" }), "Straight-line projection") : null,
      goal != null ? el("span", null, el("i", { class: "key line ref" }), "Goal") : null,
      ov ? el("span", null, el("i", { class: `key line ${ov.cls}` }), `${ov.title}, ${ovWeekly ? "weekly average" : "7-day average"} (right scale)`) : null,
    ),
    compare,
    ovNote ? el("p", { class: "strip-note" }, ovNote) : null,
    el("div", { class: "stats" },
      metric(`Change, ${range.label}`, `${signed(change)} lb`, "trend to trend"),
      metric("Pace", rp ? `${signed(rp.weekly)} lb/wk` : "—", rp ? `${fmtNum(Math.abs(rp.weekly / last.lb) * 100, 1)}% of body weight` : "last 4 weeks"),
      metric("Range", lows != null ? `${fmtNum(lows, 1)}–${fmtNum(highs, 1)}` : "—", "lowest to highest"),
    ),
    lossRate(data) && lossRate(data).fast ? el("div", { class: "callout watch-note" },
      el("div", null,
        el("strong", null, `Losing ${fmtNum(lossRate(data).pct, 1)}% of body weight a week`),
        el("span", null, "That’s above 1% a week over the last 4 weeks. Faster loss tends to take more muscle with it, so protein and strength work matter more right now."),
      )) : null,
    el("p", { class: "caption" }, showProj
      ? `The trend smooths day-to-day water swings. The projection extends the straight-line fit since starting tirzepatide (${signed(proj.weekly, 2)} lb a week) six weeks out. It describes the past; it isn’t a prediction.`
      : "The trend smooths day-to-day water swings, so one high or low weigh-in barely moves it."),
    dataView("Recent weigh-ins", ["Date", "Weight", "Trend"], recent.map((w) => {
      const s = sm.find((x) => x.at.getTime() === w.at.getTime());
      return [`${fmtDateCT(w.at, true)}, ${w.at.getFullYear()}`, fmtNum(w.lb, 1), s ? fmtNum(s.trend, 1) : "—"];
    })),
  );
}

function lastNDays(n) {
  const today = todayKey();
  return Array.from({ length: n }, (_, i) => shiftDay(today, -(n - 1 - i)));
}

function renderFoodTrends(data) {
  const t = getTargets(data);
  const byDay = new Map((data.daily_totals || []).map((r) => [r.date, r]));
  const keys = lastNDays(30);
  const logged = keys.filter((k) => byDay.has(k));
  if (!logged.length) return card("Calories and protein", el("p", { class: "empty" }, "No food logged in the last 30 days."));
  const today = todayKey();
  if (logged.length < 3) {
    return card("Calories and protein",
      el("p", { class: "lead" }, `${logged.length} day${logged.length === 1 ? "" : "s"} logged in the last 30. The daily charts appear once 3 days are in.`),
      el("div", { class: "props" },
        ...logged.map((k) => {
          const r = byDay.get(k);
          return prop(fmtShortDate(k), `${fmtNum(r.calories, 0)} kcal, ${fmtNum(r.protein_g, 0)} g protein`);
        }),
      ),
    );
  }
  const mk = (field, cls, target, unit, title) => {
    const days = keys.map((k) => ({ key: k, v: byDay.has(k) ? num(byDay.get(k)[field]) : null, today: k === today }));
    const vals = days.filter((d) => d.v != null);
    const avg = vals.reduce((a, d) => a + d.v, 0) / vals.length;
    const hit = target != null ? vals.filter((d) => (field === "protein_g" ? d.v >= target : d.v <= target)).length : null;
    const ro = readout(`${fmtNum(avg, 0)} ${unit} average`, hit != null ? `${hit} of ${vals.length} logged days ${field === "protein_g" ? "at or above" : "at or under"} target` : `${vals.length} logged days`);
    return el("div", { class: "subchart" },
      el("h3", null, el("i", { class: `key rect ${cls}`, "aria-hidden": "true" }), title),
      ro.node,
      columnChart({
        days,
        target,
        targetLabel: target != null ? `Target ${fmtNum(target, 0)}` : null,
        cls,
        height: 140,
        aria: `${title}, last 30 days`,
        onScrub: (d) => {
          if (!d) return ro.reset();
          ro.set(d.v != null ? `${fmtNum(d.v, 0)} ${unit}` : "Not logged", fmtShortDate(d.key));
        },
      }),
    );
  };
  return card("Calories and protein",
    mk("calories", "s1", t.calories, "kcal", "Calories"),
    mk("protein_g", "s2", t.protein, "g", "Protein"),
    dataView("Daily totals", ["Day", "kcal", "Protein"], [...logged].reverse().map((k) => [fmtShortDate(k), fmtNum(byDay.get(k).calories, 0), `${fmtNum(byDay.get(k).protein_g, 0)} g`])),
  );
}

function renderStepsCard(data) {
  const byDay = new Map((data.daily_health || []).map((r) => [r.day, r]));
  const keys = lastNDays(30);
  const days = keys.map((k) => ({ key: k, v: byDay.has(k) ? num(byDay.get(k).steps) : null }));
  const vals = days.filter((d) => d.v != null);
  if (vals.length < 3) return null;
  const avg = vals.reduce((a, d) => a + d.v, 0) / vals.length;
  const ro = readout(`${fmtNum(avg, 0)} a day`, `Average over ${vals.length} days with data`);
  return card("Steps",
    ro.node,
    columnChart({
      days,
      cls: "s4",
      height: 150,
      fmtY: (v) => (v >= 1000 ? `${fmtNum(v / 1000, 0)}K` : fmtNum(v, 0)),
      aria: "Steps, last 30 days",
      onScrub: (d) => {
        if (!d) return ro.reset();
        ro.set(d.v != null ? `${fmtNum(d.v, 0)} steps` : "No data", fmtShortDate(d.key));
      },
    }),
    el("p", { class: "caption" }, "From Apple Health imports, last 30 days."),
  );
}

function renderStall(data) {
  const s = stallCheck(data);
  return card("Stall check",
    el("p", { class: s.ready ? "lead" : "empty" }, s.summary),
    s.ready && s.changed && s.changed.length
      ? el("ul", { class: "receipts" }, ...s.changed.map((c) => el("li", null, c)))
      : null,
    el("p", { class: "caption" }, "A description of what changed, not advice."),
  );
}

function renderCycles(data) {
  const recaps = cycleRecaps(data);
  if (!recaps.length) return card("Cycle recaps", el("p", { class: "empty" }, "Needs logged doses to split cycles."));
  return card("Cycle recaps",
    ...[...recaps].reverse().map((c) => el("div", { class: "cycle" },
      el("h3", null,
        `Cycle ${c.index}, ${fmtNum(c.start.dose_mg, 1)} mg`,
        c.open ? el("span", { class: "badge good" }, "Current") : null,
      ),
      el("p", { class: "cycle-dates" }, `${fmtDateCT(c.start.at, false)} to ${c.open ? "now" : fmtShortDate(c.endDay)}`),
      el("div", { class: "props" },
        prop("Weight", c.delta != null ? `${signed(c.delta)} lb` : "Needs weigh-ins in this cycle"),
        prop("Eating", c.ate ? VS_LABELS[c.ate] : "Needs ate-vs-usual check-ins"),
        prop("Movement", c.moved ? VS_LABELS[c.moved] : (c.steps != null ? `Avg ${fmtNum(c.steps, 0)} steps` : "Needs movement check-ins")),
        prop("Feel", c.feel ? FEEL_LABELS[c.feel] : (c.foodNoise != null ? `Avg food noise ${fmtNum(c.foodNoise, 1)}` : "Needs feel tags")),
        c.vsPrev && c.vsPrev.weight != null ? prop("vs previous", `${signed(c.vsPrev.weight)} lb`) : null,
      ),
    )),
  );
}

function renderWearOff(data) {
  const w = wearOff(data);
  return card("Wear-off",
    el("p", { class: w.ready ? "lead" : "empty" }, w.summary),
    w.ready && w.details && w.details.length
      ? el("ul", { class: "receipts" }, ...w.details.map((d) => el("li", null, `Cycle ${d.cycle}: ${d.fading ? "fading tags" : ""}${d.fading && d.noiseRise ? " and " : ""}${d.noiseRise ? "late-cycle food noise rose" : ""}.`)))
      : null,
  );
}

function renderFeel(data) {
  const f = feelReport(data);
  if (!f.ready) return card("Feel report", el("p", { class: "empty" }, f.summary));
  const cell = (label, row) => metric(label, row ? fmtNum(row.mean, 1) : "—", row ? `${row.n} days` : null);
  return card("Feel report",
    el("div", { class: "tiles" },
      cell("Mood", f.mood),
      cell("Energy", f.energy),
      cell("Food noise", f.food_noise),
      cell("Sleep quality", f.sleep_quality),
    ),
    el("p", { class: "caption" }, `Averages across ${f.count} scored days, on a 1–10 scale.`),
  );
}

function renderExplorer(data) {
  const catalog = metricCatalog(data);
  const xMeta = catalog.find((m) => m.id === state.explorerX) || catalog[0];
  const yMeta = catalog.find((m) => m.id === state.explorerY) || catalog[1];
  const pairs = alignedPair(xMeta.series, yMeta.series);
  const xSel = select({ name: "ex" }, catalog.map((m) => ({ value: m.id, label: m.label })), xMeta.id);
  const ySel = select({ name: "ey" }, catalog.map((m) => ({ value: m.id, label: m.label })), yMeta.id);
  const onChange = () => {
    state.explorerX = xSel.value;
    state.explorerY = ySel.value;
    render();
  };
  xSel.addEventListener("change", onChange);
  ySel.addEventListener("change", onChange);
  const ro = readout(pairs.length >= 3 ? `${pairs.length} overlapping days` : "", "Each dot is a day where both were logged");
  return card("Pattern explorer",
    el("div", { class: "grid two tight" }, field("Across", xSel), field("Up", ySel)),
    pairs.length >= 3
      ? el("div", null,
          ro.node,
          scatterPlot(pairs, {
            aria: `${xMeta.label} vs ${yMeta.label}`,
            onScrub: (p) => {
              if (!p) return ro.reset();
              ro.set(`${fmtNum(p.x, 1)} and ${fmtNum(p.y, 1)}`, `${fmtShortDate(p.day)}: ${xMeta.label} and ${yMeta.label}`);
            },
          }),
        )
      : el("p", { class: "empty" }, `Needs ${Math.max(0, 3 - pairs.length)} more overlapping day${3 - pairs.length === 1 ? "" : "s"} for ${xMeta.label} and ${yMeta.label}.`),
  );
}

function renderEarnWall(data) {
  const cells = earnDays(data, 8);
  const earned = cells.filter((c) => c.earned).length;
  const hasAny = cells.some((c) => c.earned != null);
  if (!hasAny) {
    return card("Earn It wall", el("p", { class: "empty" }, "Mark Earn It on the Log tab to start the wall."));
  }
  const dow = ["S", "M", "T", "W", "T", "F", "S"];
  const first = cells[0].day;
  const [y, m, d] = first.split("-").map(Number);
  const weekday = new Date(Date.UTC(y, m - 1, d)).getUTCDay();
  const pad = Array.from({ length: weekday }, () => el("div", { class: "cell blank" }));
  return card("Earn It wall",
    el("p", { class: "lead" }, `${earned} earned day${earned === 1 ? "" : "s"} in the last 8 weeks.`),
    el("div", { class: "wall" },
      ...dow.map((d0) => el("div", { class: "dow" }, d0)),
      ...pad,
      ...cells.map((c) => el("div", {
        class: "cell" + (c.earned ? " earned" : c.has && c.earned === false ? " missed" : "") + (c.today ? " today" : ""),
        title: `${fmtShortDate(c.day)}: ${c.earned ? "earned" : c.has && c.earned === false ? "not earned" : "not marked"}`,
      })),
    ),
    el("div", { class: "legend" },
      el("span", null, el("i", { class: "key rect earned" }), "Earned"),
      el("span", null, el("i", { class: "key rect missed" }), "Not earned"),
      el("span", null, el("i", { class: "key rect blank" }), "Not marked"),
    ),
  );
}

function renderSideEffects(data) {
  const rows = data.side_effects || [];
  if (!rows.length) return card("Side effects", el("p", { class: "empty" }, "No side effects logged yet."));
  return card("Side effects",
    el("ul", { class: "list" },
      ...[...rows].reverse().map((r) => {
        const sev = num(r.severity) || 0;
        const tone = sev >= 7 ? "high" : sev >= 4 ? "mid" : "low";
        return el("li", { class: "effect" },
          el("div", { class: "effect-main" },
            el("span", { class: "effect-name" }, r.effect),
            el("span", { class: "effect-sub" }, [fmtShortDate(r.recorded_on), r.notes].filter(Boolean).join(". ")),
          ),
          el("span", { class: `sev ${tone}`, "aria-label": `Severity ${sev} of 10` }, String(sev), el("small", null, "/10")),
        );
      }),
    ),
  );
}

function renderMeasurements(data) {
  // Body fat and lean mass have their own card.
  const rows = (data.measurements || []).filter((r) => r.metric !== "body_fat_pct" && r.metric !== "lean_mass_lb");
  if (!rows.length) return card("Measurements", el("p", { class: "empty" }, "No tape measurements yet. Log waist or other metrics on the Log tab."));
  const byMetric = {};
  for (const r of rows) (byMetric[r.metric] ||= []).push(r);
  const charts = Object.entries(byMetric).map(([name, list]) => {
    const sorted = list.filter((r) => parseTs(r.measured_at) && num(r.value) != null).sort((a, b) => parseTs(a.measured_at) - parseTs(b.measured_at));
    const pts = sorted.map((r) => ({ t: parseTs(r.measured_at), v: num(r.value) }));
    const unit = (sorted[0] && sorted[0].unit) || "";
    const lastP = pts[pts.length - 1];
    const ro = readout(lastP ? `${fmtNum(lastP.v, 1)} ${unit}` : "—", lastP ? `Latest, ${fmtDateCT(lastP.t, true)}` : "");
    return el("div", { class: "subchart" },
      el("h3", null, capitalize(name)),
      ro.node,
      pts.length >= 2
        ? timeChart({
            t0: pts[0].t, t1: new Date(Math.max(Date.now(), lastP.t.getTime())), height: 150, aria: name,
            fmtY: (v) => fmtNum(v, 1),
            series: [{ id: "m", cls: "s1", type: "line", endDot: true, points: pts }, { id: "md", cls: "s1", type: "dots", points: pts }],
            snap: "m",
            onScrub: (r) => { if (!r) return ro.reset(); ro.set(`${fmtNum(r.point.v, 1)} ${unit}`, fmtDateCT(r.point.t, true)); },
          })
        : el("p", { class: "empty" }, "Log one more to see a trend."),
    );
  });
  return card("Measurements", ...charts);
}

function renderWeekly(data) {
  const weeks = data.weekly_summary || [];
  if (!weeks.length) return null;
  return card("Weekly summary",
    el("div", { class: "table-scroll" }, el("table", { class: "data" },
      el("thead", null, el("tr", null, el("th", null, "Week of"), el("th", { class: "num" }, "kcal/day"), el("th", { class: "num" }, "Protein"), el("th", { class: "num" }, "Avg lb"))),
      el("tbody", null, ...[...weeks].reverse().slice(0, 8).map((w) => el("tr", null,
        el("td", null, fmtShortDate(w.week)),
        el("td", { class: "num" }, fmtNum(w.avg_daily_calories, 0)),
        el("td", { class: "num" }, w.avg_protein_g != null ? `${fmtNum(w.avg_protein_g, 0)} g` : "—"),
        el("td", { class: "num" }, w.avg_weight_lb != null ? fmtNum(w.avg_weight_lb, 1) : "—"),
      ))),
    )),
  );
}

function renderWorkouts(data) {
  const workouts = data.workouts || [];
  if (!workouts.length) return null;
  return card("Workouts",
    el("p", { class: "lead" }, `${fmtNum(data.workout_count || workouts.length, 0)} workouts imported from Apple Health. The latest ${Math.min(8, workouts.length)}:`),
    el("div", { class: "table-scroll" }, el("table", { class: "data" },
      el("thead", null, el("tr", null, el("th", null, "When"), el("th", null, "Activity"), el("th", { class: "num" }, "Min"), el("th", { class: "num" }, "Avg HR"))),
      el("tbody", null, ...workouts.slice(0, 8).map((w) => el("tr", null,
        el("td", null, parseTs(w.started_at) ? fmtDateCT(parseTs(w.started_at), true) : "—"),
        el("td", null, capitalize(w.activity || "—"), w.distance_mi != null ? el("span", { class: "sub" }, `${fmtNum(w.distance_mi, 2)} mi`) : null),
        el("td", { class: "num" }, fmtNum(w.duration_min, 0)),
        el("td", { class: "num" }, w.avg_hr != null ? fmtNum(w.avg_hr, 0) : "—"),
      ))),
    )),
  );
}

function renderExport(data) {
  return card("Prescriber export",
    el("p", { class: "lead" }, "Files stay on this phone. Save a print view as a PDF from the print sheet."),
    el("div", { class: "form-actions" },
      el("button", { type: "button", class: "primary", onClick: () => prescriberCSV(data) }, "Download CSV"),
      el("button", { type: "button", onClick: () => prescriberPrint(data) }, "Print or save PDF"),
      el("button", { type: "button", onClick: () => coachPackPrint(data) }, "4-week coach pack"),
    ),
    el("p", { class: "caption" }, "The 4-week pack is a one-pager of recent weight, doses, protein hit rate, food thoughts and side effects, meant for a doctor."),
    el("p", { class: "caption" }, "Not possible on the web: Apple Health sync, home-screen widgets, an Apple Watch app, or body-fat estimates from photos."),
  );
}

/* Trends, one section at a time: a summary that opens each section, then the detail cards. */
function renderTrendsTab(data) {
  const active = trendSection();
  const sections = {
    summary: () => [renderTrendSummary(data), renderWeightCard(data)],
    weight: () => [renderWeightCard(data), renderStall(data), renderBodyComp(data)],
    food: () => [renderFoodTrends(data), renderMaintenance(data), renderProteinCard(data), renderFoodThoughtsCard(data)],
    meds: () => [renderShotWeek(data), renderAppetiteByLevel(data), renderRetaVsTirz(data), renderCycles(data), renderFeel(data), renderWearOff(data), renderSideEffects(data)],
    body: () => [renderOffNormalTrends(data), renderHeartCard(data), renderMoreHealth(data), renderMeasurements(data)],
    training: () => [renderStepsCard(data), renderWorkouts(data)],
    more: () => [renderExplorer(data), renderEarnWall(data), renderWeekly(data), renderExport(data)],
  };
  return el("div", { class: "stack" }, renderTrendNav(active), ...sections[active]());
}

function renderApp(data) {
  const body = state.tab === "meds" ? renderMedsTab(data)
    : state.tab === "trends" ? renderTrendsTab(data)
    : state.tab === "log" ? renderLogTab(data)
    : renderTodayTab(data);
  return el("div", { class: "shell" + (state.updating ? " refreshing" : "") },
    renderTopbar(data),
    body,
    tabNav(),
  );
}

function renderGate() {
  const err = state.error === "bad-passcode"
    ? "That passcode didn’t work. Try again."
    : state.error === "empty-passcode"
      ? "Enter your passcode first."
      : null;
  const letters = state.gateLetters;
  const dots = el("div", { class: "pin-dots", "aria-hidden": "true" });
  const field = el("input", {
    type: "password",
    id: "passcode",
    name: "passcode",
    class: "pin-input",
    autocomplete: "current-password",
    autocapitalize: "off",
    autocorrect: "off",
    spellcheck: "false",
    enterkeyhint: "go",
    inputmode: letters ? "text" : "numeric",
    pattern: letters ? null : "[0-9]*",
    maxlength: "64",
    "aria-label": "Passcode",
    disabled: state.loading ? "disabled" : null,
  });
  const drawDots = () => {
    const n = field.value.length;
    dots.innerHTML = "";
    const count = Math.max(4, n);
    for (let i = 0; i < count; i++) dots.append(el("span", { class: i < n ? "on" : "" }));
    unlock.disabled = state.loading || n === 0;
  };
  const onSubmit = () => {
    if (state.loading) return;
    submitPasscode(field.value);
  };
  const unlock = el("button", { type: "button", class: "primary wide", onClick: onSubmit }, state.loading ? "Checking…" : "Unlock");
  field.addEventListener("input", drawDots);
  field.addEventListener("keydown", (e) => {
    if (e.key === "Enter") {
      e.preventDefault();
      onSubmit();
    }
  });
  const pad = el("label", { class: "pin-pad" + (err ? " shake" : ""), for: "passcode" }, dots, field);
  drawDots();
  const box = el("main", { class: "gate" },
    el("img", { class: "gate-icon", src: "icons/icon-180.png", alt: "", width: "72", height: "72" }),
    el("h1", null, "Log"),
    el("p", { class: "gate-sub" }, "Enter your passcode"),
    pad,
    el("p", { class: "gate-err", role: "alert" }, err || ""),
    unlock,
    el("button", {
      type: "button",
      class: "link",
      onClick: () => { state.gateLetters = !state.gateLetters; render(); setTimeout(() => { const f = $("#passcode"); if (f) f.focus(); }, 0); },
    }, letters ? "Use number pad" : "Use letters"),
    el("p", { class: "gate-note" }, "This phone remembers it until you tap Lock."),
  );
  // Desktop browsers focus right away; on iPhone the number pad opens when you tap the dots.
  setTimeout(() => { if (!("ontouchstart" in window)) field.focus(); }, 0);
  return box;
}

function renderUnauthorized() {
  return el("main", { class: "gate" },
    el("img", { class: "gate-icon", src: "icons/icon-180.png", alt: "", width: "72", height: "72" }),
    el("h1", null, "Log"),
    el("p", { class: "gate-sub" }, "This access link isn’t valid anymore. Open the app without the link and use your passcode."),
    el("button", { type: "button", class: "primary wide", onClick: lock }, "Use passcode"),
  );
}

function renderError() {
  return el("main", { class: "gate" },
    el("img", { class: "gate-icon", src: "icons/icon-180.png", alt: "", width: "72", height: "72" }),
    el("h1", null, "Log"),
    el("p", { class: "gate-sub" }, "Couldn’t load your log. Check your connection, then try again."),
    el("button", { type: "button", class: "primary wide", onClick: () => load(false) }, "Try again"),
  );
}

function renderLoading() {
  return el("div", { class: "shell skel", "aria-busy": "true" },
    el("header", { class: "topbar" }, el("div", { class: "titles" }, el("h1", null, "Log"))),
    el("div", { class: "hero" }, el("div", { class: "pulse big" }), el("div", { class: "pulse" })),
    el("div", { class: "card" }, el("div", { class: "pulse" }), el("div", { class: "pulse" }), el("div", { class: "pulse short" })),
    el("div", { class: "card" }, el("div", { class: "pulse" }), el("div", { class: "pulse short" })),
  );
}

function fmtShortDate(isoDate) {
  if (!isoDate) return "—";
  const [y, m, d] = String(isoDate).split("-").map(Number);
  if (!y) return "—";
  const dt = new Date(Date.UTC(y, m - 1, d, 18, 0, 0));
  return fmtDateCT(dt, false);
}

function render() {
  lastWidth = window.innerWidth;
  const root = $("#app");
  const scrollY = window.scrollY;
  root.innerHTML = "";
  const gate = !hasCredential() || state.error === "bad-passcode" || state.error === "empty-passcode";
  document.body.classList.toggle("locked", gate || (state.error && !state.data));
  syncShell(!!(gate || (state.error && !state.data)));
  if (gate) root.append(renderGate());
  else if (state.loading && !state.data) root.append(renderLoading());
  else if (state.error === "unauthorized") root.append(renderUnauthorized());
  else if (state.error && !state.data) root.append(renderError());
  else if (state.data) {
    root.append(renderApp(state.data));
    window.scrollTo(0, scrollY);
  }
}

/* ---------- the native shell (iPhone app 1.2+) ---------- */
// Inside the app, LogShell.swift sets window.LOG_NATIVE before this runs: the tab bar is native and
// the passcode lives in the Keychain. In a browser (and the tests) none of this applies.
const NATIVE = window.LOG_NATIVE || null;
const nativeTabs = !!(NATIVE && NATIVE.tabs);
document.documentElement.classList.toggle("native-tabs", nativeTabs);

function shellPost(message) {
  try {
    const h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.logShell;
    return h ? Promise.resolve(h.postMessage(message)).catch(() => null) : Promise.resolve(null);
  } catch (_) {
    return Promise.resolve(null);
  }
}

function storePasscode(code) {
  if (window.LOG_DEMO) return;
  if (NATIVE && NATIVE.keychain) {
    shellPost({ type: "setPasscode", passcode: code });
    try { localStorage.removeItem(PASS_KEY); } catch (_) { /* ignore */ }
    return;
  }
  try { localStorage.setItem(PASS_KEY, code); } catch (_) { /* ignore quota */ }
}

function clearPasscode() {
  if (NATIVE && NATIVE.keychain) shellPost({ type: "clearPasscode" });
  try { localStorage.removeItem(PASS_KEY); } catch (_) { /* ignore */ }
}

async function readPasscode() {
  if (window.LOG_DEMO) return "demo";
  let local = "";
  try { local = localStorage.getItem(PASS_KEY) || ""; } catch (_) { /* ignore */ }
  if (!(NATIVE && NATIVE.keychain)) return local;
  const saved = await shellPost({ type: "getPasscode" });
  if (saved) return String(saved);
  // Moving from 1.1, which kept it in the web view's storage: hand it to the Keychain once.
  if (local) storePasscode(local);
  return local;
}

/* The native tab bar picked a tab (or the current one again). */
function selectTab(id) {
  if (!TABS.some((t) => t.id === id)) return;
  if (state.tab === id) {
    if (id === "today" && state.dayOffset) { state.daySlide = "next"; state.dayOffset = 0; render(); }
    window.scrollTo({ top: 0, behavior: "smooth" });
    return;
  }
  state.tab = id;
  state.formMessage = null;
  state.checkinOpen = false;
  render();
  window.scrollTo(0, 0);
}
window.logShellSelectTab = selectTab;

/* Keep the native tab bar in step with the page: hidden on the lock screen, following tab changes. */
const shellSeen = { tab: null, locked: null };
function syncShell(locked) {
  if (!nativeTabs) return;
  if (shellSeen.locked !== locked) { shellSeen.locked = locked; shellPost({ type: "locked", locked }); }
  if (!locked && shellSeen.tab !== state.tab) { shellSeen.tab = state.tab; shellPost({ type: "tab", tab: state.tab }); }
}

async function boot() {
  state.token = readToken();
  state.passcode = state.token ? "" : await readPasscode();
  // Open straight to the last data this phone saw, then refresh it in place.
  if (hasCredential()) {
    try {
      const cached = JSON.parse(localStorage.getItem(CACHE_KEY) || "null");
      if (cached && cached.as_of) { state.data = cached; state.fromCache = true; }
    } catch (_) { /* ignore a bad cache */ }
  }
  const demoTab = () => { if (window.LOG_DEMO && window.LOG_DEMO.tab) selectTab(window.LOG_DEMO.tab); };
  if (state.data) { render(); demoTab(); load(true).then(() => autoSyncHealth()); }
  else load(false).then(() => { demoTab(); autoSyncHealth(); });
}

// The iPhone app ships its files inside the app, so it needs no service worker (and WKWebView has none).
const isNativeApp = !!(window.Capacitor && typeof window.Capacitor.isNativePlatform === "function" && window.Capacitor.isNativePlatform());
if (!isNativeApp && "serviceWorker" in navigator && (location.protocol === "https:" || location.hostname === "localhost" || location.hostname === "127.0.0.1")) {
  window.addEventListener("load", () => { navigator.serviceWorker.register("sw.js").catch(() => { /* offline shell is optional */ }); });
}

/* Redraw charts when the width really differs from the one they were drawn at. */
let resizeTimer = null;
window.addEventListener("resize", () => {
  // The Log tab has no charts; redrawing it, or an open form, would wipe what you've typed.
  if (state.tab === "log" || state.checkinOpen || state.editTargets) return;
  if (Math.abs(window.innerWidth - lastWidth) < 24) return;
  clearTimeout(resizeTimer);
  resizeTimer = setTimeout(() => {
    lastWidth = window.innerWidth;
    if (state.data && hasCredential()) render();
  }, 150);
});

window.addEventListener("keydown", (e) => {
  if (state.tab !== "today" || !state.data || e.target.closest("input, textarea, select, .chart-wrap")) return;
  if (e.key === "ArrowLeft") goToDay(state.data, (state.dayOffset || 0) - 1);
  else if (e.key === "ArrowRight") goToDay(state.data, (state.dayOffset || 0) + 1);
});

/* ---------- pull to refresh (home-screen app and the Log iPhone app) ---------- */
// Pull down from the top of any tab: syncs the last two days from Apple Health when it can,
// then reloads. Browsers in a tab already have their own pull to refresh, so it stays off there.
const PTR_TRIGGER = 64;
const ptr = { start: null, pull: 0, busy: false, node: null };

function ptrEnabled() {
  return isStandalone() || nativeTabs || canSyncHealth();
}

function ptrNode() {
  if (!ptr.node) {
    ptr.node = el("div", { class: "ptr", "aria-hidden": "true" });
    ptr.node.innerHTML = ICONS.refresh;
    document.body.append(ptr.node);
  }
  return ptr.node;
}

function ptrSet(px, settle) {
  ptr.pull = px;
  const n = ptrNode();
  n.classList.toggle("settle", !!settle);
  n.classList.toggle("on", px > 0);
  n.classList.toggle("ready", px >= PTR_TRIGGER);
  n.style.setProperty("--pull", `${px}px`);
  n.style.setProperty("--p", String(Math.min(1, px / PTR_TRIGGER)));
}

async function pullRefresh() {
  ptr.busy = true;
  const n = ptrNode();
  ptrSet(PTR_TRIGGER, true);
  n.classList.add("spin");
  try {
    if (canSyncHealth() && !state.healthBusy) {
      state.healthBusy = true;
      const r = await syncAppleHealth({ days: 2 });
      state.healthBusy = false;
      state.healthMsg = r.ok ? null : { ok: false, text: r.reason };
    } else if (NATIVE && NATIVE.healthSync && !window.LOG_DEMO) {
      await shellPost({ type: "syncHealth" }); // the app's native Apple Health sync
    }
    await load(true, true);
  } finally {
    ptr.busy = false;
    n.classList.remove("spin");
    ptrSet(0, true);
  }
}

window.addEventListener("touchstart", (e) => {
  ptr.start = null;
  if (!ptrEnabled() || ptr.busy || e.touches.length !== 1 || window.scrollY > 0) return;
  if (!state.data || !hasCredential() || document.body.classList.contains("locked")) return;
  if (e.target.closest("input, textarea, select, .chart-wrap, .week-strip, .table-scroll")) return;
  ptr.start = { x: e.touches[0].clientX, y: e.touches[0].clientY, dir: null };
}, { passive: true });

window.addEventListener("touchmove", (e) => {
  if (!ptr.start) return;
  const t = e.touches[0];
  const dx = t.clientX - ptr.start.x;
  const dy = t.clientY - ptr.start.y;
  if (!ptr.start.dir) {
    if (Math.abs(dx) < 8 && Math.abs(dy) < 8) return;
    ptr.start.dir = dy > 0 && Math.abs(dy) > Math.abs(dx) * 1.5 ? "down" : "other";
  }
  if (ptr.start.dir !== "down" || window.scrollY > 0) {
    if (ptr.pull) ptrSet(0, true);
    ptr.start = null;
    return;
  }
  ptrSet(Math.min(110, Math.max(0, dy) * 0.5));
}, { passive: true });

window.addEventListener("touchend", () => {
  if (!ptr.start) return;
  ptr.start = null;
  if (ptr.pull >= PTR_TRIGGER) pullRefresh();
  else if (ptr.pull) ptrSet(0, true);
}, { passive: true });

window.addEventListener("touchcancel", () => {
  ptr.start = null;
  if (ptr.pull && !ptr.busy) ptrSet(0, true);
}, { passive: true });

document.documentElement.classList.toggle("ptr-on", ptrEnabled());

const isSelfTest = /(?:^|\/)test-features\.html$/.test(location.pathname);
if (!isSelfTest) {
  window.addEventListener("hashchange", boot);
  boot();
  // Background refresh every minute, but not while you're filling in a form on the Log tab.
  setInterval(() => {
    if (!hasCredential() || state.loading || state.formBusy) return;
    if (state.tab === "log" || state.checkinOpen || state.editTargets) return;
    load(true, true);
  }, 60000);
}
