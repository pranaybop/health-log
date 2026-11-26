-- Accounts, part 2
-- - log_meal_for: meals logged in the app (people without the Grok bot describe a meal, their own
--   AI key turns it into items, they review and save). One call saves all items of one meal.
--   p_user null means the owner (passcode or bot callers).
-- - log_claim_owner gains p_by_passcode: the owner can link a new sign-in to the existing data by
--   entering the passcode once, instead of relying on the sign-in email matching.

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

DROP FUNCTION IF EXISTS public.log_claim_owner(uuid, text);
CREATE OR REPLACE FUNCTION public.log_claim_owner(p_user uuid, p_email text, p_by_passcode boolean DEFAULT false) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE o log.owner%ROWTYPE; t text; n bigint := 0; c bigint;
BEGIN
  SELECT * INTO o FROM log.owner WHERE singleton FOR UPDATE;
  IF o.claimed_at IS NOT NULL THEN
    RETURN jsonb_build_object('ok', true, 'owner', o.user_id = p_user, 'claimed', false);
  END IF;
  IF NOT p_by_passcode AND lower(coalesce(p_email, '')) <> lower(o.email) THEN
    RETURN jsonb_build_object('ok', true, 'owner', false, 'claimed', false);
  END IF;
  IF EXISTS (SELECT 1 FROM log.profile WHERE user_id = p_user) OR EXISTS (SELECT 1 FROM log.weights WHERE user_id = p_user) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'account_has_data');
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

REVOKE ALL ON FUNCTION public.log_meal_for(uuid, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.log_meal_for(uuid, jsonb) TO service_role;
REVOKE ALL ON FUNCTION public.log_claim_owner(uuid, text, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.log_claim_owner(uuid, text, boolean) TO service_role;
