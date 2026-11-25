/* Charts for Log. Plain SVG drawn at the real pixel width of the card, so text
   stays readable on a phone. Uses el(), num(), fmtNum(), dateKeyCT() from app.js
   at call time. Every chart has a readout above it that follows your finger. */

const SVGNS = "http://www.w3.org/2000/svg";
const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

function svgEl(tag, attrs, text) {
  const n = document.createElementNS(SVGNS, tag);
  for (const [k, v] of Object.entries(attrs || {})) if (v != null) n.setAttribute(k, String(v));
  if (text != null) n.textContent = text;
  return n;
}

/* Width of the plot area inside a card: viewport, minus page gutters and card padding. */
function chartWidth() {
  const vw = Math.min(window.innerWidth || 390, 720);
  return Math.max(240, Math.round(vw - 32 - 36));
}

function niceStep(span, count) {
  const raw = span / Math.max(1, count);
  const mag = Math.pow(10, Math.floor(Math.log10(raw)));
  const n = raw / mag;
  const s = n <= 1 ? 1 : n <= 2 ? 2 : n <= 2.5 ? 2.5 : n <= 5 ? 5 : 10;
  return s * mag;
}

function niceTicks(lo, hi, count) {
  if (!(hi > lo)) { hi = lo + 1; lo -= 1; }
  const step = niceStep(hi - lo, count || 4);
  const start = Math.floor(lo / step) * step;
  const end = Math.ceil(hi / step) * step;
  const ticks = [];
  for (let v = start; v <= end + step / 2; v += step) ticks.push(Number(v.toFixed(6)));
  return { ticks, lo: start, hi: end };
}

function ymd(date) {
  const [y, m, d] = dateKeyCT(date).split("-").map(Number);
  return { y, m, d };
}

/* Noon Central on a calendar day, as a Date. Close enough to midnight for axis ticks. */
function ctNoon(y, m, d) {
  return new Date(Date.UTC(y, m - 1, d, 18, 0, 0));
}

/* Calendar-aligned ticks: weeks start Monday, months on the 1st, years on Jan 1. */
function timeTicks(t0, t1, width) {
  const spanDays = (t1 - t0) / 86400000;
  const maxTicks = Math.max(2, Math.floor(width / 56));
  const units = [
    { kind: "day", n: 1, days: 1 }, { kind: "day", n: 2, days: 2 }, { kind: "week", n: 1, days: 7 }, { kind: "week", n: 2, days: 14 },
    { kind: "month", n: 1, days: 30.4 }, { kind: "month", n: 3, days: 91 }, { kind: "month", n: 6, days: 182 },
    { kind: "year", n: 1, days: 365 }, { kind: "year", n: 2, days: 730 },
  ];
  const unit = units.find((u) => spanDays / u.days <= maxTicks) || units[units.length - 1];
  const out = [];
  const s = ymd(t0);
  if (unit.kind === "day" || unit.kind === "week") {
    let cur = ctNoon(s.y, s.m, s.d);
    if (unit.kind === "week") {
      while (cur.getUTCDay() !== 1) cur = new Date(cur.getTime() + 86400000);
    }
    for (; cur <= t1; cur = new Date(cur.getTime() + unit.days * 86400000)) {
      if (cur >= t0) out.push({ t: cur, label: `${MONTHS[cur.getUTCMonth()]} ${cur.getUTCDate()}` });
    }
  } else if (unit.kind === "month") {
    let y = s.y;
    let m = s.m + 1;
    if (m > 12) { m = 1; y += 1; }
    while ((m - 1) % unit.n !== 0) { m += 1; if (m > 12) { m = 1; y += 1; } }
    for (let cur = ctNoon(y, m, 1); cur <= t1;) {
      const mm = cur.getUTCMonth();
      out.push({ t: cur, label: mm === 0 ? String(cur.getUTCFullYear()) : MONTHS[mm] });
      m += unit.n;
      while (m > 12) { m -= 12; y += 1; }
      cur = ctNoon(y, m, 1);
    }
  } else {
    let y = s.y + 1;
    while (y % unit.n !== 0) y += 1;
    for (let cur = ctNoon(y, 1, 1); cur <= t1; y += unit.n, cur = ctNoon(y, 1, 1)) {
      out.push({ t: cur, label: String(y) });
    }
  }
  return out;
}

/* Monotone cubic path (Fritsch–Carlson): smooth, never overshoots the data. */
function smoothPath(pts) {
  if (pts.length < 3) return pts.map((p, i) => `${i ? "L" : "M"}${p[0].toFixed(1)},${p[1].toFixed(1)}`).join("");
  const n = pts.length;
  const dx = [], dy = [], m = [];
  for (let i = 0; i < n - 1; i++) {
    dx.push(pts[i + 1][0] - pts[i][0]);
    dy.push(pts[i + 1][1] - pts[i][1]);
    m.push(dx[i] ? dy[i] / dx[i] : 0);
  }
  const t = [m[0]];
  for (let i = 1; i < n - 1; i++) t.push(m[i - 1] * m[i] <= 0 ? 0 : (m[i - 1] + m[i]) / 2);
  t.push(m[n - 2]);
  for (let i = 0; i < n - 1; i++) {
    if (m[i] === 0) { t[i] = 0; t[i + 1] = 0; continue; }
    const a = t[i] / m[i];
    const b = t[i + 1] / m[i];
    const h = a * a + b * b;
    if (h > 9) {
      const k = 3 / Math.sqrt(h);
      t[i] = k * a * m[i];
      t[i + 1] = k * b * m[i];
    }
  }
  let d = `M${pts[0][0].toFixed(1)},${pts[0][1].toFixed(1)}`;
  for (let i = 0; i < n - 1; i++) {
    const h = dx[i] / 3;
    d += `C${(pts[i][0] + h).toFixed(1)},${(pts[i][1] + t[i] * h).toFixed(1)} ${(pts[i + 1][0] - h).toFixed(1)},${(pts[i + 1][1] - t[i + 1] * h).toFixed(1)} ${pts[i + 1][0].toFixed(1)},${pts[i + 1][1].toFixed(1)}`;
  }
  return d;
}

function linePath(pts) {
  return pts.map((p, i) => `${i ? "L" : "M"}${p[0].toFixed(1)},${p[1].toFixed(1)}`).join("");
}

function nearestIndex(sorted, value, key) {
  let lo = 0;
  let hi = sorted.length - 1;
  while (lo < hi) {
    const mid = (lo + hi) >> 1;
    if (key(sorted[mid]) < value) lo = mid + 1;
    else hi = mid;
  }
  if (lo > 0 && Math.abs(key(sorted[lo - 1]) - value) <= Math.abs(key(sorted[lo]) - value)) return lo - 1;
  return lo;
}

/* Wire pointer + keyboard scrubbing to a chart. `positions` are x pixels of snap points. */
function attachScrub(wrap, svg, { positions, height, padTop, padBottom, onMove, onEnd }) {
  if (!positions.length) return;
  const hair = svgEl("line", { class: "crosshair", x1: 0, x2: 0, y1: padTop, y2: height - padBottom, visibility: "hidden" });
  svg.append(hair);
  let idx = null;
  const show = (i) => {
    idx = Math.max(0, Math.min(positions.length - 1, i));
    const x = positions[idx];
    hair.setAttribute("x1", x);
    hair.setAttribute("x2", x);
    hair.setAttribute("visibility", "visible");
    wrap.classList.add("scrubbing");
    onMove(idx);
  };
  const hide = () => {
    idx = null;
    hair.setAttribute("visibility", "hidden");
    wrap.classList.remove("scrubbing");
    onEnd();
  };
  const fromEvent = (e) => {
    const r = svg.getBoundingClientRect();
    const scale = (Number(svg.getAttribute("width")) || r.width) / r.width;
    const x = (e.clientX - r.left) * scale;
    let best = 0;
    let bestD = Infinity;
    for (let i = 0; i < positions.length; i++) {
      const d = Math.abs(positions[i] - x);
      if (d < bestD) { bestD = d; best = i; }
    }
    return best;
  };
  // Touch: drag to scrub; after lifting, the reading stays for a moment so it can be read.
  let linger = null;
  const clearLinger = () => { if (linger) { clearTimeout(linger); linger = null; } };
  svg.addEventListener("pointerdown", (e) => { clearLinger(); show(fromEvent(e)); });
  svg.addEventListener("pointermove", (e) => { if (e.pointerType === "mouse" || (idx != null && !linger)) show(fromEvent(e)); });
  svg.addEventListener("pointerup", (e) => {
    if (e.pointerType !== "mouse") { clearLinger(); linger = setTimeout(() => { linger = null; hide(); }, 2500); }
  });
  svg.addEventListener("pointercancel", () => { clearLinger(); hide(); });
  svg.addEventListener("pointerleave", (e) => { if (e.pointerType === "mouse") hide(); });
  wrap.addEventListener("keydown", (e) => {
    if (e.key === "ArrowLeft" || e.key === "ArrowRight") {
      e.preventDefault();
      show(idx == null ? positions.length - 1 : idx + (e.key === "ArrowRight" ? 1 : -1));
    } else if (e.key === "Escape" || e.key === "Home" || e.key === "End") {
      if (e.key === "Escape") hide();
      else show(e.key === "Home" ? 0 : positions.length - 1);
    }
  });
  wrap.addEventListener("blur", hide);
  return { hair, show, hide };
}

/*
  timeChart({
    t0, t1,                       domain (Dates)
    series: [{ id, label, cls, type: "smooth" | "line" | "dots" | "area", points: [{ t, v }], dashed }],
    refs: [{ v, label }],         horizontal reference lines (goal, target)
    marks: [{ t, label }],        vertical markers (Now, switch day)
    snap: "seriesId",             series whose points the scrubber snaps to
    height, fmtY, yPad, yMin, yMax, aria,
    onScrub(point | null)         update the readout
  })
*/
function timeChart(opts) {
  const width = chartWidth();
  const height = opts.height || 200;
  const pad = { l: 40, r: 10, t: 12, b: 24 };
  const t0 = opts.t0.getTime();
  const t1 = Math.max(opts.t1.getTime(), t0 + 86400000);
  const vals = [];
  for (const s of opts.series) for (const p of s.points) {
    const tt = p.t.getTime();
    if (tt >= t0 && tt <= t1 && Number.isFinite(p.v)) vals.push(p.v);
  }
  for (const r of opts.refs || []) if (Number.isFinite(r.v) && r.inDomain !== false) vals.push(r.v);
  if (!vals.length) return el("p", { class: "empty" }, "Not enough data in this range.");
  let lo = opts.yMin != null ? opts.yMin : Math.min(...vals);
  let hi = opts.yMax != null ? opts.yMax : Math.max(...vals);
  const ypad = opts.yPad != null ? opts.yPad : (hi - lo) * 0.08 || 1;
  if (opts.yMin == null) lo -= ypad;
  if (opts.yMax == null) hi += ypad;
  const yt = niceTicks(lo, hi, opts.yTicks || 4);
  if (opts.yMin != null) yt.lo = opts.yMin;
  const X = (t) => pad.l + ((t - t0) / (t1 - t0)) * (width - pad.l - pad.r);
  const Y = (v) => pad.t + (1 - (v - yt.lo) / (yt.hi - yt.lo)) * (height - pad.t - pad.b);
  const fmtY = opts.fmtY || ((v) => fmtNum(v, 0));

  const svg = svgEl("svg", { class: "chart", width, height, viewBox: `0 0 ${width} ${height}`, role: "img", "aria-label": opts.aria || "Chart" });
  for (const v of yt.ticks) {
    if (v < yt.lo - 1e-9 || v > yt.hi + 1e-9) continue;
    svg.append(svgEl("line", { class: "grid", x1: pad.l, x2: width - pad.r, y1: Y(v), y2: Y(v) }));
    svg.append(svgEl("text", { class: "tick", x: pad.l - 8, y: Y(v) + 4, "text-anchor": "end" }, fmtY(v)));
  }
  for (const tk of timeTicks(new Date(t0), new Date(t1), width - pad.l - pad.r)) {
    const x = X(tk.t.getTime());
    if (x < pad.l + 12 || x > width - pad.r - 12) continue;
    svg.append(svgEl("text", { class: "tick", x, y: height - 6, "text-anchor": "middle" }, tk.label));
  }
  for (const r of opts.refs || []) {
    if (!Number.isFinite(r.v) || r.v < yt.lo || r.v > yt.hi) continue;
    svg.append(svgEl("line", { class: "ref", x1: pad.l, x2: width - pad.r, y1: Y(r.v), y2: Y(r.v) }));
    if (r.label) svg.append(svgEl("text", { class: "ref-label", x: width - pad.r, y: Y(r.v) - 5, "text-anchor": "end" }, r.label));
  }
  for (const mk of opts.marks || []) {
    const tt = mk.t.getTime();
    if (tt < t0 || tt > t1) continue;
    svg.append(svgEl("line", { class: "mark", x1: X(tt), x2: X(tt), y1: pad.t, y2: height - pad.b }));
    if (mk.label) {
      const anchor = X(tt) > width - 60 ? "end" : "start";
      svg.append(svgEl("text", { class: "mark-label", x: X(tt) + (anchor === "end" ? -4 : 4), y: pad.t + 10, "text-anchor": anchor }, mk.label));
    }
  }
  const bottom = height - pad.b;
  const plotted = {};
  for (const s of opts.series) {
    const pts = s.points
      .filter((p) => Number.isFinite(p.v) && p.t.getTime() >= t0 && p.t.getTime() <= t1)
      .map((p) => [X(p.t.getTime()), Y(Math.max(yt.lo, Math.min(yt.hi, p.v))), p]);
    plotted[s.id] = pts;
    if (!pts.length) continue;
    const cls = `series ${s.cls || "s1"}${s.dashed ? " dashed" : ""}`;
    if (s.type === "dots") {
      const g = svgEl("g", { class: `${cls} dots` });
      for (const p of pts) g.append(svgEl("circle", { cx: p[0].toFixed(1), cy: p[1].toFixed(1), r: s.r || 3 }));
      svg.append(g);
      continue;
    }
    const d = s.type === "smooth" || s.type === "area" ? smoothPath(pts) : linePath(pts);
    if (s.type === "area" || s.fill) {
      svg.append(svgEl("path", { class: `${cls} wash`, d: `${d}L${pts[pts.length - 1][0].toFixed(1)},${bottom}L${pts[0][0].toFixed(1)},${bottom}Z` }));
    }
    svg.append(svgEl("path", { class: `${cls} stroke`, d }));
    if (s.endDot) {
      const last = pts[pts.length - 1];
      svg.append(svgEl("circle", { class: `${cls} end`, cx: last[0].toFixed(1), cy: last[1].toFixed(1), r: 4.5 }));
    }
  }
  const wrap = el("div", { class: "chart-wrap", tabindex: "0", "aria-label": `${opts.aria || "Chart"}. Use left and right arrow keys to read values.` });
  wrap.append(svg);

  const snapPts = plotted[opts.snap] || [];
  if (snapPts.length && opts.onScrub) {
    const markers = opts.series.filter((s) => s.type !== "dots" || s.id === opts.snap).map((s) => {
      const c = svgEl("circle", { class: `series ${s.cls || "s1"} focus`, r: 5, visibility: "hidden" });
      svg.append(c);
      return { s, c };
    });
    attachScrub(wrap, svg, {
      positions: snapPts.map((p) => p[0]),
      height,
      padTop: pad.t,
      padBottom: pad.b,
      onMove: (i) => {
        const p = snapPts[i][2];
        const at = p.t.getTime();
        const readings = {};
        for (const { s, c } of markers) {
          const list = plotted[s.id];
          if (!list || !list.length) { c.setAttribute("visibility", "hidden"); continue; }
          const j = nearestIndex(list, at, (q) => q[2].t.getTime());
          const q = list[j];
          const close = Math.abs(q[2].t.getTime() - at) <= (opts.snapToleranceMs || 36 * 3600000);
          if (close) {
            c.setAttribute("cx", q[0].toFixed(1));
            c.setAttribute("cy", q[1].toFixed(1));
            c.setAttribute("visibility", "visible");
            readings[s.id] = q[2];
          } else c.setAttribute("visibility", "hidden");
        }
        opts.onScrub({ point: p, readings });
      },
      onEnd: () => {
        for (const { c } of markers) c.setAttribute("visibility", "hidden");
        opts.onScrub(null);
      },
    });
  }
  return wrap;
}

/*
  columnChart({ days: [{ key: "YYYY-MM-DD", v }], target, cls, height, fmtY, aria, onScrub })
  One column per calendar day, 4px rounded tops, square at the baseline, target as a dashed rule.
*/
function columnChart(opts) {
  const width = chartWidth();
  const height = opts.height || 150;
  const pad = { l: 40, r: 10, t: 14, b: 24 };
  const days = opts.days;
  const vals = days.map((d) => d.v).filter((v) => Number.isFinite(v));
  if (opts.target != null) vals.push(opts.target);
  const yt = niceTicks(0, Math.max(1, ...vals) * 1.05, 3);
  yt.lo = 0;
  const slot = (width - pad.l - pad.r) / days.length;
  const bw = Math.max(2, Math.min(24, slot - 2));
  const Y = (v) => pad.t + (1 - v / yt.hi) * (height - pad.t - pad.b);
  const fmtY = opts.fmtY || ((v) => fmtNum(v, 0));
  const svg = svgEl("svg", { class: "chart", width, height, viewBox: `0 0 ${width} ${height}`, role: "img", "aria-label": opts.aria || "Columns" });
  for (const v of yt.ticks) {
    svg.append(svgEl("line", { class: v === 0 ? "axis" : "grid", x1: pad.l, x2: width - pad.r, y1: Y(v), y2: Y(v) }));
    svg.append(svgEl("text", { class: "tick", x: pad.l - 8, y: Y(v) + 4, "text-anchor": "end" }, fmtY(v)));
  }
  const centers = [];
  days.forEach((d, i) => {
    const cx = pad.l + slot * i + slot / 2;
    centers.push(cx);
    if (!Number.isFinite(d.v) || d.v <= 0) return;
    const top = Y(d.v);
    const base = Y(0);
    const x = cx - bw / 2;
    const r = Math.min(4, bw / 2, base - top);
    svg.append(svgEl("path", {
      class: `col ${opts.cls || "s1"}${d.today ? " today" : ""}`,
      d: `M${x.toFixed(1)},${base}V${(top + r).toFixed(1)}Q${x.toFixed(1)},${top.toFixed(1)} ${(x + r).toFixed(1)},${top.toFixed(1)}H${(x + bw - r).toFixed(1)}Q${(x + bw).toFixed(1)},${top.toFixed(1)} ${(x + bw).toFixed(1)},${(top + r).toFixed(1)}V${base}Z`,
    }));
  });
  const labelIdx = [0, Math.floor((days.length - 1) / 2), days.length - 1];
  for (const i of labelIdx) {
    const d = days[i];
    if (!d) continue;
    const [, m, dd] = d.key.split("-").map(Number);
    svg.append(svgEl("text", { class: "tick", x: centers[i], y: height - 6, "text-anchor": i === 0 ? "start" : i === days.length - 1 ? "end" : "middle" }, `${MONTHS[m - 1]} ${dd}`));
  }
  if (opts.target != null) {
    svg.append(svgEl("line", { class: "ref", x1: pad.l, x2: width - pad.r, y1: Y(opts.target), y2: Y(opts.target) }));
    svg.append(svgEl("text", { class: "ref-label", x: width - pad.r, y: Y(opts.target) - 5, "text-anchor": "end" }, opts.targetLabel || `Target ${fmtY(opts.target)}`));
  }
  const wrap = el("div", { class: "chart-wrap", tabindex: "0", "aria-label": `${opts.aria || "Columns"}. Use left and right arrow keys to read values.` });
  wrap.append(svg);
  if (opts.onScrub) {
    attachScrub(wrap, svg, {
      positions: centers,
      height,
      padTop: pad.t,
      padBottom: pad.b,
      onMove: (i) => opts.onScrub(days[i]),
      onEnd: () => opts.onScrub(null),
    });
  }
  return wrap;
}

/* Scatter for the pattern explorer: 8px dots with a surface ring, nearest-point readout. */
function scatterPlot(pairs, opts) {
  const width = chartWidth();
  const height = 220;
  const pad = { l: 40, r: 12, t: 12, b: 26 };
  if (!pairs.length) return el("p", { class: "empty" }, "Not enough overlapping days for those two metrics.");
  const xt = niceTicks(Math.min(...pairs.map((p) => p.x)), Math.max(...pairs.map((p) => p.x)), 4);
  const yt = niceTicks(Math.min(...pairs.map((p) => p.y)), Math.max(...pairs.map((p) => p.y)), 4);
  const X = (v) => pad.l + ((v - xt.lo) / (xt.hi - xt.lo)) * (width - pad.l - pad.r);
  const Y = (v) => pad.t + (1 - (v - yt.lo) / (yt.hi - yt.lo)) * (height - pad.t - pad.b);
  const svg = svgEl("svg", { class: "chart", width, height, viewBox: `0 0 ${width} ${height}`, role: "img", "aria-label": opts.aria || "Scatter" });
  for (const v of yt.ticks) {
    svg.append(svgEl("line", { class: "grid", x1: pad.l, x2: width - pad.r, y1: Y(v), y2: Y(v) }));
    svg.append(svgEl("text", { class: "tick", x: pad.l - 8, y: Y(v) + 4, "text-anchor": "end" }, fmtNum(v, v % 1 ? 1 : 0)));
  }
  for (const v of xt.ticks) {
    svg.append(svgEl("text", { class: "tick", x: X(v), y: height - 6, "text-anchor": "middle" }, fmtNum(v, v % 1 ? 1 : 0)));
  }
  const g = svgEl("g", { class: "series s1 dots ringed" });
  const dots = pairs.map((p) => {
    const c = svgEl("circle", { cx: X(p.x).toFixed(1), cy: Y(p.y).toFixed(1), r: 4.5 });
    g.append(c);
    return c;
  });
  svg.append(g);
  const wrap = el("div", { class: "chart-wrap", tabindex: "0", "aria-label": `${opts.aria || "Scatter"}. Use left and right arrow keys to read points.` });
  wrap.append(svg);
  if (opts.onScrub) {
    const order = pairs.map((p, i) => i).sort((a, b) => pairs[a].x - pairs[b].x);
    const focus = svgEl("circle", { class: "series s1 focus", r: 6, visibility: "hidden" });
    svg.append(focus);
    attachScrub(wrap, svg, {
      positions: order.map((i) => X(pairs[i].x)),
      height,
      padTop: pad.t,
      padBottom: pad.b,
      onMove: (k) => {
        const i = order[k];
        focus.setAttribute("cx", dots[i].getAttribute("cx"));
        focus.setAttribute("cy", dots[i].getAttribute("cy"));
        focus.setAttribute("visibility", "visible");
        opts.onScrub(pairs[i]);
      },
      onEnd: () => { focus.setAttribute("visibility", "hidden"); opts.onScrub(null); },
    });
  }
  return wrap;
}

/* Front-facing torso with the six rotation sites. The person's right is on the viewer's left. */
const SITE_POS = {
  "Abd UR": [94, 84], "Abd UL": [146, 84],
  "Abd LR": [94, 140], "Abd LL": [146, 140],
  "Love R": [62, 118], "Love L": [178, 118],
};

function siteMap(rot) {
  const svg = svgEl("svg", { class: "sitemap", viewBox: "0 0 240 200", role: "img", "aria-label": "Injection site map, front view of the abdomen" });
  // Ribcage to hips: wide at the chest, in at the waist, out again at the hips.
  svg.append(svgEl("path", {
    class: "torso",
    d: "M58,6 C88,-2 152,-2 182,6 C190,36 188,70 180,104 C174,132 186,162 196,198 L44,198 C54,162 66,132 60,104 C52,70 50,36 58,6 Z",
  }));
  svg.append(svgEl("path", { class: "ribs", d: "M76,30 Q120,52 164,30" }));
  svg.append(svgEl("circle", { class: "navel", cx: 120, cy: 112, r: 3 }));
  svg.append(svgEl("text", { class: "side-label", x: 18, y: 62, "text-anchor": "start" }, "R"));
  svg.append(svgEl("text", { class: "side-label", x: 222, y: 62, "text-anchor": "end" }, "L"));
  for (const s of Object.keys(SITE_POS)) {
    const [x, y] = SITE_POS[s];
    const state = s === rot.next ? "next" : s === rot.lastSite ? "last" : rot.lastUsed[s] ? "used" : "unused";
    const g = svgEl("g", { class: `site-dot ${state}` });
    g.append(svgEl("circle", { cx: x, cy: y, r: 15 }));
    g.append(svgEl("text", { x, y: y + 4, "text-anchor": "middle" }, s.replace("Abd ", "").replace("Love ", "")));
    svg.append(g);
  }
  return svg;
}

/* A small table twin for any chart: tap to reveal the numbers. */
function dataView(summary, headers, rows) {
  return el("details", { class: "dataview" },
    el("summary", null, summary),
    el("table", { class: "data" },
      el("thead", null, el("tr", null, ...headers.map((h, i) => el("th", { class: i ? "num" : null }, h)))),
      el("tbody", null, ...rows.map((r) => el("tr", null, ...r.map((c, i) => el("td", { class: i ? "num" : null }, c))))),
    ),
  );
}
