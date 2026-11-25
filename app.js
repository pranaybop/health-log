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

const state = {
  token: "",
  data: null,
  error: null,
  loading: true,
  updating: false,
  weightRange: "90d",
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

function siteLabel(notes) {
  if (!notes) return "—";
  const m = notes.match(/site\s+([^;]+)/i);
  if (!m) return "—";
  const key = m[1].trim();
  return SITE_LABELS[key] || key;
}

function remainingAt(at, doses) {
  let total = 0;
  for (const d of doses) {
    const t = parseTs(d.taken_at);
    const mg = num(d.dose_mg);
    if (!t || mg == null || at < t) continue;
    const days = (at - t) / 86400000;
    total += mg * Math.pow(0.5, days / HALF_LIFE_DAYS);
  }
  return total;
}

function plannedDoses(doses) {
  const list = doses
    .map((d) => ({ ...d, taken_at: d.taken_at, dose_mg: num(d.dose_mg) }))
    .filter((d) => d.dose_mg != null && parseTs(d.taken_at));
  const last = list[list.length - 1];
  if (!last) return { list, next: null, withNext: list };
  const lastAt = parseTs(last.taken_at);
  const next = new Date(lastAt.getTime() + 7 * 86400000);
  if (next >= RETA_START) return { list, next: null, withNext: list };
  const planned = { taken_at: next.toISOString(), dose_mg: last.dose_mg || 3, compound: last.compound || "tirzepatide", planned: true };
  return { list, next, withNext: list.concat(planned) };
}

async function fetchData() {
  const res = await fetch(API_URL, {
    headers: { "x-log-token": state.token },
    cache: "no-store",
    referrerPolicy: "no-referrer",
  });
  if (res.status === 401) throw new Error("unauthorized");
  if (!res.ok) throw new Error("Could not load the log.");
  return res.json();
}

async function load(isRefresh) {
  if (!state.token) {
    state.loading = false;
    state.error = "missing-token";
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
  } catch (err) {
    if (!state.data) state.error = err.message === "unauthorized" ? "unauthorized" : "load-failed";
    else state.error = "refresh-failed";
  } finally {
    state.loading = false;
    state.updating = false;
    render();
  }
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
  const lo = opts.floor != null ? opts.floor : Math.min(0, ...all);
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
    const cls = si === 0 ? "line" : "line alt";
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

function levelSeries(doses, withPlanned) {
  if (!doses.length) return null;
  const start = parseTs(doses[0].taken_at);
  const end = RETA_START;
  const points = [];
  const labels = [];
  for (let t = new Date(start); t <= end; t = new Date(t.getTime() + 86400000)) {
    const noon = new Date(t);
    points.push(remainingAt(noon, withPlanned ? plannedDoses(doses).withNext : doses));
    const key = dateKeyCT(noon);
    const mark = ["2026-11-02", "2026-11-08", "2026-11-15", "2026-11-22", "2026-11-29", "2026-12-06"].includes(key);
    labels.push(mark ? fmtDateCT(noon, false) : "");
  }
  return { points, labels };
}

function renderMissing() {
  return el("div", { class: "state" },
    el("h1", null, "Log"),
    el("p", null, "This link is missing its access key. Open the full link you were sent, including the part after #."),
  );
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

function renderApp(data) {
  const asOf = parseTs(data.as_of) || new Date();
  const today = todayTotals(data);
  const meals = todayMeals(data);
  const health = latestHealth(data);
  const doses = data.doses || [];
  const { next } = plannedDoses(doses);
  const lastDose = doses.length ? doses[doses.length - 1] : null;
  const levelNow = remainingAt(new Date(), doses);
  const wstats = weightStats(data.weights || []);
  const series = levelSeries(doses, false);
  const seriesNext = levelSeries(doses, true);

  const protein = today ? num(today.protein_g) : null;
  const callout = today
    ? el("div", { class: "callout" },
        el("strong", null, protein != null && protein < 100
          ? "Today's protein is still modest for training."
          : "Today's meals are logged."),
        el("span", null,
          protein != null
            ? `Protein today is ${fmtNum(protein, 0)} g from ${today.meal_count} meal${today.meal_count === 1 ? "" : "s"}. `
            : "",
          next
            ? `The next tirzepatide dose is ${fmtDateCT(next, true)}, ${daysWord(daysUntil(next))}. `
            : "",
          `Retatrutide starts ${fmtDateCT(RETA_START, true)}.`,
        ),
      )
    : null;

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
      prop("Frequency", "Weekly"),
      prop("Next dose", next ? `${fmtDateCT(next, true)}, ${daysWord(daysUntil(next))}` : "—"),
      prop("Estimated level", `${fmtNum(levelNow, 2)} mg`),
      prop("Total doses", `${doses.length}, totaling ${fmtNum(doses.reduce((a, d) => a + (num(d.dose_mg) || 0), 0), 0)} mg`),
      prop("Then", `Retatrutide on ${fmtDateCT(RETA_START, true)}`),
    ),
    el("p", { class: "caption" }, "Estimated from a 5-day half-life model, not a lab measurement. Dose times from the WeightSnap import were recorded as noon CT."),
  );

  const weightCard = wstats
    ? card("Weight",
        el("div", { class: "metrics" },
          metric("Current", `${fmtNum(wstats.current.lb, 1)} lb`, fmtDateTimeCT(wstats.current.at)),
          metric("Since Nov 2", `${wstats.change > 0 ? "+" : ""}${fmtNum(wstats.change, 1)} lb`, `from ${fmtNum(wstats.start.lb, 1)} lb`),
          metric("Goal", `${fmtNum(GOAL_LB, 0)} lb`, `${fmtNum(wstats.current.lb - GOAL_LB, 1)} lb to go`),
          metric("Entries", fmtNum(wstats.parsed.length, 0), `${fmtDateCT(wstats.parsed[0].at, false)} – ${fmtDateCT(wstats.current.at, false)}`),
        ),
        el("div", { class: "seg", style: { margin: "12px 0 8px" } },
          ...["90d", "1y", "all"].map((r) =>
            el("button", {
              type: "button",
              "aria-pressed": state.weightRange === r ? "true" : "false",
              onClick: () => { state.weightRange = r; render(); },
            }, r === "90d" ? "90 days" : r === "1y" ? "1 year" : "All"),
          ),
        ),
        (() => {
          const pts = filterWeights(wstats.parsed, state.weightRange);
          const labels = pts.map(() => "");
          if (pts.length) {
            labels[0] = fmtDateCT(pts[0].at, false);
            labels[pts.length - 1] = fmtDateCT(pts[pts.length - 1].at, false);
            const mid = Math.floor((pts.length - 1) / 2);
            if (mid > 0 && mid < pts.length - 1) labels[mid] = fmtDateCT(pts[mid].at, false);
          }
          return lineChart([{ values: pts.map((p) => p.lb) }], {
            area: true,
            format: (v) => fmtNum(v, 0),
            labels,
            aria: "Weight in pounds",
          });
        })(),
      )
    : card("Weight", el("p", { class: "caption" }, "No weigh-ins are in the log yet. Send a weight and it will show up here on the next refresh."));

  const levelCard = series
    ? card("Estimated tirzepatide level",
        el("div", { class: "legend" },
          el("span", null, el("i", { class: "swatch" }), "Logged doses"),
          el("span", null, el("i", { class: "swatch alt" }), "With Nov 29 dose"),
        ),
        lineChart(
          [
            { values: series.points },
            { values: seriesNext ? seriesNext.points : [] },
          ],
          { floor: 0, ceiling: 5, format: (v) => `${fmtNum(v, 1)} mg`, labels: series.labels, aria: "Estimated tirzepatide level" },
        ),
        el("p", { class: "caption" }, "Daily estimates at noon CT. The second line includes a planned 3 mg dose on Nov 29, then no further tirzepatide before the Dec 6 switch."),
      )
    : null;

  const macroCard = today
    ? card("Macros",
        (() => {
          const rows = [
            { label: "Carbs", value: num(today.carbs_g) || 0, display: `${fmtNum(today.carbs_g, 0)} g` },
            { label: "Protein", value: num(today.protein_g) || 0, display: `${fmtNum(today.protein_g, 0)} g` },
            { label: "Fat", value: num(today.fat_g) || 0, display: `${fmtNum(today.fat_g, 0)} g` },
            { label: "Fiber", value: num(today.fiber_g) || 0, display: `${fmtNum(today.fiber_g, 0)} g` },
          ].sort((a, b) => b.value - a.value);
          const max = Math.max(...rows.map((r) => r.value), 1);
          return el("div", { class: "bars" },
            ...rows.map((r) =>
              el("div", { class: "bar-row" },
                el("span", null, r.label),
                el("div", { class: "bar-track" },
                  el("div", { class: r.label === "Protein" ? "bar-fill" : "bar-fill rest", style: { width: `${(r.value / max) * 100}%` } }),
                ),
                el("span", { class: "bar-val" }, r.display),
              ),
            ),
          );
        })(),
        el("p", { class: "caption" }, "Macros are estimated and may not sum to the calorie total."),
      )
    : null;

  const mealsCard = card("Meals",
    meals.length
      ? el("table", { class: "data" },
          el("thead", null, el("tr", null,
            el("th", null, "Time"),
            el("th", null, "Meal"),
            el("th", { class: "num" }, "Cal"),
            el("th", { class: "num" }, "Protein"),
          )),
          el("tbody", null, ...meals.map((m) =>
            el("tr", null,
              el("td", null, parseTs(m.eaten_at) ? fmtTimeCT(parseTs(m.eaten_at)) : "—"),
              el("td", null, m.item || "—", m.quantity ? el("span", { class: "sub" }, `${capitalize(m.meal_type || "")} · ${m.quantity}`) : el("span", { class: "sub" }, capitalize(m.meal_type || ""))),
              el("td", { class: "num" }, fmtNum(m.calories, 0)),
              el("td", { class: "num" }, `${fmtNum(m.protein_g, 0)} g`),
            ),
          )),
        )
      : el("p", { class: "caption" }, "No meals logged today yet."),
  );

  const totals = (data.daily_totals || []).slice(-14);
  const foodChart = totals.length
    ? card("Daily calories and protein",
        el("div", { class: "legend" },
          el("span", null, el("i", { class: "swatch" }), "Calories"),
          el("span", null, el("i", { class: "swatch alt" }), "Protein (g)"),
        ),
        lineChart(
          [
            { values: totals.map((d) => num(d.calories) || 0) },
            { values: totals.map((d) => num(d.protein_g) || 0) },
          ],
          {
            floor: 0,
            labels: totals.map((d, i) => (i === 0 || i === totals.length - 1 ? fmtShortDate(d.date) : "")),
            format: (v) => fmtNum(v, 0),
            aria: "Daily calories and protein",
          },
        ),
      )
    : null;

  const healthRows = (data.daily_health || []).slice(-30);
  const healthCard = healthRows.length
    ? card("Last 30 days",
        el("div", { class: "legend" },
          el("span", null, el("i", { class: "swatch" }), "Steps"),
        ),
        lineChart(
          [{ values: healthRows.map((d) => num(d.steps) || 0) }],
          {
            floor: 0,
            area: true,
            labels: healthRows.map((d, i) => (i === 0 || i === healthRows.length - 1 ? fmtShortDate(d.day) : "")),
            format: (v) => fmtNum(v, 0),
            aria: "Daily steps",
          },
        ),
        health && health.day === todayKey()
          ? el("div", { class: "props" },
              prop("Active calories", `${fmtNum(health.active_kcal, 0)} kcal`),
              prop("Exercise", `${fmtNum(health.exercise_min, 0)} min`),
              prop("Stand hours", fmtNum(health.stand_hours, 0)),
              prop("HRV", health.hrv_ms != null ? `${fmtNum(health.hrv_ms, 0)} ms` : "—"),
            )
          : null,
      )
    : null;

  const doseCard = card("Dosing history",
    doses.length
      ? el("table", { class: "data" },
          el("thead", null, el("tr", null,
            el("th", null, "Date"),
            el("th", { class: "num" }, "Dose"),
            el("th", null, "Drug"),
            el("th", null, "Site"),
          )),
          el("tbody", null, ...doses.map((d) =>
            el("tr", null,
              el("td", null, parseTs(d.taken_at) ? fmtDateCT(parseTs(d.taken_at), true) : "—"),
              el("td", { class: "num" }, `${fmtNum(d.dose_mg, 0)} mg`),
              el("td", null, capitalize(d.compound || "")),
              el("td", null, siteLabel(d.notes)),
            ),
          )),
        )
      : el("p", { class: "caption" }, "No doses logged yet."),
  );

  const weeks = (data.weekly_summary || []).slice(-6).reverse();
  const weekCard = weeks.length
    ? card("Weekly summary",
        el("table", { class: "data" },
          el("thead", null, el("tr", null,
            el("th", null, "Week of"),
            el("th", { class: "num" }, "Avg cal"),
            el("th", { class: "num" }, "Avg protein"),
            el("th", { class: "num" }, "Avg weight"),
          )),
          el("tbody", null, ...weeks.map((w) =>
            el("tr", null,
              el("td", null, fmtShortDate(w.week)),
              el("td", { class: "num" }, w.avg_daily_calories != null ? fmtNum(w.avg_daily_calories, 0) : "—"),
              el("td", { class: "num" }, w.avg_protein_g != null ? `${fmtNum(w.avg_protein_g, 0)} g` : "—"),
              el("td", { class: "num" }, w.avg_weight_lb != null ? `${fmtNum(w.avg_weight_lb, 1)} lb` : "—"),
            ),
          )),
        ),
      )
    : null;

  const upcoming = card("Upcoming",
    el("div", { class: "upcoming" },
      next ? el("div", { class: "item" }, el("span", null, "Next tirzepatide, 3 mg"), el("span", { class: "when" }, `${fmtDateCT(next, true)} · ${daysWord(daysUntil(next))}`)) : null,
      el("div", { class: "item" }, el("span", null, "Start retatrutide"), el("span", { class: "when" }, `${fmtDateCT(RETA_START, true)} · ${daysWord(daysUntil(RETA_START))}`)),
      el("div", { class: "item" }, el("span", null, "BMW Dallas Half Marathon"), el("span", { class: "when" }, `${fmtDateCT(HALF_MARATHON, true)} · ${daysWord(daysUntil(HALF_MARATHON))}`)),
    ),
  );

  const workouts = data.workouts || [];
  const workoutCard = workouts.length
    ? card("Workouts",
        el("table", { class: "data" },
          el("thead", null, el("tr", null,
            el("th", null, "When"),
            el("th", null, "Activity"),
            el("th", { class: "num" }, "Min"),
            el("th", { class: "num" }, "kcal"),
          )),
          el("tbody", null, ...workouts.slice(0, 8).map((w) =>
            el("tr", null,
              el("td", null, parseTs(w.started_at) ? fmtDateCT(parseTs(w.started_at), true) : "—"),
              el("td", null, capitalize(w.activity || "Workout"), w.distance_mi != null ? el("span", { class: "sub" }, `${fmtNum(w.distance_mi, 2)} mi`) : null),
              el("td", { class: "num" }, fmtNum(w.duration_min, 0)),
              el("td", { class: "num" }, fmtNum(w.active_kcal, 0)),
            ),
          )),
        ),
        el("p", { class: "caption" },
          `Showing the most recent of ${fmtNum(data.workout_count || workouts.length, 0)} workouts in the log. ` +
          (parseTs(workouts[0].started_at) && dateKeyCT(parseTs(workouts[0].started_at)) < "2026-01-01"
            ? "The latest imported workout is from 2025."
            : ""),
        ),
      )
    : null;

  const refreshLabel = state.updating ? "Refreshing…" : "Refresh";
  const updatedLabel = state.error === "refresh-failed"
    ? `Couldn’t refresh. Still showing ${fmtDateTimeCT(asOf)}.`
    : `Updated ${fmtDateTimeCT(asOf)}`;

  return el("div", null,
    el("header", { class: "topbar" },
      el("div", null,
        el("h1", null, "Log"),
        el("div", { class: "updated" }, updatedLabel),
      ),
      el("div", { class: "top-actions" },
        el("button", { type: "button", class: "primary", disabled: state.updating, onClick: () => load(true) }, refreshLabel),
      ),
    ),
    callout,
    todayCard,
    el("div", { class: "grid two" }, medCard, weightCard),
    levelCard,
    el("div", { class: "grid two" }, macroCard, mealsCard),
    foodChart,
    healthCard,
    doseCard,
    weekCard,
    upcoming,
    workoutCard,
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
  if (!state.token) root.append(renderMissing());
  else if (state.loading && !state.data) root.append(renderLoading());
  else if (state.error === "unauthorized") root.append(renderUnauthorized());
  else if (state.error && !state.data) root.append(renderError());
  else if (state.data) root.append(renderApp(state.data));
}

state.token = readToken();
window.addEventListener("hashchange", () => {
  state.token = readToken();
  load(false);
});
load(false);
setInterval(() => {
  if (state.token && !state.loading) load(true);
}, 60000);
