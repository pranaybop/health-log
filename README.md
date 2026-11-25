# Log

Live health dashboard for the private `log` schema in Supabase project `qnbshmenmurdaogslmrj`. The UI is this static app on GitHub Pages: https://pranaybop.github.io/health-log/

Open that URL and enter your passcode. This device stores it in `localStorage` (`log.passcode`) until you tap Lock. The older `#k=` access-token link still works. The page fetches on load, refreshes every 60 seconds, and has a manual Refresh control.

Do not put passcodes, access tokens, or other secrets in this repo.

Times display in America/Chicago. Meal macros may be estimates. Drug level is a half-life model (tirzepatide 5 days / 120 hours, retatrutide 6 days / 144 hours), not a lab measurement.

## Frontend

No build step and no dependencies. Scripts load in this order: `analytics.js` (pure calculations: weight smoothing, pace, drug level, cycles), `export.js` (prescriber CSV/PDF), `forms.js` (Log tab), `charts.js` (SVG charts with touch scrubbing, site map), `app.js` (state, tabs, rendering). `styles.css` follows the system light/dark setting. Bump the `?v=` query in `index.html` when shipping changes so iPhone Safari picks them up.

Calorie and protein targets on Today come from active `log.goals` rows (`kind` `calories` / `protein`) when present; otherwise from targets set on the device (`localStorage` `log.targets`). Edit targets tries a `goal_set` write first and falls back to the device while that action isn't deployed.

The weight chart's Compare control draws calories (`daily_totals`), steps or sleep (`daily_health`, last 365 days) as a bar strip under the chart on the same days, with its own scale. 1Y and All use weekly averages. The choice is kept on the device (`log.overlay`).

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
- `log.profile` — single row (`id = 1`): `start_weight_lb` (271.8), `goal_weight_lb` (235), `height_in`
- `log.goals` — optional targets; a weight goal of 235 lb by 2027-01-01 is seeded
- `log.progress_photos` — metadata only; private Storage is not wired up

All `log` tables have RLS enabled. Privileges are for `service_role` / `postgres` only. The Data API does not expose schema `log`; the app goes through the Edge Functions and `SECURITY DEFINER` RPCs `public.log_dashboard_payload()` and `public.log_write(text, jsonb)`.

## Write rules (for Log, Claude, or the app)

Insert only. Never update or delete existing rows unless explicitly asked, except: merge fields on today’s check-in / side-effect upsert, fill `log.doses.site` from notes (already done), and the allowed `protocol.next_site` / `profile` updates above. Never run DDL from a logging session. After a write, confirm in one line what was logged.

## Not feasible on the web

Apple Health / HealthKit sync, home-screen widgets, an Apple Watch app, and AI body-fat estimates from photos. The app is a PWA (manifest + icons) so it can be added to the iPhone home screen.
