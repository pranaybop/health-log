# Log

A GLP-1 and health tracker: a native iPhone app (`ios-app/`, SwiftUI) on top of the private `log` schema in Supabase project `qnbshmenmurdaogslmrj` (`supabase/`). What the app does, how to build it and how to install it are in [`ios-app/README.md`](ios-app/README.md#features).

The old web dashboard (GitHub Pages) and the app's embedded web code were removed on Nov 26, 2026; everything is native Swift now. Their history is in git if you ever need it.

Do not put passcodes, access tokens, API keys or other secrets in this repo; it's public. Tests and CI screenshots run on made-up data only (`ios-app/ios/screenshots/demo.json`, `ios-app/ios/App/LogNative/Tests`).

Times follow each account's time zone (the original log is America/Chicago). Meal macros may be estimates. Drug level is a half-life model (tirzepatide 5 days / 120 hours, retatrutide 6 days / 144 hours), not a lab measurement.

Calorie and protein targets come from active `log.goals` rows (`kind` `calories` / `protein`, set with `goal_set`).

## Endpoints

`log-dashboard` and `log-write` take a signed-in session (`Authorization: Bearer`, from `log-auth`) or the original log's `x-log-passcode` / `x-log-token`. Passcode auth is a SHA-256 match (or the `LOG_APP_PASSCODE` / `LOG_DASHBOARD_TOKEN` function secrets if set). Failed auth waits 600ms and returns 401. The iPhone app calls them directly; the CORS rules (for the old website's origin) don't apply to it. `p_user` is the signed-in account, or null for the owner (passcode or bot token).

| Function | Method | URL | Role |
| --- | --- | --- | --- |
| `log-dashboard` | GET | `https://qnbshmenmurdaogslmrj.supabase.co/functions/v1/log-dashboard` | Read-only. Calls `public.log_dashboard_payload_for(p_user)` and returns that user's JSON (`as_of`, meals, weights, doses, daily_totals, weekly_summary, daily_health, workouts, checkins, side_effects, protocol, vials, measurements, profile, goals). Adds `account` and signed `progress_photos`. |
| `log-write` | POST | `https://qnbshmenmurdaogslmrj.supabase.co/functions/v1/log-write` | Body: `{ "action": "<name>", "payload": { ... } }`. Calls that action's `*_for` RPC, except `progress_photo_sign` (upload URL only). |

`log-write` actions (`log_write_for`, except the RPCs named below and `progress_photo_sign`):

- `checkin_upsert` — upsert today’s (or `day`) check-in for this user; merges provided fields so a 3-tap does not wipe a deep check-in
- `earn_it` — `{ earned: true|false, day? }`
- `weigh_in` — insert `{ weight_lb, measured_at?, notes? }`
- `dose_log` — insert `{ compound, dose_mg, units?, site?, skipped?, taken_at?, notes? }`; updates `protocol.next_site` after a real shot
- `side_effect_upsert` — upsert `{ effect, severity, recorded_on?, notes? }` on `(user_id, recorded_on, effect)`
- `measurement` — insert `{ metric, value, unit?, measured_at?, notes? }`
- `vial_start` — insert a vial (`total_mg` or `total_units` required)
- `profile_update` — update this user's profile (`start_weight_lb`, `goal_weight_lb`, `height_in`)
- `goal_set` — `{ kind: calories|protein, target }`; marks the current active target of that kind `retired` and inserts the new one (no-op if unchanged)
- `food_thought` — insert a one-tap "thinking about food" `{ strength?: 1–3, at?, note? }` into `log.food_thoughts`
- `health_sync` — from the iPhone app: `days` (upsert into `log.daily_health` on `(user_id, day)`; fields not sent are kept), `weights`, `body` (`body_fat_pct`, `lean_mass_lb` into `log.measurements`) and `workouts`, skipping anything already logged at the same time
- `health_metrics` — `{ metrics: [{ day, metric, value, unit? }] }` (up to 800), upserted on `(user_id, day, metric)` by `public.log_health_metrics_for(uuid, jsonb)`
- `meal_log` — insert one meal's items `{ meal_type?, eaten_at?, items: [{ item, calories?, ... }] }` via `public.log_meal_for`
- `account_setup` — this user's name, time zone, weights, height, and `settings` via `public.log_account_setup_for`
- `regimen_set` — insert a schedule `{ compound, dose_mg, every_days?, days_on?, days_off?, start_on?, end_on? }` via `public.log_regimen_set_for`
- `regimen_end` — `{ id }`; sets that regimen `done` (the row stays) via `public.log_regimen_end_for`
- `progress_photo_sign` — signed upload URL for a jpeg in the private `progress-photos` bucket; no row yet
- `progress_photo_save` — record the uploaded object `{ path, weight_lb, ... }` via `public.log_progress_photo_save_for`
- `progress_photo_delete` — `{ id }`; deletes the row and the object via `public.log_progress_photo_delete_for`

Allowed injection sites: `Abd LR`, `Abd LL`, `Abd UR`, `Abd UL`, `Love L`, `Love R`. Compounds: `tirzepatide`, `retatrutide`, `semaglutide`, `tesamorelin` (`log.dose_plan` is the weekly GLP-1 sheet and does not include tesamorelin).

The reconstitution calculator is client-side only and does not write.

## Schema (`log`)

Existing:

- `log.meals` — `eaten_at`, `meal_type`, `item`, `quantity`, `calories`, `protein_g`, `carbs_g`, `fat_g`, `fiber_g`, `source`, `notes`, `logged_by`
- `log.weights` — `measured_at`, `weight_lb`, `notes`
- `log.doses` — `taken_at`, `compound`, `dose_mg`, `units`, `notes`, plus `site` (text) and `skipped` (bool, default false)
- `log.daily_health`, `log.workouts`
- Views: `log.daily_totals`, `log.weekly_summary`

Added for WeightSnap-parity:

- `log.checkins` — PK `(user_id, day)` (the account's time zone). `ate_vs_usual` / `moved_vs_usual` (`less`\|`usual`\|`more`), `dose_feel` (`strong`\|`fading`\|`not_feeling_it`), `mood` / `food_noise` / `energy` / `sleep_quality` (1–10), `sleep_hours`, `exercise_minutes`, `steps`, `resting_hr`, `active_calories`, `earned` (Earn It), `notes`, `source`, `logged_by`, `checked_in_at`
- `log.side_effects` — `recorded_on`, `recorded_at`, `effect`, `severity` (1–10), `notes`; unique `(user_id, recorded_on, effect)`
- `log.protocol` — `compound`, `display_name`, `typical_dose_mg`, `units`, `frequency`, `status` (`active`\|`paused`\|`retired`\|`as_needed`), `half_life_hours`, `started_on`, `next_site`, `notes`. Seeded: tirzepatide 3 mg weekly, active, 120 h, started 2026-11-02; retatrutide planned 2026-12-06, paused, 144 h, 25 units = 2.5 mg at 10 mg/mL (the first step of `log.dose_plan`)
- `log.vials` — inventory for supply runway (`total_` / `remaining_` mg or units, concentration, expiry)
- `log.measurements` — `measured_at`, `metric`, `value`, `unit`
- `log.profile` — one row per `user_id`: `start_weight_lb`, `goal_weight_lb`, `height_in`, `time_zone`, `display_name`, `settings`
- `log.goals` — optional targets; a weight goal of 235 lb by 2027-01-01 is seeded
- `log.progress_photos` — weigh-in photo metadata. Bytes live in the private `progress-photos` bucket; clients only get a short-lived signed URL (`supabase/functions/_shared/progress_photos.ts`)
- `log.regimen` — repeating schedule per user: compound, dose, `every_days`, optional `days_on` / `days_off`, `start_on` / `end_on`, `status` (`planned`\|`active`\|`paused`\|`done`)
- `log.food_thoughts` — `thought_at`, `strength` (1 passing thought, 2 strong pull, 3 craving), `note`
- `log.dose_plan` — PK `(user_id, planned_on)`: the planned weekly doses from the titration sheet in Drive (last tirzepatide week Nov 29, then retatrutide weeks 1–26, Dec 6 2026 to May 30 2027, 130 mg): `week`, `compound`, `dose_mg`, `units`, `vial_draw`, `notes`. Planned only; taken doses stay in `log.doses`.
- `log.health_metrics` — PK `(user_id, day, metric)`: every other daily Apple Health number (`value`, `unit`, `source`, `updated_at`). Metrics: `heart_rate_avg` / `_min` / `_max`, `respiratory_rate`, `spo2_avg` / `_min`, `bp_systolic` / `bp_diastolic`, `glucose_avg` / `_min` / `_max`, `body_temp_f`, `basal_temp_f`, `wrist_temp_f`, `sleep_in_bed_h`, `sleep_core_min`, `sleep_deep_min`, `sleep_rem_min`, `sleep_awake_min`, `basal_kcal`, `total_kcal`, `dietary_kcal`, `water_oz`, `flights`, `cycling_mi`, `mindful_min`, `state_of_mind`, `height_in`

The dashboard payload also carries `food_thoughts` (last 180 days), `health_metrics` (`{ metric: [[day, value], ...] }`, last 120 days), `dose_plan` (every planned dose) and `regimens`.

All `log` tables have RLS enabled and are scoped by `user_id`. Privileges are for `service_role` / `postgres` only. The Data API does not expose schema `log`. The Edge Functions call `SECURITY DEFINER` `*_for` RPCs: `log_dashboard_payload_for`, `log_write_for`, `log_health_metrics_for`, `log_meal_for`, `log_account_setup_for`, `log_regimen_set_for`, `log_regimen_end_for`, `log_progress_photos_for`, `log_progress_photo_save_for`, `log_progress_photo_delete_for`.

## Write rules (for Log, Claude, or the app)

Insert or upsert this user's rows. Do not delete, except `progress_photo_delete` (the row and the private object). `regimen_end` sets `status` to `done` and does not remove the row. Also allowed: merging today’s check-in or a side effect, `protocol.next_site` after a real shot, and profile / goal updates (`profile_update`, `account_setup`, `goal_set`). Never run DDL from a logging session. After a write, confirm in one line what was logged.
