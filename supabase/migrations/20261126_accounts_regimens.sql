-- Accounts, part 5: people set up their own medications.
-- - semaglutide joins tirzepatide, retatrutide and tesamorelin wherever a compound is checked.
-- - log_regimen_set_for adds a schedule (first run or Meds). log_regimen_end_for ends one;
--   the row stays, only its status (done) and end date change.

ALTER TABLE log.doses DROP CONSTRAINT doses_compound_check,
  ADD CONSTRAINT doses_compound_check CHECK (compound IS NULL OR compound IN ('tirzepatide','retatrutide','semaglutide','tesamorelin'));
ALTER TABLE log.regimen DROP CONSTRAINT regimen_compound_check,
  ADD CONSTRAINT regimen_compound_check CHECK (compound IN ('tirzepatide','retatrutide','semaglutide','tesamorelin'));
ALTER TABLE log.dose_plan DROP CONSTRAINT dose_plan_compound_check,
  ADD CONSTRAINT dose_plan_compound_check CHECK (compound IN ('tirzepatide','retatrutide','semaglutide'));

DO $$
DECLARE d text := pg_get_functiondef('public.log_write(text,jsonb)'::regprocedure); n int;
BEGIN
  n := (SELECT count(*) FROM regexp_matches(d, 'IN \(''tirzepatide'',''retatrutide'',''tesamorelin''\)', 'g'));
  IF n <> 2 THEN RAISE EXCEPTION 'compound patch: expected 2 matches, found %', n; END IF;
  d := replace(d, 'IN (''tirzepatide'',''retatrutide'',''tesamorelin'')', 'IN (''tirzepatide'',''retatrutide'',''semaglutide'',''tesamorelin'')');
  EXECUTE d;
END $$;

CREATE OR REPLACE FUNCTION public.log_regimen_set_for(p_user uuid, p_payload jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
  v_compound text := p_payload->>'compound';
  v_dose numeric := NULLIF(p_payload->>'dose_mg', '')::numeric;
  v_units numeric := NULLIF(p_payload->>'units', '')::numeric;
  v_every int := COALESCE(NULLIF(p_payload->>'every_days', '')::int, 7);
  v_on int := NULLIF(p_payload->>'days_on', '')::int;
  v_off int := NULLIF(p_payload->>'days_off', '')::int;
  v_time text := NULLIF(p_payload->>'time_of_day', '');
  v_start date := NULLIF(p_payload->>'start_on', '')::date;
  v_end date := NULLIF(p_payload->>'end_on', '')::date;
  v_conc numeric := NULLIF(p_payload->>'concentration_mg_per_ml', '')::numeric;
  v_sites text;
  v_id uuid;
BEGIN
  PERFORM public.log_as(p_user);
  v_start := COALESCE(v_start, (now() AT TIME ZONE log.current_tz())::date);
  IF v_compound IS NULL OR v_compound NOT IN ('tirzepatide','retatrutide','semaglutide','tesamorelin') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_enum', 'field', 'compound');
  END IF;
  IF v_dose IS NULL OR v_dose < 0.05 OR v_dose > 50 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'out_of_range', 'field', 'dose_mg');
  END IF;
  IF v_units IS NOT NULL AND (v_units < 0 OR v_units > 1000) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'out_of_range', 'field', 'units');
  END IF;
  IF v_every < 1 OR v_every > 28 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'out_of_range', 'field', 'every_days');
  END IF;
  IF (v_on IS NOT NULL AND (v_on < 1 OR v_on > 28)) OR (v_off IS NOT NULL AND (v_off < 1 OR v_off > 28)) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'out_of_range', 'field', 'days_on');
  END IF;
  IF v_time IS NOT NULL AND v_time NOT IN ('morning', 'evening', 'night') THEN v_time := NULL; END IF;
  IF v_end IS NOT NULL AND v_end < v_start THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_date', 'field', 'end_on');
  END IF;
  IF v_conc IS NOT NULL AND (v_conc <= 0 OR v_conc > 1000) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'out_of_range', 'field', 'concentration_mg_per_ml');
  END IF;
  IF jsonb_typeof(p_payload->'sites') = 'array' THEN
    SELECT string_agg(s, ', ') INTO v_sites FROM jsonb_array_elements_text(p_payload->'sites') s
    WHERE s IN ('Abd LR', 'Abd LL', 'Abd UR', 'Abd UL', 'Love L', 'Love R');
  END IF;
  INSERT INTO log.regimen (user_id, compound, display_name, dose_mg, units, every_days, days_on, days_off, time_of_day,
                           start_on, end_on, concentration_mg_per_ml, sites, status, notes, source)
  VALUES (log.current_user_id(), v_compound, NULLIF(left(p_payload->>'display_name', 60), ''), v_dose, v_units, v_every,
          v_on, v_off, v_time, v_start, v_end, v_conc, v_sites,
          CASE WHEN v_start > (now() AT TIME ZONE log.current_tz())::date THEN 'planned' ELSE 'active' END, NULLIF(left(p_payload->>'notes', 500), ''), 'app')
  RETURNING id INTO v_id;
  RETURN jsonb_build_object('ok', true, 'action', 'regimen_set', 'id', v_id);
EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range OR invalid_datetime_format OR datetime_field_overflow OR check_violation THEN
  RETURN jsonb_build_object('ok', false, 'error', 'validation_failed');
END $$;

CREATE OR REPLACE FUNCTION public.log_regimen_end_for(p_user uuid, p_payload jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE v_id uuid := NULLIF(p_payload->>'id', '')::uuid; n int;
BEGIN
  PERFORM public.log_as(p_user);
  UPDATE log.regimen SET status = 'done',
    end_on = GREATEST(start_on, LEAST(COALESCE(end_on, (now() AT TIME ZONE log.current_tz())::date), (now() AT TIME ZONE log.current_tz())::date))
  WHERE id = v_id AND user_id = log.current_user_id() AND status IN ('active', 'planned', 'paused');
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n = 0 THEN RETURN jsonb_build_object('ok', false, 'error', 'not_found', 'field', 'id'); END IF;
  RETURN jsonb_build_object('ok', true, 'action', 'regimen_end', 'id', v_id);
EXCEPTION WHEN invalid_text_representation THEN
  RETURN jsonb_build_object('ok', false, 'error', 'invalid_id', 'field', 'id');
END $$;

REVOKE ALL ON FUNCTION public.log_regimen_set_for(uuid, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.log_regimen_set_for(uuid, jsonb) TO service_role;
REVOKE ALL ON FUNCTION public.log_regimen_end_for(uuid, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.log_regimen_end_for(uuid, jsonb) TO service_role;
