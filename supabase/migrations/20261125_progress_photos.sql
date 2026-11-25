-- Progress photos: link a private image to a weigh-in.
-- Apply this in the Supabase SQL editor (or `supabase db push`). Do not run it from the app.
-- After it succeeds, deploy the log-dashboard and log-write Edge Functions.
--
-- The bucket is private (public = false). storage.objects already has RLS on.
-- anon and authenticated have no access to this bucket. The Edge Functions use the
-- service role, which bypasses RLS, and hand the phone a short-lived signed URL.

ALTER TABLE log.progress_photos
  ADD COLUMN IF NOT EXISTS weight_lb numeric,
  ADD COLUMN IF NOT EXISTS day date,
  ADD COLUMN IF NOT EXISTS weight_id uuid,
  ADD COLUMN IF NOT EXISTS content_type text NOT NULL DEFAULT 'image/jpeg',
  ADD COLUMN IF NOT EXISTS byte_size integer;

ALTER TABLE log.progress_photos DROP CONSTRAINT IF EXISTS progress_photos_weight_lb_check;
ALTER TABLE log.progress_photos
  ADD CONSTRAINT progress_photos_weight_lb_check
  CHECK (weight_lb IS NULL OR (weight_lb >= 50 AND weight_lb <= 600));

ALTER TABLE log.progress_photos DROP CONSTRAINT IF EXISTS progress_photos_byte_size_check;
ALTER TABLE log.progress_photos
  ADD CONSTRAINT progress_photos_byte_size_check
  CHECK (byte_size IS NULL OR (byte_size > 0 AND byte_size <= 2097152));

ALTER TABLE log.progress_photos DROP CONSTRAINT IF EXISTS progress_photos_content_type_check;
ALTER TABLE log.progress_photos
  ADD CONSTRAINT progress_photos_content_type_check
  CHECK (content_type = 'image/jpeg');

ALTER TABLE log.progress_photos DROP CONSTRAINT IF EXISTS progress_photos_storage_path_check;
ALTER TABLE log.progress_photos
  ADD CONSTRAINT progress_photos_storage_path_check
  CHECK (
    storage_path IS NULL
    OR storage_path ~ '^[0-9]{4}/[0-9]{2}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jpg$'
  );

ALTER TABLE log.progress_photos DROP CONSTRAINT IF EXISTS progress_photos_weight_id_fkey;
ALTER TABLE log.progress_photos
  ADD CONSTRAINT progress_photos_weight_id_fkey
  FOREIGN KEY (weight_id) REFERENCES log.weights (id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS progress_photos_taken_at_idx
  ON log.progress_photos (taken_at DESC NULLS LAST, created_at DESC);

CREATE UNIQUE INDEX IF NOT EXISTS progress_photos_storage_path_uidx
  ON log.progress_photos (storage_path);

COMMENT ON TABLE log.progress_photos IS
  'Progress photo metadata linked to a weigh-in. Bytes live in the private progress-photos Storage bucket. Clients only receive short-lived signed URLs.';
COMMENT ON COLUMN log.progress_photos.weight_lb IS 'Weight of the weigh-in this photo belongs to, in pounds.';
COMMENT ON COLUMN log.progress_photos.day IS 'America/Chicago calendar day of the weigh-in.';
COMMENT ON COLUMN log.progress_photos.weight_id IS 'log.weights row this photo was taken with, when it is still there.';
COMMENT ON COLUMN log.progress_photos.storage_path IS 'Object name inside the private progress-photos bucket. Not a public URL.';

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types, type)
VALUES (
  'progress-photos',
  'progress-photos',
  false,
  2097152,
  ARRAY['image/jpeg']::text[],
  'STANDARD'::storage.buckettype
)
ON CONFLICT (id) DO UPDATE SET
  public = false,
  file_size_limit = EXCLUDED.file_size_limit,
  allowed_mime_types = EXCLUDED.allowed_mime_types,
  type = EXCLUDED.type;

-- Restrictive policies are AND-ed with any later permissive policy, so a broad
-- "authenticated can read storage" policy still cannot see this bucket.
-- Signed URLs are minted by the service role inside the Edge Functions and do not
-- need a permissive policy. No policy here grants access.

DROP POLICY IF EXISTS progress_photos_block_select ON storage.objects;
CREATE POLICY progress_photos_block_select
  ON storage.objects
  AS RESTRICTIVE
  FOR SELECT
  TO anon, authenticated
  USING (bucket_id <> 'progress-photos');

DROP POLICY IF EXISTS progress_photos_block_insert ON storage.objects;
CREATE POLICY progress_photos_block_insert
  ON storage.objects
  AS RESTRICTIVE
  FOR INSERT
  TO anon, authenticated
  WITH CHECK (bucket_id <> 'progress-photos');

DROP POLICY IF EXISTS progress_photos_block_update ON storage.objects;
CREATE POLICY progress_photos_block_update
  ON storage.objects
  AS RESTRICTIVE
  FOR UPDATE
  TO anon, authenticated
  USING (bucket_id <> 'progress-photos')
  WITH CHECK (bucket_id <> 'progress-photos');

DROP POLICY IF EXISTS progress_photos_block_delete ON storage.objects;
CREATE POLICY progress_photos_block_delete
  ON storage.objects
  AS RESTRICTIVE
  FOR DELETE
  TO anon, authenticated
  USING (bucket_id <> 'progress-photos');

-- Newest photos for the timeline. Signed URLs are added by log-dashboard, not here.
CREATE OR REPLACE FUNCTION public.log_progress_photos()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
      'id', t.id,
      'taken_at', t.taken_at,
      'day', t.day,
      'weight_lb', t.weight_lb,
      'weight_id', t.weight_id,
      'storage_path', t.storage_path,
      'notes', t.notes
    ) ORDER BY t.taken_at DESC NULLS LAST, t.created_at DESC)
    FROM (
      SELECT id, taken_at, day, weight_lb, weight_id, storage_path, notes, created_at
      FROM log.progress_photos
      WHERE storage_path IS NOT NULL
      ORDER BY taken_at DESC NULLS LAST, created_at DESC
      LIMIT 400
    ) t
  ), '[]'::jsonb);
$$;

CREATE OR REPLACE FUNCTION public.log_progress_photo_save(p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_path text;
  v_id uuid;
  v_weight_id uuid;
  v_at timestamptz;
  v_day date;
  v_lb numeric;
  v_bytes integer;
  v_notes text;
BEGIN
  IF p_payload IS NULL OR jsonb_typeof(p_payload) <> 'object' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_json');
  END IF;

  v_path := p_payload->>'path';
  IF v_path IS NULL OR v_path !~ '^[0-9]{4}/[0-9]{2}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jpg$' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_path', 'field', 'path');
  END IF;

  IF COALESCE(p_payload->>'weight_lb', '') = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'required', 'field', 'weight_lb');
  END IF;
  v_lb := (p_payload->>'weight_lb')::numeric;
  IF v_lb < 50 OR v_lb > 600 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'out_of_range', 'field', 'weight_lb');
  END IF;

  IF COALESCE(p_payload->>'weight_id', '') <> '' THEN
    v_weight_id := (p_payload->>'weight_id')::uuid;
    IF NOT EXISTS (SELECT 1 FROM log.weights w WHERE w.id = v_weight_id) THEN
      v_weight_id := NULL;
    END IF;
  END IF;

  IF COALESCE(p_payload->>'taken_at', '') <> '' THEN
    v_at := (p_payload->>'taken_at')::timestamptz;
  ELSE
    v_at := now();
  END IF;

  IF COALESCE(p_payload->>'day', '') <> '' THEN
    v_day := (p_payload->>'day')::date;
  ELSE
    v_day := (v_at AT TIME ZONE 'America/Chicago')::date;
  END IF;

  IF COALESCE(p_payload->>'byte_size', '') <> '' THEN
    v_bytes := (p_payload->>'byte_size')::integer;
    IF v_bytes < 1 OR v_bytes > 2097152 THEN
      RETURN jsonb_build_object('ok', false, 'error', 'out_of_range', 'field', 'byte_size');
    END IF;
  END IF;

  v_notes := NULLIF(left(COALESCE(p_payload->>'notes', ''), 500), '');

  INSERT INTO log.progress_photos (
    taken_at, day, weight_lb, weight_id, storage_path, content_type, byte_size, notes, logged_by
  )
  VALUES (v_at, v_day, v_lb, v_weight_id, v_path, 'image/jpeg', v_bytes, v_notes, 'log-app')
  ON CONFLICT (storage_path) DO UPDATE SET
    taken_at = EXCLUDED.taken_at,
    day = EXCLUDED.day,
    weight_lb = EXCLUDED.weight_lb,
    weight_id = EXCLUDED.weight_id,
    byte_size = EXCLUDED.byte_size,
    notes = COALESCE(EXCLUDED.notes, log.progress_photos.notes),
    content_type = 'image/jpeg'
  RETURNING id INTO v_id;

  RETURN jsonb_build_object(
    'ok', true,
    'action', 'progress_photo_save',
    'id', v_id,
    'path', v_path,
    'weight_lb', v_lb,
    'weight_id', v_weight_id,
    'taken_at', v_at,
    'day', v_day
  );
EXCEPTION
  WHEN invalid_text_representation OR numeric_value_out_of_range OR datetime_field_overflow THEN
    RETURN jsonb_build_object('ok', false, 'error', 'validation_failed');
END;
$$;

-- Removes the metadata row and returns the object name so the Edge Function can delete the bytes.
-- Deleting a photo is the one allowed delete. Other log rows stay insert-only.
CREATE OR REPLACE FUNCTION public.log_progress_photo_delete(p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  v_id uuid;
  v_path text;
BEGIN
  IF p_payload IS NULL OR COALESCE(p_payload->>'id', '') = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'required', 'field', 'id');
  END IF;
  v_id := (p_payload->>'id')::uuid;
  SELECT storage_path INTO v_path FROM log.progress_photos WHERE id = v_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', true, 'action', 'progress_photo_delete', 'id', v_id, 'missing', true);
  END IF;
  DELETE FROM log.progress_photos WHERE id = v_id;
  RETURN jsonb_build_object(
    'ok', true,
    'action', 'progress_photo_delete',
    'id', v_id,
    'storage_path', v_path
  );
EXCEPTION
  WHEN invalid_text_representation THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_id', 'field', 'id');
END;
$$;

REVOKE ALL ON FUNCTION public.log_progress_photos() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.log_progress_photo_save(jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.log_progress_photo_delete(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.log_progress_photos() TO service_role;
GRANT EXECUTE ON FUNCTION public.log_progress_photo_save(jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.log_progress_photo_delete(jsonb) TO service_role;
