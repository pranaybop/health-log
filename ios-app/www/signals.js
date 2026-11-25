/*
  Energy balance, off-normal days and appetite by drug level (Nov 25, 2026).
  Pure rendering on the dashboard payload. Each card says what it's still missing
  rather than guessing.
*/

const KCAL_PER_LB = 3500;

function medianOf(vals) {
  const v = vals.filter((x) => Number.isFinite(x)).sort((a, b) => a - b);
  if (!v.length) return null;
  const m = Math.floor(v.length / 2);
  return v.length % 2 ? v[m] : (v[m - 1] + v[m]) / 2;
}

/* ---------- Maintenance calories ---------- */

/* Apple Watch total burned (active + resting) for full days in [fromKey, toKey]. A day the
   watch was barely worn reads far low, so days under 70% of the window's middle value drop out. */
function completeBurnDays(data, fromKey, toKey) {
  const today = todayKey();
  const pts = metricPoints(data, "total_kcal").filter((p) => p.key >= fromKey && p.key <= toKey && p.key < today);
  const med = medianOf(pts.map((p) => p.v));
  return med == null ? [] : pts.filter((p) => p.v >= 0.7 * med);
}

function maintenanceEstimate(data) {
  const end = shiftDay(todayKey(), -1);
  const start = shiftDay(end, -27);
  const days = 28;
  const burn = completeBurnDays(data, start, end);
  const watch = burn.length >= 7 ? medianOf(burn.map((p) => p.v)) : null;
  // A partly logged day would make maintenance look lower than it is, so only fuller days count.
  const logged = (data.daily_totals || [])
    .filter((r) => r.date >= start && r.date <= end && num(r.calories) != null && num(r.calories) >= 800)
    .map((r) => ({ key: r.date, t: keyToNoon(r.date), v: num(r.calories) }))
    .sort((a, b) => (a.key < b.key ? -1 : 1));
  const intake = logged.length ? logged.reduce((a, p) => a + p.v, 0) / logged.length : null;
  const sm = smoothWeights(parseWeights(data.weights || []));
  const startTrend = trendAt(sm, keyToNoon(start));
  const endTrend = trendAt(sm, new Date(keyToNoon(end).getTime() + 12 * 3600000));
  const weighIns = sm.filter((w) => { const k = dateKeyCT(w.at); return k >= start && k <= end; }).length;
  const change = startTrend != null && endTrend != null && weighIns >= 6 ? endTrend - startTrend : null;
  const rate = change != null ? (change / days) * 7 : null;
  const fromLogs = logged.length >= 14 && change != null ? intake - (change * KCAL_PER_LB) / days : null;
  return { start, end, burn, watch, logged, intake, rate, fromLogs, weighIns };
}

function renderMaintenance(data) {
  const m = maintenanceEstimate(data);
  if (!m.burn.length && !m.logged.length) return null;
  const target = getTargets(data).calories;
  const best = m.fromLogs != null ? m.fromLogs : m.watch;
  const ro = readout(best != null ? `About ${fmtNum(Math.round(best / 10) * 10, 0)} kcal a day` : "Not enough data yet",
    m.fromLogs != null ? "From your food logs and weight trend, last 4 full weeks" : m.watch != null ? "Apple Watch, burned per day over the last 4 full weeks" : "Needs a week of Apple Watch days or two weeks of food logs");
  const t0 = new Date(keyToNoon(m.start).getTime() - 12 * 3600000);
  const t1 = new Date(keyToNoon(m.end).getTime() + 12 * 3600000);
  const smooth = (pts) => rollingMean(pts, 7);
  const series = [];
  if (m.burn.length) {
    series.push({ id: "burn", cls: "s1 faint", type: "dots", r: 2.5, points: m.burn });
    if (m.burn.length > 2) series.push({ id: "burnS", cls: "s1", type: "smooth", endDot: true, points: smooth(m.burn) });
  }
  if (m.logged.length) series.push({ id: "eat", cls: "s2", type: "dots", r: 3.5, points: m.logged });
  const refs = [];
  if (target != null) refs.push({ v: target, label: `Target ${fmtNum(target, 0)}` });
  const byKey = (list) => new Map(list.map((p) => [p.key, p.v]));
  const burnMap = byKey(m.burn);
  const eatMap = byKey(m.logged);
  const chart = series.length ? timeChart({
    t0, t1, height: 170, aria: "Calories burned and eaten, last 4 full weeks", refs,
    fmtY: (v) => fmtNum(v, 0),
    series,
    snap: m.burn.length ? "burn" : "eat",
    onScrub: (r) => {
      if (!r) return ro.reset();
      const k = r.point.key;
      const b = burnMap.get(k);
      const e = eatMap.get(k);
      ro.set(b != null ? `${fmtNum(b, 0)} kcal burned` : "Watch day skipped", `${fmtShortDate(k)}${e != null ? `. Ate ${fmtNum(e, 0)} kcal` : ""}`);
    },
  }) : null;
  const under = target != null && m.watch != null ? m.watch - target : null;
  return card("Maintenance calories",
    ro.node,
    chart,
    chart ? el("div", { class: "legend" },
      m.burn.length ? el("span", null, el("i", { class: "key line s1" }), "Burned, Apple Watch (7-day average)") : null,
      m.logged.length ? el("span", null, el("i", { class: "key dot s2" }), "Food logged") : null,
      target != null ? el("span", null, el("i", { class: "key line ref" }), "Calorie target") : null,
    ) : null,
    el("div", { class: "props" },
      prop("Apple Watch says", m.watch != null ? `${fmtNum(m.watch, 0)} kcal a day (${m.burn.length} days)` : `Needs 7 full days (${m.burn.length} so far)`),
      prop("Food logs and weight say", m.fromLogs != null
        ? `${fmtNum(m.fromLogs, 0)} kcal a day`
        : `Needs 14 logged days in the 4 weeks (${m.logged.length} so far)`),
      m.logged.length ? prop("You ate", `${fmtNum(m.intake, 0)} kcal a day on average (${m.logged.length} logged days)`) : null,
      m.rate != null ? prop("Weight trend", `${signed(m.rate, 1)} lb a week`) : null,
      under != null ? prop(`Eating ${fmtNum(target, 0)}`, under > 0
        ? `${fmtNum(under, 0)} kcal under the watch, about ${fmtNum((under * 7) / KCAL_PER_LB, 1)} lb a week if it's right`
        : `${fmtNum(-under, 0)} kcal over the watch's estimate`) : null,
    ),
    el("p", { class: "caption" }, "From logs: average calories logged plus 3,500 kcal for every pound the weight trend dropped, over the last 4 full weeks. Only days with at least 800 kcal logged count, since a half-logged day would pull it down. The watch figure is total burned (active plus resting), skipping days it was barely worn, and uses the middle day so one odd reading doesn't skew it. Watch estimates can be off by a few hundred calories either way."),
  );
}

/* ---------- Off your normal ---------- */

const NORMAL_SIGNALS = [
  { id: "resting_hr", label: "Resting heart rate", lower: "resting heart rate", daily: true, up: true, floor: () => 4, unit: "bpm", d: 0 },
  { id: "hrv_ms", label: "HRV", lower: "HRV", daily: true, up: false, floor: (med) => 0.2 * med, unit: "ms", d: 0 },
  { id: "respiratory_rate", label: "Breathing rate", lower: "breathing rate", up: true, floor: () => 1.5, unit: "/min", d: 1 },
  { id: "wrist_temp_f", label: "Wrist temperature", lower: "wrist temperature", up: true, floor: () => 0.9, unit: "°F", d: 1 },
];

const signalCache = new WeakMap();

function signalMaps(data) {
  if (signalCache.has(data)) return signalCache.get(data);
  const maps = {};
  for (const s of NORMAL_SIGNALS) {
    const m = new Map();
    if (s.daily) for (const r of data.daily_health || []) { const v = num(r[s.id]); if (v != null) m.set(r.day, v); }
    else for (const p of metricPoints(data, s.id)) m.set(p.key, p.v);
    maps[s.id] = m;
  }
  signalCache.set(data, maps);
  return maps;
}

/* Each signal on `key` against the 30 days before it: the middle value, and a spread from the
   median absolute deviation (so one wild day doesn't widen it). Off means past
   max(2 × spread, a floor): 4 bpm, 20% of HRV, 1.5 breaths a minute, 0.9 °F. */
function offNormal(data, key) {
  const maps = signalMaps(data);
  const checked = [];
  for (const s of NORMAL_SIGNALS) {
    const m = maps[s.id];
    const v = m.get(key);
    if (v == null) continue;
    const base = [];
    for (let k = shiftDay(key, -30); k < key; k = shiftDay(k, 1)) if (m.has(k)) base.push(m.get(k));
    if (base.length < 7) continue;
    const med = medianOf(base);
    const spread = 1.4826 * medianOf(base.map((x) => Math.abs(x - med)));
    const margin = Math.max(2 * spread, s.floor(med));
    const diff = v - med;
    const off = s.up ? diff >= margin : -diff >= margin;
    checked.push({ s, v, med, diff, off });
  }
  return { key, checked, off: checked.filter((c) => c.off) };
}

function fmtSignalDiff(c) {
  if (c.s.id === "hrv_ms") return `${signed((c.diff / c.med) * 100, 0)}%`;
  return `${signed(c.diff, c.s.d)}${c.s.unit === "/min" || c.s.unit === "°F" ? c.s.unit : ` ${c.s.unit}`}`;
}

function fmtSignal(c, v) {
  const unit = c.s.unit === "/min" || c.s.unit === "°F" ? c.s.unit : ` ${c.s.unit}`;
  return `${fmtNum(v, c.s.d)}${unit}`;
}

function signalRows(result) {
  return el("div", { class: "signal-rows" },
    ...result.checked.map((c) => el("div", { class: "signal-row" + (c.off ? " off" : "") },
      el("span", { class: "signal-name" }, c.s.label),
      el("span", { class: "signal-val" }, fmtSignal(c, c.v), el("span", { class: "sub" }, `normal ${fmtSignal(c, c.med)}`)),
      el("span", { class: c.off ? "chip watch" : "chip quiet" }, c.off ? `${c.s.up ? "▲" : "▼"} ${fmtSignalDiff(c)}` : "Normal"),
    )),
  );
}

const OFF_CAUSES = "Common causes: a hard workout, short or late sleep, alcohol, a dose change, or getting sick.";

/* Today (or the day being viewed): only shows up when two or more signals are off. */
function renderOffNormal(data, key) {
  const r = offNormal(data, key);
  if (r.off.length < 2) return null;
  return card("Off your normal",
    el("div", { class: "callout watch-note first" },
      el("strong", null, `${r.off.length} of ${r.checked.length} recovery signals are off your normal`),
      el("span", null, OFF_CAUSES),
    ),
    signalRows(r),
  );
}

/* Trends: the latest day against normal, and which of the last 60 days were off. */
function renderOffNormalTrends(data) {
  const today = todayKey();
  let latest = null;
  for (let k = today, i = 0; i < 3 && !latest; i++, k = shiftDay(k, -1)) {
    const r = offNormal(data, k);
    if (r.checked.length >= 2) latest = r;
  }
  const days = [];
  for (let i = 59; i >= 0; i--) {
    const k = shiftDay(today, -i);
    const r = offNormal(data, k);
    days.push({ key: k, checked: r.checked.length, off: r.off, flagged: r.off.length >= 2 });
  }
  const tracked = days.filter((d) => d.checked >= 2);
  if (!latest && !tracked.length) return null;
  const flagged = days.filter((d) => d.flagged);
  const strip = el("div", { class: "off-strip", role: "img", "aria-label": flagged.length ? `Off-normal days in the last 60: ${flagged.map((d) => fmtShortDate(d.key)).join(", ")}` : "No off-normal days in the last 60" },
    ...days.map((d) => el("span", { class: d.flagged ? "flag" : d.checked >= 2 ? "ok" : "none", title: fmtShortDate(d.key) })),
  );
  return card("Off your normal",
    latest ? el("p", { class: "lead" }, `${dayTitle(latest.key)}: ${latest.off.length ? `${latest.off.length} of ${latest.checked.length} signals off` : `all ${latest.checked.length} signals normal`}`) : null,
    latest ? signalRows(latest) : null,
    el("h3", { class: "hm-group" }, "Last 60 days"),
    strip,
    el("div", { class: "strip-axis" }, el("span", null, fmtShortDate(days[0].key)), el("span", null, "Today")),
    el("div", { class: "legend" },
      el("span", null, el("i", { class: "key rect off-flag" }), "Two or more off"),
      el("span", null, el("i", { class: "key rect off-ok" }), "Normal"),
      el("span", null, el("i", { class: "key rect off-none" }), "Not enough data"),
    ),
    el("p", { class: "strip-note" }, flagged.length
      ? `${flagged.length} day${flagged.length === 1 ? "" : "s"} with two or more signals off.`
      : `No days with two or more signals off (${tracked.length} days had enough data).`),
    flagged.length ? el("div", { class: "props" },
      ...flagged.slice(-5).reverse().map((d) => prop(fmtShortDate(d.key), d.off.map((c) => `${c.s.lower} ${fmtSignalDiff(c)}`).join(", "))),
    ) : null,
    el("p", { class: "caption" }, `Each signal is compared with the middle of its previous 30 days. Off means past twice its usual spread, and at least 4 bpm resting heart rate, 20% HRV, 1.5 breaths a minute or 0.9 °F wrist temperature. Today shows a card when two or more are off. ${OFF_CAUSES}`),
  );
}

/* ---------- Appetite by drug level ---------- */

/* Modeled level of the compound you're on, as a share of the peak a weekly dose at your latest
   amount settles at: a fair scale across doses and across the switch (half-lives 5 and 6 days). */
function levelShareAt(data, at) {
  const doses = (data.doses || [])
    .filter((d) => !d.skipped && parseTs(d.taken_at) && num(d.dose_mg) != null && parseTs(d.taken_at) <= at)
    .sort((a, b) => parseTs(a.taken_at) - parseTs(b.taken_at));
  const last = doses[doses.length - 1];
  if (!last) return null;
  const comp = String(last.compound || "").toLowerCase();
  const same = doses.filter((d) => String(d.compound || "").toLowerCase() === comp);
  const h = halfLifeDays(comp, data.protocol);
  const peak = num(last.dose_mg) / (1 - Math.pow(0.5, 7 / h));
  return peak > 0 ? remainingAt(at, same, data.protocol) / peak : null;
}

const LEVEL_BINS = [
  { label: "Low", sub: "under 55%", lo: 0, hi: 0.55 },
  { label: "Middle", sub: "55–75%", lo: 0.55, hi: 0.75 },
  { label: "High", sub: "75% and up", lo: 0.75, hi: Infinity },
];

const binOf = (share) => LEVEL_BINS.findIndex((b) => share >= b.lo && share < b.hi);

function appetiteByLevel(data) {
  const noise = LEVEL_BINS.map(() => []);
  for (const c of data.checkins || []) {
    const v = num(c.food_noise);
    if (!c.day || v == null) continue;
    // Rated in the evening check-in: use its time, or 8 pm that day.
    const at = parseTs(c.checked_in_at) || new Date(keyToNoon(c.day).getTime() + 8 * 3600000);
    const share = levelShareAt(data, at);
    if (share == null) continue;
    noise[binOf(share)].push(v);
  }
  // Food thoughts: count each at its exact time, and divide by the hours spent in each band
  // since you started tracking them, so a band you were rarely in isn't over-counted.
  const thoughts = LEVEL_BINS.map(() => 0);
  const hours = LEVEL_BINS.map(() => 0);
  const times = (data.food_thoughts || []).map((t) => parseTs(t.thought_at)).filter(Boolean).sort((a, b) => a - b);
  let trackedDays = 0;
  if (times.length) {
    const from = midnightCT(dateKeyCT(times[0]));
    const now = new Date();
    trackedDays = (now - from) / 86400000;
    for (let t = from.getTime(); t < now.getTime(); t += 3600000) {
      const share = levelShareAt(data, new Date(t));
      if (share != null) hours[binOf(share)] += 1;
    }
    for (const at of times) {
      const share = levelShareAt(data, at);
      if (share != null) thoughts[binOf(share)] += 1;
    }
  }
  const nowShare = levelShareAt(data, new Date());
  return {
    noise: noise.map((list) => ({ n: list.length, avg: list.length ? list.reduce((a, b) => a + b, 0) / list.length : null })),
    thoughts: thoughts.map((n, i) => ({ n, perDay: hours[i] >= 12 ? n / (hours[i] / 24) : null, days: hours[i] / 24 })),
    trackedDays,
    nowShare,
  };
}

function renderAppetiteByLevel(data) {
  if (!(data.doses || []).some((d) => !d.skipped && num(d.dose_mg) != null)) return null;
  const a = appetiteByLevel(data);
  const noiseN = a.noise.reduce((s, b) => s + b.n, 0);
  const now = a.nowShare != null ? LEVEL_BINS[binOf(a.nowShare)] : null;
  const lo = a.noise[0];
  const hi = a.noise[2];
  const gap = lo.n >= 3 && hi.n >= 3 ? lo.avg - hi.avg : null;
  const lead = gap != null
    ? (Math.abs(gap) < 0.5 ? "Food noise is about the same at low and high levels so far." : `Food noise runs ${fmtNum(Math.abs(gap), 1)} points ${gap > 0 ? "lower" : "higher"} when the level is high than when it's low.`)
    : noiseN < 5 ? `Needs at least 5 check-ins with food noise to compare (${noiseN} so far).` : "Needs 3 check-ins at both low and high levels to compare.";
  const bar = (v, max, cls) => el("div", { class: "bar-track" }, el("div", { class: `bar-fill ${cls}`, style: { width: `${Math.min(100, ((v || 0) / max) * 100)}%` } }));
  const maxPerDay = Math.max(1, ...a.thoughts.map((t) => t.perDay || 0));
  return card("Appetite by drug level",
    el("p", { class: "lead" }, lead),
    now ? el("p", { class: "strip-note" }, `Right now: ${fmtNum(a.nowShare * 100, 0)}% of peak (${now.label.toLowerCase()}).`) : null,
    el("h3", { class: "hm-group" }, "Food noise in check-ins, out of 10"),
    el("div", { class: "bars level-bars" },
      ...LEVEL_BINS.map((b, i) => el("div", { class: "bar-row" },
        el("span", { class: "bar-name" }, b.label, el("span", { class: "sub" }, b.sub)),
        bar(a.noise[i].avg, 10, "s1"),
        el("span", { class: "bar-val" }, a.noise[i].avg == null ? "—" : `${fmtNum(a.noise[i].avg, 1)}`, el("span", { class: "sub" }, `${a.noise[i].n} day${a.noise[i].n === 1 ? "" : "s"}`)),
      )),
    ),
    el("h3", { class: "hm-group" }, "Food thoughts a day"),
    a.trackedDays >= 3 ? el("div", { class: "bars level-bars" },
      ...LEVEL_BINS.map((b, i) => el("div", { class: "bar-row" },
        el("span", { class: "bar-name" }, b.label, el("span", { class: "sub" }, b.sub)),
        bar(a.thoughts[i].perDay, maxPerDay, "s2"),
        el("span", { class: "bar-val" }, a.thoughts[i].perDay == null ? "—" : fmtNum(a.thoughts[i].perDay, 1), el("span", { class: "sub" }, `${a.thoughts[i].n} logged`)),
      )),
    ) : el("p", { class: "strip-note" }, "Shows once you've tracked food thoughts for 3 days. Tap a food-thought button on Today when one hits."),
    el("p", { class: "caption" }, "Level is the modeled amount of the medication you're on, as a share of the peak a weekly dose at your latest amount settles at (half-life 5 days for tirzepatide, 6 for retatrutide), so it reads the same across dose changes and the switch. Food thoughts are divided by the hours you spent in each band. A dash means no data in that band yet."),
  );
}

/* ---------- Dose plan (log.dose_plan, from the titration sheet) ---------- */

function planRows(data) {
  return (data.dose_plan || [])
    .filter((r) => r.planned_on && num(r.dose_mg) != null)
    .map((r) => ({ ...r, dose_mg: num(r.dose_mg), units: num(r.units) }))
    .sort((a, b) => (a.planned_on < b.planned_on ? -1 : 1));
}

/* The next planned dose that hasn't been logged yet (today counts until a dose is logged today). */
function nextPlanned(data) {
  const today = todayKey();
  const loggedDays = new Set((data.doses || []).filter((d) => !d.skipped && parseTs(d.taken_at)).map((d) => dateKeyCT(parseTs(d.taken_at))));
  return planRows(data).find((r) => r.planned_on >= today && !loggedDays.has(r.planned_on)) || null;
}

function planDoseText(r) {
  const name = capitalize(r.compound || "");
  return `${name} ${fmtNum(r.dose_mg, 1)} mg${r.units != null ? ` (${fmtNum(r.units, 0)} units)` : ""}`;
}

/* Consecutive weeks at the same compound and dose form a step. */
function planSteps(rows) {
  const steps = [];
  for (const r of rows) {
    const last = steps[steps.length - 1];
    if (last && last.compound === r.compound && last.dose_mg === r.dose_mg) { last.to = r.planned_on; last.weeks += 1; }
    else steps.push({ compound: r.compound, dose_mg: r.dose_mg, units: r.units, from: r.planned_on, to: r.planned_on, weeks: 1 });
  }
  return steps;
}

function renderDosePlan(data) {
  const rows = planRows(data);
  if (!rows.length) return null;
  const next = nextPlanned(data);
  const steps = planSteps(rows);
  const reta = rows.filter((r) => r.compound === "retatrutide");
  const total = reta.reduce((a, r) => a + r.dose_mg, 0);
  const today = todayKey();
  const usedSoFar = reta.filter((r) => r.planned_on < (next ? next.planned_on : "9999")).reduce((a, r) => a + r.dose_mg, 0);
  const stepUp = next ? rows.find((r) => r.planned_on > next.planned_on && r.compound === next.compound && r.dose_mg > next.dose_mg) : null;
  const when = (key) => {
    const d = daysUntil(keyToNoon(key));
    return `${fmtDateCT(keyToNoon(key), true)}, ${daysWord(d)}`;
  };
  const currentStep = next ? steps.find((s) => next.planned_on >= s.from && next.planned_on <= s.to) : null;
  return card("Dose plan",
    next ? el("p", { class: "lead" }, `Next: ${planDoseText(next)}${next.week ? `, week ${next.week} of ${reta.length}` : ""}.`) : el("p", { class: "lead" }, "Every planned dose is done."),
    next ? el("div", { class: "props" },
      prop("When", when(next.planned_on)),
      next.vial_draw ? prop("Draw from", next.vial_draw) : null,
      next.notes ? prop("Note", next.notes) : null,
      stepUp ? prop("Next step-up", `${fmtNum(stepUp.dose_mg, 1)} mg${stepUp.units != null ? ` (${fmtNum(stepUp.units, 0)} units)` : ""} on ${fmtDateCT(keyToNoon(stepUp.planned_on), true)}`) : null,
      reta.length ? prop("Retatrutide used", `${fmtNum(usedSoFar, 1)} of ${fmtNum(total, 0)} mg planned`) : null,
    ) : null,
    el("div", { class: "table-scroll" }, el("table", { class: "data compact plan-steps" },
      el("thead", null, el("tr", null, el("th", null, "Dose"), el("th", null, "Sundays"), el("th", { class: "num" }, "Weeks"))),
      el("tbody", null, ...steps.map((s) => el("tr", { class: s === currentStep ? "on" : s.to < today ? "done" : null },
        el("td", null, `${s.compound === "tirzepatide" ? "Tirz " : ""}${fmtNum(s.dose_mg, 1)} mg${s.units != null ? `, ${fmtNum(s.units, 0)} u` : ""}`),
        el("td", null, s.from === s.to ? fmtShortDate(s.from) : `${fmtShortDate(s.from)} – ${fmtShortDate(s.to)}`),
        el("td", { class: "num" }, String(s.weeks)),
      ))),
    )),
    el("p", { class: "caption" }, "From your titration sheet. The plan is a guide; what you actually take is what you log. 1 mg = 10 units at 10 mg/mL."),
  );
}

/* ---------- Trends: sections and the summary ---------- */

const TREND_SECTIONS = [
  { id: "summary", label: "Summary" },
  { id: "weight", label: "Weight" },
  { id: "food", label: "Food" },
  { id: "meds", label: "Meds" },
  { id: "body", label: "Body" },
  { id: "training", label: "Training" },
  { id: "more", label: "More" },
];
const TREND_SECTION_KEY = "log.trendsSection";

function trendSection() {
  if (!state.trendSection) {
    try { state.trendSection = localStorage.getItem(TREND_SECTION_KEY) || "summary"; } catch (_) { state.trendSection = "summary"; }
  }
  return TREND_SECTIONS.some((s) => s.id === state.trendSection) ? state.trendSection : "summary";
}

function setTrendSection(id) {
  state.trendSection = id;
  try { localStorage.setItem(TREND_SECTION_KEY, id); } catch (_) { /* private mode */ }
  render();
  window.scrollTo(0, 0);
}

function renderTrendNav(active) {
  const nav = el("nav", { class: "trend-nav", "aria-label": "Trends sections" },
    el("div", { class: "trend-track" },
      ...TREND_SECTIONS.map((s) => el("button", {
        type: "button",
        class: "trend-chip",
        "aria-current": s.id === active ? "page" : null,
        onClick: () => { if (s.id !== trendSection()) setTrendSection(s.id); },
      }, s.label)),
    ),
  );
  // Keep the chosen section in view when the row scrolls sideways.
  requestAnimationFrame(() => {
    const on = nav.querySelector('[aria-current="page"]');
    const track = nav.querySelector(".trend-track");
    if (on && track && (on.offsetLeft < track.scrollLeft || on.offsetLeft + on.offsetWidth > track.scrollLeft + track.clientWidth)) {
      track.scrollLeft = on.offsetLeft - 16;
    }
  });
  return nav;
}

function summaryTile(id, label, value, sub, spark) {
  return el("button", { type: "button", class: "sum-tile", onClick: () => setTrendSection(id) },
    el("span", { class: "sum-label" }, label),
    el("span", { class: "sum-value" }, value),
    el("span", { class: "sum-sub" }, sub),
    spark || null,
  );
}

function renderTrendSummary(data) {
  const now = new Date();
  const today = todayKey();
  const t30 = new Date(now.getTime() - 30 * 86400000);
  const tiles = [];

  // Weight
  const sm = smoothWeights(parseWeights(data.weights || []));
  const last = sm[sm.length - 1];
  const rate = trendRate(sm, 28);
  tiles.push(summaryTile("weight", "Weight",
    last ? `${fmtNum(last.trend, 1)} lb` : "—",
    rate != null ? `${signed(rate, 1)} lb a week, 4-week trend` : "Needs more weigh-ins",
    last ? sparkline(sm.filter((w) => w.at >= t30).map((w) => ({ t: w.at, v: w.trend })), t30, now) : null));

  // Food, last 7 days
  const t = getTargets(data);
  const week = lastNDays(7).map((k) => totalsOn(data, k)).filter((r) => r && num(r.calories) != null);
  const kcal = week.length ? week.reduce((a, r) => a + num(r.calories), 0) / week.length : null;
  const pro = week.length ? week.reduce((a, r) => a + (num(r.protein_g) || 0), 0) / week.length : null;
  const hits = t.protein != null ? week.filter((r) => num(r.protein_g) >= t.protein).length : null;
  tiles.push(summaryTile("food", "Food, last 7 days",
    kcal != null ? `${fmtNum(kcal, 0)} kcal` : "Not logged",
    kcal != null ? `${fmtNum(pro, 0)} g protein a day${hits != null ? `, target hit ${hits} of ${week.length}` : ""}` : "Log meals to see averages",
    sparkline(lastNDays(30).map((k) => ({ k, r: totalsOn(data, k) })).filter((x) => x.r && num(x.r.calories) != null).map((x) => ({ t: keyToNoon(x.k), v: num(x.r.calories) })), t30, now)));

  // Maintenance
  const m = maintenanceEstimate(data);
  const best = m.fromLogs != null ? m.fromLogs : m.watch;
  tiles.push(summaryTile("food", "Maintenance",
    best != null ? `${fmtNum(Math.round(best / 10) * 10, 0)} kcal` : "—",
    m.fromLogs != null ? "From food logs and weight" : m.watch != null ? "Apple Watch estimate" : "Needs more data",
    m.burn.length ? sparkline(m.burn, new Date(keyToNoon(m.start).getTime() - 43200000), now) : null));

  // Medication
  const share = levelShareAt(data, now);
  const next = nextPlanned(data);
  const levelPts = [];
  for (let i = 13; i >= 0; i--) {
    const at = new Date(now.getTime() - i * 86400000);
    const s = levelShareAt(data, at);
    if (s != null) levelPts.push({ t: at, v: s });
  }
  tiles.push(summaryTile("meds", "Medication",
    share != null ? `${fmtNum(share * 100, 0)}% of peak` : "No doses yet",
    next ? `Next: ${planDoseText(next)}, ${fmtDateCT(keyToNoon(next.planned_on), true)}` : "Estimated level now",
    levelPts.length > 1 ? sparkline(levelPts, new Date(now.getTime() - 14 * 86400000), now) : null));

  // Recovery
  let rec = offNormal(data, today);
  if (rec.checked.length < 2) rec = offNormal(data, shiftDay(today, -1));
  const rhr = (data.daily_health || []).filter((r) => num(r.resting_hr) != null).map((r) => ({ t: keyToNoon(r.day), v: num(r.resting_hr) })).filter((p) => p.t >= t30);
  tiles.push(summaryTile("body", "Recovery",
    rec.checked.length < 2 ? "—" : rec.off.length >= 2 ? `${rec.off.length} of ${rec.checked.length} off` : "Normal",
    rec.checked.length < 2 ? "Needs Apple Health data" : rec.off.length ? rec.off.map((c) => `${c.s.lower} ${fmtSignalDiff(c)}`).join(", ") : `${rec.checked.length} signals in their usual range`,
    rhr.length > 1 ? sparkline(rhr, t30, now) : null));

  return el("section", { class: "sum-grid", "aria-label": "Summary" }, ...tiles);
}
