-- Daily (and other non-weekly) peptide regimens, starting with tesamorelin.
-- log.dose_plan stays the week-by-week GLP-1 plan; log.regimen holds a repeating schedule:
-- a compound, a dose, how often, and from/to dates. The app expands it into planned days.
--
-- Also lets tesamorelin doses and vials be logged (log.doses check and log_write's compound
-- checks), and adds 'regimens' to the dashboard payload.
-- The personal regimen rows are inserted separately and are not part of this public file.

CREATE TABLE IF NOT EXISTS log.regimen (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  compound text NOT NULL CHECK (compound IN ('tirzepatide', 'retatrutide', 'tesamorelin')),
  display_name text,
  dose_mg numeric CHECK (dose_mg IS NULL OR (dose_mg > 0 AND dose_mg <= 50)),
  units numeric CHECK (units IS NULL OR (units >= 0 AND units <= 1000)),
  every_days integer NOT NULL DEFAULT 1 CHECK (every_days BETWEEN 1 AND 28),
  days_on integer CHECK (days_on IS NULL OR days_on BETWEEN 1 AND 28),
  days_off integer CHECK (days_off IS NULL OR days_off BETWEEN 1 AND 28),
  time_of_day text CHECK (time_of_day IS NULL OR time_of_day IN ('morning', 'evening', 'night')),
  start_on date NOT NULL,
  end_on date CHECK (end_on IS NULL OR end_on >= start_on),
  concentration_mg_per_ml numeric CHECK (concentration_mg_per_ml IS NULL OR concentration_mg_per_ml > 0),
  sites text,
  status text NOT NULL DEFAULT 'planned' CHECK (status IN ('planned', 'active', 'paused', 'done')),
  notes text,
  source text,
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE log.regimen ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON log.regimen FROM PUBLIC, anon, authenticated;

COMMENT ON TABLE log.regimen IS
  'Repeating peptide schedules (daily tesamorelin and the like). every_days: 1 = daily, 7 = weekly. days_on/days_off: cycles such as 5 on, 2 off.';

ALTER TABLE log.doses DROP CONSTRAINT IF EXISTS doses_compound_check;
ALTER TABLE log.doses ADD CONSTRAINT doses_compound_check
  CHECK (compound IS NULL OR compound IN ('tirzepatide', 'retatrutide', 'tesamorelin'));

-- log_write: accept tesamorelin for dose_log and vial_start (the only two compound checks).
DO $$
DECLARE
  d text := pg_get_functiondef('public.log_write(text,jsonb)'::regprocedure);
  old_list text := $q$IN ('tirzepatide','retatrutide')$q$;
  new_list text := $q$IN ('tirzepatide','retatrutide','tesamorelin')$q$;
BEGIN
  IF strpos(d, new_list) = 0 THEN
    EXECUTE replace(d, old_list, new_list);
  END IF;
END $$;

-- Dashboard payload: add 'regimens' (before 'goals').
DO $$
DECLARE
  d text := pg_get_functiondef('public.log_dashboard_payload()'::regprocedure);
  anchor text := $q$'goals', COALESCE($q$;
  added text := $q$'regimens', COALESCE((SELECT jsonb_agg(row_to_json(t) ORDER BY t.start_on) FROM (
      SELECT id, compound, display_name, dose_mg, units, every_days, days_on, days_off, time_of_day, start_on, end_on,
             concentration_mg_per_ml, sites, status, notes FROM log.regimen) t), '[]'::jsonb),
    $q$;
BEGIN
  IF strpos(d, $q$'regimens'$q$) = 0 THEN
    IF strpos(d, anchor) = 0 THEN
      RAISE EXCEPTION 'log_dashboard_payload: anchor not found';
    END IF;
    EXECUTE replace(d, anchor, added || anchor);
  END IF;
END $$;
