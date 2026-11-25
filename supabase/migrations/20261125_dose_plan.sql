-- 2026-11-25: the dose plan from the titration sheet in Drive: one row per planned Sunday dose
-- (the last tirzepatide week, then the retatrutide weeks). Planned doses only;
-- what was actually taken stays in log.doses. Adds 'dose_plan' to the dashboard payload.

CREATE TABLE IF NOT EXISTS log.dose_plan (
  planned_on date PRIMARY KEY,
  week int CHECK (week BETWEEN 1 AND 104),
  compound text NOT NULL CHECK (compound IN ('tirzepatide', 'retatrutide')),
  dose_mg numeric NOT NULL CHECK (dose_mg > 0 AND dose_mg <= 50),
  units numeric CHECK (units > 0 AND units <= 100),
  vial_draw text,
  notes text,
  source text NOT NULL DEFAULT 'drive-sheet',
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE log.dose_plan ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON log.dose_plan FROM PUBLIC;
REVOKE ALL ON log.dose_plan FROM anon, authenticated;

-- The 27 rows were loaded from the sheet when this ran (Nov 25, 2026). They're personal, so
-- they aren't kept in this public repo: re-load them from the sheet if this is ever rebuilt.
-- INSERT INTO log.dose_plan (week, planned_on, compound, dose_mg, units, vial_draw, notes) VALUES (...);

CREATE OR REPLACE FUNCTION public.log_dashboard_payload()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'pg_temp'
AS $function$
  SELECT jsonb_build_object(
    'as_of', now(),
    'meals', COALESCE((SELECT jsonb_agg(row_to_json(t) ORDER BY t.eaten_at) FROM (
      SELECT id, eaten_at, meal_type, item, quantity, calories, protein_g, carbs_g, fat_g, fiber_g, source, notes FROM log.meals) t), '[]'::jsonb),
    'weights', COALESCE((SELECT jsonb_agg(row_to_json(t) ORDER BY t.measured_at) FROM (
      SELECT id, measured_at, weight_lb, notes FROM log.weights) t), '[]'::jsonb),
    'doses', COALESCE((SELECT jsonb_agg(row_to_json(t) ORDER BY t.taken_at) FROM (
      SELECT id, taken_at, compound, dose_mg, units, site, skipped, notes FROM log.doses) t), '[]'::jsonb),
    'daily_totals', COALESCE((SELECT jsonb_agg(row_to_json(t) ORDER BY t.date) FROM (
      SELECT date, calories, protein_g, carbs_g, fat_g, fiber_g, meal_count FROM log.daily_totals) t), '[]'::jsonb),
    'weekly_summary', COALESCE((SELECT jsonb_agg(row_to_json(t) ORDER BY t.week) FROM (
      SELECT week, avg_daily_calories, avg_protein_g, calories, days_logged, min_weight_lb, max_weight_lb, avg_weight_lb FROM log.weekly_summary) t), '[]'::jsonb),
    'daily_health', COALESCE((SELECT jsonb_agg(row_to_json(t) ORDER BY t.day) FROM (
      SELECT day, steps, distance_mi, active_kcal, exercise_min, stand_hours, resting_hr, hrv_ms, vo2max, sleep_hours, source
      FROM log.daily_health
      WHERE day >= ((now() AT TIME ZONE 'America/Chicago')::date - 365)) t), '[]'::jsonb),
    'health_metrics', COALESCE((SELECT jsonb_object_agg(t.metric, t.pts) FROM (
      SELECT metric, jsonb_agg(jsonb_build_array(day, value) ORDER BY day) AS pts
      FROM log.health_metrics
      WHERE day >= ((now() AT TIME ZONE 'America/Chicago')::date - 120)
      GROUP BY metric) t), '{}'::jsonb),
    'workouts', COALESCE((SELECT jsonb_agg(row_to_json(t) ORDER BY t.started_at DESC) FROM (
      SELECT id, started_at, ended_at, activity, duration_min, distance_mi, active_kcal, avg_hr, max_hr, indoor, source
      FROM log.workouts ORDER BY started_at DESC LIMIT 25) t), '[]'::jsonb),
    'workout_count', (SELECT count(*)::int FROM log.workouts),
    'run_weeks', COALESCE((SELECT jsonb_agg(row_to_json(t) ORDER BY t.week) FROM (
      SELECT date_trunc('week', started_at AT TIME ZONE 'America/Chicago')::date AS week,
             count(*)::int AS runs,
             round(COALESCE(sum(distance_mi), 0)::numeric, 2) AS miles,
             round(COALESCE(max(distance_mi), 0)::numeric, 2) AS longest_mi,
             round(COALESCE(sum(duration_min), 0)::numeric, 0) AS minutes
      FROM log.workouts
      WHERE activity = 'running' AND started_at >= now() - interval '26 weeks'
      GROUP BY 1) t), '[]'::jsonb),
    'health_span', (SELECT jsonb_build_object('first_day', min(day), 'last_day', max(day), 'days', count(*)::int) FROM log.daily_health),
    'checkins', COALESCE((SELECT jsonb_agg(row_to_json(t) ORDER BY t.day) FROM (
      SELECT day, ate_vs_usual, moved_vs_usual, dose_feel, mood, food_noise, energy, sleep_quality, sleep_hours, exercise_minutes, steps, resting_hr, active_calories, earned, notes, source
      FROM log.checkins) t), '[]'::jsonb),
    'side_effects', COALESCE((SELECT jsonb_agg(row_to_json(t) ORDER BY t.recorded_at) FROM (
      SELECT id, recorded_on, recorded_at, effect, severity, notes FROM log.side_effects) t), '[]'::jsonb),
    'food_thoughts', COALESCE((SELECT jsonb_agg(row_to_json(t) ORDER BY t.thought_at) FROM (
      SELECT id, thought_at, strength, note FROM log.food_thoughts
      WHERE thought_at >= now() - interval '180 days') t), '[]'::jsonb),
    'protocol', COALESCE((SELECT jsonb_agg(row_to_json(t) ORDER BY t.started_on NULLS LAST) FROM (
      SELECT id, compound, display_name, typical_dose_mg, units, frequency, status, half_life_hours, started_on, next_site, notes FROM log.protocol) t), '[]'::jsonb),
    'dose_plan', COALESCE((SELECT jsonb_agg(row_to_json(t) ORDER BY t.planned_on) FROM (
      SELECT planned_on, week, compound, dose_mg, units, vial_draw, notes FROM log.dose_plan) t), '[]'::jsonb),
    'vials', COALESCE((SELECT jsonb_agg(row_to_json(t) ORDER BY t.started_on NULLS LAST) FROM (
      SELECT id, compound, label, started_on, opened_at, total_mg, remaining_mg, total_units, remaining_units, concentration_mg_per_ml, expired_on, notes FROM log.vials) t), '[]'::jsonb),
    'measurements', COALESCE((SELECT jsonb_agg(row_to_json(t) ORDER BY t.measured_at) FROM (
      SELECT id, measured_at, metric, value, unit, notes FROM log.measurements) t), '[]'::jsonb),
    'profile', (SELECT to_jsonb(t) FROM (SELECT start_weight_lb, goal_weight_lb, height_in, notes FROM log.profile WHERE id = 1) t),
    'goals', COALESCE((SELECT jsonb_agg(row_to_json(t) ORDER BY t.due_on NULLS LAST) FROM (
      SELECT id, kind, target, unit, due_on, notes, status FROM log.goals) t), '[]'::jsonb)
  );
$function$;
