BEGIN;

CREATE INDEX IF NOT EXISTS idx_ips_frames_type_received_at
  ON wialon.ips_frames (frame_type, received_at DESC);

CREATE UNIQUE INDEX IF NOT EXISTS ux_observations_semantic_dedup
  ON wialon.observations (
    imei,
    bssid,
    frame_ts,
    COALESCE(rssi_dbm, -32768),
    COALESCE(chan, -1),
    COALESCE(frame_type, 'sd')
  )
  WHERE frame_ts IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS ux_events_semantic_dedup
  ON wialon.events (imei, bssid, event_type, event_ts, source);

CREATE UNIQUE INDEX IF NOT EXISTS ux_events_raw_last_event
  ON wialon.events (raw_last_id, event_type)
  WHERE raw_last_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_events_imei_event_ts_id
  ON wialon.events (imei, event_ts DESC, id DESC);

CREATE INDEX IF NOT EXISTS idx_events_bssid_event_ts_id
  ON wialon.events (bssid, event_ts DESC, id DESC);

CREATE TABLE IF NOT EXISTS wialon.retention_policy (
  target_table TEXT PRIMARY KEY,
  keep_interval INTERVAL NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT retention_policy_positive_interval CHECK (keep_interval > INTERVAL '0')
);

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
  SELECT keep_interval INTO v_raw_keep
  FROM wialon.retention_policy
  WHERE target_table = 'wialon.ips_frames';

  SELECT keep_interval INTO v_obs_keep
  FROM wialon.retention_policy
  WHERE target_table = 'wialon.observations';

  SELECT keep_interval INTO v_events_keep
  FROM wialon.retention_policy
  WHERE target_table = 'wialon.events';

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

CREATE OR REPLACE FUNCTION wialon.trg_parse_sd_from_raw()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_m TEXT[];
  v_ts_raw TEXT;
  v_lat_raw TEXT;
  v_lon_raw TEXT;
  v_params TEXT;
  v_frame_ts TIMESTAMPTZ;
  v_lat DOUBLE PRECISION;
  v_lon DOUBLE PRECISION;
  v_bssid TEXT;
  v_rssi INT;
  v_chan INT;
  v_wifi_event TEXT;
  v_extra JSONB;
  v_obs_id BIGINT;
BEGIN
  IF NEW.frame_type <> 'sd' OR NEW.frame IS NULL OR NEW.frame !~ '^#SD#' THEN
    RETURN NEW;
  END IF;

  v_m := regexp_match(
    NEW.frame,
    '^#SD#([^,]+),([^,]+),([^,]+),[^,]*,[^,]*,(.*)$'
  );

  IF v_m IS NULL THEN
    RETURN NEW;
  END IF;

  v_ts_raw := v_m[1];
  v_lat_raw := v_m[2];
  v_lon_raw := v_m[3];
  v_params := v_m[4];

  IF v_ts_raw ~ '^[0-9]{10}(\.[0-9]+)?$' THEN
    v_frame_ts := to_timestamp(v_ts_raw::double precision);
  ELSIF v_ts_raw ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T' THEN
    v_frame_ts := v_ts_raw::timestamptz;
  ELSE
    v_frame_ts := NEW.received_at;
  END IF;

  BEGIN
    v_lat := v_lat_raw::double precision;
  EXCEPTION WHEN OTHERS THEN
    v_lat := NULL;
  END;

  BEGIN
    v_lon := v_lon_raw::double precision;
  EXCEPTION WHEN OTHERS THEN
    v_lon := NULL;
  END;

  v_bssid := NULLIF((regexp_match(v_params, '(?:^|;)wifi_bssid:([^;]+)'))[1], '');
  IF v_bssid IS NOT NULL THEN
    v_bssid := upper(v_bssid);
  END IF;

  BEGIN
    v_rssi := NULLIF((regexp_match(v_params, '(?:^|;)wifi_rssi:([-]?[0-9]+)'))[1], '')::INT;
  EXCEPTION WHEN OTHERS THEN
    v_rssi := NULL;
  END;

  BEGIN
    v_chan := NULLIF((regexp_match(v_params, '(?:^|;)wifi_chan:([0-9]+)'))[1], '')::INT;
  EXCEPTION WHEN OTHERS THEN
    v_chan := NULL;
  END;

  v_wifi_event := NULLIF((regexp_match(v_params, '(?:^|;)wifi_event:([^;]+)'))[1], '');

  IF NEW.imei IS NULL OR v_bssid IS NULL THEN
    RETURN NEW;
  END IF;

  v_extra := jsonb_strip_nulls(jsonb_build_object(
    'lat', v_lat,
    'lon', v_lon,
    'wifi_event', v_wifi_event
  ));

  INSERT INTO wialon.observations (
    received_at,
    frame_ts,
    remote_addr,
    imei,
    bssid,
    rssi_dbm,
    chan,
    frame_type,
    raw_frame_id,
    extra
  )
  VALUES (
    NEW.received_at,
    v_frame_ts,
    NEW.remote_addr,
    NEW.imei,
    v_bssid,
    v_rssi,
    v_chan,
    'sd',
    NEW.id,
    COALESCE(v_extra, '{}'::jsonb)
  )
  ON CONFLICT (raw_frame_id) DO NOTHING
  RETURNING id INTO v_obs_id;

  IF v_wifi_event IN ('appeared', 'disappeared') THEN
    INSERT INTO wialon.events (
      event_ts,
      received_at,
      imei,
      bssid,
      event_type,
      source,
      first_observation_id,
      last_observation_id,
      raw_first_id,
      raw_last_id,
      details
    )
    VALUES (
      COALESCE(v_frame_ts, NEW.received_at),
      NEW.received_at,
      NEW.imei,
      v_bssid,
      v_wifi_event,
      'frame',
      v_obs_id,
      v_obs_id,
      NEW.id,
      NEW.id,
      jsonb_strip_nulls(jsonb_build_object(
        'chan', v_chan,
        'rssi_dbm', v_rssi,
        'lat', v_lat,
        'lon', v_lon
      ))
    )
    ON CONFLICT DO NOTHING;
  END IF;

  RETURN NEW;
EXCEPTION
  WHEN OTHERS THEN
    RETURN NEW;
END;
$$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_trigger
    WHERE tgname = 'trg_parse_sd_from_raw_ai'
      AND tgrelid = 'wialon.ips_frames'::regclass
  ) THEN
    CREATE TRIGGER trg_parse_sd_from_raw_ai
    AFTER INSERT ON wialon.ips_frames
    FOR EACH ROW
    EXECUTE FUNCTION wialon.trg_parse_sd_from_raw();
  END IF;
END;
$$;

GRANT SELECT ON wialon.retention_policy TO wialon_wifi;
GRANT EXECUTE ON FUNCTION wialon.run_retention(TIMESTAMPTZ) TO wialon_wifi;
GRANT EXECUTE ON FUNCTION wialon.trg_parse_sd_from_raw() TO wialon_wifi;

COMMIT;
