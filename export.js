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
