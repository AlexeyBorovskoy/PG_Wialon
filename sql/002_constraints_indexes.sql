BEGIN;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'observations_raw_frame_id_fkey'
  ) THEN
    ALTER TABLE wialon.observations
      ADD CONSTRAINT observations_raw_frame_id_fkey
      FOREIGN KEY (raw_frame_id)
      REFERENCES wialon.ips_frames (id)
      ON DELETE SET NULL;
  END IF;
END;
$$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'events_event_type_chk'
  ) THEN
    ALTER TABLE wialon.events
      ADD CONSTRAINT events_event_type_chk
      CHECK (event_type IN ('appeared', 'disappeared'));
  END IF;
END;
$$;

CREATE INDEX IF NOT EXISTS idx_ips_frames_received_at
  ON wialon.ips_frames (received_at DESC);

CREATE INDEX IF NOT EXISTS idx_ips_frames_imei_received_at
  ON wialon.ips_frames (imei, received_at DESC);

CREATE INDEX IF NOT EXISTS idx_ips_frames_type_received_at
  ON wialon.ips_frames (frame_type, received_at DESC);

CREATE INDEX IF NOT EXISTS allowlist_enabled_idx
  ON wialon.allowlist (enabled);

CREATE UNIQUE INDEX IF NOT EXISTS observations_raw_frame_id_uniq
  ON wialon.observations (raw_frame_id)
  WHERE raw_frame_id IS NOT NULL;

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

CREATE INDEX IF NOT EXISTS observations_imei_received_at_idx
  ON wialon.observations (imei, received_at DESC);

CREATE INDEX IF NOT EXISTS observations_bssid_received_at_idx
  ON wialon.observations (bssid, received_at DESC);

CREATE INDEX IF NOT EXISTS observations_imei_frame_ts_idx
  ON wialon.observations (imei, frame_ts DESC);

CREATE INDEX IF NOT EXISTS observations_bssid_frame_ts_idx
  ON wialon.observations (bssid, frame_ts DESC);

CREATE UNIQUE INDEX IF NOT EXISTS ux_events_semantic_dedup
  ON wialon.events (imei, bssid, event_type, event_ts, source);

CREATE UNIQUE INDEX IF NOT EXISTS ux_events_raw_last_event
  ON wialon.events (raw_last_id, event_type)
  WHERE raw_last_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_events_imei_event_ts_id
  ON wialon.events (imei, event_ts DESC, id DESC);

CREATE INDEX IF NOT EXISTS idx_events_bssid_event_ts_id
  ON wialon.events (bssid, event_ts DESC, id DESC);

COMMIT;
