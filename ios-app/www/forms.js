const WRITE_URL = "https://qnbshmenmurdaogslmrj.supabase.co/functions/v1/log-write";

async function writeLog(action, payload) {
  const res = await fetch(WRITE_URL, {
    method: "POST",
    headers: { ...authHeaders(), "Content-Type": "application/json" },
    cache: "no-store",
    referrerPolicy: "no-referrer",
    body: JSON.stringify({ action, payload }),
  });
  let body = null;
  try { body = await res.json(); } catch (_) { body = null; }
  if (res.status === 401) throw new Error("unauthorized");
  if (!body || body.ok === false) {
    const field = body && body.field ? ` (${body.field})` : "";
    const err = (body && body.error) || "write_failed";
    throw new Error(`${err}${field}`);
  }
  if (!res.ok) throw new Error((body && body.error) || "write_failed");
  return body;
}

function field(label, input) {
  return el("label", { class: "field" }, label, input);
}

function input(attrs) {
  return el("input", attrs);
}

function select(attrs, options, value) {
  const s = el("select", attrs, ...options.map((o) => {
    const opt = el("option", { value: o.value }, o.label);
    if (String(value ?? "") === String(o.value)) opt.selected = true;
    return opt;
  }));
  return s;
}

function chips(name, options, current) {
  const wrap = el("div", { class: "chips", role: "group" });
  wrap.dataset.name = name;
  wrap.dataset.value = current || "";
  for (const o of options) {
    const btn = el("button", {
      type: "button",
      class: "chip" + (current === o.value ? " on" : ""),
      "aria-pressed": current === o.value ? "true" : "false",
      onClick: () => {
        wrap.dataset.value = o.value;
        for (const b of wrap.querySelectorAll(".chip")) {
          const on = b.dataset.value === o.value;
          b.classList.toggle("on", on);
          b.setAttribute("aria-pressed", on ? "true" : "false");
        }
      },
    }, o.label);
    btn.dataset.value = o.value;
    wrap.append(btn);
  }
  return wrap;
}

function chipValue(wrap) {
  return (wrap && wrap.dataset.value) || "";
}

function rangeField(label, name, min, max, value) {
  const out = el("span", { class: "n" }, value == null || value === "" ? "—" : String(value));
  const r = input({ type: "range", name, min, max, step: "1", value: value ?? min });
  if (value == null || value === "") r.value = "";
  // Keep a usable default in the middle if empty; track unset via dataset
  r.dataset.unset = value == null || value === "" ? "1" : "0";
  if (r.dataset.unset === "1") r.value = String(Math.round((min + max) / 2));
  out.textContent = r.dataset.unset === "1" ? "—" : r.value;
  const paint = () => {
    const pct = r.dataset.unset === "1" ? 0 : ((Number(r.value) - min) / (max - min)) * 100;
    r.style.setProperty("--pct", pct.toFixed(1) + "%");
  };
  paint();
  r.addEventListener("input", () => {
    r.dataset.unset = "0";
    out.textContent = r.value;
    paint();
  });
  return el("label", { class: "field" }, label, el("div", { class: "range" }, r, out));
}

function setFormMessage(ok, text) {
  state.formMessage = { ok, text };
}

async function handleWrite(action, payload, success) {
  let ok = false;
  try {
    state.formBusy = true;
    render();
    await writeLog(action, payload);
    ok = true;
    setFormMessage(true, success);
    await load(true);
  } catch (err) {
    setFormMessage(false, err.message === "unauthorized" ? "Passcode was rejected. Lock and unlock again." : `Could not save: ${err.message}`);
  } finally {
    // Re-render after clearing the busy flag, or every Save button stays disabled.
    state.formBusy = false;
    render();
  }
  return ok;
}

function todayCheckin(data) {
  return checkinOn(data, todayKey());
}

function renderToast() {
  if (!state.formMessage) return null;
  return el("p", { class: "toast " + (state.formMessage.ok ? "ok" : "err"), role: "status" }, state.formMessage.text);
}

/* A form that folds away. Its open state survives re-renders, so typing isn't lost to a refresh. */
function fold(id, title, hint, ...kids) {
  const d = el("details", { class: "card fold", open: state.openForms[id] ? true : null },
    el("summary", null,
      el("span", { class: "fold-text" },
        el("span", { class: "fold-title" }, title),
        hint ? el("span", { class: "fold-hint" }, hint) : null,
      ),
    ),
    el("div", { class: "fold-body" }, ...kids),
  );
  d.addEventListener("toggle", () => { state.openForms[id] = d.open; });
  return d;
}

/*
  One check-in, always the full one: the three taps plus mood, food noise, energy,
  sleep and activity. Used inline on Today (for whichever day is showing) and on Log.
*/
const CHECKIN_INT_FIELDS = ["mood", "food_noise", "energy", "sleep_quality", "exercise_minutes", "steps", "resting_hr", "active_calories"];

function renderCheckinForm(data, key, opts) {
  const o = opts || {};
  const cur = checkinOn(data, key) || {};
  const ate = chips("ate_vs_usual", [
    { value: "less", label: "Ate less" },
    { value: "usual", label: "Usual" },
    { value: "more", label: "Ate more" },
  ], cur.ate_vs_usual);
  const moved = chips("moved_vs_usual", [
    { value: "less", label: "Moved less" },
    { value: "usual", label: "Usual" },
    { value: "more", label: "Moved more" },
  ], cur.moved_vs_usual);
  const feel = chips("dose_feel", [
    { value: "strong", label: "Strong" },
    { value: "fading", label: "Fading" },
    { value: "not_feeling_it", label: "Not feeling it" },
  ], cur.dose_feel);
  const numField = (label, name, attrs) => field(label, input({ type: "number", name, value: cur[name] ?? "", ...attrs }));
  const health = el("details", { class: "sub-fold" },
    el("summary", null, "Health numbers (optional)"),
    el("div", { class: "grid two tight" },
      numField("Steps", "steps", { min: "0", step: "1", inputmode: "numeric" }),
      numField("Resting HR", "resting_hr", { min: "20", max: "220", step: "1", inputmode: "numeric" }),
      numField("Active calories", "active_calories", { min: "0", step: "1", inputmode: "numeric" }),
    ),
  );
  const form = el("div", { class: "log-form checkin-form" },
    el("div", { class: "field" }, "Ate vs usual", ate),
    el("div", { class: "field" }, "Moved vs usual", moved),
    el("div", { class: "field" }, "Dose feel", feel),
    rangeField("Mood", "mood", 1, 10, cur.mood),
    rangeField("Food noise", "food_noise", 1, 10, cur.food_noise),
    rangeField("Energy", "energy", 1, 10, cur.energy),
    rangeField("Sleep quality", "sleep_quality", 1, 10, cur.sleep_quality),
    el("div", { class: "grid two tight" },
      numField("Sleep hours", "sleep_hours", { min: "0", max: "24", step: "0.1", inputmode: "decimal" }),
      numField("Exercise minutes", "exercise_minutes", { min: "0", max: "1440", step: "1", inputmode: "numeric" }),
    ),
    health,
    field("Notes", el("textarea", { name: "notes" }, cur.notes || "")),
  );
  const valOf = (name) => form.querySelector(`[name="${name}"]`);
  const maybe = (name, integer) => {
    const node = valOf(name);
    if (!node) return undefined;
    if (node.type === "range" && node.dataset.unset === "1") return undefined;
    const v = (node.value || "").trim();
    if (v === "") return undefined;
    return integer ? parseInt(v, 10) : Number(v);
  };
  const isToday = key === todayKey();
  const save = el("button", {
    type: "button",
    class: "primary",
    disabled: state.formBusy,
    onClick: async () => {
      const payload = { day: key };
      if (chipValue(ate)) payload.ate_vs_usual = chipValue(ate);
      if (chipValue(moved)) payload.moved_vs_usual = chipValue(moved);
      if (chipValue(feel)) payload.dose_feel = chipValue(feel);
      for (const k of CHECKIN_INT_FIELDS) {
        const v = maybe(k, true);
        if (v != null && !Number.isNaN(v)) payload[k] = v;
      }
      const sh = maybe("sleep_hours", false);
      if (sh != null && !Number.isNaN(sh)) payload.sleep_hours = sh;
      const n = valOf("notes").value.trim();
      if (n) payload.notes = n;
      if (Object.keys(payload).length === 1) {
        setFormMessage(false, "Answer at least one question first.");
        render();
        return;
      }
      const ok = await handleWrite("checkin_upsert", payload, isToday ? "Saved today’s check-in." : `Saved the check-in for ${fmtShortDate(key)}.`);
      if (ok && o.onSaved) o.onSaved();
    },
  }, "Save check-in");
  return el("div", { class: "checkin" },
    form,
    el("div", { class: "form-actions" },
      save,
      o.onCancel ? el("button", { type: "button", onClick: o.onCancel }, "Cancel") : null,
    ),
  );
}

function renderCheckinCard(data) {
  return card("Today’s check-in",
    el("p", { class: "caption first" }, "How the day went. Everything is optional, and saving again updates today’s answers."),
    renderCheckinForm(data, todayKey()),
  );
}

function renderWeighIn() {
  const wt = field("Weight (lb)", input({ type: "number", name: "weight_lb", min: "50", max: "600", step: "0.1", inputmode: "decimal", required: true, class: "big-input", placeholder: "0.0" }));
  const notes = field("Notes", input({ type: "text", name: "notes", maxlength: "200" }));
  const box = el("div", { class: "log-form" }, wt, notes);
  return card("Weigh-in",
    box,
    el("div", { class: "form-actions" },
      el("button", {
        type: "button",
        class: "primary",
        disabled: state.formBusy,
        onClick: () => {
          const weight_lb = box.querySelector("[name=weight_lb]").value.trim();
          if (!weight_lb) {
            setFormMessage(false, "Enter a weight.");
            render();
            return;
          }
          const payload = { weight_lb };
          const n = box.querySelector("[name=notes]").value.trim();
          if (n) payload.notes = n;
          handleWrite("weigh_in", payload, `Logged ${weight_lb} lb.`);
        },
      }, "Save weigh-in"),
    ),
  );
}

function renderDoseForm(data) {
  const rot = siteRotation(data);
  const active = (data.protocol || []).find((p) => p.status === "active") || {};
  const compound = select({ name: "compound" }, [
    { value: "tirzepatide", label: "Tirzepatide" },
    { value: "retatrutide", label: "Retatrutide" },
  ], active.compound || "tirzepatide");
  const mg = field("Dose (mg)", input({ type: "number", name: "dose_mg", min: "0.05", max: "50", step: "0.05", value: active.typical_dose_mg ?? 3, inputmode: "decimal" }));
  const units = field("Units (optional)", input({ type: "number", name: "units", min: "0", max: "1000", step: "1", value: active.units ?? "", inputmode: "numeric" }));
  const site = chips("site", SITES.map((s) => ({ value: s, label: SITE_LABELS[s] || s })), rot.next || rot.lastSite || "");
  const skip = el("label", { class: "toggle" },
    el("span", null, "Mark as skipped"),
    input({ type: "checkbox", name: "skipped", role: "switch" }),
  );
  const notes = field("Notes", input({ type: "text", name: "notes" }));
  const box = el("div", { class: "log-form" },
    field("Compound", compound), mg, units,
    el("div", { class: "field" }, "Injection site", site),
    skip, notes,
  );
  return fold("dose", "Log a dose", rot.next ? `Suggested site: ${SITE_LABELS[rot.next] || rot.next}` : "Pick the site you used",
    box,
    el("div", { class: "form-actions" },
      el("button", {
        type: "button",
        class: "primary",
        disabled: state.formBusy,
        onClick: () => {
          const skipped = box.querySelector("[name=skipped]").checked;
          const payload = { compound: compound.value, skipped };
          const dose = box.querySelector("[name=dose_mg]").value.trim();
          const u = box.querySelector("[name=units]").value.trim();
          const n = box.querySelector("[name=notes]").value.trim();
          if (!skipped) {
            if (!dose) {
              setFormMessage(false, "Enter a dose in mg, or mark the shot as skipped.");
              render();
              return;
            }
            payload.dose_mg = dose;
          } else if (dose) payload.dose_mg = dose;
          if (u) payload.units = u;
          if (chipValue(site)) payload.site = chipValue(site);
          if (n) payload.notes = n;
          handleWrite("dose_log", payload, skipped ? "Logged a skipped dose." : `Logged ${payload.compound} ${payload.dose_mg || ""} mg.`);
        },
      }, "Save dose"),
    ),
  );
}

function renderSideEffectForm() {
  const effect = field("Effect", input({ type: "text", name: "effect", maxlength: "80", placeholder: "Headache, nausea…" }));
  const sev = rangeField("Severity", "severity", 1, 10, 5);
  // default severity to 5, already set
  sev.querySelector("input").dataset.unset = "0";
  sev.querySelector(".n").textContent = "5";
  const notes = field("Notes", input({ type: "text", name: "notes" }));
  const box = el("div", { class: "log-form" }, effect, sev, notes);
  return fold("side", "Side effect", "Name it and rate it 1 to 10",
    box,
    el("div", { class: "form-actions" },
      el("button", {
        type: "button",
        class: "primary",
        disabled: state.formBusy,
        onClick: () => {
          const name = box.querySelector("[name=effect]").value.trim();
          const severity = box.querySelector("[name=severity]").value;
          if (!name) {
            setFormMessage(false, "Name the side effect.");
            render();
            return;
          }
          const payload = { effect: name, severity };
          const n = box.querySelector("[name=notes]").value.trim();
          if (n) payload.notes = n;
          handleWrite("side_effect_upsert", payload, `Logged ${name}.`);
        },
      }, "Save side effect"),
    ),
  );
}

function renderEarnIt(data) {
  const cur = todayCheckin(data);
  const status = cur && cur.earned === true ? "You earned it today." : cur && cur.earned === false ? "Marked as not earned today." : "Not marked yet today.";
  return card("Earn It",
    el("p", { class: "caption first" }, status),
    el("div", { class: "form-actions" },
      el("button", { type: "button", class: "primary", disabled: state.formBusy, onClick: () => handleWrite("earn_it", { earned: true }, "Earned it.") }, "Yes, earned it"),
      el("button", { type: "button", disabled: state.formBusy, onClick: () => handleWrite("earn_it", { earned: false }, "Marked as not earned.") }, "Not today"),
    ),
  );
}

function renderMeasurementForm() {
  const metric = field("Metric", select({ name: "metric" }, [
    { value: "waist", label: "Waist" },
    { value: "chest", label: "Chest" },
    { value: "hip", label: "Hip" },
    { value: "neck", label: "Neck" },
    { value: "thigh", label: "Thigh" },
    { value: "arm", label: "Arm" },
    { value: "body_fat_pct", label: "Body fat %" },
    { value: "lean_mass_lb", label: "Lean mass (lb)" },
  ], "waist"));
  const value = field("Value", input({ type: "number", name: "value", min: "0", max: "1000", step: "0.1", inputmode: "decimal" }));
  const unit = field("Unit", select({ name: "unit" }, [
    { value: "in", label: "in" },
    { value: "cm", label: "cm" },
    { value: "lb", label: "lb" },
    { value: "kg", label: "kg" },
    { value: "%", label: "%" },
  ], "in"));
  const box = el("div", { class: "log-form" }, metric, value, unit);
  return fold("measure", "Measurement", "Waist, chest, hip and more",
    box,
    el("div", { class: "form-actions" },
      el("button", {
        type: "button",
        class: "primary",
        disabled: state.formBusy,
        onClick: () => {
          const v = box.querySelector("[name=value]").value.trim();
          if (!v) {
            setFormMessage(false, "Enter a measurement.");
            render();
            return;
          }
          handleWrite("measurement", {
            metric: box.querySelector("[name=metric]").value,
            value: v,
            unit: box.querySelector("[name=unit]").value,
          }, "Saved measurement.");
        },
      }, "Save measurement"),
    ),
  );
}

function renderVialForm() {
  const compound = field("Compound", select({ name: "compound" }, [
    { value: "tirzepatide", label: "Tirzepatide" },
    { value: "retatrutide", label: "Retatrutide" },
  ], "tirzepatide"));
  const label = field("Label (optional)", input({ type: "text", name: "label", maxlength: "80" }));
  const totalMg = field("Total mg", input({ type: "number", name: "total_mg", min: "0", step: "0.1", inputmode: "decimal" }));
  const totalU = field("Total units", input({ type: "number", name: "total_units", min: "0", step: "1", inputmode: "numeric" }));
  const conc = field("Concentration (mg/mL, optional)", input({ type: "number", name: "concentration_mg_per_ml", min: "0", step: "0.1", inputmode: "decimal" }));
  const exp = field("Expires on", input({ type: "date", name: "expired_on" }));
  const notes = field("Notes", input({ type: "text", name: "notes" }));
  const box = el("div", { class: "log-form" }, compound, label, totalMg, totalU, conc, exp, notes);
  return fold("vial", "Start a vial", "Track supply runway",
    box,
    el("div", { class: "form-actions" },
      el("button", {
        type: "button",
        class: "primary",
        disabled: state.formBusy,
        onClick: () => {
          const payload = { compound: box.querySelector("[name=compound]").value };
          for (const k of ["label", "total_mg", "total_units", "concentration_mg_per_ml", "expired_on", "notes"]) {
            const v = box.querySelector(`[name=${k}]`).value.trim();
            if (v) payload[k] = v;
          }
          if (!payload.total_mg && !payload.total_units) {
            setFormMessage(false, "Enter total mg or total units.");
            render();
            return;
          }
          handleWrite("vial_start", payload, "Vial added.");
        },
      }, "Save vial"),
    ),
  );
}

function renderReconCalc() {
  const vial = field("Vial amount (mg)", input({ type: "number", name: "vial_mg", min: "0", step: "0.1", value: "", inputmode: "decimal" }));
  const dil = field("Diluent (mL)", input({ type: "number", name: "diluent_ml", min: "0", step: "0.1", value: "1", inputmode: "decimal" }));
  const dose = field("Desired dose (mg)", input({ type: "number", name: "want_mg", min: "0", step: "0.05", inputmode: "decimal" }));
  const out = el("p", { class: "calc-out" }, "This stays on your device and is not saved. Assumes 100 units = 1 mL.");
  const box = el("div", { class: "log-form" }, vial, dil, dose, out);
  const recalc = () => {
    const v = Number(box.querySelector("[name=vial_mg]").value);
    const m = Number(box.querySelector("[name=diluent_ml]").value);
    const w = Number(box.querySelector("[name=want_mg]").value);
    if (!(v > 0) || !(m > 0) || !(w > 0)) {
      out.textContent = "This stays on your device and is not saved. Assumes 100 units = 1 mL.";
      return;
    }
    const units = (w / v) * m * 100;
    const conc = v / m;
    out.textContent = `Draw ${fmtNum(units, 1)} units. That’s ${fmtNum(conc, 2)} mg/mL after mixing. Not saved.`;
  };
  box.querySelectorAll("input").forEach((i) => i.addEventListener("input", recalc));
  return fold("recon", "Reconstitution calculator", "Units to draw for a dose. Not saved",
    el("p", { class: "caption first" }, "For the planned retatrutide start: mix the vial with 1 mL, then 20 units is the planned first dose. The mg equivalent is still unknown."),
    box,
  );
}

function renderLogTab(data) {
  return el("div", { class: "stack" },
    renderToast(),
    canSyncHealth() ? card("Apple Health", el("p", { class: "caption first" }, "Activity, sleep stages, heart rate, breathing, blood oxygen, blood pressure, glucose, temperature, energy, water, weigh-ins, body fat and workouts. When the app opens it catches up on recent days and keeps backfilling your history."), renderHealthSync(true)) : null,
    renderCheckinCard(data),
    el("div", { class: "grid two" }, renderWeighIn(), renderEarnIt(data)),
    el("h2", { class: "section-title" }, "More to log"),
    renderDoseForm(data),
    renderSideEffectForm(),
    renderMeasurementForm(),
    renderVialForm(),
    renderReconCalc(),
    renderAppVersion(),
  );
}

/* Which build this is, so you can tell installs apart. Stamped by the iPhone app workflow. */
function appVersionText() {
  const v = window.LOG_VERSION || {};
  if (!v.version || v.version === "dev") return "Log, development copy";
  const built = v.built ? `, built ${fmtDateCT(new Date(v.built), true)}` : "";
  return `Log ${v.version}${v.build ? ` (build ${v.build})` : ""}${built}`;
}

function renderAppVersion() {
  return el("p", { class: "app-version" }, appVersionText());
}
