BEGIN;

INSERT INTO wialon.retention_policy (target_table, keep_interval)
VALUES
  ('wialon.ips_frames', INTERVAL '30 days'),
  ('wialon.observations', INTERVAL '90 days'),
  ('wialon.events', INTERVAL '180 days')
ON CONFLICT (target_table) DO UPDATE
SET keep_interval = EXCLUDED.keep_interval,
    updated_at = now();

CREATE OR REPLACE FUNCTION wialon.run_retention(p_run_at TIMESTAMPTZ DEFAULT now())
RETURNS TABLE (target_table TEXT, deleted_rows BIGINT)
LANGUAGE plpgsql
AS $$
DECLARE
  v_raw_keep INTERVAL;
  v_obs_keep INTERVAL;
  v_events_keep INTERVAL;
  v_rows BIGINT;
BEGIN
  SELECT rp.keep_interval INTO v_raw_keep
  FROM wialon.retention_policy rp
  WHERE rp.target_table = 'wialon.ips_frames';

  SELECT rp.keep_interval INTO v_obs_keep
  FROM wialon.retention_policy rp
  WHERE rp.target_table = 'wialon.observations';

  SELECT rp.keep_interval INTO v_events_keep
  FROM wialon.retention_policy rp
  WHERE rp.target_table = 'wialon.events';

  v_raw_keep := COALESCE(v_raw_keep, INTERVAL '30 days');
  v_obs_keep := COALESCE(v_obs_keep, INTERVAL '90 days');
  v_events_keep := COALESCE(v_events_keep, INTERVAL '180 days');

  DELETE FROM wialon.events
  WHERE event_ts < (p_run_at - v_events_keep);
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  target_table := 'wialon.events';
  deleted_rows := v_rows;
  RETURN NEXT;

  DELETE FROM wialon.observations
  WHERE received_at < (p_run_at - v_obs_keep);
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  target_table := 'wialon.observations';
  deleted_rows := v_rows;
  RETURN NEXT;

  DELETE FROM wialon.ips_frames
  WHERE received_at < (p_run_at - v_raw_keep);
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  target_table := 'wialon.ips_frames';
  deleted_rows := v_rows;
  RETURN NEXT;
END;
$$;

COMMENT ON FUNCTION wialon.run_retention(TIMESTAMPTZ)
  IS 'Execute daily: SELECT * FROM wialon.run_retention(now());';

COMMIT;
