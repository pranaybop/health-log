-- 2026-11-25: every other daily Apple Health number (heart rate, blood oxygen, respiratory
-- rate, blood pressure, glucose, temperatures, flights, cycling, basal energy, mindful
-- minutes, water, dietary energy, state of mind, height). One row per day and metric;
-- a sync refreshes that day's value, as it does for log.daily_health.
-- Also adds health_metrics (last 120 days, {metric: [[day, value], ...]}) to the payload;
-- the full payload function as applied is in 20261125_food_thoughts_and_payload.sql plus
-- the 'health_metrics' key after 'daily_health'.

CREATE TABLE IF NOT EXISTS log.health_metrics (
  day date NOT NULL,
  metric text NOT NULL CHECK (metric ~ '^[a-z0-9_]{2,40}$'),
  value numeric NOT NULL,
  unit text,
  source text NOT NULL DEFAULT 'healthkit',
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (day, metric)
);
ALTER TABLE log.health_metrics ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON log.health_metrics FROM PUBLIC;
REVOKE ALL ON log.health_metrics FROM anon, authenticated;

CREATE OR REPLACE FUNCTION public.log_health_metrics(p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_today date := (now() AT TIME ZONE 'America/Chicago')::date;
  v_row jsonb;
  v_day date;
  v_n integer := 0;
BEGIN
  IF p_payload IS NULL OR jsonb_typeof(p_payload->'metrics') IS DISTINCT FROM 'array' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'required', 'field', 'metrics');
  END IF;
  IF jsonb_array_length(p_payload->'metrics') > 800 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'too_many', 'field', 'metrics');
  END IF;
  FOR v_row IN SELECT value FROM jsonb_array_elements(p_payload->'metrics') LOOP
    v_day := (v_row->>'day')::date;
    IF v_day < DATE '2015-01-01' OR v_day > v_today + 1 THEN
      RETURN jsonb_build_object('ok', false, 'error', 'date_out_of_range', 'field', 'metrics.day');
    END IF;
    INSERT INTO log.health_metrics (day, metric, value, unit, source, updated_at)
    VALUES (v_day, v_row->>'metric', round((v_row->>'value')::numeric, 3), NULLIF(left(COALESCE(v_row->>'unit', ''), 12), ''), 'healthkit', now())
    ON CONFLICT (day, metric) DO UPDATE SET
      value = EXCLUDED.value,
      unit = EXCLUDED.unit,
      source = 'healthkit',
      updated_at = now();
    v_n := v_n + 1;
  END LOOP;
  RETURN jsonb_build_object('ok', true, 'action', 'health_metrics', 'metrics', v_n);
EXCEPTION
  WHEN check_violation OR invalid_text_representation OR numeric_value_out_of_range OR datetime_field_overflow OR not_null_violation THEN
    RETURN jsonb_build_object('ok', false, 'error', 'validation_failed');
END;
$$;

REVOKE ALL ON FUNCTION public.log_health_metrics(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.log_health_metrics(jsonb) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.log_health_metrics(jsonb) TO service_role;
