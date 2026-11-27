-- Accounts, part 3: a photo row can only be updated by the user who owns it.
DO $$
DECLARE d text := pg_get_functiondef('public.log_progress_photo_save(jsonb)'::regprocedure); n int;
BEGIN
  n := (SELECT count(*) FROM regexp_matches(d, 'content_type = ''image/jpeg''\n  RETURNING id INTO v_id;', 'g'));
  IF n <> 1 THEN RAISE EXCEPTION 'photo save patch: expected 1 match, found %', n; END IF;
  d := replace(d, E'content_type = ''image/jpeg''\n  RETURNING id INTO v_id;',
    E'content_type = ''image/jpeg''\n  WHERE log.progress_photos.user_id = log.current_user_id()\n  RETURNING id INTO v_id;\n  IF v_id IS NULL THEN\n    RETURN jsonb_build_object(''ok'', false, ''error'', ''invalid_path'', ''field'', ''path'');\n  END IF;');
  EXECUTE d;
END $$;
