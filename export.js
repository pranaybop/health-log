function csvEscape(v) {
  if (v == null) return "";
  const s = String(v);
  if (/[",\n]/.test(s)) return `"${s.replace(/"/g, '""')}"`;
  return s;
}

function toCSV(rows, cols) {
  const header = cols.map((c) => csvEscape(c.label)).join(",");
  const body = rows.map((r) => cols.map((c) => csvEscape(typeof c.value === "function" ? c.value(r) : r[c.key])).join(","));
  return [header, ...body].join("\n") + "\n";
}

function downloadText(filename, text, mime) {
  const blob = new Blob([text], { type: mime || "text/csv;charset=utf-8" });
  const url = URL.createObjectURL(blob);
  const a = el("a", { href: url, download: filename });
  document.body.append(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

function prescriberCSV(data) {
  const parts = [];
  parts.push("MEALS");
  parts.push(toCSV(data.meals || [], [
    { label: "eaten_at", key: "eaten_at" },
    { label: "meal_type", key: "meal_type" },
    { label: "item", key: "item" },
    { label: "quantity", key: "quantity" },
    { label: "calories", key: "calories" },
    { label: "protein_g", key: "protein_g" },
    { label: "carbs_g", key: "carbs_g" },
    { label: "fat_g", key: "fat_g" },
    { label: "fiber_g", key: "fiber_g" },
    { label: "notes", key: "notes" },
  ]));
  parts.push("", "WEIGHTS");
  parts.push(toCSV(data.weights || [], [
    { label: "measured_at", key: "measured_at" },
    { label: "weight_lb", key: "weight_lb" },
    { label: "notes", key: "notes" },
  ]));
  parts.push("", "DOSES");
  parts.push(toCSV(data.doses || [], [
    { label: "taken_at", key: "taken_at" },
    { label: "compound", key: "compound" },
    { label: "dose_mg", key: "dose_mg" },
    { label: "units", key: "units" },
    { label: "site", key: "site" },
    { label: "skipped", key: "skipped" },
    { label: "notes", key: "notes" },
  ]));
  parts.push("", "CHECKINS");
  parts.push(toCSV(data.checkins || [], [
    { label: "day", key: "day" },
    { label: "ate_vs_usual", key: "ate_vs_usual" },
    { label: "moved_vs_usual", key: "moved_vs_usual" },
    { label: "dose_feel", key: "dose_feel" },
    { label: "mood", key: "mood" },
    { label: "food_noise", key: "food_noise" },
    { label: "energy", key: "energy" },
    { label: "sleep_quality", key: "sleep_quality" },
    { label: "sleep_hours", key: "sleep_hours" },
    { label: "exercise_minutes", key: "exercise_minutes" },
    { label: "steps", key: "steps" },
    { label: "resting_hr", key: "resting_hr" },
    { label: "active_calories", key: "active_calories" },
    { label: "earned", key: "earned" },
    { label: "notes", key: "notes" },
  ]));
  parts.push("", "SIDE EFFECTS");
  parts.push(toCSV(data.side_effects || [], [
    { label: "recorded_on", key: "recorded_on" },
    { label: "recorded_at", key: "recorded_at" },
    { label: "effect", key: "effect" },
    { label: "severity", key: "severity" },
    { label: "notes", key: "notes" },
  ]));
  parts.push("", "MEASUREMENTS");
  parts.push(toCSV(data.measurements || [], [
    { label: "measured_at", key: "measured_at" },
    { label: "metric", key: "metric" },
    { label: "value", key: "value" },
    { label: "unit", key: "unit" },
    { label: "notes", key: "notes" },
  ]));
  const stamp = todayKey();
  downloadText(`log-prescriber-${stamp}.csv`, parts.join("\n"));
}

function prescriberPrint(data) {
  const j = journeyStats(data);
  const doses = data.doses || [];
  const v = verdictCard(data);
  const w = window.open("", "_blank");
  if (!w) {
    state.formMessage = { ok: false, text: "Allow pop-ups to print the prescriber report, or use CSV instead." };
    render();
    return;
  }
  const row = (k, val) => `<tr><th>${k}</th><td>${val}</td></tr>`;
  const meals = (data.meals || []).map((m) => {
    const t = parseTs(m.eaten_at);
    return `<tr><td>${t ? fmtDateTimeCT(t) : ""}</td><td>${m.meal_type || ""}</td><td>${m.item || ""}</td><td>${m.calories ?? ""}</td><td>${m.protein_g ?? ""}</td></tr>`;
  }).join("");
  const doseRows = doses.map((d) => {
    const t = parseTs(d.taken_at);
    return `<tr><td>${t ? fmtDateCT(t, true) : ""}</td><td>${d.compound || ""}</td><td>${d.skipped ? "skipped" : (d.dose_mg ?? "")}</td><td>${d.site || ""}</td></tr>`;
  }).join("");
  w.document.write(`<!DOCTYPE html><html><head><title>Log prescriber report</title>
    <style>
      body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; color: #111; padding: 24px; }
      h1 { margin: 0 0 4px; }
      .muted { color: #555; }
      table { border-collapse: collapse; width: 100%; margin: 16px 0; }
      th, td { text-align: left; padding: 6px 8px; border-bottom: 1px solid #ddd; vertical-align: top; }
      th { width: 30%; color: #555; font-weight: 600; }
    </style></head><body>
    <h1>Health log</h1>
    <p class="muted">Prescriber report · generated ${fmtDateTimeCT(new Date())} · times in America/Chicago</p>
    <h2>Summary</h2>
    <table>
      ${row("Verdict", v.label)}
      ${row("Current weight", j ? `${fmtNum(j.current.lb, 1)} lb` : "—")}
      ${row("Start weight", j ? `${fmtNum(j.startLb, 1)} lb` : "—")}
      ${row("Goal", j && j.goalLb != null ? `${fmtNum(j.goalLb, 1)} lb` : "—")}
      ${row("Change since start", j ? `${fmtNum(j.changeStart, 1)} lb` : "—")}
      ${row("Change since tirzepatide", j ? `${fmtNum(j.changeTirz, 1)} lb` : "—")}
    </table>
    <h2>Doses</h2>
    <table><tr><th>Date</th><th>Compound</th><th>Dose</th><th>Site</th></tr>${doseRows || "<tr><td colspan=4>None</td></tr>"}</table>
    <h2>Meals</h2>
    <table><tr><th>When</th><th>Type</th><th>Item</th><th>Cal</th><th>Protein</th></tr>${meals || "<tr><td colspan=5>None</td></tr>"}</table>
    <p class="muted">Drug level is an estimate from half-life, not a lab measurement. Meal macros may be estimates.</p>
    </body></html>`);
  w.document.close();
  w.focus();
  w.print();
}


function coachPackWindow(fromKey, toKey, data) {
  const inWin = (k) => k && k >= fromKey && k <= toKey;
  const j = journeyStats(data);
  const weights = parseWeights(data.weights || []).filter((w) => inWin(dateKeyCT(w.at)));
  const firstW = weights[0] ? weights[0].lb : null;
  const lastW = weights.length ? weights[weights.length - 1].lb : null;
  const t = getTargets(data);
  const foodDays = (data.daily_totals || []).filter((r) => inWin(r.date) && num(r.protein_g) != null);
  const hits = t.protein != null ? foodDays.filter((r) => num(r.protein_g) >= t.protein).length : null;
  const avgPro = foodDays.length ? foodDays.reduce((a, r) => a + num(r.protein_g), 0) / foodDays.length : null;
  const monday = (() => {
    const tk = toKey;
    const d = keyToNoon(tk);
    return shiftDay(tk, -((d.getUTCDay() + 6) % 7));
  })();
  const weeks = (data.run_weeks || []).filter((w) => w.week && w.week >= shiftDay(fromKey, -6) && w.week <= monday);
  const miles = weeks.reduce((a, w) => a + (num(w.miles) || 0), 0);
  const longest = weeks.reduce((a, w) => Math.max(a, num(w.longest_mi) || 0), 0);
  const thoughts = (data.food_thoughts || []).filter((x) => {
    const at = parseTs(x.thought_at);
    return at && inWin(dateKeyCT(at));
  });
  const strong = thoughts.filter((x) => num(x.strength) >= 2).length;
  const effects = (data.side_effects || []).filter((s) => inWin(s.recorded_on));
  const doses = (data.doses || []).filter((d) => parseTs(d.taken_at) && inWin(dateKeyCT(parseTs(d.taken_at))));
  const fmt = (v, d) => (v == null ? "—" : fmtNum(v, d));
  const row = (k, val) => `<tr><th>${k}</th><td>${val}</td></tr>`;
  const doseRows = doses.map((d) => {
    const at = parseTs(d.taken_at);
    return `<tr><td>${at ? fmtDateCT(at, true) : ""}</td><td>${d.compound || ""}</td><td>${d.skipped ? "skipped" : (d.dose_mg ?? d.units ?? "")}</td><td>${d.site || ""}</td></tr>`;
  }).join("");
  const effectRows = effects.map((s) => `<tr><td>${fmtShortDate(s.recorded_on)}</td><td>${s.effect || ""}</td><td>${s.severity ?? ""}</td><td>${s.notes || ""}</td></tr>`).join("");
  const weekRows = weeks.map((w) => `<tr><td>${fmtShortDate(w.week)}</td><td>${fmt(num(w.miles), 1)}</td><td>${fmt(num(w.longest_mi), 1)}</td><td>${w.runs ?? ""}</td></tr>`).join("");
  return `<!DOCTYPE html><html><head><title>Log 4-week coach pack</title>
    <style>
      body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; color: #111; padding: 24px; max-width: 740px; }
      h1 { margin: 0 0 4px; font-size: 24px; }
      h2 { margin: 22px 0 6px; font-size: 16px; }
      .muted { color: #555; margin: 0 0 16px; }
      table { border-collapse: collapse; width: 100%; margin: 8px 0 0; }
      th, td { text-align: left; padding: 6px 8px; border-bottom: 1px solid #ddd; vertical-align: top; font-size: 13px; }
      table.kv th { width: 40%; color: #555; font-weight: 600; }
      @media print { body { padding: 0; } }
    </style></head><body>
    <h1>4-week coach pack</h1>
    <p class="muted">${fmtShortDate(fromKey)} to ${fmtShortDate(toKey)} · generated ${fmtDateTimeCT(new Date())} · America/Chicago</p>
    <h2>Summary</h2>
    <table class="kv">
      ${row("Current weight", j ? `${fmtNum(j.current.lb, 1)} lb` : "—")}
      ${row("Weight in this window", firstW != null && lastW != null ? `${fmtNum(firstW, 1)} → ${fmtNum(lastW, 1)} lb (${signed(lastW - firstW)} lb, ${weights.length} weigh-ins)` : "No weigh-ins in this window")}
      ${row("Protein hit rate", hits != null ? `${hits} of ${foodDays.length} logged days at ${fmtNum(t.protein, 0)} g or more` : (foodDays.length ? `Average ${fmt(avgPro, 0)} g; no protein target set` : "No food logged"))}
      ${row("Running miles", weeks.length ? `${fmt(miles, 1)} mi across ${weeks.length} week${weeks.length === 1 ? "" : "s"}; longest run ${fmt(longest, 1)} mi` : "No run weeks in this window")}
      ${row("Food thoughts", thoughts.length ? `${thoughts.length} logged, ${strong} strong pull or craving` : "None logged")}
      ${row("Side effects", effects.length ? `${effects.length} logged` : "None logged")}
      ${row("Doses", doses.length ? `${doses.length} in this window` : "None logged")}
    </table>
    <h2>Doses</h2>
    <table><tr><th>Date</th><th>Compound</th><th>Dose</th><th>Site</th></tr>${doseRows || "<tr><td colspan=4>None in this window</td></tr>"}</table>
    <h2>Weekly running</h2>
    <table><tr><th>Week of</th><th>Miles</th><th>Longest</th><th>Runs</th></tr>${weekRows || "<tr><td colspan=4>None in this window</td></tr>"}</table>
    <h2>Side effects</h2>
    <table><tr><th>Date</th><th>Effect</th><th>Severity</th><th>Notes</th></tr>${effectRows || "<tr><td colspan=4>None in this window</td></tr>"}</table>
    <p class="muted">Meal macros may be estimates. Drug level is not included. This pack covers the last 28 days only.</p>
    </body></html>`;
}

function coachPackPrint(data) {
  const toKey = todayKey();
  const fromKey = shiftDay(toKey, -27);
  const w = window.open("", "_blank");
  if (!w) {
    state.formMessage = { ok: false, text: "Allow pop-ups to print the 4-week pack, or use CSV instead." };
    render();
    return;
  }
  w.document.write(coachPackWindow(fromKey, toKey, data));
  w.document.close();
  w.focus();
  w.print();
}
