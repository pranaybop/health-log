-- Accounts, part 4: the per-user entry points also serve the owner. A null p_user means the
-- caller used the passcode or the bot token, and the owner is used (log.current_user_id()'s fallback).
CREATE OR REPLACE FUNCTION public.log_as(p_user uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
BEGIN
  PERFORM set_config('log.user_id', COALESCE(p_user::text, ''), true);
END $$;

CREATE OR REPLACE FUNCTION public.log_account_setup_for(p_user uuid, p_payload jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_tz text := NULLIF(p_payload->>'time_zone', ''); v_user uuid;
BEGIN
  PERFORM public.log_as(p_user);
  v_user := log.current_user_id();
  IF v_tz IS NOT NULL AND NOT EXISTS (SELECT 1 FROM pg_timezone_names WHERE name = v_tz) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_time_zone', 'field', 'time_zone');
  END IF;
  INSERT INTO log.profile (user_id) VALUES (v_user) ON CONFLICT (user_id) DO NOTHING;
  UPDATE log.profile SET
    display_name = COALESCE(NULLIF(left(p_payload->>'display_name', 80), ''), display_name),
    time_zone = COALESCE(v_tz, time_zone),
    start_weight_lb = COALESCE(NULLIF(p_payload->>'start_weight_lb', '')::numeric, start_weight_lb),
    goal_weight_lb = COALESCE(NULLIF(p_payload->>'goal_weight_lb', '')::numeric, goal_weight_lb),
    height_in = COALESCE(NULLIF(p_payload->>'height_in', '')::numeric, height_in),
    settings = CASE WHEN jsonb_typeof(p_payload->'settings') = 'object' THEN settings || (p_payload->'settings') ELSE settings END,
    onboarded_at = CASE WHEN (p_payload->>'done')::boolean IS TRUE THEN COALESCE(onboarded_at, now()) ELSE onboarded_at END,
    updated_at = now()
  WHERE user_id = v_user;
  RETURN jsonb_build_object('ok', true, 'action', 'account_setup');
EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range THEN
  RETURN jsonb_build_object('ok', false, 'error', 'validation_failed');
END $$;
CREATE OR REPLACE FUNCTION public.log_meal_for(p_user uuid, p_payload jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
  v_items jsonb := p_payload->'items';
  v_type text := NULLIF(p_payload->>'meal_type', '');
  v_at timestamptz := COALESCE(NULLIF(p_payload->>'eaten_at', '')::timestamptz, now());
  v_source text := COALESCE(NULLIF(p_payload->>'source', ''), 'app');
  v_note text := NULLIF(left(p_payload->>'notes', 500), '');
  it jsonb; v_ids uuid[] := '{}'; v_id uuid; v_kcal numeric := 0; v_user uuid;
BEGIN
  PERFORM public.log_as(p_user);
  v_user := log.current_user_id();
  IF jsonb_typeof(v_items) <> 'array' OR jsonb_array_length(v_items) NOT BETWEEN 1 AND 30 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'validation_failed', 'field', 'items');
  END IF;
  IF v_type IS NOT NULL AND v_type NOT IN ('breakfast', 'lunch', 'dinner', 'snack') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'validation_failed', 'field', 'meal_type');
  END IF;
  IF v_at > now() + interval '1 hour' OR v_at < now() - interval '7 days' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'validation_failed', 'field', 'eaten_at');
  END IF;
  IF v_source NOT IN ('app', 'app-ai') THEN v_source := 'app'; END IF;
  FOR it IN SELECT * FROM jsonb_array_elements(v_items) LOOP
    IF NULLIF(btrim(it->>'item'), '') IS NULL OR length(it->>'item') > 200
       OR COALESCE((it->>'calories')::numeric, 0) NOT BETWEEN 0 AND 5000
       OR COALESCE((it->>'protein_g')::numeric, 0) NOT BETWEEN 0 AND 500
       OR COALESCE((it->>'carbs_g')::numeric, 0) NOT BETWEEN 0 AND 1000
       OR COALESCE((it->>'fat_g')::numeric, 0) NOT BETWEEN 0 AND 500
       OR COALESCE((it->>'fiber_g')::numeric, 0) NOT BETWEEN 0 AND 200 THEN
      RETURN jsonb_build_object('ok', false, 'error', 'validation_failed', 'field', 'items');
    END IF;
  END LOOP;
  FOR it IN SELECT * FROM jsonb_array_elements(v_items) LOOP
    INSERT INTO log.meals (user_id, eaten_at, meal_type, item, quantity, calories, protein_g, carbs_g, fat_g, fiber_g, source, notes, logged_by)
    VALUES (v_user, v_at, v_type, btrim(it->>'item'), NULLIF(left(it->>'quantity', 100), ''),
            (it->>'calories')::numeric, (it->>'protein_g')::numeric, (it->>'carbs_g')::numeric,
            (it->>'fat_g')::numeric, (it->>'fiber_g')::numeric, v_source, v_note, 'app')
    RETURNING id INTO v_id;
    v_ids := v_ids || v_id;
    v_kcal := v_kcal + COALESCE((it->>'calories')::numeric, 0);
  END LOOP;
  RETURN jsonb_build_object('ok', true, 'action', 'meal_log', 'ids', to_jsonb(v_ids), 'calories', v_kcal);
EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range OR invalid_datetime_format OR datetime_field_overflow THEN
  RETURN jsonb_build_object('ok', false, 'error', 'validation_failed');
END $$;
