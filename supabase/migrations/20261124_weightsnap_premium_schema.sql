-- Additive WeightSnap-parity schema for log.
-- Does not delete or rewrite existing meal, weight, dose, or health rows.
-- The only update of existing rows is filling log.doses.site from notes.

CREATE TABLE log.checkins (
  day date PRIMARY KEY,
  ate_vs_usual text CHECK (ate_vs_usual IS NULL OR ate_vs_usual = ANY (ARRAY['less','usual','more'])),
  moved_vs_usual text CHECK (moved_vs_usual IS NULL OR moved_vs_usual = ANY (ARRAY['less','usual','more'])),
  dose_feel text CHECK (dose_feel IS NULL OR dose_feel = ANY (ARRAY['strong','fading','not_feeling_it'])),
  mood integer CHECK (mood IS NULL OR (mood >= 1 AND mood <= 10)),
  food_noise integer CHECK (food_noise IS NULL OR (food_noise >= 1 AND food_noise <= 10)),
  energy integer CHECK (energy IS NULL OR (energy >= 1 AND energy <= 10)),
  sleep_quality integer CHECK (sleep_quality IS NULL OR (sleep_quality >= 1 AND sleep_quality <= 10)),
  sleep_hours numeric,
  exercise_minutes integer,
  steps integer,
  resting_hr integer,
  active_calories integer,
  earned boolean,
  notes text,
  source text,
  logged_by text DEFAULT 'log-app',
  checked_in_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE log.checkins IS 'Daily check-in (America/Chicago date). Earn It is the earned flag.';

CREATE TABLE log.side_effects (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  recorded_on date NOT NULL,
  recorded_at timestamptz NOT NULL DEFAULT now(),
  effect text NOT NULL,
  severity integer NOT NULL CHECK (severity >= 1 AND severity <= 10),
  notes text,
  logged_by text DEFAULT 'log-app',
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (recorded_on, effect)
);
COMMENT ON TABLE log.side_effects IS 'One row per side effect per calendar day.';

ALTER TABLE log.doses ADD COLUMN IF NOT EXISTS site text;
ALTER TABLE log.doses ADD COLUMN IF NOT EXISTS skipped boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN log.doses.site IS 'Injection site code, e.g. Abd LR, Love L.';
COMMENT ON COLUMN log.doses.skipped IS 'True when a scheduled dose was skipped.';

UPDATE log.doses
SET site = TRIM(SUBSTRING(notes FROM 'site[[:space:]]+([^;]+)'))
WHERE site IS NULL
  AND notes ~* 'site[[:space:]]+[^;]';

CREATE TABLE log.protocol (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  compound text NOT NULL,
  display_name text,
  typical_dose_mg numeric,
  units numeric,
  frequency text,
  status text NOT NULL CHECK (status = ANY (ARRAY['active','paused','retired','as_needed'])),
  half_life_hours numeric,
  started_on date,
  next_site text,
  notes text,
  created_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE log.protocol IS 'Medication protocol: active, planned, retired, or as needed.';

INSERT INTO log.protocol (compound, display_name, typical_dose_mg, units, frequency, status, half_life_hours, started_on, next_site, notes)
VALUES
  ('tirzepatide', 'Tirzepatide', 3, NULL, 'weekly', 'active', 120, '2026-11-02', 'Love R', 'Started 2 mg weekly on Nov 2, increased to 3 mg on Nov 22. Next site after Love L is Love R.'),
  ('retatrutide', 'Retatrutide', NULL, 20, 'weekly', 'paused', 144, '2026-12-06', NULL, 'Planned start Sunday Dec 6, 2026. Mix the vial with 1 mL, then take 20 units. Do not overlap with tirzepatide. typical_dose_mg left null until the mg equivalent is known.');

CREATE TABLE log.vials (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  compound text NOT NULL,
  label text,
  started_on date,
  opened_at timestamptz,
  total_mg numeric,
  remaining_mg numeric,
  total_units numeric,
  remaining_units numeric,
  concentration_mg_per_ml numeric,
  expired_on date,
  notes text,
  logged_by text DEFAULT 'log-app',
  created_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE log.vials IS 'Vial inventory for supply runway.';

CREATE TABLE log.measurements (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  measured_at timestamptz NOT NULL DEFAULT now(),
  metric text NOT NULL,
  value numeric NOT NULL,
  unit text NOT NULL DEFAULT 'in',
  notes text,
  logged_by text DEFAULT 'log-app',
  created_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE log.measurements IS 'Body measurements (waist, chest, hip, neck, etc.).';

CREATE TABLE log.profile (
  id integer PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  start_weight_lb numeric,
  goal_weight_lb numeric,
  height_in numeric,
  notes text,
  updated_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE log.profile IS 'Single-row profile for journey start and goal.';

INSERT INTO log.profile (id, start_weight_lb, goal_weight_lb, height_in, notes)
VALUES (1, 253.1, 235, NULL, 'Start weight from the WeightSnap report as of Nov 24, 2026. Goal 235 lb by Jan 1, 2027, set Nov 1.');

CREATE TABLE log.goals (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kind text NOT NULL,
  target numeric,
  unit text,
  due_on date,
  notes text,
  status text NOT NULL DEFAULT 'active' CHECK (status = ANY (ARRAY['active','paused','met','retired'])),
  created_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE log.goals IS 'Optional targets (weight, protein, steps, etc.).';

INSERT INTO log.goals (kind, target, unit, due_on, notes, status)
VALUES ('weight', 235, 'lb', '2027-01-01', 'Weight goal set Nov 1, 2026.', 'active');

CREATE TABLE log.progress_photos (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  taken_at timestamptz,
  storage_path text,
  notes text,
  logged_by text DEFAULT 'log-app',
  created_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE log.progress_photos IS 'Optional photo metadata. Private Storage bucket is not wired up yet.';

-- Privileges: service_role only, same pattern as existing log tables.
DO $$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'checkins','side_effects','protocol','vials','measurements','profile','goals','progress_photos'
  ]
  LOOP
    EXECUTE format('ALTER TABLE log.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('REVOKE ALL ON TABLE log.%I FROM PUBLIC, anon, authenticated', t);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, REFERENCES, TRIGGER, TRUNCATE, DELETE ON TABLE log.%I TO postgres, service_role', t);
  END LOOP;
END $$;

GRANT USAGE ON SCHEMA log TO service_role, postgres;
