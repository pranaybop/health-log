-- Read-only JSON payload for the log dashboard Edge Function.
-- EXECUTE is granted only to service_role.
CREATE OR REPLACE FUNCTION public.log_dashboard_payload()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT jsonb_build_object(
    'as_of', now(),
    'meals', COALESCE((
      SELECT jsonb_agg(row_to_json(t) ORDER BY t.eaten_at)
      FROM (
        SELECT id, eaten_at, meal_type, item, quantity, calories, protein_g, carbs_g, fat_g, fiber_g, source, notes
        FROM log.meals
      ) t
    ), '[]'::jsonb),
    'weights', COALESCE((
      SELECT jsonb_agg(row_to_json(t) ORDER BY t.measured_at)
      FROM (
        SELECT id, measured_at, weight_lb, notes
        FROM log.weights
      ) t
    ), '[]'::jsonb),
    'doses', COALESCE((
      SELECT jsonb_agg(row_to_json(t) ORDER BY t.taken_at)
      FROM (
        SELECT id, taken_at, compound, dose_mg, units, notes
        FROM log.doses
      ) t
    ), '[]'::jsonb),
    'daily_totals', COALESCE((
      SELECT jsonb_agg(row_to_json(t) ORDER BY t.date)
      FROM (
        SELECT date, calories, protein_g, carbs_g, fat_g, fiber_g, meal_count
        FROM log.daily_totals
      ) t
    ), '[]'::jsonb),
    'weekly_summary', COALESCE((
      SELECT jsonb_agg(row_to_json(t) ORDER BY t.week)
      FROM (
        SELECT week, avg_daily_calories, avg_protein_g, calories, days_logged, min_weight_lb, max_weight_lb, avg_weight_lb
        FROM log.weekly_summary
      ) t
    ), '[]'::jsonb),
    'daily_health', COALESCE((
      SELECT jsonb_agg(row_to_json(t) ORDER BY t.day)
      FROM (
        SELECT day, steps, distance_mi, active_kcal, exercise_min, stand_hours, resting_hr, hrv_ms, vo2max, sleep_hours, source
        FROM log.daily_health
        WHERE day >= ((now() AT TIME ZONE 'America/Chicago')::date - 365)
      ) t
    ), '[]'::jsonb),
    'workouts', COALESCE((
      SELECT jsonb_agg(row_to_json(t) ORDER BY t.started_at DESC)
      FROM (
        SELECT id, started_at, ended_at, activity, duration_min, distance_mi, active_kcal, avg_hr, max_hr, indoor, source
        FROM log.workouts
        ORDER BY started_at DESC
        LIMIT 25
      ) t
    ), '[]'::jsonb),
    'workout_count', (SELECT count(*)::int FROM log.workouts),
    'health_span', (
      SELECT jsonb_build_object('first_day', min(day), 'last_day', max(day), 'days', count(*)::int)
      FROM log.daily_health
    )
  );
$$;

REVOKE ALL ON FUNCTION public.log_dashboard_payload() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.log_dashboard_payload() FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.log_dashboard_payload() TO service_role;
