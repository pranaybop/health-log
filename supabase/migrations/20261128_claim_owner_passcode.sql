-- The owner log moves only from the passcode claim.
-- A sign-in (p_by_passcode false) only reports whether this account already owns the log.
-- p_email is ignored: a matching email is not a claim.
-- An account already has data when it has any row in any log table, not only profile or weights.

CREATE OR REPLACE FUNCTION public.log_claim_owner(p_user uuid, p_email text, p_by_passcode boolean DEFAULT false) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE o log.owner%ROWTYPE; t text; n bigint := 0; c bigint; taken boolean;
BEGIN
  SELECT * INTO o FROM log.owner WHERE singleton FOR UPDATE;
  IF o.claimed_at IS NOT NULL THEN
    RETURN jsonb_build_object('ok', true, 'owner', o.user_id = p_user, 'claimed', false);
  END IF;
  IF NOT COALESCE(p_by_passcode, false) THEN
    RETURN jsonb_build_object('ok', true, 'owner', false, 'claimed', false);
  END IF;
  FOR t IN SELECT c2.relname FROM pg_class c2 JOIN pg_namespace n2 ON n2.oid = c2.relnamespace
           WHERE n2.nspname = 'log' AND c2.relkind = 'r' AND c2.relname <> 'owner' LOOP
    EXECUTE format('SELECT EXISTS (SELECT 1 FROM log.%I WHERE user_id = $1)', t) INTO taken USING p_user;
    IF taken THEN
      RETURN jsonb_build_object('ok', false, 'error', 'account_has_data');
    END IF;
  END LOOP;
  FOR t IN SELECT c2.relname FROM pg_class c2 JOIN pg_namespace n2 ON n2.oid = c2.relnamespace
           WHERE n2.nspname = 'log' AND c2.relkind = 'r' AND c2.relname <> 'owner' LOOP
    EXECUTE format('UPDATE log.%I SET user_id = $1 WHERE user_id = $2', t) USING p_user, o.user_id;
    GET DIAGNOSTICS c = ROW_COUNT;
    n := n + c;
  END LOOP;
  UPDATE log.owner SET user_id = p_user, claimed_at = now() WHERE singleton;
  RETURN jsonb_build_object('ok', true, 'owner', true, 'claimed', true, 'rows', n);
END $$;

REVOKE ALL ON FUNCTION public.log_claim_owner(uuid, text, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.log_claim_owner(uuid, text, boolean) TO service_role;
