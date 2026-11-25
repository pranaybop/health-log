/*
  Tracking cards added Nov 25, 2026: food thoughts, the week after a shot, heart
  (resting HR and HRV), body composition, protein hit rate and loss rate.
  Pure rendering on top of the dashboard payload; writes go through log-write.
*/

const STRENGTHS = [
  { v: 1, label: "Passing thought" },
  { v: 2, label: "Strong pull" },
  { v: 3, label: "Craving" },
];

const COMMON_EFFECTS = ["Nausea", "Constipation", "Reflux", "Fatigue", "Headache", "Low appetite"];

function thoughtsOn(data, key) {
  return (data.food_thoughts || []).filter((t) => parseTs(t.thought_at) && dateKeyCT(parseTs(t.thought_at)) === key);
}

/* Days since the most recent real shot on or before a calendar day (0 = shot day). */
function shotDayIndex(doses, key) {
  let best = null;
  for (const d of doses) {
    if (d.skipped) continue;
    const t = parseTs(d.taken_at);
    if (!t) continue;
    const k = dateKeyCT(t);
    if (k <= key && (best == null || k > best)) best = k;
  }
  if (!best) return null;
  const n = dayDiff(key, best);
  return n >= 0 && n <= 6 ? n : null;
}

/* Loss rate as a share of body weight per week, from the 4-week fit of weigh-ins. */
function lossRate(data) {
  const parsed = parseWeights(data.weights || []);
  if (!parsed.length) return null;
  const rp = recentPace(parsed, 28);
  if (!rp) return null;
  const cur = parsed[parsed.length - 1].lb;
  const pct = (-rp.weekly / cur) * 100;
  return { weekly: rp.weekly, pct, fast: pct > 1 };
}

/* ---------- Today: food thoughts and side effects ---------- */

function renderFeelNow(data, key) {
  const isToday = key === todayKey();
  const list = thoughtsOn(data, key);
  const last = list.length ? parseTs(list[list.length - 1].thought_at) : null;
  const effects = (data.side_effects || []).filter((s) => s.recorded_on === key);
  if (!isToday) {
    if (!list.length && !effects.length) return null;
    return card("Food thoughts and side effects",
      el("div", { class: "props" },
        prop("Food thoughts", list.length ? `${list.length}${last ? `, last at ${fmtTimeCT(last).replace(" CT", "")}` : ""}` : "None logged"),
        prop("Side effects", effects.length ? effects.map((s) => `${s.effect} ${s.severity}/10`).join(", ") : "None logged"),
      ),
    );
  }
  const status = list.length
    ? `${list.length} today, last at ${fmtTimeCT(last).replace(" CT", "")}.`
    : "None yet today.";
  const tap = (s) => el("button", {
    type: "button",
    class: "thought-btn" + (s.v === 3 ? " strong" : ""),
    disabled: state.formBusy,
    onClick: () => handleWrite("food_thought", { strength: s.v }, `Logged a food thought (${s.label.toLowerCase()}).`),
  }, s.label);
  return cardWithAction("Thinking about food?",
    el("button", { type: "button", class: "link", onClick: () => { state.effectOpen = !state.effectOpen; render(); } }, state.effectOpen ? "Close" : "Side effect?"),
    el("p", { class: "caption first" }, "Tap when it happens. It shows when food noise peaks in your week."),
    el("div", { class: "thoughts" }, ...STRENGTHS.map(tap)),
    el("p", { class: "caption" }, status),
    state.effectOpen ? renderQuickEffect(data) : null,
    effects.length ? el("p", { class: "caption" }, `Side effects today: ${effects.map((s) => `${s.effect} ${s.severity}/10`).join(", ")}.`) : null,
  );
}

function renderQuickEffect() {
  const name = input({ type: "text", name: "effect", maxlength: "80", placeholder: "Or type one" });
  const pick = chips("effect_pick", COMMON_EFFECTS.map((e) => ({ value: e, label: e })), "");
  pick.classList.add("effect-chips");
  pick.addEventListener("click", () => { if (chipValue(pick)) name.value = ""; });
  const sev = rangeField("How bad, 1 to 10", "severity", 1, 10, 4);
  return el("div", { class: "log-form quick-effect" },
    pick,
    field("Something else", name),
    sev,
    el("div", { class: "form-actions" },
      el("button", {
        type: "button",
        class: "primary",
        disabled: state.formBusy,
        onClick: async () => {
          const effect = name.value.trim() || chipValue(pick);
          if (!effect) { setFormMessage(false, "Pick or type a side effect."); render(); return; }
          const ok = await handleWrite("side_effect_upsert", { effect, severity: sev.querySelector("input").value }, `Logged ${effect.toLowerCase()}.`);
          if (ok) { state.effectOpen = false; render(); }
        },
      }, "Save side effect"),
    ),
  );
}

/* ---------- Trends ---------- */

function renderProteinCard(data) {
  const t = getTargets(data).protein;
  const rows = (data.daily_totals || []).filter((r) => r.date >= shiftDay(todayKey(), -29) && num(r.protein_g) != null);
  if (!rows.length) return null;
  const avg = rows.reduce((a, r) => a + num(r.protein_g), 0) / rows.length;
  const last7 = rows.filter((r) => r.date >= shiftDay(todayKey(), -6));
  const avg7 = last7.length ? last7.reduce((a, r) => a + num(r.protein_g), 0) / last7.length : null;
  const hits = t != null ? rows.filter((r) => num(r.protein_g) >= t).length : null;
  return card("Protein target",
    el("div", { class: "tiles" },
      metric("Days at target", hits != null ? `${hits} of ${rows.length}` : "—", t != null ? `${fmtNum(t, 0)} g or more, last 30 days` : "Set a target on Today"),
      metric("Average", `${fmtNum(avg, 0)} g`, `${rows.length} logged day${rows.length === 1 ? "" : "s"}`),
      metric("Last 7 days", avg7 != null ? `${fmtNum(avg7, 0)} g` : "—", "average a logged day"),
      metric("Short by", t != null ? `${fmtNum(Math.max(0, t - avg), 0)} g` : "—", "average gap to target"),
    ),
    el("p", { class: "caption" }, "Only days with food logged count, so a missing day doesn't drag the average down."),
  );
}

function renderFoodThoughtsCard(data) {
  const all = (data.food_thoughts || []).map((t) => ({ ...t, at: parseTs(t.thought_at) })).filter((t) => t.at);
  if (!all.length) return card("Food thoughts", el("p", { class: "empty" }, "Tap a button under Thinking about food? on Today when it happens. Patterns show up here."));
  const firstKey = dateKeyCT(all[0].at);
  const keys = lastNDays(30).filter((k) => k >= firstKey);
  const counts = new Map();
  for (const t of all) { const k = dateKeyCT(t.at); counts.set(k, (counts.get(k) || 0) + 1); }
  const days = keys.map((k) => ({ key: k, v: counts.get(k) || 0, today: k === todayKey() }));
  const total = days.reduce((a, d) => a + d.v, 0);
  const hours = new Array(24).fill(0);
  for (const t of all) hours[hourCT(t.at)] += 1;
  const peak = hours.indexOf(Math.max(...hours));
  const peakLabel = new Intl.DateTimeFormat("en-US", { hour: "numeric", hour12: true, timeZone: "UTC" }).format(new Date(Date.UTC(2020, 0, 1, peak)));
  const strong = all.filter((t) => num(t.strength) >= 2).length;
  const ro = readout(`${fmtNum(total / Math.max(1, keys.length), 1)} a day`, `${total} since ${fmtShortDate(firstKey)}`);
  return card("Food thoughts",
    ro.node,
    keys.length >= 2 ? columnChart({
      days,
      cls: "s2",
      height: 130,
      fmtY: (v) => fmtNum(v, 0),
      aria: "Food thoughts a day",
      onScrub: (d) => { if (!d) return ro.reset(); ro.set(`${d.v} food thought${d.v === 1 ? "" : "s"}`, fmtShortDate(d.key)); },
    }) : null,
    el("div", { class: "props" },
      prop("Most often around", peakLabel),
      prop("Strong pull or craving", `${strong} of ${all.length}`),
    ),
  );
}

/* Food noise, food thoughts, side effects and energy by day since the shot. */
function renderShotWeek(data) {
  const doses = data.doses || [];
  if (!doses.some((d) => !d.skipped)) return null;
  const cols = [0, 1, 2, 3, 4, 5, 6];
  const acc = () => cols.map(() => ({ sum: 0, n: 0 }));
  const rows = {
    noise: { label: "Food noise", unit: "/10", cells: acc() },
    thoughts: { label: "Food thoughts", unit: "", cells: acc() },
    effects: { label: "Side effects", unit: "/10", cells: acc() },
    energy: { label: "Energy", unit: "/10", cells: acc() },
  };
  const add = (row, key, v) => {
    const i = shotDayIndex(doses, key);
    if (i == null || v == null || !Number.isFinite(v)) return;
    rows[row].cells[i].sum += v;
    rows[row].cells[i].n += 1;
  };
  for (const c of data.checkins || []) {
    add("noise", c.day, num(c.food_noise));
    add("energy", c.day, num(c.energy));
  }
  const thoughtDays = new Map();
  for (const t of data.food_thoughts || []) {
    const at = parseTs(t.thought_at);
    if (at) thoughtDays.set(dateKeyCT(at), (thoughtDays.get(dateKeyCT(at)) || 0) + 1);
  }
  if (thoughtDays.size) {
    const first = [...thoughtDays.keys()].sort()[0];
    for (let k = first; k <= todayKey(); k = shiftDay(k, 1)) add("thoughts", k, thoughtDays.get(k) || 0);
  }
  const effByDay = new Map();
  for (const s of data.side_effects || []) {
    const v = num(s.severity);
    if (v == null) continue;
    effByDay.set(s.recorded_on, Math.max(effByDay.get(s.recorded_on) || 0, v));
  }
  for (const [k, v] of effByDay) add("effects", k, v);
  const any = Object.values(rows).some((r) => r.cells.some((c) => c.n));
  if (!any) return card("The week after a shot", el("p", { class: "empty" }, "Fills in as you check in, tap food thoughts and log side effects."));
  const head = el("div", { class: "sw-row sw-head" }, el("span", null, ""), ...cols.map((i) => el("span", null, i === 0 ? "Shot" : `+${i}`)));
  const body = Object.values(rows).map((r) => {
    const avgs = r.cells.map((c) => (c.n ? c.sum / c.n : null));
    const max = Math.max(...avgs.filter((v) => v != null), 0.0001);
    return el("div", { class: "sw-row" },
      el("span", { class: "sw-label" }, r.label),
      ...avgs.map((v) => el("span", {
        class: "sw-cell" + (v == null ? " none" : ""),
        style: v == null ? null : `--a: ${(0.12 + 0.6 * (v / max)).toFixed(2)}`,
        title: v == null ? "No data" : `${fmtNum(v, 1)}${r.unit}`,
      }, v == null ? "·" : fmtNum(v, v < 10 && v % 1 ? 1 : 0))),
    );
  });
  return card("The week after a shot",
    el("p", { class: "caption first" }, "Average by day since your shot. Darker means higher within the row. Side effects use the worst one that day."),
    el("div", { class: "shotweek", role: "table", "aria-label": "Averages by day since shot" }, head, ...body),
    dataView("The week after a shot", ["", ...cols.map((i) => (i === 0 ? "Shot day" : `Day ${i}`))],
      Object.values(rows).map((r) => [r.label, ...r.cells.map((c) => (c.n ? `${fmtNum(c.sum / c.n, 1)} (${c.n})` : "—"))])),
  );
}

function heartSeries(data, field) {
  return (data.daily_health || [])
    .filter((r) => num(r[field]) != null)
    .map((r) => ({ t: keyToNoon(r.day), v: num(r[field]), key: r.day }));
}

function avgBetween(pts, fromKey, toKey) {
  const v = pts.filter((p) => p.key >= fromKey && p.key <= toKey).map((p) => p.v);
  return v.length ? { avg: v.reduce((a, b) => a + b, 0) / v.length, n: v.length } : null;
}

function renderHeartCard(data) {
  const rhr = heartSeries(data, "resting_hr");
  const hrv = heartSeries(data, "hrv_ms");
  if (rhr.length < 3 && hrv.length < 3) return null;
  const t1 = new Date();
  const t0 = new Date(t1.getTime() - 120 * 86400000);
  const today = todayKey();
  const tirzKey = dateKeyCT(TIRZ_START);
  const marks = [{ t: TIRZ_START, label: "Tirzepatide" }];
  if (RETA_START <= t1) marks.push({ t: RETA_START, label: "Retatrutide" });
  const sub = (pts, title, unit, cls, higherIsBetter) => {
    if (pts.length < 3) return null;
    const base = avgBetween(pts, shiftDay(tirzKey, -30), shiftDay(tirzKey, -1));
    const recent = avgBetween(pts, shiftDay(today, -6), today);
    const smooth = rollingMean(pts, 7);
    const ro = readout(recent ? `${fmtNum(recent.avg, 0)} ${unit}` : "—",
      recent ? `7-day average${base ? `. Before tirzepatide: ${fmtNum(base.avg, 0)}` : ""}` : "");
    const delta = recent && base ? recent.avg - base.avg : null;
    return el("div", { class: "subchart" },
      el("h3", null, el("i", { class: `key line ${cls}`, "aria-hidden": "true" }), title,
        delta != null ? el("span", { class: `badge ${Math.abs(delta) < 2 ? "steady" : (delta > 0) === higherIsBetter ? "good" : "watch"}` }, `${signed(delta, 0)} ${unit}`) : null),
      ro.node,
      timeChart({
        t0, t1, height: 150, aria: `${title}, last 120 days`, fmtY: (v) => fmtNum(v, 0),
        series: [
          { id: "d", cls: `${cls} faint`, type: "dots", r: 2, points: pts },
          { id: "s", cls, type: "smooth", endDot: true, points: smooth },
        ],
        marks,
        snap: "s",
        onScrub: (r) => {
          if (!r) return ro.reset();
          const day = r.readings && r.readings.d;
          ro.set(`${fmtNum(r.point.v, 0)} ${unit}`, `${fmtDateCT(r.point.t, true)}, 7-day average${day ? `. That day ${fmtNum(day.v, 0)}` : ""}`);
        },
      }),
    );
  };
  return card("Heart",
    sub(rhr, "Resting heart rate", "bpm", "s3", false),
    sub(hrv, "Heart rate variability", "ms", "s4", true),
    el("p", { class: "caption" }, "From Apple Health. The badge compares the last 7 days with the 30 days before tirzepatide. Watch resting heart rate after the Dec 6 switch: the retatrutide trials reported it rising."),
  );
}

function renderBodyComp(data) {
  const m = (data.measurements || []).map((r) => ({ ...r, at: parseTs(r.measured_at), v: num(r.value) })).filter((r) => r.at && r.v != null);
  const bf = m.filter((r) => r.metric === "body_fat_pct").sort((a, b) => a.at - b.at);
  const lean = m.filter((r) => r.metric === "lean_mass_lb").sort((a, b) => a.at - b.at);
  const parsed = parseWeights(data.weights || []);
  const cur = parsed[parsed.length - 1];
  const h = num((data.profile || {}).height_in);
  const bmi = cur && h ? (703 * cur.lb) / (h * h) : null;
  const tiles = [
    bmi != null ? metric("BMI", fmtNum(bmi, 1), `${fmtNum(cur.lb, 1)} lb at ${Math.floor(h / 12)}′${Math.round(h % 12)}″`) : null,
    bf.length ? metric("Body fat", `${fmtNum(bf[bf.length - 1].v, 1)}%`, bf.length > 1 ? `${signed(bf[bf.length - 1].v - bf[0].v)} pts since ${fmtDateCT(bf[0].at, false)}` : fmtDateCT(bf[0].at, true)) : null,
    lean.length ? metric("Lean mass", `${fmtNum(lean[lean.length - 1].v, 1)} lb`, lean.length > 1 ? `${signed(lean[lean.length - 1].v - lean[0].v)} lb since ${fmtDateCT(lean[0].at, false)}` : fmtDateCT(lean[0].at, true)) : null,
  ].filter(Boolean);
  // Share of the weight lost that was lean mass, between the first and latest body-composition readings.
  let share = null;
  if (lean.length >= 2) {
    const wAt = (t) => parsed.reduce((best, w) => (Math.abs(w.at - t) < Math.abs(best.at - t) ? w : best), parsed[0]);
    const w0 = wAt(lean[0].at).lb;
    const w1 = wAt(lean[lean.length - 1].at).lb;
    const lost = w0 - w1;
    if (lost > 2) share = Math.max(0, Math.min(1, (lean[0].v - lean[lean.length - 1].v) / lost));
  }
  if (share != null) tiles.push(metric("Loss that was lean", `${Math.round(share * 100)}%`, "lower is better"));
  const pts = lean.map((r) => ({ t: r.at, v: r.v }));
  const ro = pts.length ? readout(`${fmtNum(pts[pts.length - 1].v, 1)} lb`, `Lean mass, ${fmtDateCT(pts[pts.length - 1].at || pts[pts.length - 1].t, true)}`) : null;
  return card("Body composition",
    tiles.length ? el("div", { class: "tiles" }, ...tiles) : null,
    pts.length >= 2 ? el("div", { class: "subchart" }, el("h3", null, "Lean mass"), ro.node, timeChart({
      t0: pts[0].t, t1: new Date(Math.max(Date.now(), pts[pts.length - 1].t.getTime())), height: 150, aria: "Lean mass", fmtY: (v) => fmtNum(v, 0),
      series: [{ id: "l", cls: "s4", type: "line", endDot: true, points: pts }, { id: "ld", cls: "s4", type: "dots", points: pts }],
      snap: "l",
      onScrub: (r) => { if (!r) return ro.reset(); ro.set(`${fmtNum(r.point.v, 1)} lb`, fmtDateCT(r.point.t, true)); },
    })) : null,
    el("p", { class: "caption" }, bf.length || lean.length
      ? "Body fat comes from your scale through Apple Health; lean mass is that weigh-in minus its fat. Scale estimates swing day to day, so watch the direction over weeks."
      : "Body fat and lean mass sync from Apple Health in the Log iPhone app (scales like RENPHO write them there). You can also add them under Measurement on the Log tab."),
  );
}

/* ---------- More from Apple Health (log.health_metrics, last 120 days) ---------- */

const axisMinutes = (v) => (v >= 60 ? `${fmtNum(v / 60, 1)} h` : `${Math.round(v)} min`);

function fmtMinutes(min) {
  const m = Math.round(min);
  if (m < 60) return [String(m), "min"];
  const h = Math.floor(m / 60);
  return [`${h} h ${m % 60}`, "min"];
}

const MORE_HEALTH = [
  ["Heart and breathing", [
    { id: "heart_rate_avg", label: "Heart rate, daily average", unit: "bpm", d: 0 },
    { id: "heart_rate_min", label: "Lowest heart rate", unit: "bpm", d: 0 },
    { id: "heart_rate_max", label: "Highest heart rate", unit: "bpm", d: 0 },
    { id: "respiratory_rate", label: "Breathing rate", unit: "/min", d: 1 },
    { id: "spo2_avg", label: "Blood oxygen", unit: "%", d: 0 },
    { id: "spo2_min", label: "Lowest blood oxygen", unit: "%", d: 0 },
    { id: "bp_systolic", pair: "bp_diastolic", label: "Blood pressure", unit: "mmHg", d: 0 },
  ]],
  ["Sleep", [
    { id: "sleep_in_bed_h", label: "Time in bed", unit: "h", d: 1 },
    { id: "sleep_core_min", axis: axisMinutes, label: "Core sleep", fmt: fmtMinutes },
    { id: "sleep_deep_min", axis: axisMinutes, label: "Deep sleep", fmt: fmtMinutes },
    { id: "sleep_rem_min", axis: axisMinutes, label: "REM sleep", fmt: fmtMinutes },
    { id: "sleep_awake_min", axis: axisMinutes, label: "Awake during the night", fmt: fmtMinutes },
    { id: "wrist_temp_f", label: "Wrist temperature while asleep", unit: "°F", d: 1 },
  ]],
  ["Energy and food", [
    { id: "total_kcal", label: "Total energy burned", unit: "kcal", d: 0 },
    { id: "basal_kcal", label: "Resting energy", unit: "kcal", d: 0 },
    { id: "dietary_kcal", label: "Calories logged in Health", unit: "kcal", d: 0 },
    { id: "water_oz", label: "Water", unit: "fl oz", d: 0 },
  ]],
  ["Activity", [
    { id: "flights", label: "Flights climbed", unit: "", d: 0 },
    { id: "cycling_mi", label: "Cycling distance", unit: "mi", d: 1 },
    { id: "mindful_min", label: "Mindful minutes", unit: "min", d: 0 },
  ]],
  ["Other", [
    { id: "glucose_avg", label: "Blood glucose, average", unit: "mg/dL", d: 0 },
    { id: "glucose_min", label: "Lowest blood glucose", unit: "mg/dL", d: 0 },
    { id: "glucose_max", label: "Highest blood glucose", unit: "mg/dL", d: 0 },
    { id: "body_temp_f", label: "Body temperature", unit: "°F", d: 1 },
    { id: "basal_temp_f", label: "Basal body temperature", unit: "°F", d: 1 },
    { id: "state_of_mind", label: "Mood, from −1 to +1", fmt: (v) => [signed(v, 2), ""], axis: (v) => signed(v, 1) },
    { id: "height_in", label: "Height", fmt: (v) => [`${Math.floor(v / 12)}′${fmtNum(v % 12, 0)}″`, ""], axis: (v) => `${fmtNum(v, 1)} in` },
  ]],
];

function metricPoints(data, id) {
  const rows = (data.health_metrics || {})[id] || [];
  return rows
    .map(([day, v]) => ({ key: day, t: keyToNoon(day), v: Number(v) }))
    .filter((p) => p.key && Number.isFinite(p.v))
    .sort((a, b) => (a.key < b.key ? -1 : 1));
}

function metricParts(def, v, pairV) {
  if (def.fmt) return def.fmt(v);
  const main = pairV != null ? `${fmtNum(v, def.d)}/${fmtNum(pairV, def.d)}` : fmtNum(v, def.d);
  return [main, def.unit];
}

const TIGHT_UNITS = ["%", "°F", "/min"];

function metricText(def, v, pairV) {
  const [a, b] = metricParts(def, v, pairV);
  return b ? (TIGHT_UNITS.includes(b) ? `${a}${b}` : `${a}\u00a0${b}`) : a;
}

function sparkline(pts, t0, t1) {
  const w = 56;
  const h = 22;
  const svg = svgEl("svg", { class: "hm-spark", viewBox: `0 0 ${w} ${h}`, width: w, height: h, "aria-hidden": "true", focusable: "false" });
  const recent = pts.filter((p) => p.t >= t0);
  if (!recent.length) return svg;
  const lo = Math.min(...recent.map((p) => p.v));
  const hi = Math.max(...recent.map((p) => p.v));
  const X = (t) => 2 + ((t - t0) / (t1 - t0)) * (w - 4);
  const Y = (v) => (hi === lo ? h / 2 : 3 + (1 - (v - lo) / (hi - lo)) * (h - 6));
  if (recent.length > 1) {
    svg.append(svgEl("path", { d: recent.map((p, i) => `${i ? "L" : "M"}${X(p.t).toFixed(1)},${Y(p.v).toFixed(1)}`).join("") }));
  }
  const last = recent[recent.length - 1];
  svg.append(svgEl("circle", { cx: X(last.t).toFixed(1), cy: Y(last.v).toFixed(1), r: 2.2 }));
  return svg;
}

function metricChart(def, pts, pairPts) {
  const t1 = new Date();
  const t0 = new Date(t1.getTime() - 120 * 86400000);
  const smooth = (list) => rollingMean(list, 7);
  const last = pts[pts.length - 1];
  const pairOn = (key) => (pairPts ? pairPts.find((p) => p.key === key) : null);
  const lastPair = pairOn(last.key);
  const ro = readout(metricText(def, last.v, lastPair ? lastPair.v : null), `${fmtShortDate(last.key)}. The line is a 7-day average.`);
  const series = [
    { id: "d", cls: "s1 faint", type: "dots", r: 2, points: pts },
    { id: "s", cls: "s1", type: "smooth", endDot: true, points: smooth(pts) },
  ];
  if (pairPts && pairPts.length) {
    series.push({ id: "d2", cls: "s2 faint", type: "dots", r: 2, points: pairPts });
    series.push({ id: "s2", cls: "s2", type: "smooth", endDot: true, points: smooth(pairPts) });
  }
  // Axis labels: one decimal only when the ticks fall between whole numbers.
  const fmtY = def.axis || ((v) => fmtNum(v, Math.abs(v - Math.round(v)) < 1e-6 ? 0 : Math.max(1, def.d)));
  return el("div", { class: "hm-chart" },
    ro.node,
    timeChart({
      t0, t1, height: 140, aria: `${def.label}, last 120 days`, fmtY,
      series,
      snap: "d",
      onScrub: (r) => {
        if (!r) return ro.reset();
        const p = pairOn(r.point.key || dateKeyCT(r.point.t));
        ro.set(metricText(def, r.point.v, p ? p.v : null), fmtDateCT(r.point.t, true));
      },
    }),
  );
}

function renderMoreHealth(data) {
  const t1 = new Date();
  const t30 = new Date(t1.getTime() - 30 * 86400000);
  const open = state.openMetrics || (state.openMetrics = []);
  const groups = [];
  for (const [title, defs] of MORE_HEALTH) {
    const rows = [];
    for (const def of defs) {
      const pts = metricPoints(data, def.id);
      if (!pts.length) continue;
      const pairPts = def.pair ? metricPoints(data, def.pair) : null;
      const last = pts[pts.length - 1];
      const lastPair = pairPts ? pairPts.find((p) => p.key === last.key) : null;
      const month = pts.filter((p) => p.t >= t30);
      const monthPair = pairPts ? pairPts.filter((p) => p.t >= t30) : [];
      const avg = month.length > 1 ? month.reduce((a, p) => a + p.v, 0) / month.length : null;
      const avgPair = monthPair.length > 1 ? monthPair.reduce((a, p) => a + p.v, 0) / monthPair.length : null;
      const [main, unit] = metricParts(def, last.v, lastPair ? lastPair.v : null);
      const sub = `${fmtShortDate(last.key)}${avg != null ? `. 30-day average ${metricText(def, avg, avgPair)}` : ""}`;
      const row = el("details", {
        class: "hm-row",
        onToggle: () => {
          const i = open.indexOf(def.id);
          if (row.open) {
            if (i < 0) open.push(def.id);
            if (!row.querySelector(".hm-chart")) row.append(metricChart(def, pts, pairPts));
          } else if (i >= 0) open.splice(i, 1);
        },
      },
        el("summary", null,
          el("span", { class: "hm-label" }, def.label),
          sparkline(pts, t30, t1),
          el("span", { class: "hm-val" }, main, unit ? el("small", null, TIGHT_UNITS.includes(unit) ? unit : `\u00a0${unit}`) : null),
          el("span", { class: "hm-sub" }, sub),
        ),
      );
      if (open.includes(def.id)) {
        row.open = true;
        row.append(metricChart(def, pts, pairPts));
      }
      rows.push(row);
    }
    if (rows.length) groups.push(el("h3", { class: "hm-group" }, title), el("div", { class: "hm-list" }, ...rows));
  }
  if (!groups.length) {
    if (!canSyncHealth()) return null;
    return card("More from Apple Health",
      el("p", { class: "caption first" }, "Nothing here yet. Heart rate, breathing, blood oxygen, sleep stages, energy and the rest show up after the next sync."));
  }
  return card("More from Apple Health",
    ...groups,
    el("p", { class: "caption" }, "Synced from Apple Health by the Log iPhone app. Tap a row for the last 120 days."),
  );
}
