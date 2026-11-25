const API_URL = "https://qnbshmenmurdaogslmrj.supabase.co/functions/v1/log-dashboard";
const TZ = "America/Chicago";
const HALF_LIFE_DAYS = 5;
const RETA_START = new Date("2026-12-06T12:00:00-06:00");
const HALF_MARATHON = new Date("2026-12-13T08:00:00-06:00");
const GOAL_LB = 235;
const TIRZ_START = new Date("2026-11-02T12:00:00-06:00");

const SITE_LABELS = {
  "Abd LR": "Abdomen, lower right",
  "Abd LL": "Abdomen, lower left",
  "Abd UR": "Abdomen, upper right",
  "Abd UL": "Abdomen, upper left",
  "Love L": "Love handle, left",
  "Love R": "Love handle, right",
};

const PASS_KEY = "log.passcode";

const state = {
  token: "",
  passcode: "",
  data: null,
  error: null,
  loading: true,
  updating: false,
  weightRange: "90d",
  tab: "today",
  formMessage: null,
  formBusy: false,
  explorerX: "weight",
  explorerY: "steps",
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

function partsInTZ(date) {
  const fmt = new Intl.DateTimeFormat("en-US", {
    timeZone: TZ,
    year: "numeric",
    month: "short",
    day: "numeric",
    weekday: "short",
    hour: "numeric",
    minute: "2-digit",
    hour12: true,
  });
  const map = {};
  for (const p of fmt.formatToParts(date)) map[p.type] = p.value;
  return map;
}

function dateKeyCT(date) {
  const fmt = new Intl.DateTimeFormat("en-CA", {
    timeZone: TZ,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  });
  return fmt.format(date);
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
  const res = await fetch(API_URL, {
    headers: authHeaders(),
    cache: "no-store",
    referrerPolicy: "no-referrer",
  });
  if (res.status === 401) throw new Error("unauthorized");
  if (!res.ok) throw new Error("Could not load the log.");
  return res.json();
}

async function load(isRefresh) {
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
  render();
  try {
    const data = await fetchData();
    state.data = data;
    state.error = null;
    if (state.passcode && !state.token) {
      try { localStorage.setItem(PASS_KEY, state.passcode); } catch (_) { /* ignore quota */ }
    }
  } catch (err) {
    const unauthorized = err.message === "unauthorized";
    if (unauthorized && state.passcode && !state.token) {
      state.passcode = "";
      try { localStorage.removeItem(PASS_KEY); } catch (_) { /* ignore */ }
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
    render();
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
  try { localStorage.removeItem(PASS_KEY); } catch (_) { /* ignore */ }
  if (location.hash) {
    history.replaceState(null, "", location.pathname + location.search);
  }
  render();
}

function metric(label, value, detail, feature) {
  return el("div", { class: feature ? "metric feature" : "metric" },
    el("span", { class: "label" }, label),
    el("span", { class: "value" }, value),
    detail ? el("span", { class: "detail" }, detail) : null,
  );
}

function prop(k, v) {
  return el("div", { class: "prop" },
    el("span", { class: "k" }, k),
    el("span", { class: "v" }, v),
  );
}

function card(title, ...kids) {
  return el("section", { class: "card" }, el("h2", null, title), ...kids);
}

function lineChart(seriesList, opts) {
  const width = 640;
  const height = 220;
  const pad = { l: 44, r: 12, t: 16, b: 28 };
  const all = seriesList.flatMap((s) => s.values.filter((v) => Number.isFinite(v)));
  if (!all.length) return el("p", { class: "caption" }, "Not enough points to chart.");
  const lo = opts.floor != null ? opts.floor : Math.min(...all);
  const hi = opts.ceiling != null ? opts.ceiling : Math.max(...all);
  const span = hi - lo || 1;
  const n = seriesList[0].values.length;
  const xs = (i) => pad.l + (n === 1 ? 0 : (i / (n - 1)) * (width - pad.l - pad.r));
  const ys = (v) => pad.t + (1 - (v - lo) / span) * (height - pad.t - pad.b);
  const ticks = [lo, lo + span / 2, hi];
  const labelIdx = (opts.labels || []).map((lab, i) => (lab ? i : -1)).filter((i) => i >= 0);

  let svg = `<svg class="chart" viewBox="0 0 ${width} ${height}" role="img" aria-label="${opts.aria || "Chart"}">`;
  for (const t of ticks) {
    svg += `<line class="gridline" x1="${pad.l}" x2="${width - pad.r}" y1="${ys(t)}" y2="${ys(t)}" />`;
    svg += `<text class="axis" x="${pad.l - 8}" y="${ys(t) + 3}" text-anchor="end">${opts.format ? opts.format(t) : fmtNum(t, 1)}</text>`;
  }
  seriesList.forEach((s, si) => {
    const pts = s.values
      .map((v, i) => (Number.isFinite(v) ? `${xs(i).toFixed(1)},${ys(v).toFixed(1)}` : null))
      .filter(Boolean);
    if (!pts.length) return;
    const cls = (si === 0 ? "line" : "line alt") + (s.dashed ? " dash" : "");
    if (si === 0 && opts.area) {
      const first = s.values.findIndex((v) => Number.isFinite(v));
      const last = s.values.length - 1 - [...s.values].reverse().findIndex((v) => Number.isFinite(v));
      svg += `<polygon class="area" points="${xs(first)},${ys(lo)} ${pts.join(" ")} ${xs(last)},${ys(lo)}" />`;
    }
    svg += `<polyline class="${cls}" points="${pts.join(" ")}" />`;
  });
  for (const i of labelIdx) {
    svg += `<text class="lbl" x="${xs(i)}" y="${height - 8}" text-anchor="${i === 0 ? "start" : i === n - 1 ? "end" : "middle"}">${opts.labels[i]}</text>`;
  }
  for (const mark of opts.marks || []) {
    if (mark.i == null) continue;
    svg += `<line class="mark" x1="${xs(mark.i)}" x2="${xs(mark.i)}" y1="${pad.t}" y2="${height - pad.b}" />`;
    if (mark.text) {
      svg += `<text class="marklbl" x="${xs(mark.i) + 4}" y="${pad.t + 10}">${mark.text}</text>`;
    }
  }
  svg += "</svg>";
  const wrap = el("div");
  wrap.innerHTML = svg;
  return wrap;
}

function todayTotals(data) {
  const key = todayKey();
  const row = (data.daily_totals || []).find((d) => d.date === key);
  if (row) return row;
  const meals = (data.meals || []).filter((m) => {
    const t = parseTs(m.eaten_at);
    return t && dateKeyCT(t) === key;
  });
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

function todayMeals(data) {
  const key = todayKey();
  return (data.meals || []).filter((m) => {
    const t = parseTs(m.eaten_at);
    return t && dateKeyCT(t) === key;
  });
}

function latestHealth(data) {
  const rows = data.daily_health || [];
  return rows.length ? rows[rows.length - 1] : null;
}

function weightStats(weights) {
  if (!weights.length) return null;
  const parsed = weights
    .map((w) => ({ at: parseTs(w.measured_at), lb: num(w.weight_lb), notes: w.notes }))
    .filter((w) => w.at && w.lb != null)
    .sort((a, b) => a.at - b.at);
  if (!parsed.length) return null;
  const current = parsed[parsed.length - 1];
  const start = parsed.find((w) => w.at >= TIRZ_START) || parsed[0];
  return { parsed, current, start, change: current.lb - start.lb };
}

function filterWeights(parsed, range) {
  if (range === "all") return parsed;
  const days = range === "1y" ? 365 : 90;
  const cut = Date.now() - days * 86400000;
  const subset = parsed.filter((w) => w.at.getTime() >= cut);
  return subset.length ? subset : parsed.slice(-2);
}

function scatterChart(pairs, opts) {
  const width = 640;
  const height = 220;
  const pad = { l: 44, r: 12, t: 16, b: 28 };
  if (!pairs.length) return el("p", { class: "empty" }, "Not enough overlapping days for those two metrics.");
  const xs = pairs.map((p) => p.x);
  const ys = pairs.map((p) => p.y);
  const xlo = Math.min(...xs), xhi = Math.max(...xs);
  const ylo = Math.min(...ys), yhi = Math.max(...ys);
  const xspan = xhi - xlo || 1;
  const yspan = yhi - ylo || 1;
  const X = (v) => pad.l + ((v - xlo) / xspan) * (width - pad.l - pad.r);
  const Y = (v) => pad.t + (1 - (v - ylo) / yspan) * (height - pad.t - pad.b);
  let svg = `<svg class="chart" viewBox="0 0 ${width} ${height}" role="img" aria-label="${opts.aria || "Scatter"}">`;
  svg += `<line class="gridline" x1="${pad.l}" x2="${width - pad.r}" y1="${Y(ylo)}" y2="${Y(ylo)}" />`;
  svg += `<text class="axis" x="${pad.l - 8}" y="${Y(ylo) + 3}" text-anchor="end">${fmtNum(ylo, 1)}</text>`;
  svg += `<text class="axis" x="${pad.l - 8}" y="${Y(yhi) + 3}" text-anchor="end">${fmtNum(yhi, 1)}</text>`;
  svg += `<text class="lbl" x="${pad.l}" y="${height - 8}" text-anchor="start">${fmtNum(xlo, 1)}</text>`;
  svg += `<text class="lbl" x="${width - pad.r}" y="${height - 8}" text-anchor="end">${fmtNum(xhi, 1)}</text>`;
  for (const p of pairs) {
    svg += `<circle cx="${X(p.x).toFixed(1)}" cy="${Y(p.y).toFixed(1)}" r="4" fill="currentColor" opacity="0.75" />`;
  }
  svg += "</svg>";
  const wrap = el("div");
  wrap.innerHTML = svg;
  return wrap;
}

function tabNav() {
  const tabs = [
    { id: "today", label: "Today" },
    { id: "meds", label: "Meds" },
    { id: "trends", label: "Trends" },
    { id: "log", label: "Log" },
  ];
  return el("nav", { class: "tabnav", "aria-label": "Sections" },
    ...tabs.map((t) => el("button", {
      type: "button",
      "aria-current": state.tab === t.id ? "page" : null,
      onClick: () => { state.tab = t.id; state.formMessage = null; render(); },
    }, t.label)),
  );
}

function renderJourney(data) {
  const j = journeyStats(data);
  if (!j) return card("Journey", el("p", { class: "empty" }, "Needs a weigh-in to start the journey header."));
  const pace = j.pace
    ? (j.pace.met
      ? "At or past the goal."
      : j.pace.stalled
        ? `${fmtNum(j.pace.toGo, 1)} lb to go · pace is too flat to date.`
        : `${fmtNum(j.pace.toGo, 1)} lb to go · ${fmtNum(j.pace.rate, 1)} lb/week since the first post-dose weigh-in, would reach ${fmtNum(j.goalLb, 0)} around ${fmtDateCT(j.pace.eta, true)}.`)
    : (j.goalLb != null ? "Set a goal to see pace." : "No goal weight set.");
  return card("Journey",
    el("div", { class: "journey" },
      metric("Start", `${fmtNum(j.startLb, 1)} lb`, "WeightSnap start"),
      metric("Current", `${fmtNum(j.current.lb, 1)} lb`, fmtDateCT(j.current.at, true)),
      metric("Change", `${j.changeStart > 0 ? "+" : ""}${fmtNum(j.changeStart, 1)} lb`, `Since start · ${j.changeTirz > 0 ? "+" : ""}${fmtNum(j.changeTirz, 1)} lb since ${fmtDateCT(j.sinceTirz.at, false)}`),
      metric("Goal", j.goalLb != null ? `${fmtNum(j.goalLb, 1)} lb` : "—", pace),
    ),
  );
}

function renderVerdict(data) {
  const v = verdictCard(data);
  const badgeClass = v.tone === "watch" ? "badge watch" : v.tone === "good" ? "badge" : "badge steady";
  return card("Verdict",
    el("div", { class: "verdict" },
      el("span", { class: badgeClass }, v.label),
      el("ul", null, ...v.receipts.map((r) => el("li", null, r))),
    ),
  );
}

function renderCheckinNudge(data) {
  const cur = todayCheckin(data);
  if (cur && (cur.ate_vs_usual || cur.moved_vs_usual || cur.dose_feel || cur.mood != null)) {
    return el("div", { class: "callout" },
      el("strong", null, "Today’s check-in is in."),
      el("span", null, [
        cur.ate_vs_usual ? `Ate: ${VS_LABELS[cur.ate_vs_usual] || cur.ate_vs_usual}. ` : "",
        cur.moved_vs_usual ? `Moved: ${VS_LABELS[cur.moved_vs_usual] || cur.moved_vs_usual}. ` : "",
        cur.dose_feel ? `Feel: ${FEEL_LABELS[cur.dose_feel] || cur.dose_feel}.` : "",
      ].join("") || "Open the Log tab to add more."),
    );
  }
  return el("div", { class: "callout" },
    el("strong", null, "No 3-tap check-in yet today."),
    el("span", null, "It takes a few taps on the Log tab: ate, moved, and how the dose feels."),
    el("div", { class: "form-actions", style: { marginTop: "8px" } },
      el("button", { type: "button", class: "primary", onClick: () => { state.tab = "log"; render(); } }, "Check in"),
    ),
  );
}

function renderSiteMap(data) {
  const rot = siteRotation(data);
  return card("Injection sites",
    el("p", { class: "caption" },
      rot.lastSite ? `Last used ${rot.lastSite} on ${fmtDateCT(parseTs(rot.last.taken_at), true)}.` : "No sites logged yet.",
      rot.next ? ` Suggested next: ${rot.next}.` : "",
    ),
    el("div", { class: "sites" },
      ...SITES.map((s) => {
        const used = rot.lastUsed[s];
        const cls = s === rot.next ? "site next" : s === rot.lastSite ? "site last" : "site";
        return el("div", { class: cls },
          s,
          el("span", { class: "sub" },
            s === rot.next ? "Suggested next" : used ? `Last ${fmtDateCT(used, false)}` : "Not used yet",
          ),
        );
      }),
    ),
  );
}

function renderTitration(data) {
  const steps = titrationHistory(data.doses || []);
  if (!steps.length) return card("Titration", el("p", { class: "empty" }, "No doses yet."));
  return card("Titration history",
    el("div", { class: "props" },
      ...steps.map((d) => prop(
        fmtDateCT(parseTs(d.taken_at), true),
        d.skipped
          ? `Skipped ${capitalize(d.compound || "")}`
          : `${fmtNum(d.mg, 1)} mg ${capitalize(d.compound || "")}${d.changed && d.mg != null ? " · change" : ""}${d.site ? " · " + d.site : ""}`,
      )),
    ),
  );
}

function renderVials(data) {
  const r = vialRunway(data);
  if (!r.ready) return card("Vials", el("p", { class: "empty" }, r.summary));
  return card("Vials",
    r.soonest ? el("p", { class: "caption" }, `Supply runway: around ${fmtDateCT(r.soonest.until, true)} if the current weekly dose continues.`) : null,
    el("div", { class: "props" },
      ...r.items.map((v) => prop(
        `${capitalize(v.compound)}${v.label ? " · " + v.label : ""}`,
        [
          v.remaining_mg != null ? `${fmtNum(v.remaining_mg, 1)} / ${fmtNum(v.total_mg, 1)} mg` : "",
          v.remaining_units != null ? `${fmtNum(v.remaining_units, 0)} units left` : "",
          v.expired_on ? `exp ${fmtShortDate(v.expired_on)}` : "",
        ].filter(Boolean).join(" · ") || "—",
      )),
    ),
  );
}

function renderProtocol(data) {
  const rows = data.protocol || [];
  if (!rows.length) return null;
  return card("Protocol",
    ...rows.map((p) => el("div", { class: "cycle" },
      el("h3", null, p.display_name || capitalize(p.compound)),
      el("div", { class: "props" },
        prop("Status", p.status),
        prop("Dose", p.typical_dose_mg != null ? `${fmtNum(p.typical_dose_mg, 1)} mg ${p.frequency || ""}`.trim() : (p.units != null ? `${fmtNum(p.units, 0)} units ${p.frequency || ""}`.trim() : "—")),
        prop("Half-life", p.half_life_hours != null ? `${fmtNum(p.half_life_hours / 24, 1)} days` : "—"),
        prop("Starts", p.started_on ? fmtShortDate(p.started_on) : "—"),
        p.notes ? prop("Notes", p.notes) : null,
      ),
    )),
  );
}

function renderStall(data) {
  const s = stallCheck(data);
  return card("Stall check",
    el("p", { class: s.ready ? "" : "empty" }, s.summary),
    s.ready && s.changed && s.changed.length
      ? el("ul", null, ...s.changed.map((c) => el("li", null, c)))
      : null,
    el("p", { class: "caption" }, "This is a description of what changed, not advice."),
  );
}

function renderCycles(data) {
  const recaps = cycleRecaps(data);
  if (!recaps.length) return card("Cycle recaps", el("p", { class: "empty" }, "Needs logged doses to split cycles."));
  return card("Cycle recaps",
    ...recaps.map((c) => el("div", { class: "cycle" },
      el("h3", null, `Cycle ${c.index} · ${fmtDateCT(c.start.at, false)}–${c.open ? "now" : fmtShortDate(c.endDay)} · ${fmtNum(c.start.dose_mg, 1)} mg`),
      el("div", { class: "props" },
        prop("Weight", c.delta != null ? `${fmtNum(c.delta, 1)} lb` : "Needs weigh-ins in this cycle"),
        prop("Eating", c.ate ? VS_LABELS[c.ate] : "Needs ate-vs-usual check-ins"),
        prop("Movement", c.moved ? VS_LABELS[c.moved] : (c.steps != null ? `Avg ${fmtNum(c.steps, 0)} steps` : "Needs movement check-ins")),
        prop("Feel", c.feel ? FEEL_LABELS[c.feel] : (c.foodNoise != null ? `Avg food noise ${fmtNum(c.foodNoise, 1)}` : "Needs feel tags")),
        c.vsPrev && c.vsPrev.weight != null ? prop("vs previous", `${c.vsPrev.weight > 0 ? "+" : ""}${fmtNum(c.vsPrev.weight, 1)} lb change`) : null,
      ),
    )),
  );
}

function renderWearOff(data) {
  const w = wearOff(data);
  return card("Wear-off",
    el("p", { class: w.ready ? "" : "empty" }, w.summary),
    w.ready && w.details && w.details.length
      ? el("ul", null, ...w.details.map((d) => el("li", null, `Cycle ${d.cycle}: ${d.fading ? "fading tags" : ""}${d.fading && d.noiseRise ? " and " : ""}${d.noiseRise ? "late-cycle food noise rose" : ""}.`)))
      : null,
  );
}

function renderFeel(data) {
  const f = feelReport(data);
  if (!f.ready) return card("Feel report", el("p", { class: "empty" }, f.summary));
  const cell = (label, row) => metric(label, row ? fmtNum(row.mean, 1) : "—", row ? `${row.n} days` : null);
  return card("Feel report",
    el("p", { class: "caption" }, `Averages across ${f.count} scored days (1–10).`),
    el("div", { class: "metrics four" },
      cell("Mood", f.mood),
      cell("Energy", f.energy),
      cell("Food noise", f.food_noise),
      cell("Sleep quality", f.sleep_quality),
    ),
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
  return card("Pattern explorer",
    el("p", { class: "caption" }, "Pick any two metrics. Points are days where both were logged."),
    el("div", { class: "grid two" }, field("X axis", xSel), field("Y axis", ySel)),
    pairs.length >= 3
      ? scatterChart(pairs, { aria: `${xMeta.label} vs ${yMeta.label}` })
      : el("p", { class: "empty" }, `Needs ${Math.max(0, 3 - pairs.length)} more overlapping day${3 - pairs.length === 1 ? "" : "s"} for ${xMeta.label} and ${yMeta.label}.`),
    pairs.length >= 3 ? el("p", { class: "caption" }, `${pairs.length} overlapping days.`) : null,
  );
}

function renderEarnWall(data) {
  const cells = earnDays(data, 8);
  const earned = cells.filter((c) => c.earned).length;
  const hasAny = cells.some((c) => c.earned != null);
  if (!hasAny) {
    return card("Earn It wall", el("p", { class: "empty" }, "Needs a check-in with Earn It marked to start the wall. Use the Log tab."));
  }
  const dow = ["S", "M", "T", "W", "T", "F", "S"];
  // Align first cell to Sunday
  const first = cells[0].day;
  const [y, m, d] = first.split("-").map(Number);
  const weekday = new Date(Date.UTC(y, m - 1, d)).getUTCDay();
  const pad = Array.from({ length: weekday }, () => el("div", { class: "cell", style: { visibility: "hidden" } }));
  return card("Earn It wall",
    el("p", { class: "caption" }, `${earned} earned day${earned === 1 ? "" : "s"} in the last 8 weeks.`),
    el("div", { class: "wall" },
      ...dow.map((d0) => el("div", { class: "dow" }, d0)),
      ...pad,
      ...cells.map((c) => el("div", {
        class: "cell" + (c.earned ? " earned" : c.has && c.earned === false ? " missed" : "") + (c.today ? " today" : ""),
        title: c.day,
      })),
    ),
  );
}

function renderSideEffects(data) {
  const rows = data.side_effects || [];
  if (!rows.length) return card("Side effects", el("p", { class: "empty" }, "No side effects logged yet."));
  return card("Side effect timeline",
    el("table", { class: "data" },
      el("thead", null, el("tr", null, el("th", null, "Day"), el("th", null, "Effect"), el("th", { class: "num" }, "Sev"))),
      el("tbody", null, ...[...rows].reverse().map((r) => el("tr", null,
        el("td", null, fmtShortDate(r.recorded_on)),
        el("td", null, r.effect, r.notes ? el("span", { class: "sub" }, r.notes) : null),
        el("td", { class: "num" }, el("span", { class: "sev" }, r.severity)),
      ))),
    ),
  );
}

function renderMeasurements(data) {
  const rows = data.measurements || [];
  if (!rows.length) return card("Measurements", el("p", { class: "empty" }, "No body measurements yet. Log waist or other metrics on the Log tab."));
  const byMetric = {};
  for (const r of rows) {
    const k = r.metric;
    (byMetric[k] ||= []).push(r);
  }
  const charts = Object.entries(byMetric).map(([metric, list]) => {
    const sorted = list.filter((r) => parseTs(r.measured_at) && num(r.value) != null).sort((a, b) => parseTs(a.measured_at) - parseTs(b.measured_at));
    const values = sorted.map((r) => num(r.value));
    const labels = sorted.map((r, i) => (i === 0 || i === sorted.length - 1) ? fmtDateCT(parseTs(r.measured_at), false) : "");
    return el("div", null,
      el("h3", { style: { fontSize: "15px", margin: "0 0 6px" } }, `${capitalize(metric)} (${sorted[0] && sorted[0].unit || ""})`),
      lineChart([{ values }], { labels, aria: metric, format: (v) => fmtNum(v, 1) }),
    );
  });
  return card("Measurements", ...charts);
}

function renderExport(data) {
  return card("Prescriber export",
    el("p", { class: "caption" }, "Downloads stay on this device. The print view includes the journey summary, doses and meals. Use your browser’s print dialog to save a PDF."),
    el("div", { class: "form-actions" },
      el("button", { type: "button", class: "primary", onClick: () => prescriberCSV(data) }, "Download CSV"),
      el("button", { type: "button", onClick: () => prescriberPrint(data) }, "Print / PDF"),
    ),
    el("p", { class: "caption" }, "Not available on the web: Apple Health / HealthKit sync, home-screen widgets, an Apple Watch app, or AI body-fat estimates from photos."),
  );
}

function renderTodayTab(data) {
  const today = todayTotals(data);
  const meals = todayMeals(data);
  const health = latestHealth(data);
  const doses = data.doses || [];
  const { next } = plannedDoses(doses, data.protocol);
  const lastDose = [...doses].reverse().find((d) => !d.skipped) || null;
  const levelNow = remainingAt(new Date(), doses, data.protocol);
  const protein = today ? num(today.protein_g) : null;

  const todayCard = card("Today",
    el("div", { class: "metrics four" },
      metric("Calories", today ? fmtNum(today.calories, 0) : "—", today ? `${today.meal_count} meals` : "No meals yet"),
      metric("Protein", today ? `${fmtNum(today.protein_g, 0)} g` : "—", "Featured for half training", true),
      metric("Steps", health && health.day === todayKey() ? fmtNum(health.steps, 0) : "—", health && health.distance_mi != null ? `${fmtNum(health.distance_mi, 1)} mi` : null),
      metric("Sleep", health && health.sleep_hours != null ? `${fmtNum(health.sleep_hours, 1)} h` : "—", health && health.resting_hr != null ? `RHR ${fmtNum(health.resting_hr, 0)}` : null),
    ),
  );

  const medCard = card("Medication",
    el("div", { class: "props" },
      prop("Drug", lastDose ? capitalize(lastDose.compound || "Tirzepatide") : "—"),
      prop("Last dose", lastDose ? `${fmtNum(lastDose.dose_mg, 0)} mg on ${fmtDateCT(parseTs(lastDose.taken_at), true)}` : "—"),
      prop("Est. level now", `${fmtNum(levelNow, 2)} mg`),
      prop("Next dose", next ? `${fmtDateCT(next, true)} · ${daysWord(daysUntil(next))}` : "Retatrutide starts " + fmtDateCT(RETA_START, true)),
      prop("Site", lastDose ? siteLabel(lastDose) : "—"),
    ),
    el("p", { class: "caption" }, "Estimated from half-life, not a lab measurement."),
  );

  const macros = today
    ? card("Macros",
        el("div", { class: "bars" },
          ...[
            ["Protein", num(today.protein_g), "g", 1],
            ["Carbs", num(today.carbs_g), "g", 0.45],
            ["Fat", num(today.fat_g), "g", 0.45],
            ["Fiber", num(today.fiber_g), "g", 0.45],
          ].map(([label, v, unit, opacity]) => {
            const max = Math.max(num(today.protein_g) || 0, num(today.carbs_g) || 0, num(today.fat_g) || 0, 1);
            return el("div", { class: "bar-row" },
              el("span", null, label),
              el("div", { class: "bar-track" }, el("div", { class: "bar-fill" + (opacity < 1 ? " rest" : ""), style: { width: `${Math.min(100, ((v || 0) / max) * 100)}%` } })),
              el("span", { class: "bar-val" }, v == null ? "—" : `${fmtNum(v, 0)} ${unit}`),
            );
          }),
        ),
      )
    : card("Macros", el("p", { class: "empty" }, "No meals logged today."));

  const mealsCard = card("Meals",
    meals.length
      ? el("table", { class: "data" },
          el("thead", null, el("tr", null, el("th", null, "When"), el("th", null, "Item"), el("th", { class: "num" }, "Cal"), el("th", { class: "num" }, "P"))),
          el("tbody", null, ...meals.map((m) => el("tr", null,
            el("td", null, parseTs(m.eaten_at) ? fmtTimeCT(parseTs(m.eaten_at)) : "—", el("span", { class: "sub" }, capitalize(m.meal_type || ""))),
            el("td", null, m.item || "—", m.notes ? el("span", { class: "sub" }, m.notes) : null),
            el("td", { class: "num" }, fmtNum(m.calories, 0)),
            el("td", { class: "num" }, fmtNum(m.protein_g, 0)),
          ))),
        )
      : el("p", { class: "empty" }, "No meals yet today. Ask Log or Claude to record them."),
  );

  const upcoming = card("Upcoming",
    el("div", { class: "upcoming" },
      next ? el("div", { class: "item" }, el("span", null, "Tirzepatide dose"), el("span", { class: "when" }, `${fmtDateCT(next, true)} · ${daysWord(daysUntil(next))}`)) : null,
      el("div", { class: "item" }, el("span", null, "Switch to retatrutide"), el("span", { class: "when" }, `${fmtDateCT(RETA_START, true)} · ${daysWord(daysUntil(RETA_START))}`)),
      el("div", { class: "item" }, el("span", null, "Dallas Half Marathon"), el("span", { class: "when" }, `${fmtDateCT(HALF_MARATHON, true)} · ${daysWord(daysUntil(HALF_MARATHON))}`)),
    ),
  );

  return el("div", null,
    renderJourney(data),
    renderVerdict(data),
    renderCheckinNudge(data),
    todayCard,
    el("div", { class: "grid two" }, medCard, upcoming),
    el("div", { class: "grid two" }, macros, mealsCard),
    el("p", { class: "install" }, "Add to Home Screen: in Safari, open Share, then Add to Home Screen. Your passcode stays on this phone."),
  );
}

function renderMedsTab(data) {
  const doses = data.doses || [];
  const series = levelSeries(doses, data.protocol, false);
  const seriesNext = levelSeries(doses, data.protocol, true);
  const levelCard = card("Drug level",
    series
      ? el("div", null,
          el("div", { class: "legend" },
            el("span", null, el("span", { class: "swatch" }), "Logged doses"),
            el("span", null, el("span", { class: "swatch alt" }), "With next planned shot"),
          ),
          lineChart(
            [
              { values: series.points },
              { values: seriesNext ? seriesNext.plannedPts : series.points, dashed: true },
            ],
            { labels: series.labels, area: true, floor: 0, aria: "Estimated drug level", format: (v) => fmtNum(v, 1), marks: series.marks },
          ),
        )
      : el("p", { class: "empty" }, "No doses to chart."),
    el("p", { class: "caption" }, "Tirzepatide half-life is modeled at 5 days, retatrutide at 6 days. The gold dashed line includes the next planned tirzepatide dose if it falls before the Dec 6 switch. The chart does not invent a retatrutide mg amount. Estimate only, not a lab value."),
  );

  const doseCard = card("Dosing history",
    doses.length
      ? el("table", { class: "data" },
          el("thead", null, el("tr", null, el("th", null, "When"), el("th", null, "Dose"), el("th", null, "Site"))),
          el("tbody", null, ...[...doses].reverse().map((d) => el("tr", null,
            el("td", null, parseTs(d.taken_at) ? fmtDateCT(parseTs(d.taken_at), true) : "—"),
            el("td", null, d.skipped ? "Skipped" : `${fmtNum(d.dose_mg, 1)} mg`, el("span", { class: "sub" }, capitalize(d.compound || ""))),
            el("td", null, siteLabel(d)),
          ))),
        )
      : el("p", { class: "empty" }, "No doses logged."),
  );

  return el("div", null, levelCard, renderSiteMap(data), renderTitration(data), renderVials(data), renderProtocol(data), doseCard);
}

function renderTrendsTab(data) {
  const wstats = weightStats(data.weights || []);
  const rangeBtns = el("div", { class: "seg" },
    ...["90d", "1y", "all"].map((r) => el("button", {
      type: "button",
      "aria-pressed": state.weightRange === r,
      onClick: () => { state.weightRange = r; render(); },
    }, r === "90d" ? "90 days" : r === "1y" ? "1 year" : "All")),
  );
  let weightCard;
  if (!wstats) {
    weightCard = card("Weight", el("p", { class: "empty" }, "No weigh-ins yet."));
  } else {
    const subset = filterWeights(wstats.parsed, state.weightRange);
    const values = subset.map((w) => w.lb);
    const labels = subset.map((w, i) => (i === 0 || i === subset.length - 1 || i === Math.floor((subset.length - 1) / 2)) ? fmtDateCT(w.at, false) : "");
    const proj = weightProjection(data, 42);
    const projChart = proj.ready
      ? el("div", null,
          el("p", { class: "caption" }, `Projection from the post-dose trend: ${fmtNum(proj.weekly, 2)} lb/week (description only, not a prediction you should trust as advice).`),
          lineChart(
            [{ values: proj.actual }, { values: proj.projected, dashed: true }],
            { labels: proj.labels, aria: "Weight with projection", format: (v) => fmtNum(v, 0) },
          ),
        )
      : el("p", { class: "empty" }, `Needs ${proj.need} more weigh-in${proj.need === 1 ? "" : "s"} since starting tirzepatide for a trendline.`);
    weightCard = card("Weight",
      rangeBtns,
      lineChart([{ values }], { labels, area: true, aria: "Weight", format: (v) => fmtNum(v, 0) }),
      projChart,
    );
  }

  const totals = data.daily_totals || [];
  const last30 = totals.slice(-30);
  const foodChart = last30.length
    ? card("Daily calories and protein",
        el("div", { class: "legend" },
          el("span", null, el("span", { class: "swatch" }), "Calories"),
          el("span", null, el("span", { class: "swatch alt" }), "Protein (g)"),
        ),
        lineChart(
          [
            { values: last30.map((r) => num(r.calories)) },
            { values: last30.map((r) => num(r.protein_g)) },
          ],
          {
            labels: last30.map((r, i) => (i === 0 || i === last30.length - 1) ? fmtShortDate(r.date) : ""),
            aria: "Calories and protein",
          },
        ),
      )
    : null;

  const health = data.daily_health || [];
  const steps = health.slice(-30);
  const healthCard = steps.length
    ? card("Steps, last 30 days",
        lineChart([{ values: steps.map((r) => num(r.steps)) }], {
          labels: steps.map((r, i) => (i === 0 || i === steps.length - 1) ? fmtShortDate(r.day) : ""),
          area: true,
          aria: "Steps",
          format: (v) => fmtNum(v, 0),
        }),
      )
    : null;

  const weeks = data.weekly_summary || [];
  const weekCard = weeks.length
    ? card("Weekly summary",
        el("table", { class: "data" },
          el("thead", null, el("tr", null, el("th", null, "Week"), el("th", { class: "num" }, "kcal/d"), el("th", { class: "num" }, "Protein"), el("th", { class: "num" }, "Weight"))),
          el("tbody", null, ...[...weeks].reverse().slice(0, 8).map((w) => el("tr", null,
            el("td", null, fmtShortDate(w.week)),
            el("td", { class: "num" }, fmtNum(w.avg_daily_calories, 0)),
            el("td", { class: "num" }, `${fmtNum(w.avg_protein_g, 0)} g`),
            el("td", { class: "num" }, w.avg_weight_lb != null ? fmtNum(w.avg_weight_lb, 1) : "—"),
          ))),
        ),
      )
    : null;

  const workouts = data.workouts || [];
  const workoutCard = workouts.length
    ? card("Workouts (historical)",
        el("p", { class: "caption" }, `${data.workout_count || workouts.length} imported workouts. The latest ones here stop in spring 2025, so this is history, not current training.`),
        el("table", { class: "data" },
          el("thead", null, el("tr", null, el("th", null, "When"), el("th", null, "Activity"), el("th", { class: "num" }, "Min"))),
          el("tbody", null, ...workouts.slice(0, 8).map((w) => el("tr", null,
            el("td", null, parseTs(w.started_at) ? fmtDateCT(parseTs(w.started_at), true) : "—"),
            el("td", null, w.activity || "—"),
            el("td", { class: "num" }, fmtNum(w.duration_min, 0)),
          ))),
        ),
      )
    : null;

  return el("div", null,
    weightCard,
    renderStall(data),
    renderCycles(data),
    renderExplorer(data),
    renderWearOff(data),
    renderFeel(data),
    renderEarnWall(data),
    renderSideEffects(data),
    renderMeasurements(data),
    foodChart,
    healthCard,
    weekCard,
    workoutCard,
    renderExport(data),
  );
}

function renderApp(data) {
  const asOf = parseTs(data.as_of) || new Date();
  const updatedLabel = state.error === "refresh-failed"
    ? `Couldn’t refresh. Still showing ${fmtDateTimeCT(asOf)}.`
    : `Updated ${fmtDateTimeCT(asOf)}`;
  const refreshLabel = state.updating ? "Refreshing…" : "Refresh";
  const body = state.tab === "meds" ? renderMedsTab(data)
    : state.tab === "trends" ? renderTrendsTab(data)
    : state.tab === "log" ? renderLogTab(data)
    : renderTodayTab(data);
  return el("div", null,
    el("header", { class: "topbar" },
      el("div", null,
        el("h1", null, "Log"),
        el("div", { class: "updated" }, updatedLabel),
      ),
      el("div", { class: "top-actions" },
        el("button", { type: "button", disabled: state.updating || state.formBusy, onClick: lock }, "Lock"),
        el("button", { type: "button", class: "primary", disabled: state.updating || state.formBusy, onClick: () => load(true) }, refreshLabel),
      ),
    ),
    body,
    tabNav(),
  );
}



function renderGate() {
  const err = state.error === "bad-passcode"
    ? "That passcode was not accepted."
    : state.error === "empty-passcode"
      ? "Enter your passcode."
      : null;
  const field = el("input", {
    type: "password",
    id: "passcode",
    name: "passcode",
    autocomplete: "current-password",
    enterkeyhint: "done",
    inputmode: "text",
    "aria-label": "Passcode",
    disabled: state.loading ? "disabled" : null,
  });
  const onSubmit = () => {
    if (state.loading) return;
    submitPasscode(field.value);
  };
  field.addEventListener("keydown", (e) => {
    if (e.key === "Enter") {
      e.preventDefault();
      onSubmit();
    }
  });
  const box = el("div", { class: "state gate" },
    el("h1", null, "Log"),
    el("p", null, "Enter your passcode to open the dashboard. This device will remember it until you lock."),
    err ? el("p", { class: "err" }, err) : null,
    el("div", { class: "gate-row" },
      field,
      el("button", { type: "button", class: "primary", disabled: state.loading, onClick: onSubmit }, state.loading ? "Checking…" : "Unlock"),
    ),
  );
  setTimeout(() => field.focus(), 0);
  return box;
}

function renderUnauthorized() {
  return el("div", { class: "state" },
    el("h1", null, "Log"),
    el("p", null, "The access key in this link is not valid. Ask Log for a new link."),
  );
}

function renderError() {
  return el("div", { class: "state" },
    el("h1", null, "Log"),
    el("p", { class: "err" }, "The dashboard could not load the log."),
    el("button", { class: "primary", onClick: () => load(false) }, "Try again"),
  );
}

function renderLoading() {
  return el("div", { class: "skel" },
    el("div", { class: "topbar" }, el("h1", null, "Log")),
    el("div", { class: "card" }, el("div", { class: "pulse" }), el("div", { class: "pulse" }), el("div", { class: "pulse" })),
    el("div", { class: "card" }, el("div", { class: "pulse" }), el("div", { class: "pulse" })),
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
  const root = $("#app");
  root.innerHTML = "";
  if (!hasCredential() || state.error === "bad-passcode" || state.error === "empty-passcode") {
    root.append(renderGate());
  } else if (state.loading && !state.data) root.append(renderLoading());
  else if (state.error === "unauthorized") root.append(renderUnauthorized());
  else if (state.error && !state.data) root.append(renderError());
  else if (state.data) root.append(renderApp(state.data));
}

function boot() {
  state.token = readToken();
  if (!state.token) {
    try { state.passcode = localStorage.getItem(PASS_KEY) || ""; }
    catch (_) { state.passcode = ""; }
  } else {
    state.passcode = "";
  }
  load(false);
}

window.addEventListener("hashchange", boot);
boot();
setInterval(() => {
  if (hasCredential() && !state.loading) load(true);
}, 60000);
