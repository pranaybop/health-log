/*
  Switch and recovery cards (Nov 25, 2026): protein streak, retatrutide switch,
  reta vs tirz, sleep stages, vial runway by compound. Pure rendering on the
  dashboard payload; no invented numbers.
*/

function protocolRow(data, compound) {
  return (data.protocol || []).find((p) => String(p.compound || "").toLowerCase() === compound) || null;
}

function firstGlp1At(data) {
  const doses = (data.doses || [])
    .filter((d) => !d.skipped && parseTs(d.taken_at) && /tirzepatide|retatrutide/i.test(d.compound || ""))
    .sort((a, b) => parseTs(a.taken_at) - parseTs(b.taken_at));
  if (doses[0]) return parseTs(doses[0].taken_at);
  const p = protocolRow(data, "tirzepatide");
  if (p && p.started_on) return keyToNoon(p.started_on);
  return TIRZ_START;
}

function retaSwitchAt(data) {
  const p = protocolRow(data, "retatrutide");
  if (p && p.started_on) return keyToNoon(p.started_on);
  return RETA_START;
}

function firstRetaDose(data) {
  return (data.doses || [])
    .filter((d) => !d.skipped && parseTs(d.taken_at) && String(d.compound || "").toLowerCase() === "retatrutide")
    .sort((a, b) => parseTs(a.taken_at) - parseTs(b.taken_at))[0] || null;
}

function mean(vals) {
  return vals.length ? vals.reduce((a, b) => a + b, 0) / vals.length : null;
}

function proteinStreak(data) {
  const target = getTargets(data).protein;
  const today = todayKey();
  const todayRow = totalsOn(data, today);
  const todayPro = todayRow ? num(todayRow.protein_g) : null;
  if (target == null) return { target: null, streak: 0, remaining: null, hitToday: false, todayPro };
  const remaining = Math.max(0, target - (todayPro || 0));
  const hitToday = todayPro != null && todayPro >= target;
  let streak = 0;
  let k = hitToday ? today : shiftDay(today, -1);
  for (let i = 0; i < 400; i++) {
    const row = totalsOn(data, k);
    const pro = row ? num(row.protein_g) : null;
    if (pro == null || pro < target) break;
    streak += 1;
    k = shiftDay(k, -1);
  }
  return { target, streak, remaining, hitToday, todayPro };
}

function thoughtsByDay(data) {
  const out = new Map();
  let first = null;
  for (const t of data.food_thoughts || []) {
    const at = parseTs(t.thought_at);
    if (!at) continue;
    const k = dateKeyCT(at);
    out.set(k, (out.get(k) || 0) + 1);
    if (!first || k < first) first = k;
  }
  if (first) {
    const today = todayKey();
    for (let k = first; k <= today; k = shiftDay(k, 1)) if (!out.has(k)) out.set(k, 0);
  }
  return out;
}

function noiseByDay(data) {
  const out = new Map();
  for (const c of data.checkins || []) {
    const v = num(c.food_noise);
    if (c.day && v != null) out.set(c.day, v);
  }
  return out;
}

function metricValueOn(data, id, key) {
  const rows = (data.health_metrics || {})[id] || [];
  for (const row of rows) {
    const day = Array.isArray(row) ? row[0] : row.day;
    const v = Array.isArray(row) ? row[1] : row.value;
    if (day === key && Number.isFinite(Number(v))) return Number(v);
  }
  return null;
}

function sleepHoursOn(data, key) {
  const h = (data.daily_health || []).find((r) => r.day === key);
  if (h && num(h.sleep_hours) != null) return num(h.sleep_hours);
  const inBed = metricValueOn(data, "sleep_in_bed_h", key);
  if (inBed != null) return inBed;
  const parts = ["sleep_core_min", "sleep_deep_min", "sleep_rem_min"].map((id) => metricValueOn(data, id, key));
  if (parts.some((v) => v != null)) return parts.reduce((a, v) => a + (v || 0), 0) / 60;
  return null;
}

/* ---------- Protein remaining + streak (line under Food today) ---------- */

function renderProteinLine(data, key) {
  if (key !== todayKey()) return null;
  const s = proteinStreak(data);
  if (s.target == null) return null;
  const streakText = s.streak === 0
    ? "No hit streak yet."
    : `${s.streak} day${s.streak === 1 ? "" : "s"} in a row at your protein target.`;
  const remainText = s.hitToday
    ? `Target hit today.`
    : `${fmtNum(s.remaining, 0)} g left to hit ${fmtNum(s.target, 0)} g.`;
  return el("p", { class: "protein-line" + (s.hitToday || s.streak >= 3 ? " good" : "") }, `${remainText} ${streakText}`);
}

/* ---------- 4. Retatrutide switch ---------- */

function renderHalfLifePreview() {
  const t0 = new Date();
  t0.setHours(12, 0, 0, 0);
  const days = 14;
  const seriesFor = (hl, cls, id) => {
    const points = [];
    for (let i = 0; i <= days * 4; i++) {
      const t = new Date(t0.getTime() + i * 6 * 3600000);
      points.push({ t, v: Math.pow(0.5, (i * 0.25) / hl) });
    }
    return { id, label: id === "reta" ? "Retatrutide, 6-day half-life" : "Tirzepatide, 5-day half-life", cls, type: "line", dashed: id === "tirz", points };
  };
  return timeChart({
    t0,
    t1: new Date(t0.getTime() + days * 86400000),
    height: 150,
    yMin: 0,
    yMax: 1,
    yTicks: 3,
    aria: "Relative remaining after a dose, tirzepatide vs retatrutide half-life",
    fmtY: (v) => `${fmtNum(v * 100, 0)}%`,
    series: [seriesFor(5, "s3", "tirz"), seriesFor(6, "s2", "reta")],
    snap: "reta",
  });
}

function renderSwitchCard(data) {
  const start = retaSwitchAt(data);
  const days = daysUntil(start);
  const first = firstRetaDose(data);
  if (first && daysUntil(parseTs(first.taken_at)) < -14) return null;
  const rot = siteRotation(data);
  const next = rot.next ? (SITE_LABELS[rot.next] || rot.next) : "—";
  const p = protocolRow(data, "retatrutide");
  const units = p && num(p.units) != null ? num(p.units) : null;
  const mg = p && num(p.typical_dose_mg) != null ? num(p.typical_dose_mg) : null;
  const doseText = units != null
    ? `Take ${fmtNum(units, 0)} units${mg != null ? ` (${fmtNum(mg, 1)} mg at ${fmtNum(mg / (units / 100), 0)} mg/mL)` : ""}.`
    : mg != null ? `Take ${fmtNum(mg, 1)} mg.` : "Take the planned first dose.";
  let headline;
  if (first) headline = `First retatrutide dose logged ${fmtDateCT(parseTs(first.taken_at), true)}.`;
  else if (days > 0) headline = `Switch in ${days} day${days === 1 ? "" : "s"}, ${fmtDateCT(start, true)}.`;
  else if (days === 0) headline = "Switch day is today.";
  else headline = `Planned start was ${fmtDateCT(start, true)}. No retatrutide dose is logged yet.`;
  return card("Retatrutide switch",
    el("p", { class: "lead" }, headline),
    el("ul", { class: "checklist" },
      el("li", null, el("span", { class: "box", "aria-hidden": "true" }), `Mix the vial with 1 mL.`),
      el("li", null, el("span", { class: "box", "aria-hidden": "true" }), doseText),
      el("li", null, el("span", { class: "box", "aria-hidden": "true" }), "Don’t overlap with tirzepatide — this is a switch, not a stack."),
      el("li", null, el("span", { class: "box", "aria-hidden": "true" }), `Next site: ${next}.`),
    ),
    el("div", { class: "subchart" },
      el("h3", null, "Half-life shape"),
      renderHalfLifePreview(),
    ),
    el("div", { class: "legend" },
      el("span", null, el("i", { class: "key line s3 dashed" }), "Tirzepatide, 5 days"),
      el("span", null, el("i", { class: "key line s2" }), "Retatrutide, 6 days"),
    ),
    el("p", { class: "caption" }, "The chart is the share left after a dose, not milligrams, so it compares the 144-hour and 120-hour half-lives on the same scale."),
  );
}

/* ---------- Reta vs tirz ---------- */

function windowStats(data, fromKey, toKey) {
  const inWin = (k) => k >= fromKey && k <= toKey;
  const weights = parseWeights(data.weights || []).filter((w) => inWin(dateKeyCT(w.at)));
  const startW = weights[0] ? weights[0].lb : null;
  const endW = weights.length ? weights[weights.length - 1].lb : null;
  const delta = startW != null && endW != null ? endW - startW : null;
  const noise = mean((data.checkins || []).filter((c) => inWin(c.day)).map((c) => num(c.food_noise)).filter((v) => v != null));
  const energy = mean((data.checkins || []).filter((c) => inWin(c.day)).map((c) => num(c.energy)).filter((v) => v != null));
  const effects = (data.side_effects || []).filter((s) => inWin(s.recorded_on));
  const effectAvg = mean(effects.map((s) => num(s.severity)).filter((v) => v != null));
  const hrv = mean((data.daily_health || []).filter((r) => inWin(r.day)).map((r) => num(r.hrv_ms)).filter((v) => v != null));
  const rhr = mean((data.daily_health || []).filter((r) => inWin(r.day)).map((r) => num(r.resting_hr)).filter((v) => v != null));
  const burnDays = completeBurnDays(data, fromKey, toKey);
  const burn = burnDays.length >= 3 ? medianOf(burnDays.map((p) => p.v)) : null;
  const sleepVals = [];
  let k = fromKey;
  while (k <= toKey) {
    const v = sleepHoursOn(data, k);
    if (v != null) sleepVals.push(v);
    k = shiftDay(k, 1);
  }
  return {
    delta,
    noise,
    energy,
    effectAvg,
    effectN: effects.length,
    hrv,
    rhr,
    burn,
    sleep: mean(sleepVals),
    weighIns: weights.length,
  };
}

function renderRetaVsTirz(data) {
  const first = firstRetaDose(data);
  const today = todayKey();
  // Before the switch, show the tirzepatide baseline (last 4 full weeks) so it's there to compare against.
  const reta0 = first ? dateKeyCT(parseTs(first.taken_at)) : null;
  const tirz1 = reta0 ? shiftDay(reta0, -1) : shiftDay(today, -1);
  const tirz0 = shiftDay(tirz1, -27);
  const a = windowStats(data, tirz0, tirz1);
  const b = reta0 ? windowStats(data, reta0, shiftDay(reta0, 13)) : null;
  const cell = (label, av, bv, fmt) => el("tr", null,
    el("td", null, label),
    el("td", null, av == null ? "—" : fmt(av)),
    el("td", null, !b ? "" : bv == null ? "—" : fmt(bv)),
  );
  const retaDays = reta0 ? Math.min(14, dayDiff(today, reta0) + 1) : 0;
  const lead = reta0
    ? `Last 4 weeks on tirzepatide (${fmtShortDate(tirz0)}–${fmtShortDate(tirz1)}) vs the first ${Math.max(1, retaDays)} day${retaDays === 1 ? "" : "s"} on retatrutide.`
    : `Your tirzepatide baseline for the last 4 full weeks (${fmtShortDate(tirz0)}–${fmtShortDate(tirz1)}). The retatrutide column starts with your first dose (planned ${fmtDateCT(retaSwitchAt(data), true)}).`;
  return card("Retatrutide vs tirzepatide",
    el("p", { class: "lead" }, lead),
    el("div", { class: "table-scroll" }, el("table", { class: "data compact" },
      el("thead", null, el("tr", null, el("th", null, ""), el("th", null, "Tirzepatide"), el("th", null, b ? "Retatrutide" : ""))),
      el("tbody", null,
        cell("Weight change", a.delta, b && b.delta, (v) => `${signed(v)} lb`),
        cell("Food noise", a.noise, b && b.noise, (v) => `${fmtNum(v, 1)} /10`),
        cell("Energy", a.energy, b && b.energy, (v) => `${fmtNum(v, 1)} /10`),
        cell("Side effects", a.effectAvg, b && b.effectAvg, (v) => `${fmtNum(v, 1)} /10`),
        cell("Resting heart rate", a.rhr, b && b.rhr, (v) => `${fmtNum(v, 0)} bpm`),
        cell("HRV", a.hrv, b && b.hrv, (v) => `${fmtNum(v, 0)} ms`),
        cell("Burned a day", a.burn, b && b.burn, (v) => `${fmtNum(v, 0)} kcal`),
        cell("Sleep", a.sleep, b && b.sleep, (v) => `${fmtNum(v, 1)} h`),
      ),
    )),
    el("p", { class: "caption" }, "Averages over each window; calories burned is the Apple Watch's middle full day. Dashes mean that measure wasn’t logged in the window. The retatrutide column fills in over the first two weeks. This is a comparison, not advice."),
  );
}

/* ---------- 8. Compound-aware vial runway (used from renderVials) ---------- */

function compoundRunway(data, compound) {
  const r = vialRunway(data);
  if (!r.ready) return { ready: false, items: [] };
  const items = r.items.filter((v) => String(v.compound || "").toLowerCase() === compound);
  if (!items.length) return { ready: false, items: [] };
  const proto = protocolRow(data, compound) || {};
  const weeklyMg = num(proto.typical_dose_mg);
  const weeklyUnits = num(proto.units);
  let mg = 0;
  let units = 0;
  let hasMg = false;
  let hasUnits = false;
  for (const v of items) {
    const remMg = num(v.remaining_mg != null ? v.remaining_mg : v.total_mg);
    const remU = num(v.remaining_units != null ? v.remaining_units : v.total_units);
    if (remMg != null) { mg += remMg; hasMg = true; }
    if (remU != null) { units += remU; hasUnits = true; }
  }
  let weeks = null;
  if (weeklyMg && hasMg) weeks = mg / weeklyMg;
  else if (weeklyUnits && hasUnits) weeks = units / weeklyUnits;
  return { ready: true, items, mg: hasMg ? mg : null, units: hasUnits ? units : null, weeks, weeklyMg, weeklyUnits };
}

function renderCompoundRunway(data) {
  const switchAt = retaSwitchAt(data);
  const days = daysUntil(switchAt);
  const tirz = compoundRunway(data, "tirzepatide");
  const reta = compoundRunway(data, "retatrutide");
  if (!tirz.ready && !reta.ready) return null;
  const bits = [];
  if (tirz.ready) {
    const shotsLeft = tirz.weeks != null ? Math.floor(tirz.weeks) : null;
    const shotsNeeded = days > 0 ? Math.ceil(days / 7) : 0;
    let line;
    if (days <= 0) line = `Tirzepatide: ${tirz.mg != null ? `${fmtNum(tirz.mg, tirz.mg % 1 ? 1 : 0)} mg on hand` : `${tirz.items.length} vial${tirz.items.length === 1 ? "" : "s"}`}. The switch date has arrived.`;
    else if (shotsLeft != null) {
      const enough = shotsLeft >= shotsNeeded;
      line = `Tirzepatide: ${fmtNum(tirz.mg, tirz.mg % 1 ? 1 : 0)} mg, about ${fmtNum(tirz.weeks, 1)} weekly shot${tirz.weeks === 1 ? "" : "s"} at ${fmtNum(tirz.weeklyMg, 1)} mg. The switch is in ${days} day${days === 1 ? "" : "s"} (about ${shotsNeeded} shot${shotsNeeded === 1 ? "" : "s"}). ${enough ? "That covers the remaining tirzepatide weeks." : "That may run short before Dec 6."}`;
    } else line = `Tirzepatide: ${tirz.items.length} vial${tirz.items.length === 1 ? "" : "s"} on hand.`;
    bits.push(line);
  } else if (days > 0) {
    bits.push("No tirzepatide vials are logged, so runway before Dec 6 can’t be calculated.");
  }
  if (reta.ready) {
    if (reta.weeks != null && reta.weeklyUnits) {
      bits.push(`Retatrutide: ${fmtNum(reta.units, 0)} units on hand, about ${fmtNum(reta.weeks, 1)} week${reta.weeks === 1 ? "" : "s"} at ${fmtNum(reta.weeklyUnits, 0)} units a week.`);
    } else if (reta.mg != null) {
      bits.push(`Retatrutide: ${fmtNum(reta.mg, reta.mg % 1 ? 1 : 0)} mg on hand${reta.weeks != null ? `, about ${fmtNum(reta.weeks, 1)} week${reta.weeks === 1 ? "" : "s"}` : ""}.`);
    } else bits.push(`Retatrutide: ${reta.items.length} vial${reta.items.length === 1 ? "" : "s"} on hand.`);
  } else {
    bits.push("No retatrutide vials are logged yet.");
  }
  return el("p", { class: "caption runway-note" }, bits.join(" "));
}

/* ---------- 9. Last night's sleep + 7-day debt ---------- */

function sleepStagesOn(data, key) {
  const core = metricValueOn(data, "sleep_core_min", key);
  const deep = metricValueOn(data, "sleep_deep_min", key);
  const rem = metricValueOn(data, "sleep_rem_min", key);
  const awake = metricValueOn(data, "sleep_awake_min", key);
  if (core == null && deep == null && rem == null && awake == null) return null;
  return { core, deep, rem, awake };
}

function nightKeyFor(data, view) {
  const today = todayKey();
  if (view && view !== today) return view;
  if (sleepHoursOn(data, today) != null || sleepStagesOn(data, today)) return today;
  const y = shiftDay(today, -1);
  if (sleepHoursOn(data, y) != null || sleepStagesOn(data, y)) return y;
  return today;
}

function renderSleepNight(data, key) {
  const isToday = !key || key === todayKey();
  const night = nightKeyFor(data, key || todayKey());
  const hours = sleepHoursOn(data, night);
  const stages = sleepStagesOn(data, night);
  const keys = lastNDays(7);
  const nights = keys.map((k) => ({ key: k, h: sleepHoursOn(data, k) })).filter((n) => n.h != null);
  if (hours == null && !stages && nights.length < 3) {
    if (!isToday) return null;
    return card("Sleep", el("p", { class: "empty" }, "No sleep stages or hours yet. They appear after an Apple Health sync from the iPhone app."));
  }
  const REF = 8;
  const avg = mean(nights.map((n) => n.h));
  const shortfall = nights.length ? nights.reduce((a, n) => a + Math.max(0, REF - n.h), 0) : null;
  const total = stages ? ["core", "deep", "rem", "awake"].reduce((a, k) => a + (stages[k] || 0), 0) : 0;
  const bar = stages && total > 0
    ? el("div", { class: "sleep-stages", role: "img", "aria-label": "Sleep stages" },
        ...[
          ["core", "Core", "s1"],
          ["deep", "Deep", "s3"],
          ["rem", "REM", "s4"],
          ["awake", "Awake", "awake"],
        ].map(([k, label, cls]) => {
          const v = stages[k];
          if (v == null || v <= 0) return null;
          return el("span", { class: cls, style: { width: `${(v / total) * 100}%` }, title: `${label} ${fmtNum(v, 0)} min` });
        }).filter(Boolean),
      )
    : null;
  const stageBits = stages
    ? [
        stages.core != null ? `Core ${fmtNum(stages.core, 0)} min` : null,
        stages.deep != null ? `Deep ${fmtNum(stages.deep, 0)} min` : null,
        stages.rem != null ? `REM ${fmtNum(stages.rem, 0)} min` : null,
        stages.awake != null ? `Awake ${fmtNum(stages.awake, 0)} min` : null,
      ].filter(Boolean).join(" · ")
    : null;
  const label = night === todayKey() ? "Last night" : fmtShortDate(night);
  return card("Sleep",
    el("div", { class: "tiles" },
      metric(label, hours != null ? `${fmtNum(hours, 1)} h` : "—", stageBits || (hours != null ? "asleep" : "no hours for this night")),
      metric("7-night average", avg != null ? `${fmtNum(avg, 1)} h` : "—", nights.length ? `${nights.length} night${nights.length === 1 ? "" : "s"} with data` : "needs more nights"),
      metric("vs 8-hour nights", shortfall != null ? `${fmtNum(shortfall, 1)} h short` : "—", "Sum of shortfalls on recorded nights, not a personal target"),
    ),
    bar,
    bar ? el("div", { class: "legend" },
      el("span", null, el("i", { class: "key rect s1" }), "Core"),
      el("span", null, el("i", { class: "key rect s3" }), "Deep"),
      el("span", null, el("i", { class: "key rect s4" }), "REM"),
      el("span", null, el("i", { class: "key rect awake" }), "Awake"),
    ) : null,
    !stages && hours != null ? el("p", { class: "caption" }, "Stage breakdown will show once sleep stages sync from Apple Health.") : null,
    nights.length < 3 ? el("p", { class: "caption" }, "Sleep debt uses recorded nights only, compared with an 8-hour reference, and needs a few more nights to settle.") : null,
  );
}
