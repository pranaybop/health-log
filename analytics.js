/* WeightSnap-style analytics. Depends on helpers from app.js at call time. */

const SITES = ["Abd LR", "Abd LL", "Abd UR", "Abd UL", "Love L", "Love R"];
const FEEL_LABELS = { strong: "Strong", fading: "Fading", not_feeling_it: "Not feeling it" };
const VS_LABELS = { less: "Less", usual: "Usual", more: "More" };

function halfLifeDays(compound, protocol) {
  const rows = protocol || [];
  const p = rows.find((r) => (r.compound || "").toLowerCase() === String(compound || "").toLowerCase());
  const hours = num(p && p.half_life_hours);
  if (hours) return hours / 24;
  return String(compound || "").toLowerCase() === "retatrutide" ? 6 : 5;
}

function remainingAt(at, doses, protocol) {
  let total = 0;
  for (const d of doses || []) {
    if (d.skipped) continue;
    const t = parseTs(d.taken_at);
    const mg = num(d.dose_mg);
    if (!t || mg == null || at < t) continue;
    const days = (at - t) / 86400000;
    total += mg * Math.pow(0.5, days / halfLifeDays(d.compound, protocol));
  }
  return total;
}

function plannedDoses(doses, protocol) {
  const list = (doses || [])
    .filter((d) => !d.skipped && num(d.dose_mg) != null && parseTs(d.taken_at))
    .map((d) => ({ ...d, dose_mg: num(d.dose_mg) }));
  const last = list[list.length - 1];
  if (!last) return { list, next: null, withNext: list };
  const lastAt = parseTs(last.taken_at);
  const next = new Date(lastAt.getTime() + 7 * 86400000);
  if (next >= RETA_START) return { list, next: null, withNext: list };
  const active = (protocol || []).find((p) => p.status === "active");
  const plannedMg = num(active && active.typical_dose_mg) || last.dose_mg || 3;
  const planned = {
    taken_at: next.toISOString(),
    dose_mg: plannedMg,
    compound: last.compound || "tirzepatide",
    planned: true,
  };
  return { list, next, withNext: list.concat(planned) };
}

function levelSeries(doses, protocol, withPlanned) {
  const real = (doses || []).filter((d) => !d.skipped && parseTs(d.taken_at) && num(d.dose_mg) != null);
  if (!real.length) return null;
  const start = parseTs(real[0].taken_at);
  const end = new Date(RETA_START.getTime() + 14 * 86400000);
  const source = withPlanned ? plannedDoses(doses, protocol).withNext : real;
  const points = [];
  const plannedPts = [];
  const labels = [];
  const marks = [];
  for (let t = new Date(start); t <= end; t = new Date(t.getTime() + 86400000)) {
    const noon = new Date(t);
    points.push(remainingAt(noon, real, protocol));
    plannedPts.push(remainingAt(noon, source, protocol));
    const key = dateKeyCT(noon);
    const markDates = ["2026-11-02", "2026-11-08", "2026-11-15", "2026-11-22", "2026-11-29", "2026-12-06"];
    labels.push(markDates.includes(key) ? fmtDateCT(noon, false) : "");
    if (key === "2026-12-06") marks.push({ i: points.length - 1, text: "Reta" });
  }
  return { points, plannedPts, labels, marks };
}

function parseWeights(weights) {
  return (weights || [])
    .map((w) => ({ at: parseTs(w.measured_at), lb: num(w.weight_lb), notes: w.notes, day: parseTs(w.measured_at) && dateKeyCT(parseTs(w.measured_at)) }))
    .filter((w) => w.at && w.lb != null)
    .sort((a, b) => a.at - b.at);
}

function dailyWeight(parsed) {
  const byDay = new Map();
  for (const w of parsed) {
    if (!byDay.has(w.day)) byDay.set(w.day, w);
    else byDay.set(w.day, w); // latest that day
  }
  return [...byDay.values()].sort((a, b) => a.at - b.at);
}

function ema(values, span) {
  if (!values.length) return [];
  const alpha = 2 / (span + 1);
  const out = [];
  let prev = null;
  for (const v of values) {
    if (v == null) { out.push(prev); continue; }
    prev = prev == null ? v : alpha * v + (1 - alpha) * prev;
    out.push(prev);
  }
  return out;
}

/* Time-aware exponential smoothing for irregular weigh-ins: each reading pulls the
   trend toward it by 1 - e^(-dt / tau). Long gaps let a new reading count almost fully;
   same-day repeats barely move it. */
function smoothWeights(parsed, tauDays) {
  const tau = tauDays || 7;
  let trend = null;
  let prev = null;
  return parsed.map((w) => {
    if (trend == null) trend = w.lb;
    else {
      const dt = Math.max(0, (w.at - prev) / 86400000);
      trend += (1 - Math.exp(-dt / tau)) * (w.lb - trend);
    }
    prev = w.at;
    return { ...w, trend };
  });
}

function trendAt(smoothed, at) {
  let hit = null;
  for (const w of smoothed) {
    if (w.at <= at) hit = w;
    else break;
  }
  return hit ? hit.trend : null;
}

/* Trend change per week over the last `days` days (negative = losing). */
function trendRate(smoothed, days) {
  if (smoothed.length < 2) return null;
  const last = smoothed[smoothed.length - 1];
  const from = trendAt(smoothed, new Date(last.at.getTime() - days * 86400000));
  if (from == null) return null;
  return ((last.trend - from) / days) * 7;
}

/* Straight-line pace through the last `days` days of weigh-ins (one per day). */
function recentPace(parsed, days) {
  if (!parsed.length) return null;
  const last = parsed[parsed.length - 1];
  const daily = dailyWeight(parsed.filter((w) => w.at >= new Date(last.at.getTime() - days * 86400000)));
  if (daily.length < 4) return null;
  const t0 = daily[0].at.getTime();
  const span = (daily[daily.length - 1].at.getTime() - t0) / 86400000;
  if (span < 7) return null;
  const fit = linearFit(daily.map((w) => ({ x: (w.at.getTime() - t0) / 86400000, y: w.lb })));
  if (!fit) return null;
  return { weekly: fit.slope * 7, fittedNow: fit.intercept + fit.slope * span, n: daily.length };
}

/* Drug level on a real time axis, every `stepHours`, from the first dose to two weeks after the switch. */
function levelPoints(doses, protocol, stepHours) {
  const real = (doses || []).filter((d) => !d.skipped && parseTs(d.taken_at) && num(d.dose_mg) != null);
  if (!real.length) return null;
  const planned = plannedDoses(doses, protocol).withNext;
  const start = parseTs(real[0].taken_at);
  const end = new Date(RETA_START.getTime() + 14 * 86400000);
  const step = (stepHours || 6) * 3600000;
  const times = new Set();
  for (let t = start.getTime(); t <= end.getTime(); t += step) times.add(t);
  // Add each shot's instant (and the moment before) so peaks are sharp, not smeared over a step.
  for (const d of planned) {
    const t = parseTs(d.taken_at).getTime();
    if (t > start.getTime() && t <= end.getTime()) { times.add(t - 60000); times.add(t); }
  }
  const sorted = [...times].sort((a, b) => a - b);
  const logged = sorted.map((t) => ({ t: new Date(t), v: remainingAt(new Date(t), real, protocol) }));
  const withNext = sorted.map((t) => ({ t: new Date(t), v: remainingAt(new Date(t), planned, protocol) }));
  return { logged, withNext, start, end };
}

function linearFit(points) {
  // points: {x days, y}
  const n = points.length;
  if (n < 2) return null;
  const meanX = points.reduce((a, p) => a + p.x, 0) / n;
  const meanY = points.reduce((a, p) => a + p.y, 0) / n;
  let nume = 0, deno = 0;
  for (const p of points) {
    nume += (p.x - meanX) * (p.y - meanY);
    deno += (p.x - meanX) ** 2;
  }
  if (!deno) return null;
  const slope = nume / deno;
  const intercept = meanY - slope * meanX;
  return { slope, intercept };
}

function journeyStats(data) {
  const profile = data.profile || {};
  const parsed = parseWeights(data.weights || []);
  if (!parsed.length) return null;
  const current = parsed[parsed.length - 1];
  const startLb = num(profile.start_weight_lb) ?? parsed[0].lb;
  const goalLb = num(profile.goal_weight_lb);
  const sinceTirz = parsed.find((w) => w.at >= TIRZ_START) || parsed[0];
  const changeStart = current.lb - startLb;
  const changeTirz = current.lb - sinceTirz.lb;
  let pace = null;
  if (goalLb != null && current.lb !== goalLb) {
    const toGo = current.lb - goalLb;
    const days = Math.max(1, (current.at - sinceTirz.at) / 86400000);
    const rate = (sinceTirz.lb - current.lb) / days; // lb lost per day
    if (rate > 0.01 && toGo > 0) {
      const daysNeeded = toGo / rate;
      const eta = new Date(current.at.getTime() + daysNeeded * 86400000);
      pace = { rate: rate * 7, daysNeeded, eta, toGo };
    } else if (toGo <= 0) {
      pace = { met: true, toGo };
    } else {
      pace = { stalled: true, toGo };
    }
  }
  return { current, startLb, goalLb, sinceTirz, changeStart, changeTirz, pace };
}

function verdictCard(data) {
  const j = journeyStats(data);
  const doses = (data.doses || []).filter((d) => !d.skipped);
  const receipts = [];
  let label = "Building";
  let tone = "steady";

  if (!j) {
    return { label: "Building", tone: "steady", receipts: ["Needs a weigh-in to start a verdict."] };
  }
  receipts.push(`Current weight ${fmtNum(j.current.lb, 1)} lb as of ${fmtDateCT(j.current.at, true)}.`);
  receipts.push(`${fmtNum(j.changeTirz, 1)} lb since the first weigh-in after starting tirzepatide (${fmtDateCT(j.sinceTirz.at, false)}, ${fmtNum(j.sinceTirz.lb, 1)} lb).`);
  receipts.push(`${doses.length} dose${doses.length === 1 ? "" : "s"} logged.`);

  const daysOn = (Date.now() - TIRZ_START.getTime()) / 86400000;
  const recent = parseWeights(data.weights).filter((w) => w.at >= TIRZ_START);
  const stall = stallCheck(data);
  if (daysOn < 10 && j.changeTirz > -2) {
    label = "Building";
    tone = "steady";
    receipts.push("Still early in the first cycles.");
  } else if (stall && stall.stalled) {
    label = "Worth watching";
    tone = "watch";
    receipts.push(stall.summary);
  } else if (j.changeTirz <= -8) {
    label = "Working";
    tone = "good";
    receipts.push("Weight has moved down clearly since the first post-dose weigh-in.");
  } else if (Math.abs(j.changeTirz) < 2) {
    label = "Steady";
    tone = "steady";
  } else if (j.changeTirz > 2) {
    label = "Worth watching";
    tone = "watch";
    receipts.push("Weight is up since the first post-dose weigh-in.");
  } else {
    label = "Working";
    tone = "good";
  }
  return { label, tone, receipts };
}

function stallCheck(data) {
  const daily = dailyWeight(parseWeights(data.weights).filter((w) => w.at >= new Date(Date.now() - 40 * 86400000)));
  const need = 6;
  if (daily.length < need) {
    return { stalled: false, ready: false, need: need - daily.length, summary: `Needs ${need - daily.length} more weigh-in${need - daily.length === 1 ? "" : "s"} in this window for a stall check.` };
  }
  const windowed = daily.filter((w) => w.at >= new Date(Date.now() - 21 * 86400000));
  if (windowed.length < 4) {
    return { stalled: false, ready: false, need: 4 - windowed.length, summary: `Needs ${4 - windowed.length} more weigh-in${4 - windowed.length === 1 ? "" : "s"} in the last 3 weeks.` };
  }
  const xs = windowed.map((w, i) => ({ x: (w.at - windowed[0].at) / 86400000, y: w.lb }));
  const fit = linearFit(xs);
  const change = windowed[windowed.length - 1].lb - windowed[0].lb;
  const weekly = fit ? fit.slope * 7 : change / 3;
  const stalled = Math.abs(weekly) < 0.4 && Math.abs(change) < 2;
  const changed = whatChanged(data, windowed[0].day, windowed[windowed.length - 1].day);
  return {
    stalled,
    ready: true,
    weekly,
    change,
    from: windowed[0],
    to: windowed[windowed.length - 1],
    changed,
    summary: stalled
      ? `Smoothed weight has been roughly flat for 3 weeks (${fmtNum(windowed[0].lb, 1)} to ${fmtNum(windowed[windowed.length - 1].lb, 1)} lb).`
      : `No stall — weight moved ${fmtNum(change, 1)} lb over the last 3 weeks (${fmtNum(weekly, 1)} lb/week).`,
  };
}

function whatChanged(data, fromDay, toDay) {
  const bits = [];
  const doses = (data.doses || []).filter((d) => {
    const t = parseTs(d.taken_at);
    return t && dateKeyCT(t) >= fromDay && dateKeyCT(t) <= toDay;
  });
  if (doses.length) {
    bits.push(doses.map((d) => `${d.skipped ? "Skipped" : fmtNum(d.dose_mg, 1) + " mg"} ${d.compound} on ${fmtDateCT(parseTs(d.taken_at), false)}`).join("; "));
  }
  const checkins = (data.checkins || []).filter((c) => c.day >= fromDay && c.day <= toDay);
  const stepVals = checkins.map((c) => num(c.steps)).filter((n) => n != null);
  if (stepVals.length) {
    const avg = stepVals.reduce((a, b) => a + b, 0) / stepVals.length;
    bits.push(`Average ${fmtNum(avg, 0)} steps on ${stepVals.length} check-in days.`);
  }
  const meals = (data.daily_totals || []).filter((r) => r.date >= fromDay && r.date <= toDay && num(r.calories) != null);
  if (meals.length) {
    const avg = meals.reduce((a, r) => a + num(r.calories), 0) / meals.length;
    bits.push(`${meals.length} food day${meals.length === 1 ? "" : "s"} logged, averaging ${fmtNum(avg, 0)} calories.`);
  }
  const feels = checkins.filter((c) => c.dose_feel);
  if (feels.length) bits.push(`Dose feel logged on ${feels.length} day${feels.length === 1 ? "" : "s"}.`);
  return bits;
}

function cyclesFromDoses(doses) {
  const shots = (doses || [])
    .filter((d) => !d.skipped && parseTs(d.taken_at))
    .map((d) => ({ ...d, at: parseTs(d.taken_at), day: dateKeyCT(parseTs(d.taken_at)) }))
    .sort((a, b) => a.at - b.at);
  const cycles = [];
  for (let i = 0; i < shots.length; i++) {
    const start = shots[i];
    const endAt = shots[i + 1] ? shots[i + 1].at : new Date();
    const endDay = shots[i + 1] ? shots[i + 1].day : todayKey();
    cycles.push({
      index: i + 1,
      start,
      endDay,
      endAt,
      startDay: start.day,
      open: !shots[i + 1],
    });
  }
  return cycles;
}

function cycleRecaps(data) {
  const cycles = cyclesFromDoses(data.doses || []);
  const daily = dailyWeight(parseWeights(data.weights));
  const weightOn = (day) => {
    const hits = daily.filter((w) => w.day <= day);
    return hits.length ? hits[hits.length - 1] : null;
  };
  return cycles.map((c, i, arr) => {
    const w0 = weightOn(c.startDay);
    const w1 = weightOn(c.endDay);
    const checkins = (data.checkins || []).filter((x) => x.day >= c.startDay && (x.day < c.endDay || (c.open && x.day === c.endDay)));
    const avg = (key) => {
      const vals = checkins.map((x) => num(x[key])).filter((n) => n != null);
      return vals.length ? vals.reduce((a, b) => a + b, 0) / vals.length : null;
    };
    const mode = (key) => {
      const counts = {};
      for (const x of checkins) if (x[key]) counts[x[key]] = (counts[x[key]] || 0) + 1;
      const keys = Object.keys(counts);
      if (!keys.length) return null;
      return keys.sort((a, b) => counts[b] - counts[a])[0];
    };
    const rec = {
      ...c,
      startW: w0,
      endW: w1,
      delta: w0 && w1 ? w1.lb - w0.lb : null,
      ate: mode("ate_vs_usual"),
      moved: mode("moved_vs_usual"),
      feel: mode("dose_feel"),
      foodNoise: avg("food_noise"),
      mood: avg("mood"),
      energy: avg("energy"),
      steps: avg("steps"),
      checkinCount: checkins.length,
    };
    return rec;
  }).map((rec, i, arr) => {
    if (i === 0) return rec;
    const prev = arr[i - 1];
    rec.vsPrev = {
      weight: rec.delta != null && prev.delta != null ? rec.delta - prev.delta : null,
      foodNoise: rec.foodNoise != null && prev.foodNoise != null ? rec.foodNoise - prev.foodNoise : null,
      steps: rec.steps != null && prev.steps != null ? rec.steps - prev.steps : null,
    };
    return rec;
  });
}

function wearOff(data) {
  const cycles = cyclesFromDoses(data.doses || []);
  if (cycles.length < 2) {
    return { ready: false, need: 2 - cycles.length, summary: "Needs 2 completed cycles with late-cycle check-ins for wear-off detection." };
  }
  let flagged = 0;
  let considered = 0;
  const details = [];
  for (const c of cycles) {
    if (c.open) continue;
    const checkins = (data.checkins || []).filter((x) => x.day >= c.startDay && x.day < c.endDay);
    const dayNum = (day) => {
      const a = Date.parse(c.startDay + "T12:00:00Z");
      const b = Date.parse(day + "T12:00:00Z");
      return Math.round((b - a) / 86400000);
    };
    const early = checkins.filter((x) => dayNum(x.day) <= 3);
    const late = checkins.filter((x) => dayNum(x.day) >= 5);
    const avg = (rows, key) => {
      const vals = rows.map((r) => num(r[key])).filter((n) => n != null);
      return vals.length ? vals.reduce((a, b) => a + b, 0) / vals.length : null;
    };
    const lateFeel = late.filter((r) => r.dose_feel === "fading" || r.dose_feel === "not_feeling_it").length;
    const earlyN = avg(early, "food_noise");
    const lateN = avg(late, "food_noise");
    if (lateFeel === 0 && lateN == null) continue;
    considered += 1;
    const noiseRise = earlyN != null && lateN != null && lateN - earlyN >= 2;
    const fading = lateFeel > 0;
    if (noiseRise || fading) {
      flagged += 1;
      details.push({ cycle: c.index, noiseRise, fading, earlyN, lateN });
    }
  }
  if (!considered) {
    return { ready: false, need: 1, summary: "Needs late-cycle food-noise or feel tags (days 5–7) to detect wear-off." };
  }
  return {
    ready: true,
    flagged,
    considered,
    details,
    summary: `Wear-off pattern in ${flagged} of ${considered} completed cycle${considered === 1 ? "" : "s"}.`,
  };
}

function feelReport(data) {
  const rows = (data.checkins || []).filter((c) => c.mood != null || c.energy != null || c.food_noise != null || c.sleep_quality != null);
  const need = 7;
  if (rows.length < need) {
    return { ready: false, need: need - rows.length, count: rows.length, summary: `Needs ${need - rows.length} more day${need - rows.length === 1 ? "" : "s"} with mood, energy, food noise or sleep scores.` };
  }
  const avg = (key) => {
    const vals = rows.map((r) => num(r[key])).filter((n) => n != null);
    return vals.length ? { mean: vals.reduce((a, b) => a + b, 0) / vals.length, n: vals.length } : null;
  };
  return {
    ready: true,
    count: rows.length,
    mood: avg("mood"),
    energy: avg("energy"),
    food_noise: avg("food_noise"),
    sleep_quality: avg("sleep_quality"),
  };
}

function siteRotation(data) {
  const doses = (data.doses || []).filter((d) => !d.skipped && d.site).sort((a, b) => parseTs(a.taken_at) - parseTs(b.taken_at));
  const last = doses[doses.length - 1] || null;
  const lastSite = last && last.site;
  const protocol = (data.protocol || []).find((p) => p.status === "active") || {};
  let next = protocol.next_site;
  if (!next && lastSite && SITES.includes(lastSite)) {
    next = SITES[(SITES.indexOf(lastSite) + 1) % SITES.length];
  }
  const lastUsed = {};
  for (const d of doses) lastUsed[d.site] = parseTs(d.taken_at);
  return { last, lastSite, next, lastUsed };
}

function vialRunway(data) {
  const vials = data.vials || [];
  if (!vials.length) return { ready: false, summary: "Add a vial to see inventory and supply runway." };
  // Each vial runs down at its own compound's weekly dose, not whatever is active now.
  const protocolFor = (compound) => (data.protocol || []).find((p) => p.compound === compound) || {};
  const items = vials.map((v) => {
    const proto = protocolFor(v.compound);
    const weeklyMg = num(proto.typical_dose_mg);
    const weeklyUnits = num(proto.units);
    let weeks = null;
    const remMg = num(v.remaining_mg);
    const remU = num(v.remaining_units);
    if (weeklyMg && remMg != null) weeks = remMg / weeklyMg;
    else if (weeklyUnits && remU != null) weeks = remU / weeklyUnits;
    let until = null;
    if (weeks != null) until = new Date(Date.now() + weeks * 7 * 86400000);
    return { ...v, weeks, until };
  });
  const soonest = items.filter((i) => i.until).sort((a, b) => a.until - b.until)[0] || null;
  return { ready: true, items, soonest };
}

function titrationHistory(doses) {
  const list = (doses || []).filter((d) => parseTs(d.taken_at)).sort((a, b) => parseTs(a.taken_at) - parseTs(b.taken_at));
  const steps = [];
  let prev = null;
  for (const d of list) {
    const mg = d.skipped ? null : num(d.dose_mg);
    const changed = prev && (prev.compound !== d.compound || prev.mg !== mg || prev.skipped !== !!d.skipped);
    steps.push({ ...d, mg, changed: !prev || changed });
    prev = { compound: d.compound, mg, skipped: !!d.skipped };
  }
  return steps;
}

function weightProjection(data, daysForward) {
  const daily = dailyWeight(parseWeights(data.weights).filter((w) => w.at >= TIRZ_START));
  if (daily.length < 4) return { ready: false, need: 4 - daily.length };
  const t0 = daily[0].at.getTime();
  const fit = linearFit(daily.map((w) => ({ x: (w.at - t0) / 86400000, y: w.lb })));
  if (!fit) return { ready: false, need: 1 };
  const last = daily[daily.length - 1];
  const lastX = (last.at - t0) / 86400000;
  const horizon = daysForward || 42;
  const future = [];
  const labels = [];
  const historical = daily.map((w) => w.lb);
  // Build a combined series from first point through horizon
  const points = [];
  const actual = [];
  const projected = [];
  const labs = [];
  const start = daily[0].at;
  const end = new Date(last.at.getTime() + horizon * 86400000);
  for (let t = new Date(start); t <= end; t = new Date(t.getTime() + 86400000)) {
    const x = (t - t0) / 86400000;
    const key = dateKeyCT(t);
    const hit = daily.find((w) => w.day === key);
    actual.push(hit ? hit.lb : null);
    const y = fit.intercept + fit.slope * x;
    projected.push(t >= last.at ? y : (hit ? hit.lb : y));
    const mark = key.endsWith("-01") || key === dateKeyCT(last.at) || key === dateKeyCT(end) || key === "2027-01-01";
    labs.push(mark ? fmtDateCT(t, false) : "");
  }
  return { ready: true, fit, actual, projected, labels: labs, weekly: fit.slope * 7, last };
}

function metricCatalog(data) {
  return [
    { id: "weight", label: "Weight (lb)", series: dailySeries(data, "weight") },
    { id: "steps", label: "Steps", series: dailySeries(data, "steps") },
    { id: "food_noise", label: "Food noise", series: dailySeries(data, "food_noise") },
    { id: "mood", label: "Mood", series: dailySeries(data, "mood") },
    { id: "energy", label: "Energy", series: dailySeries(data, "energy") },
    { id: "sleep_quality", label: "Sleep quality", series: dailySeries(data, "sleep_quality") },
    { id: "resting_hr", label: "Resting HR", series: dailySeries(data, "resting_hr") },
    { id: "calories", label: "Calories", series: dailySeries(data, "calories") },
    { id: "protein_g", label: "Protein (g)", series: dailySeries(data, "protein_g") },
    { id: "active_calories", label: "Active calories", series: dailySeries(data, "active_calories") },
    { id: "exercise_minutes", label: "Exercise minutes", series: dailySeries(data, "exercise_minutes") },
  ];
}

function dailySeries(data, key) {
  const map = new Map();
  if (key === "weight") {
    for (const w of dailyWeight(parseWeights(data.weights))) map.set(w.day, w.lb);
  } else if (key === "calories" || key === "protein_g") {
    for (const r of data.daily_totals || []) if (num(r[key]) != null) map.set(r.date, num(r[key]));
  } else {
    for (const c of data.checkins || []) if (num(c[key]) != null) map.set(c.day, num(c[key]));
    if (key === "steps" || key === "resting_hr" || key === "sleep_hours") {
      for (const h of data.daily_health || []) {
        const k = key === "sleep_hours" ? "sleep_hours" : key === "resting_hr" ? "resting_hr" : "steps";
        if (!map.has(h.day) && num(h[k]) != null) map.set(h.day, num(h[k]));
      }
    }
  }
  return map;
}

function alignedPair(mapA, mapB) {
  const days = [...mapA.keys()].filter((d) => mapB.has(d)).sort();
  return days.map((d) => ({ day: d, x: mapA.get(d), y: mapB.get(d) }));
}

function earnDays(data, weeks) {
  const n = (weeks || 8) * 7;
  const today = todayKey();
  const end = Date.parse(today + "T12:00:00Z");
  const start = end - (n - 1) * 86400000;
  const byDay = new Map((data.checkins || []).map((c) => [c.day, c]));
  const cells = [];
  for (let i = 0; i < n; i++) {
    const d = new Date(start + i * 86400000);
    // dateKey via UTC noon surrogate
    const iso = new Date(start + i * 86400000).toISOString().slice(0, 10);
    // The start was computed from todayKey as UTC date, which matches YYYY-MM-DD of CT dates we store
    const day = shiftDay(today, -(n - 1 - i));
    const row = byDay.get(day);
    cells.push({ day, earned: row && row.earned != null ? !!row.earned : null, has: !!row, today: day === today });
  }
  return cells;
}

function shiftDay(yyyyMmDd, delta) {
  const [y, m, d] = yyyyMmDd.split("-").map(Number);
  const dt = new Date(Date.UTC(y, m - 1, d));
  dt.setUTCDate(dt.getUTCDate() + delta);
  return dt.toISOString().slice(0, 10);
}

function nextSiteAfter(site) {
  if (!SITES.includes(site)) return SITES[0];
  return SITES[(SITES.indexOf(site) + 1) % SITES.length];
}
