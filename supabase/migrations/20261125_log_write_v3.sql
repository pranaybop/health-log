-- Insert/upsert-only write path for the Log app. No deletes.
-- 2026-11-25: adds goal_set (daily calorie / protein targets), food_thought (one-tap
-- "thinking about food" log) and health_sync (Apple Health days, weigh-ins, body
-- composition and workouts from the iPhone app; inserts skip anything already logged).
-- Validates enums and ranges. Merges check-in fields on conflict so a 3-tap
-- does not wipe a later deep check-in, and vice versa.

CREATE OR REPLACE FUNCTION public.log_write(p_action text, p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_today date := (now() AT TIME ZONE 'America/Chicago')::date;
  v_day date;
  v_id uuid;
  v_at timestamptz;
  v_text text;
  v_num numeric;
  v_int integer;
  v_bool boolean;
  v_compound text;
  v_site text;
  v_next text;
  v_effect text;
  v_unit text;
  v_metric text;
  v_idx integer;
  v_sites constant text[] := ARRAY['Abd LR','Abd LL','Abd UR','Abd UL','Love L','Love R'];
  v_row jsonb;
  v_n1 integer := 0;
  v_n2 integer := 0;
  v_n3 integer := 0;
  v_n4 integer := 0;
BEGIN
  IF p_action IS NULL OR p_action = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_action', 'field', 'action');
  END IF;
  IF p_payload IS NULL OR jsonb_typeof(p_payload) <> 'object' THEN
    p_payload := '{}'::jsonb;
  END IF;

  CASE p_action
  WHEN 'checkin_upsert' THEN
    IF p_payload ? 'day' AND COALESCE(p_payload->>'day', '') <> '' THEN
      BEGIN
        v_day := (p_payload->>'day')::date;
      EXCEPTION WHEN others THEN
        RETURN jsonb_build_object('ok', false, 'error', 'invalid_date', 'field', 'day');
      END;
    ELSE
      v_day := v_today;
    END IF;
    IF v_day < DATE '2020-01-01' OR v_day > v_today + 7 THEN
      RETURN jsonb_build_object('ok', false, 'error', 'date_out_of_range', 'field', 'day');
    END IF;

    IF p_payload ? 'ate_vs_usual' AND COALESCE(p_payload->>'ate_vs_usual','') <> ''
       AND (p_payload->>'ate_vs_usual') NOT IN ('less','usual','more') THEN
      RETURN jsonb_build_object('ok', false, 'error', 'invalid_enum', 'field', 'ate_vs_usual');
    END IF;
    IF p_payload ? 'moved_vs_usual' AND COALESCE(p_payload->>'moved_vs_usual','') <> ''
       AND (p_payload->>'moved_vs_usual') NOT IN ('less','usual','more') THEN
      RETURN jsonb_build_object('ok', false, 'error', 'invalid_enum', 'field', 'moved_vs_usual');
    END IF;
    IF p_payload ? 'dose_feel' AND COALESCE(p_payload->>'dose_feel','') <> ''
       AND (p_payload->>'dose_feel') NOT IN ('strong','fading','not_feeling_it') THEN
      RETURN jsonb_build_object('ok', false, 'error', 'invalid_enum', 'field', 'dose_feel');
    END IF;

    INSERT INTO log.checkins (
      day, ate_vs_usual, moved_vs_usual, dose_feel,
      mood, food_noise, energy, sleep_quality,
      sleep_hours, exercise_minutes, steps, resting_hr, active_calories,
      earned, notes, source, logged_by, checked_in_at
    )
    VALUES (
      v_day,
      NULLIF(p_payload->>'ate_vs_usual',''),
      NULLIF(p_payload->>'moved_vs_usual',''),
      NULLIF(p_payload->>'dose_feel',''),
      CASE WHEN p_payload ? 'mood' AND COALESCE(p_payload->>'mood','') <> '' THEN (p_payload->>'mood')::integer END,
      CASE WHEN p_payload ? 'food_noise' AND COALESCE(p_payload->>'food_noise','') <> '' THEN (p_payload->>'food_noise')::integer END,
      CASE WHEN p_payload ? 'energy' AND COALESCE(p_payload->>'energy','') <> '' THEN (p_payload->>'energy')::integer END,
      CASE WHEN p_payload ? 'sleep_quality' AND COALESCE(p_payload->>'sleep_quality','') <> '' THEN (p_payload->>'sleep_quality')::integer END,
      CASE WHEN p_payload ? 'sleep_hours' AND COALESCE(p_payload->>'sleep_hours','') <> '' THEN (p_payload->>'sleep_hours')::numeric END,
      CASE WHEN p_payload ? 'exercise_minutes' AND COALESCE(p_payload->>'exercise_minutes','') <> '' THEN (p_payload->>'exercise_minutes')::integer END,
      CASE WHEN p_payload ? 'steps' AND COALESCE(p_payload->>'steps','') <> '' THEN (p_payload->>'steps')::integer END,
      CASE WHEN p_payload ? 'resting_hr' AND COALESCE(p_payload->>'resting_hr','') <> '' THEN (p_payload->>'resting_hr')::integer END,
      CASE WHEN p_payload ? 'active_calories' AND COALESCE(p_payload->>'active_calories','') <> '' THEN (p_payload->>'active_calories')::integer END,
      CASE WHEN p_payload ? 'earned' THEN (p_payload->>'earned')::boolean END,
      NULLIF(left(p_payload->>'notes', 2000), ''),
      COALESCE(NULLIF(p_payload->>'source',''), 'log-app'),
      'log-app',
      now()
    )
    ON CONFLICT (day) DO UPDATE SET
      ate_vs_usual = COALESCE(EXCLUDED.ate_vs_usual, log.checkins.ate_vs_usual),
      moved_vs_usual = COALESCE(EXCLUDED.moved_vs_usual, log.checkins.moved_vs_usual),
      dose_feel = COALESCE(EXCLUDED.dose_feel, log.checkins.dose_feel),
      mood = COALESCE(EXCLUDED.mood, log.checkins.mood),
      food_noise = COALESCE(EXCLUDED.food_noise, log.checkins.food_noise),
      energy = COALESCE(EXCLUDED.energy, log.checkins.energy),
      sleep_quality = COALESCE(EXCLUDED.sleep_quality, log.checkins.sleep_quality),
      sleep_hours = COALESCE(EXCLUDED.sleep_hours, log.checkins.sleep_hours),
      exercise_minutes = COALESCE(EXCLUDED.exercise_minutes, log.checkins.exercise_minutes),
      steps = COALESCE(EXCLUDED.steps, log.checkins.steps),
      resting_hr = COALESCE(EXCLUDED.resting_hr, log.checkins.resting_hr),
      active_calories = COALESCE(EXCLUDED.active_calories, log.checkins.active_calories),
      earned = COALESCE(EXCLUDED.earned, log.checkins.earned),
      notes = COALESCE(EXCLUDED.notes, log.checkins.notes),
      source = COALESCE(EXCLUDED.source, log.checkins.source),
      logged_by = 'log-app',
      checked_in_at = now();

    RETURN jsonb_build_object('ok', true, 'action', 'checkin_upsert', 'day', v_day);

  WHEN 'earn_it' THEN
    IF p_payload ? 'day' AND COALESCE(p_payload->>'day', '') <> '' THEN
      BEGIN
        v_day := (p_payload->>'day')::date;
      EXCEPTION WHEN others THEN
        RETURN jsonb_build_object('ok', false, 'error', 'invalid_date', 'field', 'day');
      END;
    ELSE
      v_day := v_today;
    END IF;
    IF v_day < DATE '2020-01-01' OR v_day > v_today + 7 THEN
      RETURN jsonb_build_object('ok', false, 'error', 'date_out_of_range', 'field', 'day');
    END IF;
    IF NOT (p_payload ? 'earned') THEN
      RETURN jsonb_build_object('ok', false, 'error', 'required', 'field', 'earned');
    END IF;
    v_bool := (p_payload->>'earned')::boolean;
    INSERT INTO log.checkins (day, earned, source, logged_by, checked_in_at)
    VALUES (v_day, v_bool, 'log-app', 'log-app', now())
    ON CONFLICT (day) DO UPDATE SET
      earned = EXCLUDED.earned,
      logged_by = 'log-app',
      checked_in_at = now();
    RETURN jsonb_build_object('ok', true, 'action', 'earn_it', 'day', v_day, 'earned', v_bool);

  WHEN 'weigh_in' THEN
    IF COALESCE(p_payload->>'weight_lb','') = '' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'required', 'field', 'weight_lb');
    END IF;
    BEGIN
      v_num := (p_payload->>'weight_lb')::numeric;
    EXCEPTION WHEN others THEN
      RETURN jsonb_build_object('ok', false, 'error', 'invalid_number', 'field', 'weight_lb');
    END;
    IF v_num < 50 OR v_num > 600 THEN
      RETURN jsonb_build_object('ok', false, 'error', 'out_of_range', 'field', 'weight_lb');
    END IF;
    IF p_payload ? 'measured_at' AND COALESCE(p_payload->>'measured_at','') <> '' THEN
      BEGIN
        v_at := (p_payload->>'measured_at')::timestamptz;
      EXCEPTION WHEN others THEN
        RETURN jsonb_build_object('ok', false, 'error', 'invalid_timestamp', 'field', 'measured_at');
      END;
    ELSE
      v_at := now();
    END IF;
    INSERT INTO log.weights (measured_at, weight_lb, notes)
    VALUES (v_at, v_num, NULLIF(left(p_payload->>'notes', 2000), ''))
    RETURNING id INTO v_id;
    RETURN jsonb_build_object('ok', true, 'action', 'weigh_in', 'id', v_id, 'weight_lb', v_num, 'measured_at', v_at);

  WHEN 'dose_log' THEN
    v_compound := lower(trim(COALESCE(p_payload->>'compound','')));
    IF v_compound NOT IN ('tirzepatide','retatrutide') THEN
      RETURN jsonb_build_object('ok', false, 'error', 'invalid_enum', 'field', 'compound');
    END IF;
    v_bool := COALESCE((p_payload->>'skipped')::boolean, false);
    v_num := NULL;
    IF NOT v_bool THEN
      IF COALESCE(p_payload->>'dose_mg','') = '' THEN
        RETURN jsonb_build_object('ok', false, 'error', 'required', 'field', 'dose_mg');
      END IF;
      BEGIN
        v_num := (p_payload->>'dose_mg')::numeric;
      EXCEPTION WHEN others THEN
        RETURN jsonb_build_object('ok', false, 'error', 'invalid_number', 'field', 'dose_mg');
      END;
      IF v_num < 0.05 OR v_num > 50 THEN
        RETURN jsonb_build_object('ok', false, 'error', 'out_of_range', 'field', 'dose_mg');
      END IF;
    ELSIF COALESCE(p_payload->>'dose_mg','') <> '' THEN
      BEGIN
        v_num := (p_payload->>'dose_mg')::numeric;
      EXCEPTION WHEN others THEN
        v_num := NULL;
      END;
    END IF;
    v_site := NULLIF(trim(p_payload->>'site'), '');
    IF v_site IS NOT NULL AND NOT (v_site = ANY (v_sites)) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'invalid_enum', 'field', 'site');
    END IF;
    IF p_payload ? 'taken_at' AND COALESCE(p_payload->>'taken_at','') <> '' THEN
      BEGIN
        v_at := (p_payload->>'taken_at')::timestamptz;
      EXCEPTION WHEN others THEN
        RETURN jsonb_build_object('ok', false, 'error', 'invalid_timestamp', 'field', 'taken_at');
      END;
    ELSE
      v_at := now();
    END IF;
    INSERT INTO log.doses (taken_at, compound, dose_mg, units, notes, site, skipped)
    VALUES (
      v_at,
      v_compound,
      v_num,
      CASE WHEN COALESCE(p_payload->>'units','') <> '' THEN (p_payload->>'units')::numeric END,
      NULLIF(left(p_payload->>'notes', 2000), ''),
      v_site,
      v_bool
    )
    RETURNING id INTO v_id;
    IF v_site IS NOT NULL AND NOT v_bool THEN
      v_idx := array_position(v_sites, v_site);
      IF v_idx IS NOT NULL THEN
        v_next := v_sites[1 + (v_idx % array_length(v_sites, 1))];
        UPDATE log.protocol
        SET next_site = v_next
        WHERE compound = v_compound AND status IN ('active','paused');
      END IF;
    END IF;
    RETURN jsonb_build_object('ok', true, 'action', 'dose_log', 'id', v_id, 'compound', v_compound, 'skipped', v_bool, 'site', v_site, 'taken_at', v_at);

  WHEN 'side_effect_upsert' THEN
    v_effect := trim(COALESCE(p_payload->>'effect',''));
    IF v_effect = '' OR length(v_effect) > 80 THEN
      RETURN jsonb_build_object('ok', false, 'error', 'invalid_text', 'field', 'effect');
    END IF;
    IF COALESCE(p_payload->>'severity','') = '' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'required', 'field', 'severity');
    END IF;
    BEGIN
      v_int := (p_payload->>'severity')::integer;
    EXCEPTION WHEN others THEN
      RETURN jsonb_build_object('ok', false, 'error', 'invalid_number', 'field', 'severity');
    END;
    IF v_int < 1 OR v_int > 10 THEN
      RETURN jsonb_build_object('ok', false, 'error', 'out_of_range', 'field', 'severity');
    END IF;
    IF p_payload ? 'recorded_on' AND COALESCE(p_payload->>'recorded_on','') <> '' THEN
      BEGIN
        v_day := (p_payload->>'recorded_on')::date;
      EXCEPTION WHEN others THEN
        RETURN jsonb_build_object('ok', false, 'error', 'invalid_date', 'field', 'recorded_on');
      END;
    ELSE
      v_day := v_today;
    END IF;
    IF v_day < DATE '2020-01-01' OR v_day > v_today + 1 THEN
      RETURN jsonb_build_object('ok', false, 'error', 'date_out_of_range', 'field', 'recorded_on');
    END IF;
    INSERT INTO log.side_effects (recorded_on, recorded_at, effect, severity, notes, logged_by)
    VALUES (v_day, now(), v_effect, v_int, NULLIF(left(p_payload->>'notes', 2000), ''), 'log-app')
    ON CONFLICT (recorded_on, effect) DO UPDATE SET
      severity = EXCLUDED.severity,
      notes = COALESCE(EXCLUDED.notes, log.side_effects.notes),
      recorded_at = now(),
      logged_by = 'log-app'
    RETURNING id INTO v_id;
    RETURN jsonb_build_object('ok', true, 'action', 'side_effect_upsert', 'id', v_id, 'recorded_on', v_day, 'effect', v_effect);

  WHEN 'measurement' THEN
    v_metric := lower(trim(COALESCE(p_payload->>'metric','')));
    v_metric := regexp_replace(v_metric, '[^a-z0-9 _-]', '', 'g');
    v_metric := NULLIF(left(v_metric, 40), '');
    IF v_metric IS NULL THEN
      RETURN jsonb_build_object('ok', false, 'error', 'invalid_text', 'field', 'metric');
    END IF;
    IF COALESCE(p_payload->>'value','') = '' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'required', 'field', 'value');
    END IF;
    BEGIN
      v_num := (p_payload->>'value')::numeric;
    EXCEPTION WHEN others THEN
      RETURN jsonb_build_object('ok', false, 'error', 'invalid_number', 'field', 'value');
    END;
    IF v_num < 0 OR v_num > 1000 THEN
      RETURN jsonb_build_object('ok', false, 'error', 'out_of_range', 'field', 'value');
    END IF;
    v_unit := COALESCE(NULLIF(trim(p_payload->>'unit'), ''), 'in');
    IF v_unit NOT IN ('in','cm','%','lb','kg','mm') THEN
      RETURN jsonb_build_object('ok', false, 'error', 'invalid_enum', 'field', 'unit');
    END IF;
    IF p_payload ? 'measured_at' AND COALESCE(p_payload->>'measured_at','') <> '' THEN
      BEGIN
        v_at := (p_payload->>'measured_at')::timestamptz;
      EXCEPTION WHEN others THEN
        RETURN jsonb_build_object('ok', false, 'error', 'invalid_timestamp', 'field', 'measured_at');
      END;
    ELSE
      v_at := now();
    END IF;
    INSERT INTO log.measurements (measured_at, metric, value, unit, notes, logged_by)
    VALUES (v_at, v_metric, v_num, v_unit, NULLIF(left(p_payload->>'notes', 2000), ''), 'log-app')
    RETURNING id INTO v_id;
    RETURN jsonb_build_object('ok', true, 'action', 'measurement', 'id', v_id, 'metric', v_metric);

  WHEN 'vial_start' THEN
    v_compound := lower(trim(COALESCE(p_payload->>'compound','')));
    IF v_compound NOT IN ('tirzepatide','retatrutide') THEN
      RETURN jsonb_build_object('ok', false, 'error', 'invalid_enum', 'field', 'compound');
    END IF;
    IF COALESCE(p_payload->>'total_mg','') = '' AND COALESCE(p_payload->>'total_units','') = '' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'required', 'field', 'total_mg');
    END IF;
    IF p_payload ? 'started_on' AND COALESCE(p_payload->>'started_on','') <> '' THEN
      BEGIN
        v_day := (p_payload->>'started_on')::date;
      EXCEPTION WHEN others THEN
        RETURN jsonb_build_object('ok', false, 'error', 'invalid_date', 'field', 'started_on');
      END;
    ELSE
      v_day := v_today;
    END IF;
    INSERT INTO log.vials (
      compound, label, started_on, opened_at,
      total_mg, remaining_mg, total_units, remaining_units,
      concentration_mg_per_ml, expired_on, notes, logged_by
    )
    VALUES (
      v_compound,
      NULLIF(left(trim(COALESCE(p_payload->>'label','')), 80), ''),
      v_day,
      now(),
      CASE WHEN COALESCE(p_payload->>'total_mg','') <> '' THEN (p_payload->>'total_mg')::numeric END,
      CASE WHEN COALESCE(p_payload->>'remaining_mg','') <> '' THEN (p_payload->>'remaining_mg')::numeric
           WHEN COALESCE(p_payload->>'total_mg','') <> '' THEN (p_payload->>'total_mg')::numeric END,
      CASE WHEN COALESCE(p_payload->>'total_units','') <> '' THEN (p_payload->>'total_units')::numeric END,
      CASE WHEN COALESCE(p_payload->>'remaining_units','') <> '' THEN (p_payload->>'remaining_units')::numeric
           WHEN COALESCE(p_payload->>'total_units','') <> '' THEN (p_payload->>'total_units')::numeric END,
      CASE WHEN COALESCE(p_payload->>'concentration_mg_per_ml','') <> '' THEN (p_payload->>'concentration_mg_per_ml')::numeric END,
      CASE WHEN COALESCE(p_payload->>'expired_on','') <> '' THEN (p_payload->>'expired_on')::date END,
      NULLIF(left(p_payload->>'notes', 2000), ''),
      'log-app'
    )
    RETURNING id INTO v_id;
    RETURN jsonb_build_object('ok', true, 'action', 'vial_start', 'id', v_id, 'compound', v_compound);

  WHEN 'profile_update' THEN
    UPDATE log.profile SET
      start_weight_lb = CASE WHEN COALESCE(p_payload->>'start_weight_lb','') <> '' THEN (p_payload->>'start_weight_lb')::numeric ELSE start_weight_lb END,
      goal_weight_lb = CASE WHEN p_payload ? 'goal_weight_lb' AND COALESCE(p_payload->>'goal_weight_lb','') <> '' THEN (p_payload->>'goal_weight_lb')::numeric
                            WHEN p_payload ? 'goal_weight_lb' AND p_payload->>'goal_weight_lb' = '' THEN NULL
                            ELSE goal_weight_lb END,
      height_in = CASE WHEN COALESCE(p_payload->>'height_in','') <> '' THEN (p_payload->>'height_in')::numeric ELSE height_in END,
      notes = COALESCE(NULLIF(left(p_payload->>'notes', 2000), ''), notes),
      updated_at = now()
    WHERE id = 1;
    RETURN jsonb_build_object('ok', true, 'action', 'profile_update');

  WHEN 'goal_set' THEN
    -- Daily calorie or protein target. Retires the current active target of the
    -- same kind (status only; the row stays) and inserts the new one.
    v_text := lower(trim(COALESCE(p_payload->>'kind','')));
    IF v_text NOT IN ('calories','protein') THEN
      RETURN jsonb_build_object('ok', false, 'error', 'invalid_enum', 'field', 'kind');
    END IF;
    IF COALESCE(p_payload->>'target','') = '' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'required', 'field', 'target');
    END IF;
    BEGIN
      v_num := (p_payload->>'target')::numeric;
    EXCEPTION WHEN others THEN
      RETURN jsonb_build_object('ok', false, 'error', 'invalid_number', 'field', 'target');
    END;
    IF (v_text = 'calories' AND (v_num < 800 OR v_num > 6000))
       OR (v_text = 'protein' AND (v_num < 20 OR v_num > 400)) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'out_of_range', 'field', 'target');
    END IF;
    v_unit := CASE v_text WHEN 'calories' THEN 'kcal' ELSE 'g' END;
    SELECT id INTO v_id FROM log.goals
    WHERE kind = v_text AND status = 'active' AND target = v_num
    ORDER BY created_at DESC
    LIMIT 1;
    IF v_id IS NOT NULL THEN
      RETURN jsonb_build_object('ok', true, 'action', 'goal_set', 'id', v_id, 'kind', v_text, 'target', v_num, 'unit', v_unit, 'unchanged', true);
    END IF;
    UPDATE log.goals SET status = 'retired'
    WHERE kind = v_text AND status = 'active';
    GET DIAGNOSTICS v_int = ROW_COUNT;
    INSERT INTO log.goals (kind, target, unit, notes, status)
    VALUES (v_text, v_num, v_unit, NULLIF(left(p_payload->>'notes', 2000), ''), 'active')
    RETURNING id INTO v_id;
    RETURN jsonb_build_object('ok', true, 'action', 'goal_set', 'id', v_id, 'kind', v_text, 'target', v_num, 'unit', v_unit, 'retired', v_int);

  WHEN 'food_thought' THEN
    IF COALESCE(p_payload->>'at','') <> '' THEN
      BEGIN
        v_at := (p_payload->>'at')::timestamptz;
      EXCEPTION WHEN others THEN
        RETURN jsonb_build_object('ok', false, 'error', 'invalid_timestamp', 'field', 'at');
      END;
      IF v_at < now() - interval '7 days' OR v_at > now() + interval '5 minutes' THEN
        RETURN jsonb_build_object('ok', false, 'error', 'out_of_range', 'field', 'at');
      END IF;
    ELSE
      v_at := now();
    END IF;
    v_int := NULL;
    IF COALESCE(p_payload->>'strength','') <> '' THEN
      v_int := (p_payload->>'strength')::integer;
      IF v_int < 1 OR v_int > 3 THEN
        RETURN jsonb_build_object('ok', false, 'error', 'out_of_range', 'field', 'strength');
      END IF;
    END IF;
    INSERT INTO log.food_thoughts (thought_at, strength, note, logged_by)
    VALUES (v_at, v_int, NULLIF(left(p_payload->>'note', 500), ''), 'log-app')
    RETURNING id INTO v_id;
    RETURN jsonb_build_object('ok', true, 'action', 'food_thought', 'id', v_id, 'at', v_at);

  WHEN 'health_sync' THEN
    -- Daily Apple Health totals: fill or refresh that day's row (fields not sent are kept).
    IF jsonb_typeof(p_payload->'days') = 'array' THEN
      IF jsonb_array_length(p_payload->'days') > 62 THEN
        RETURN jsonb_build_object('ok', false, 'error', 'too_many', 'field', 'days');
      END IF;
      FOR v_row IN SELECT value FROM jsonb_array_elements(p_payload->'days') LOOP
        BEGIN
          v_day := (v_row->>'day')::date;
        EXCEPTION WHEN others THEN
          RETURN jsonb_build_object('ok', false, 'error', 'invalid_date', 'field', 'days.day');
        END;
        IF v_day < DATE '2015-01-01' OR v_day > v_today + 1 THEN
          RETURN jsonb_build_object('ok', false, 'error', 'date_out_of_range', 'field', 'days.day');
        END IF;
        INSERT INTO log.daily_health (day, steps, distance_mi, active_kcal, exercise_min, stand_hours, resting_hr, hrv_ms, vo2max, sleep_hours, source, imported_at)
        VALUES (
          v_day,
          CASE WHEN COALESCE(v_row->>'steps','') <> '' THEN round((v_row->>'steps')::numeric)::integer END,
          CASE WHEN COALESCE(v_row->>'distance_mi','') <> '' THEN round((v_row->>'distance_mi')::numeric, 2) END,
          CASE WHEN COALESCE(v_row->>'active_kcal','') <> '' THEN round((v_row->>'active_kcal')::numeric)::integer END,
          CASE WHEN COALESCE(v_row->>'exercise_min','') <> '' THEN round((v_row->>'exercise_min')::numeric)::integer END,
          CASE WHEN COALESCE(v_row->>'stand_hours','') <> '' THEN round((v_row->>'stand_hours')::numeric)::integer END,
          CASE WHEN COALESCE(v_row->>'resting_hr','') <> '' THEN round((v_row->>'resting_hr')::numeric)::integer END,
          CASE WHEN COALESCE(v_row->>'hrv_ms','') <> '' THEN round((v_row->>'hrv_ms')::numeric)::integer END,
          CASE WHEN COALESCE(v_row->>'vo2max','') <> '' THEN round((v_row->>'vo2max')::numeric, 1) END,
          CASE WHEN COALESCE(v_row->>'sleep_hours','') <> '' THEN round((v_row->>'sleep_hours')::numeric, 2) END,
          'healthkit',
          now()
        )
        ON CONFLICT (day) DO UPDATE SET
          steps = COALESCE(EXCLUDED.steps, log.daily_health.steps),
          distance_mi = COALESCE(EXCLUDED.distance_mi, log.daily_health.distance_mi),
          active_kcal = COALESCE(EXCLUDED.active_kcal, log.daily_health.active_kcal),
          exercise_min = COALESCE(EXCLUDED.exercise_min, log.daily_health.exercise_min),
          stand_hours = COALESCE(EXCLUDED.stand_hours, log.daily_health.stand_hours),
          resting_hr = COALESCE(EXCLUDED.resting_hr, log.daily_health.resting_hr),
          hrv_ms = COALESCE(EXCLUDED.hrv_ms, log.daily_health.hrv_ms),
          vo2max = COALESCE(EXCLUDED.vo2max, log.daily_health.vo2max),
          sleep_hours = COALESCE(EXCLUDED.sleep_hours, log.daily_health.sleep_hours),
          source = 'healthkit',
          imported_at = now();
        v_n1 := v_n1 + 1;
      END LOOP;
    END IF;

    -- Weigh-ins from Apple Health: insert only, skipping any already logged within 2 minutes at the same weight.
    IF jsonb_typeof(p_payload->'weights') = 'array' THEN
      IF jsonb_array_length(p_payload->'weights') > 200 THEN
        RETURN jsonb_build_object('ok', false, 'error', 'too_many', 'field', 'weights');
      END IF;
      FOR v_row IN SELECT value FROM jsonb_array_elements(p_payload->'weights') LOOP
        v_at := (v_row->>'measured_at')::timestamptz;
        v_num := round((v_row->>'weight_lb')::numeric, 1);
        IF v_num BETWEEN 50 AND 600 AND v_at <= now() + interval '1 day'
           AND NOT EXISTS (
             SELECT 1 FROM log.weights w
             WHERE w.measured_at BETWEEN v_at - interval '2 minutes' AND v_at + interval '2 minutes'
               AND abs(w.weight_lb - v_num) < 0.15) THEN
          INSERT INTO log.weights (measured_at, weight_lb, notes) VALUES (v_at, v_num, 'Apple Health');
          v_n2 := v_n2 + 1;
        END IF;
      END LOOP;
    END IF;

    -- Body composition from Apple Health: insert only, one reading per metric and time.
    IF jsonb_typeof(p_payload->'body') = 'array' THEN
      IF jsonb_array_length(p_payload->'body') > 200 THEN
        RETURN jsonb_build_object('ok', false, 'error', 'too_many', 'field', 'body');
      END IF;
      FOR v_row IN SELECT value FROM jsonb_array_elements(p_payload->'body') LOOP
        v_metric := v_row->>'metric';
        IF v_metric NOT IN ('body_fat_pct', 'lean_mass_lb') THEN
          RETURN jsonb_build_object('ok', false, 'error', 'invalid_enum', 'field', 'body.metric');
        END IF;
        v_at := (v_row->>'measured_at')::timestamptz;
        v_num := round((v_row->>'value')::numeric, 1);
        IF ((v_metric = 'body_fat_pct' AND v_num BETWEEN 2 AND 75) OR (v_metric = 'lean_mass_lb' AND v_num BETWEEN 50 AND 400))
           AND v_at <= now() + interval '1 day'
           AND NOT EXISTS (
             SELECT 1 FROM log.measurements m
             WHERE m.metric = v_metric
               AND m.measured_at BETWEEN v_at - interval '2 minutes' AND v_at + interval '2 minutes') THEN
          INSERT INTO log.measurements (measured_at, metric, value, unit, notes, logged_by)
          VALUES (v_at, v_metric, v_num, CASE v_metric WHEN 'body_fat_pct' THEN '%' ELSE 'lb' END, 'Apple Health', 'healthkit');
          v_n3 := v_n3 + 1;
        END IF;
      END LOOP;
    END IF;

    -- Workouts from Apple Health: insert only, skipping any that start within a minute of a logged one of the same kind.
    IF jsonb_typeof(p_payload->'workouts') = 'array' THEN
      IF jsonb_array_length(p_payload->'workouts') > 100 THEN
        RETURN jsonb_build_object('ok', false, 'error', 'too_many', 'field', 'workouts');
      END IF;
      FOR v_row IN SELECT value FROM jsonb_array_elements(p_payload->'workouts') LOOP
        v_at := (v_row->>'started_at')::timestamptz;
        v_text := lower(left(trim(COALESCE(v_row->>'activity', 'other')), 60));
        IF v_at <= now() + interval '1 day'
           AND NOT EXISTS (
             SELECT 1 FROM log.workouts k
             WHERE k.activity = v_text
               AND k.started_at BETWEEN v_at - interval '1 minute' AND v_at + interval '1 minute') THEN
          INSERT INTO log.workouts (started_at, ended_at, activity, duration_min, distance_mi, active_kcal, avg_hr, max_hr, indoor, source)
          VALUES (
            v_at,
            CASE WHEN COALESCE(v_row->>'ended_at','') <> '' THEN (v_row->>'ended_at')::timestamptz END,
            v_text,
            CASE WHEN COALESCE(v_row->>'duration_min','') <> '' THEN round((v_row->>'duration_min')::numeric, 1) END,
            CASE WHEN COALESCE(v_row->>'distance_mi','') <> '' THEN round((v_row->>'distance_mi')::numeric, 2) END,
            CASE WHEN COALESCE(v_row->>'active_kcal','') <> '' THEN round((v_row->>'active_kcal')::numeric)::integer END,
            CASE WHEN COALESCE(v_row->>'avg_hr','') <> '' THEN round((v_row->>'avg_hr')::numeric)::integer END,
            CASE WHEN COALESCE(v_row->>'max_hr','') <> '' THEN round((v_row->>'max_hr')::numeric)::integer END,
            CASE WHEN COALESCE(v_row->>'indoor','') <> '' THEN (v_row->>'indoor')::boolean END,
            'Apple Health'
          )
          ON CONFLICT (started_at, activity, source) DO NOTHING;
          v_n4 := v_n4 + 1;
        END IF;
      END LOOP;
    END IF;

    RETURN jsonb_build_object('ok', true, 'action', 'health_sync', 'days', v_n1, 'weights', v_n2, 'body', v_n3, 'workouts', v_n4);

  ELSE
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_action', 'field', 'action');
  END CASE;

EXCEPTION
  WHEN check_violation OR invalid_text_representation OR numeric_value_out_of_range OR datetime_field_overflow THEN
    RETURN jsonb_build_object('ok', false, 'error', 'validation_failed');
  WHEN others THEN
    RAISE;
END;
$$;

REVOKE ALL ON FUNCTION public.log_write(text, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.log_write(text, jsonb) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.log_write(text, jsonb) TO service_role;
