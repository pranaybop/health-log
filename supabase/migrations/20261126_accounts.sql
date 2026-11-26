-- Accounts: every log row belongs to a user.
--
-- How it works
-- - log.current_user_id(): the user a request is for. The Edge Functions set it per request
--   (set_config('log.user_id', ...)) after checking a signed-in session. With nothing set, it
--   falls back to the owner (log.owner), so the passcode, the Grok bot and anything that writes
--   directly keep working for the owner exactly as before.
-- - The owner starts as a placeholder id. The first time the owner signs in (by email), the
--   log-auth function calls log_claim_owner, which moves every placeholder row to the real
--   account. Nothing else changes for the owner.
-- - log.current_tz(): the user's time zone from log.profile (default America/Chicago), used
--   wherever days were counted in Central time.
-- - Unique keys that were global (one check-in per day, one Apple Health row per day, ...) are
--   now per user. Functions are patched in place: their ON CONFLICT targets, the duplicate
--   checks and the few UPDATEs get the user, and 'America/Chicago' becomes log.current_tz().
-- - A copy of every table as it was is kept in log_backup_20261126 (not exposed).

-- 0. Backup
CREATE SCHEMA IF NOT EXISTS log_backup_20261126;
REVOKE ALL ON SCHEMA log_backup_20261126 FROM PUBLIC, anon, authenticated;
DO $$
DECLARE t text;
BEGIN
  FOR t IN SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
           WHERE n.nspname = 'log' AND c.relkind = 'r' LOOP
    EXECUTE format('CREATE TABLE IF NOT EXISTS log_backup_20261126.%I AS TABLE log.%I', t, t);
  END LOOP;
END $$;

-- 1. Owner and the current user
CREATE TABLE IF NOT EXISTS log.owner (
  singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
  user_id uuid NOT NULL,
  email text NOT NULL,
  claimed_at timestamptz
);
ALTER TABLE log.owner ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON log.owner FROM PUBLIC, anon, authenticated;
-- The owner's email is set outside this public file (UPDATE log.owner SET email = ...).
INSERT INTO log.owner (user_id, email) VALUES (gen_random_uuid(), 'owner@example.invalid')
ON CONFLICT (singleton) DO NOTHING;

CREATE OR REPLACE FUNCTION log.current_user_id() RETURNS uuid
LANGUAGE sql STABLE SET search_path = pg_catalog, pg_temp AS $$
  SELECT COALESCE(NULLIF(current_setting('log.user_id', true), '')::uuid,
                  (SELECT o.user_id FROM log.owner o WHERE o.singleton))
$$;

-- 2. user_id on every table, existing rows to the owner
DO $$
DECLARE t text; owner_id uuid := (SELECT user_id FROM log.owner WHERE singleton);
BEGIN
  FOR t IN SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
           WHERE n.nspname = 'log' AND c.relkind = 'r' AND c.relname <> 'owner' LOOP
    EXECUTE format('ALTER TABLE log.%I ADD COLUMN IF NOT EXISTS user_id uuid', t);
    EXECUTE format('UPDATE log.%I SET user_id = %L WHERE user_id IS NULL', t, owner_id);
    EXECUTE format('ALTER TABLE log.%I ALTER COLUMN user_id SET NOT NULL', t);
    EXECUTE format('ALTER TABLE log.%I ALTER COLUMN user_id SET DEFAULT log.current_user_id()', t);
    EXECUTE format('CREATE INDEX IF NOT EXISTS %I ON log.%I (user_id)', t || '_user_id_idx', t);
  END LOOP;
END $$;

-- 3. Per-user keys
ALTER TABLE log.checkins DROP CONSTRAINT checkins_pkey, ADD PRIMARY KEY (user_id, day);
ALTER TABLE log.daily_health DROP CONSTRAINT daily_health_pkey, ADD PRIMARY KEY (user_id, day);
ALTER TABLE log.health_metrics DROP CONSTRAINT health_metrics_pkey, ADD PRIMARY KEY (user_id, day, metric);
ALTER TABLE log.dose_plan DROP CONSTRAINT dose_plan_pkey, ADD PRIMARY KEY (user_id, planned_on);
DO $$
DECLARE c text;
BEGIN
  SELECT conname INTO c FROM pg_constraint WHERE conrelid = 'log.side_effects'::regclass AND contype = 'u';
  IF c IS NOT NULL THEN EXECUTE format('ALTER TABLE log.side_effects DROP CONSTRAINT %I', c); END IF;
  SELECT conname INTO c FROM pg_constraint WHERE conrelid = 'log.workouts'::regclass AND contype = 'u';
  IF c IS NOT NULL THEN EXECUTE format('ALTER TABLE log.workouts DROP CONSTRAINT %I', c); END IF;
END $$;
ALTER TABLE log.side_effects ADD CONSTRAINT side_effects_user_day_effect_key UNIQUE (user_id, recorded_on, effect);
ALTER TABLE log.workouts ADD CONSTRAINT workouts_user_start_activity_source_key UNIQUE (user_id, started_at, activity, source);

-- Profile: one row per user (was the single row id = 1), plus time zone and settings.
ALTER TABLE log.profile DROP CONSTRAINT IF EXISTS profile_id_check;
ALTER TABLE log.profile DROP CONSTRAINT profile_pkey;
ALTER TABLE log.profile ALTER COLUMN id DROP NOT NULL;
ALTER TABLE log.profile ALTER COLUMN id DROP DEFAULT;
ALTER TABLE log.profile ADD PRIMARY KEY (user_id);
ALTER TABLE log.profile
  ADD COLUMN IF NOT EXISTS time_zone text NOT NULL DEFAULT 'America/Chicago',
  ADD COLUMN IF NOT EXISTS display_name text,
  ADD COLUMN IF NOT EXISTS settings jsonb NOT NULL DEFAULT '{}'::jsonb,
  ADD COLUMN IF NOT EXISTS onboarded_at timestamptz;
-- The owner has been using the app all along.
UPDATE log.profile SET onboarded_at = COALESCE(onboarded_at, now());

CREATE OR REPLACE FUNCTION log.current_tz() RETURNS text
LANGUAGE sql STABLE SET search_path = pg_catalog, pg_temp AS $$
  SELECT COALESCE((SELECT p.time_zone FROM log.profile p WHERE p.user_id = log.current_user_id()), 'America/Chicago')
$$;

-- 4. Views: the current user's rows, days in their time zone
CREATE OR REPLACE VIEW log.daily_totals AS
  SELECT (timezone(log.current_tz(), eaten_at))::date AS date,
    COALESCE(sum(calories), 0::numeric) AS calories,
    COALESCE(sum(protein_g), 0::numeric) AS protein_g,
    COALESCE(sum(carbs_g), 0::numeric) AS carbs_g,
    COALESCE(sum(fat_g), 0::numeric) AS fat_g,
    COALESCE(sum(fiber_g), 0::numeric) AS fiber_g,
    (count(*))::integer AS meal_count
  FROM log.meals
  WHERE user_id = log.current_user_id()
  GROUP BY 1;

CREATE OR REPLACE VIEW log.weekly_summary AS
  WITH meal_days AS (
    SELECT (date_trunc('week', timezone(log.current_tz(), eaten_at)))::date AS week_start,
           (timezone(log.current_tz(), eaten_at))::date AS day,
           sum(calories) AS calories, sum(protein_g) AS protein_g
    FROM log.meals WHERE user_id = log.current_user_id() GROUP BY 1, 2
  ), meal_weeks AS (
    SELECT week_start, avg(calories) AS avg_daily_calories, avg(protein_g) AS avg_protein_g,
           sum(calories) AS calories, (count(*))::integer AS days_logged
    FROM meal_days GROUP BY week_start
  ), weight_weeks AS (
    SELECT (date_trunc('week', timezone(log.current_tz(), measured_at)))::date AS week_start,
           min(weight_lb) AS min_weight_lb, max(weight_lb) AS max_weight_lb, avg(weight_lb) AS avg_weight_lb
    FROM log.weights WHERE user_id = log.current_user_id() GROUP BY 1
  )
  SELECT COALESCE(m.week_start, w.week_start) AS week, m.avg_daily_calories, m.avg_protein_g, m.calories,
         m.days_logged, w.min_weight_lb, w.max_weight_lb, w.avg_weight_lb
  FROM meal_weeks m FULL JOIN weight_weeks w ON m.week_start = w.week_start;

-- 5. Patch the write functions in place for per-user keys, filters and time zone.
CREATE OR REPLACE FUNCTION pg_temp.patch(d text, pattern text, replacement text, expected int, label text) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE n int := (SELECT count(*) FROM regexp_matches(d, pattern, 'g'));
BEGIN
  IF n <> expected THEN RAISE EXCEPTION 'patch %: expected % matches, found %', label, expected, n; END IF;
  RETURN regexp_replace(d, pattern, replacement, 'g');
END $$;

DO $$
DECLARE d text := pg_get_functiondef('public.log_write(text,jsonb)'::regprocedure);
BEGIN
  d := pg_temp.patch(d, 'ON CONFLICT \(day\)', 'ON CONFLICT (user_id, day)', 3, 'checkins/daily_health');
  d := pg_temp.patch(d, 'ON CONFLICT \(recorded_on, effect\)', 'ON CONFLICT (user_id, recorded_on, effect)', 1, 'side_effects');
  d := pg_temp.patch(d, 'ON CONFLICT \(started_at, activity, source\)', 'ON CONFLICT (user_id, started_at, activity, source)', 1, 'workouts');
  d := pg_temp.patch(d, '(UPDATE log\.protocol\s+SET next_site = v_next\s+WHERE )', '\1user_id = log.current_user_id() AND ', 1, 'protocol');
  d := pg_temp.patch(d, '(FROM log\.goals\s+WHERE )', '\1user_id = log.current_user_id() AND ', 1, 'goals select');
  d := pg_temp.patch(d, '(UPDATE log\.goals SET status = ''retired''\s+WHERE )', '\1user_id = log.current_user_id() AND ', 1, 'goals retire');
  d := pg_temp.patch(d, '(FROM log\.weights w\s+WHERE )', '\1w.user_id = log.current_user_id() AND ', 1, 'weights dup');
  d := pg_temp.patch(d, '(FROM log\.measurements m\s+WHERE )', '\1m.user_id = log.current_user_id() AND ', 1, 'measurements dup');
  d := pg_temp.patch(d, '(FROM log\.workouts k\s+WHERE )', '\1k.user_id = log.current_user_id() AND ', 1, 'workouts dup');
  d := pg_temp.patch(d, 'UPDATE log\.profile SET', 'INSERT INTO log.profile (user_id) VALUES (log.current_user_id()) ON CONFLICT (user_id) DO NOTHING;
    UPDATE log.profile SET', 1, 'profile row');
  d := pg_temp.patch(d, 'WHERE id = 1;', 'WHERE user_id = log.current_user_id();', 1, 'profile where');
  d := pg_temp.patch(d, '''America/Chicago''', 'log.current_tz()', 1, 'time zone');
  EXECUTE d;

  d := pg_get_functiondef('public.log_health_metrics(jsonb)'::regprocedure);
  d := pg_temp.patch(d, 'ON CONFLICT \(day, metric\)', 'ON CONFLICT (user_id, day, metric)', 1, 'health_metrics');
  d := pg_temp.patch(d, '''America/Chicago''', 'log.current_tz()', 1, 'health_metrics tz');
  EXECUTE d;

  d := pg_get_functiondef('public.log_progress_photo_save(jsonb)'::regprocedure);
  d := pg_temp.patch(d, '(FROM log\.weights w WHERE w\.id = v_weight_id)', '\1 AND w.user_id = log.current_user_id()', 1, 'photo weight');
  d := pg_temp.patch(d, '''America/Chicago''', 'log.current_tz()', 1, 'photo tz');
  EXECUTE d;

  d := pg_get_functiondef('public.log_progress_photo_delete(jsonb)'::regprocedure);
  d := pg_temp.patch(d, 'WHERE id = v_id', 'WHERE id = v_id AND user_id = log.current_user_id()', 2, 'photo delete');
  EXECUTE d;

  d := pg_get_functiondef('public.log_progress_photos()'::regprocedure);
  d := pg_temp.patch(d, 'WHERE storage_path IS NOT NULL', 'WHERE storage_path IS NOT NULL AND user_id = log.current_user_id()', 1, 'photo list');
  EXECUTE d;
END $$;

-- 6. The dashboard payload: the current user's rows only, days in their time zone.
CREATE OR REPLACE FUNCTION public.log_dashboard_payload()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'pg_temp'
AS $function$
  WITH u AS (SELECT log.current_user_id() AS id, log.current_tz() AS tz)
  SELECT jsonb_build_object(
    'as_of', now(),
    'user_id', (SELECT id FROM u),
    'meals', COALESCE((SELECT jsonb_agg(row_to_json(t) ORDER BY t.eaten_at) FROM (
      SELECT id, eaten_at, meal_type, item, quantity, calories, protein_g, carbs_g, fat_g, fiber_g, source, notes FROM log.meals WHERE user_id = (SELECT id FROM u)) t), '[]'::jsonb),
    'weights', COALESCE((SELECT jsonb_agg(row_to_json(t) ORDER BY t.measured_at) FROM (
      SELECT id, measured_at, weight_lb, notes FROM log.weights WHERE user_id = (SELECT id FROM u)) t), '[]'::jsonb),
    'doses', COALESCE((SELECT jsonb_agg(row_to_json(t) ORDER BY t.taken_at) FROM (
      SELECT id, taken_at, compound, dose_mg, units, site, skipped, notes FROM log.doses WHERE user_id = (SELECT id FROM u)) t), '[]'::jsonb),
    'daily_totals', COALESCE((SELECT jsonb_agg(row_to_json(t) ORDER BY t.date) FROM (
      SELECT date, calories, protein_g, carbs_g, fat_g, fiber_g, meal_count FROM log.daily_totals) t), '[]'::jsonb),
    'weekly_summary', COALESCE((SELECT jsonb_agg(row_to_json(t) ORDER BY t.week) FROM (
      SELECT week, avg_daily_calories, avg_protein_g, calories, days_logged, min_weight_lb, max_weight_lb, avg_weight_lb FROM log.weekly_summary) t), '[]'::jsonb),
    'daily_health', COALESCE((SELECT jsonb_agg(row_to_json(t) ORDER BY t.day) FROM (
      SELECT day, steps, distance_mi, active_kcal, exercise_min, stand_hours, resting_hr, hrv_ms, vo2max, sleep_hours, source
      FROM log.daily_health
      WHERE user_id = (SELECT id FROM u) AND day >= ((now() AT TIME ZONE (SELECT tz FROM u))::date - 365)) t), '[]'::jsonb),
    'health_metrics', COALESCE((SELECT jsonb_object_agg(t.metric, t.pts) FROM (
      SELECT metric, jsonb_agg(jsonb_build_array(day, value) ORDER BY day) AS pts
      FROM log.health_metrics
      WHERE user_id = (SELECT id FROM u) AND day >= ((now() AT TIME ZONE (SELECT tz FROM u))::date - 120)
      GROUP BY metric) t), '{}'::jsonb),
    'workouts', COALESCE((SELECT jsonb_agg(row_to_json(t) ORDER BY t.started_at DESC) FROM (
      SELECT id, started_at, ended_at, activity, duration_min, distance_mi, active_kcal, avg_hr, max_hr, indoor, source
      FROM log.workouts WHERE user_id = (SELECT id FROM u) ORDER BY started_at DESC LIMIT 25) t), '[]'::jsonb),
    'workout_count', (SELECT count(*)::int FROM log.workouts WHERE user_id = (SELECT id FROM u)),
    'run_weeks', COALESCE((SELECT jsonb_agg(row_to_json(t) ORDER BY t.week) FROM (
      SELECT date_trunc('week', started_at AT TIME ZONE (SELECT tz FROM u))::date AS week,
             count(*)::int AS runs,
             round(COALESCE(sum(distance_mi), 0)::numeric, 2) AS miles,
             round(COALESCE(max(distance_mi), 0)::numeric, 2) AS longest_mi,
             round(COALESCE(sum(duration_min), 0)::numeric, 0) AS minutes
      FROM log.workouts
      WHERE user_id = (SELECT id FROM u) AND activity = 'running' AND started_at >= now() - interval '26 weeks'
      GROUP BY 1) t), '[]'::jsonb),
    'health_span', (SELECT jsonb_build_object('first_day', min(day), 'last_day', max(day), 'days', count(*)::int)
      FROM log.daily_health WHERE user_id = (SELECT id FROM u)),
    'checkins', COALESCE((SELECT jsonb_agg(row_to_json(t) ORDER BY t.day) FROM (
      SELECT day, ate_vs_usual, moved_vs_usual, dose_feel, mood, food_noise, energy, sleep_quality, sleep_hours, exercise_minutes, steps, resting_hr, active_calories, earned, notes, source
      FROM log.checkins WHERE user_id = (SELECT id FROM u)) t), '[]'::jsonb),
    'side_effects', COALESCE((SELECT jsonb_agg(row_to_json(t) ORDER BY t.recorded_at) FROM (
      SELECT id, recorded_on, recorded_at, effect, severity, notes FROM log.side_effects WHERE user_id = (SELECT id FROM u)) t), '[]'::jsonb),
    'food_thoughts', COALESCE((SELECT jsonb_agg(row_to_json(t) ORDER BY t.thought_at) FROM (
      SELECT id, thought_at, strength, note FROM log.food_thoughts
      WHERE user_id = (SELECT id FROM u) AND thought_at >= now() - interval '180 days') t), '[]'::jsonb),
    'protocol', COALESCE((SELECT jsonb_agg(row_to_json(t) ORDER BY t.started_on NULLS LAST) FROM (
      SELECT id, compound, display_name, typical_dose_mg, units, frequency, status, half_life_hours, started_on, next_site, notes
      FROM log.protocol WHERE user_id = (SELECT id FROM u)) t), '[]'::jsonb),
    'dose_plan', COALESCE((SELECT jsonb_agg(row_to_json(t) ORDER BY t.planned_on) FROM (
      SELECT planned_on, week, compound, dose_mg, units, vial_draw, notes FROM log.dose_plan WHERE user_id = (SELECT id FROM u)) t), '[]'::jsonb),
    'vials', COALESCE((SELECT jsonb_agg(row_to_json(t) ORDER BY t.started_on NULLS LAST) FROM (
      SELECT id, compound, label, started_on, opened_at, total_mg, remaining_mg, total_units, remaining_units, concentration_mg_per_ml, expired_on, notes
      FROM log.vials WHERE user_id = (SELECT id FROM u)) t), '[]'::jsonb),
    'measurements', COALESCE((SELECT jsonb_agg(row_to_json(t) ORDER BY t.measured_at) FROM (
      SELECT id, measured_at, metric, value, unit, notes FROM log.measurements WHERE user_id = (SELECT id FROM u)) t), '[]'::jsonb),
    'profile', (SELECT to_jsonb(t) FROM (
      SELECT start_weight_lb, goal_weight_lb, height_in, notes, time_zone, display_name, settings, onboarded_at
      FROM log.profile WHERE user_id = (SELECT id FROM u)) t),
    'regimens', COALESCE((SELECT jsonb_agg(row_to_json(t) ORDER BY t.start_on) FROM (
      SELECT id, compound, display_name, dose_mg, units, every_days, days_on, days_off, time_of_day, start_on, end_on,
             concentration_mg_per_ml, sites, status, notes FROM log.regimen WHERE user_id = (SELECT id FROM u)) t), '[]'::jsonb),
    'goals', COALESCE((SELECT jsonb_agg(row_to_json(t) ORDER BY t.due_on NULLS LAST) FROM (
      SELECT id, kind, target, unit, due_on, notes, status FROM log.goals WHERE user_id = (SELECT id FROM u)) t), '[]'::jsonb)
  );
$function$;

-- 7. Per-user entry points for the Edge Functions (service role only). Each sets the user for
--    this transaction, then runs the existing function.
CREATE OR REPLACE FUNCTION public.log_as(p_user uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  IF p_user IS NULL THEN RAISE EXCEPTION 'user required'; END IF;
  PERFORM set_config('log.user_id', p_user::text, true);
END $$;

CREATE OR REPLACE FUNCTION public.log_dashboard_payload_for(p_user uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN PERFORM public.log_as(p_user); RETURN public.log_dashboard_payload(); END $$;

CREATE OR REPLACE FUNCTION public.log_write_for(p_user uuid, p_action text, p_payload jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN PERFORM public.log_as(p_user); RETURN public.log_write(p_action, p_payload); END $$;

CREATE OR REPLACE FUNCTION public.log_health_metrics_for(p_user uuid, p_payload jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN PERFORM public.log_as(p_user); RETURN public.log_health_metrics(p_payload); END $$;

CREATE OR REPLACE FUNCTION public.log_progress_photos_for(p_user uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN PERFORM public.log_as(p_user); RETURN public.log_progress_photos(); END $$;

CREATE OR REPLACE FUNCTION public.log_progress_photo_save_for(p_user uuid, p_payload jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN PERFORM public.log_as(p_user); RETURN public.log_progress_photo_save(p_payload); END $$;

CREATE OR REPLACE FUNCTION public.log_progress_photo_delete_for(p_user uuid, p_payload jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN PERFORM public.log_as(p_user); RETURN public.log_progress_photo_delete(p_payload); END $$;

-- The owner signs in for the first time: everything logged so far moves to that account.
CREATE OR REPLACE FUNCTION public.log_claim_owner(p_user uuid, p_email text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE o log.owner%ROWTYPE; t text; n bigint := 0; c bigint;
BEGIN
  SELECT * INTO o FROM log.owner WHERE singleton FOR UPDATE;
  IF o.claimed_at IS NOT NULL THEN
    RETURN jsonb_build_object('ok', true, 'owner', o.user_id = p_user, 'claimed', false);
  END IF;
  IF lower(coalesce(p_email, '')) <> lower(o.email) THEN
    RETURN jsonb_build_object('ok', true, 'owner', false, 'claimed', false);
  END IF;
  FOR t IN SELECT c2.relname FROM pg_class c2 JOIN pg_namespace n2 ON n2.oid = c2.relnamespace
           WHERE n2.nspname = 'log' AND c2.relkind = 'r' AND c2.relname <> 'owner' LOOP
    EXECUTE format('UPDATE log.%I SET user_id = $1 WHERE user_id = $2', t) USING p_user, o.user_id;
    GET DIAGNOSTICS c = ROW_COUNT;
    n := n + c;
  END LOOP;
  UPDATE log.owner SET user_id = p_user, claimed_at = now() WHERE singleton;
  RETURN jsonb_build_object('ok', true, 'owner', true, 'claimed', true, 'rows', n);
END $$;

-- First run: name, time zone, start and goal weight, height, settings; marks the account set up.
CREATE OR REPLACE FUNCTION public.log_account_setup_for(p_user uuid, p_payload jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_tz text := NULLIF(p_payload->>'time_zone', '');
BEGIN
  PERFORM public.log_as(p_user);
  IF v_tz IS NOT NULL AND NOT EXISTS (SELECT 1 FROM pg_timezone_names WHERE name = v_tz) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_time_zone', 'field', 'time_zone');
  END IF;
  INSERT INTO log.profile (user_id) VALUES (p_user) ON CONFLICT (user_id) DO NOTHING;
  UPDATE log.profile SET
    display_name = COALESCE(NULLIF(left(p_payload->>'display_name', 80), ''), display_name),
    time_zone = COALESCE(v_tz, time_zone),
    start_weight_lb = COALESCE(NULLIF(p_payload->>'start_weight_lb', '')::numeric, start_weight_lb),
    goal_weight_lb = COALESCE(NULLIF(p_payload->>'goal_weight_lb', '')::numeric, goal_weight_lb),
    height_in = COALESCE(NULLIF(p_payload->>'height_in', '')::numeric, height_in),
    settings = CASE WHEN jsonb_typeof(p_payload->'settings') = 'object' THEN settings || (p_payload->'settings') ELSE settings END,
    onboarded_at = CASE WHEN (p_payload->>'done')::boolean IS TRUE THEN COALESCE(onboarded_at, now()) ELSE onboarded_at END,
    updated_at = now()
  WHERE user_id = p_user;
  RETURN jsonb_build_object('ok', true, 'action', 'account_setup');
EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range THEN
  RETURN jsonb_build_object('ok', false, 'error', 'validation_failed');
END $$;

DO $$
DECLARE f text;
BEGIN
  FOREACH f IN ARRAY ARRAY['public.log_as(uuid)', 'public.log_dashboard_payload_for(uuid)', 'public.log_write_for(uuid,text,jsonb)',
    'public.log_health_metrics_for(uuid,jsonb)', 'public.log_progress_photos_for(uuid)', 'public.log_progress_photo_save_for(uuid,jsonb)',
    'public.log_progress_photo_delete_for(uuid,jsonb)', 'public.log_claim_owner(uuid,text)', 'public.log_account_setup_for(uuid,jsonb)',
    'log.current_user_id()', 'log.current_tz()'] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role', f);
  END LOOP;
END $$;
