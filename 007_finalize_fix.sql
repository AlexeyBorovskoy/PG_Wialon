BEGIN;

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
  ON CONFLICT DO NOTHING
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
    RAISE NOTICE 'wialon.trg_parse_sd_from_raw failed for raw id %, err=%', NEW.id, SQLERRM;
    RETURN NEW;
END;
$$;

-- Backfill parsed observations/events for old raw SD frames.
WITH src AS (
  SELECT
    f.id,
    f.received_at,
    f.remote_addr,
    f.imei,
    regexp_match(f.frame, '^#SD#([^,]+),([^,]+),([^,]+),[^,]*,[^,]*,(.*)$') AS m
  FROM wialon.ips_frames f
  LEFT JOIN wialon.observations o ON o.raw_frame_id = f.id
  WHERE f.frame_type = 'sd'
    AND o.id IS NULL
    AND f.frame ~ '^#SD#'
), parsed AS (
  SELECT
    s.id AS raw_frame_id,
    s.received_at,
    s.remote_addr,
    s.imei,
    CASE
      WHEN s.m[1] ~ '^[0-9]{10}(\\.[0-9]+)?$' THEN to_timestamp(s.m[1]::double precision)
      WHEN s.m[1] ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T' THEN s.m[1]::timestamptz
      ELSE s.received_at
    END AS frame_ts,
    NULLIF((regexp_match(s.m[4], '(?:^|;)wifi_bssid:([^;]+)'))[1], '') AS bssid,
    NULLIF((regexp_match(s.m[4], '(?:^|;)wifi_rssi:([-]?[0-9]+)'))[1], '')::INT AS rssi_dbm,
    NULLIF((regexp_match(s.m[4], '(?:^|;)wifi_chan:([0-9]+)'))[1], '')::INT AS chan,
    NULLIF((regexp_match(s.m[4], '(?:^|;)wifi_event:([^;]+)'))[1], '') AS wifi_event,
    CASE
      WHEN s.m[2] ~ '^[-]?[0-9]+(\\.[0-9]+)?$' THEN s.m[2]::double precision
      ELSE NULL
    END AS lat,
    CASE
      WHEN s.m[3] ~ '^[-]?[0-9]+(\\.[0-9]+)?$' THEN s.m[3]::double precision
      ELSE NULL
    END AS lon
  FROM src s
  WHERE s.m IS NOT NULL
), ins_obs AS (
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
  SELECT
    p.received_at,
    p.frame_ts,
    p.remote_addr,
    p.imei,
    upper(p.bssid),
    p.rssi_dbm,
    p.chan,
    'sd',
    p.raw_frame_id,
    jsonb_strip_nulls(jsonb_build_object(
      'lat', p.lat,
      'lon', p.lon,
      'wifi_event', p.wifi_event
    ))
  FROM parsed p
  WHERE p.imei IS NOT NULL
    AND p.bssid IS NOT NULL
  ON CONFLICT DO NOTHING
  RETURNING id, raw_frame_id
)
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
SELECT
  p.frame_ts,
  p.received_at,
  p.imei,
  upper(p.bssid),
  p.wifi_event,
  'frame',
  o.id,
  o.id,
  p.raw_frame_id,
  p.raw_frame_id,
  jsonb_strip_nulls(jsonb_build_object(
    'chan', p.chan,
    'rssi_dbm', p.rssi_dbm,
    'lat', p.lat,
    'lon', p.lon
  ))
FROM parsed p
JOIN ins_obs o ON o.raw_frame_id = p.raw_frame_id
WHERE p.wifi_event IN ('appeared', 'disappeared')
ON CONFLICT DO NOTHING;

COMMIT;
