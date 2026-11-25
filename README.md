# Log

Live health dashboard for the private `log` schema in Supabase project `qnbshmenmurdaogslmrj`.

**Since Nov 25, 2026 new work ships only in the iPhone app.** The app's files live in `ios-app/www` and are built into the .ipa (see `ios-app/README.md`). The website at https://pranaybop.github.io/health-log/ is the root of this repo, frozen at commit `ea5299a`: don't change the root files. `_config.yml` keeps `ios-app/`, `tests/` and `supabase/` off the website.

Tests: `cd tests && npm ci && npx playwright install chromium && npm test`. They serve `ios-app/www` on localhost:4173 and run on made-up data from `tests/fixture.js` (this repo is public, so never real data). GitHub Actions runs them on every app change and before every .ipa build.

The rest of this file describes the app and the backend. The UI was this static app on GitHub Pages:

Open that URL and enter your passcode. This device stores it in `localStorage` (`log.passcode`) until you tap Lock. The older `#k=` access-token link still works. The page fetches on load, refreshes every 60 seconds, and has a manual Refresh control.

Do not put passcodes, access tokens, or other secrets in this repo.

Times display in America/Chicago. Meal macros may be estimates. Drug level is a half-life model (tirzepatide 5 days / 120 hours, retatrutide 6 days / 144 hours), not a lab measurement.

## Frontend

No build step and no dependencies (in `ios-app/www` for the app). Scripts load in this order: `version.js` (the app's version and build number, written by the .ipa workflow), `analytics.js` (pure calculations: weight smoothing, pace, drug level, cycles), `export.js` (prescriber CSV/PDF and the 4-week coach pack), `forms.js` (Log tab and the check-in), `health.js` (Apple Health sync, only active inside the iPhone app), `charts.js` (SVG charts with touch scrubbing, site map), `insights.js` (food thoughts, the week after a shot, heart, body composition, more from Apple Health, running, protein hit rate), `focus.js` (race taper, protein streak, retatrutide switch, long-run timing, reta vs tirz, sleep stages, compound vial runway), `signals.js` (maintenance calories, off-your-normal recovery flags, appetite by drug level), `app.js` (state, tabs, rendering). `sw.js` is a network-first offline shell for the site's own files; the last dashboard payload is kept in `localStorage` (`log.cache`) so the app opens with data and works offline. Lock clears it. `styles.css` follows the system light/dark setting. Bump the `?v=` query in `index.html` when shipping changes so iPhone Safari picks them up.

Calorie and protein targets on Today come from active `log.goals` rows (`kind` `calories` / `protein`, set with `goal_set`); a device-only fallback (`localStorage` `log.targets`) is used only if no goals row exists. Current targets: 2,200 kcal and 150 g protein.

The weight chart's range chips include 1M/3M/1Y/All, plus Since GLP-1 (first logged tirzepatide or retatrutide dose) and Training block (start of the current run streak). Compare draws calories, steps, sleep, resting HR, HRV, food thoughts or food noise on the same days, with its own scale. Long ranges use weekly averages. The compare choice is kept on the device (`log.overlay`).

Today shows one day at a time: swipe left or right on the cards (or use the week strip, the month picker, or the arrow keys) to move between days. Past days show that day's weight or trend, food, check-in, medication level, Apple Health numbers and meals. The check-in is one full form (three taps plus mood, food noise, energy, sleep and activity) that opens in place on Today for whichever day is showing, and also sits on the Log tab. The "No check-in yet" prompt appears from 6 PM Central.

In the home-screen app and the iPhone app, pull down from the top of any tab to refresh (inside the iPhone app it also syncs the last two days from Apple Health first). In a normal browser tab the browser's own pull to refresh does the reloading.

`ios-app/` is an optional iPhone app shell (Capacitor) that loads this site; see `ios-app/README.md`. It isn't part of the web build.

To test locally, serve the folder on port 4173 (for example `npx serve -l 4173`) so CORS allows it.

## Endpoints

Both Edge Functions require `x-log-passcode` or `x-log-token`. Auth is a SHA-256 match (or the `LOG_APP_PASSCODE` / `LOG_DASHBOARD_TOKEN` function secrets if set). Failed auth waits 600ms and returns 401. CORS allows `https://pranaybop.github.io` and local `4173`.

| Function | Method | URL | Role |
| --- | --- | --- | --- |
| `log-dashboard` | GET | `https://qnbshmenmurdaogslmrj.supabase.co/functions/v1/log-dashboard` | Read-only. Calls `public.log_dashboard_payload()` and returns the JSON blob (`as_of`, meals, weights, doses, daily_totals, weekly_summary, daily_health, workouts, checkins, side_effects, protocol, vials, measurements, profile, goals). |
| `log-write` | POST | `https://qnbshmenmurdaogslmrj.supabase.co/functions/v1/log-write` | Insert / allowed upsert only. Body: `{ "action": "<name>", "payload": { ... } }`. Calls `public.log_write(p_action, p_payload)`. No deletes. |

`log-write` actions:

- `checkin_upsert` — upsert today’s (or `day`) check-in; merges provided fields so a 3-tap does not wipe a deep check-in
- `earn_it` — `{ earned: true|false, day? }`
- `weigh_in` — insert `{ weight_lb, measured_at?, notes? }`
- `dose_log` — insert `{ compound, dose_mg, units?, site?, skipped?, taken_at?, notes? }`; updates `protocol.next_site` after a real shot
- `side_effect_upsert` — upsert `{ effect, severity, recorded_on?, notes? }` on `(recorded_on, effect)`
- `measurement` — insert `{ metric, value, unit?, measured_at?, notes? }`
- `vial_start` — insert a vial (`total_mg` or `total_units` required)
- `profile_update` — update the single profile row (`start_weight_lb`, `goal_weight_lb`, `height_in`)
- `goal_set` — `{ kind: calories|protein, target }`; marks the current active target of that kind `retired` and inserts the new one (no-op if unchanged)
- `food_thought` — insert a one-tap "thinking about food" `{ strength?: 1–3, at?, note? }` into `log.food_thoughts`
- `health_sync` — from the iPhone app: `days` (upsert into `log.daily_health` by day; fields not sent are kept), `weights`, `body` (`body_fat_pct`, `lean_mass_lb` into `log.measurements`) and `workouts`, all insert-only and skipping anything already logged at the same time
- `health_metrics` — from the iPhone app: `{ metrics: [{ day, metric, value, unit? }] }` (up to 800), upserted on `(day, metric)` into `log.health_metrics` by `public.log_health_metrics(jsonb)`

Allowed injection sites: `Abd LR`, `Abd LL`, `Abd UR`, `Abd UL`, `Love L`, `Love R`. Compounds: `tirzepatide`, `retatrutide`.

The reconstitution calculator is client-side only and does not write.

## Schema (`log`)

Existing:

- `log.meals` — `eaten_at`, `meal_type`, `item`, `quantity`, `calories`, `protein_g`, `carbs_g`, `fat_g`, `fiber_g`, `source`, `notes`, `logged_by`
- `log.weights` — `measured_at`, `weight_lb`, `notes`
- `log.doses` — `taken_at`, `compound`, `dose_mg`, `units`, `notes`, plus `site` (text) and `skipped` (bool, default false)
- `log.daily_health`, `log.workouts`
- Views: `log.daily_totals`, `log.weekly_summary`

Added for WeightSnap-parity:

- `log.checkins` — PK `day` (America/Chicago date). `ate_vs_usual` / `moved_vs_usual` (`less`\|`usual`\|`more`), `dose_feel` (`strong`\|`fading`\|`not_feeling_it`), `mood` / `food_noise` / `energy` / `sleep_quality` (1–10), `sleep_hours`, `exercise_minutes`, `steps`, `resting_hr`, `active_calories`, `earned` (Earn It), `notes`, `source`, `logged_by`, `checked_in_at`
- `log.side_effects` — `recorded_on`, `recorded_at`, `effect`, `severity` (1–10), `notes`; unique `(recorded_on, effect)`
- `log.protocol` — `compound`, `display_name`, `typical_dose_mg`, `units`, `frequency`, `status` (`active`\|`paused`\|`retired`\|`as_needed`), `half_life_hours`, `started_on`, `next_site`, `notes`. Seeded: tirzepatide 3 mg weekly, active, 120 h, started 2026-11-02; retatrutide planned 2026-12-06, paused, 144 h, 20 units after mixing with 1 mL, `typical_dose_mg` null until known
- `log.vials` — inventory for supply runway (`total_` / `remaining_` mg or units, concentration, expiry)
- `log.measurements` — `measured_at`, `metric`, `value`, `unit`
- `log.profile` — single row (`id = 1`): `start_weight_lb` (271.8), `goal_weight_lb` (235), `height_in` (73)
- `log.goals` — optional targets; a weight goal of 235 lb by 2027-01-01 is seeded
- `log.progress_photos` — metadata only; private Storage is not wired up
- `log.food_thoughts` — `thought_at`, `strength` (1 passing thought, 2 strong pull, 3 craving), `note`
- `log.health_metrics` — PK `(day, metric)`: every other daily Apple Health number (`value`, `unit`, `source`, `updated_at`). Metrics: `heart_rate_avg` / `_min` / `_max`, `respiratory_rate`, `spo2_avg` / `_min`, `bp_systolic` / `bp_diastolic`, `glucose_avg` / `_min` / `_max`, `body_temp_f`, `basal_temp_f`, `wrist_temp_f`, `sleep_in_bed_h`, `sleep_core_min`, `sleep_deep_min`, `sleep_rem_min`, `sleep_awake_min`, `basal_kcal`, `total_kcal`, `dietary_kcal`, `water_oz`, `flights`, `cycling_mi`, `mindful_min`, `state_of_mind`, `height_in`

The dashboard payload also carries `food_thoughts` (last 180 days), `run_weeks` (running miles, runs and longest run per Monday week, last 26 weeks) and `health_metrics` (`{ metric: [[day, value], ...] }`, last 120 days).

All `log` tables have RLS enabled. Privileges are for `service_role` / `postgres` only. The Data API does not expose schema `log`; the app goes through the Edge Functions and `SECURITY DEFINER` RPCs `public.log_dashboard_payload()`, `public.log_write(text, jsonb)` and `public.log_health_metrics(jsonb)`.

## Write rules (for Log, Claude, or the app)

Insert only. Never update or delete existing rows unless explicitly asked, except: merge fields on today’s check-in / side-effect upsert, fill `log.doses.site` from notes (already done), and the allowed `protocol.next_site` / `profile` updates above. Never run DDL from a logging session. After a write, confirm in one line what was logged.

## Not feasible on the web

Home-screen widgets, an Apple Watch app, and AI body-fat estimates from photos. Apple Health sync needs the iPhone app in `ios-app/`. The app is a PWA (manifest + icons) so it can be added to the iPhone home screen.
