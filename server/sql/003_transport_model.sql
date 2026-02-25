BEGIN;

CREATE TABLE IF NOT EXISTS wialon.wifi_targets (
  ap_bssid TEXT PRIMARY KEY,
  vehicle_id TEXT,
  route_id TEXT,
  enabled BOOLEAN NOT NULL DEFAULT TRUE,
  valid_from TIMESTAMPTZ,
  valid_to TIMESTAMPTZ,
  meta JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT wifi_targets_valid_range_chk CHECK (
    valid_to IS NULL OR valid_from IS NULL OR valid_to >= valid_from
  )
);

CREATE TABLE IF NOT EXISTS wialon.wifi_sessions (
  id BIGSERIAL PRIMARY KEY,
  imei TEXT NOT NULL,
  ap_bssid TEXT NOT NULL,
  first_seen_ts TIMESTAMPTZ NOT NULL,
  last_seen_ts TIMESTAMPTZ NOT NULL,
  max_rssi INTEGER,
  seen_count INTEGER NOT NULL DEFAULT 1,
  state TEXT NOT NULL DEFAULT 'CLOSED',
  duration_ms BIGINT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT wifi_sessions_seen_count_chk CHECK (seen_count >= 1),
  CONSTRAINT wifi_sessions_duration_ms_chk CHECK (duration_ms IS NULL OR duration_ms >= 0),
  CONSTRAINT wifi_sessions_time_order_chk CHECK (last_seen_ts >= first_seen_ts)
);

CREATE TABLE IF NOT EXISTS wialon.wifi_events_transport (
  id BIGSERIAL PRIMARY KEY,
  ts TIMESTAMPTZ NOT NULL,
  event_type TEXT NOT NULL,
  imei TEXT NOT NULL,
  ap_bssid TEXT NOT NULL,
  vehicle_id TEXT,
  route_id TEXT,
  rssi INTEGER,
  duration_ms BIGINT,
  session_id BIGINT,
  raw_event_id BIGINT,
  details JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT wifi_events_transport_duration_ms_chk CHECK (duration_ms IS NULL OR duration_ms >= 0)
);

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'wifi_sessions_state_chk'
  ) THEN
    ALTER TABLE wialon.wifi_sessions
      ADD CONSTRAINT wifi_sessions_state_chk
      CHECK (state IN ('ABSENT', 'PRESENT', 'CLOSED'));
  END IF;
END;
$$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'wifi_events_transport_event_type_chk'
  ) THEN
    ALTER TABLE wialon.wifi_events_transport
      ADD CONSTRAINT wifi_events_transport_event_type_chk
      CHECK (event_type IN ('ENTER', 'EXIT'));
  END IF;
END;
$$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'wifi_events_transport_session_fk'
  ) THEN
    ALTER TABLE wialon.wifi_events_transport
      ADD CONSTRAINT wifi_events_transport_session_fk
      FOREIGN KEY (session_id)
      REFERENCES wialon.wifi_sessions(id)
      ON DELETE SET NULL;
  END IF;
END;
$$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'wifi_events_transport_raw_event_fk'
  ) THEN
    ALTER TABLE wialon.wifi_events_transport
      ADD CONSTRAINT wifi_events_transport_raw_event_fk
      FOREIGN KEY (raw_event_id)
      REFERENCES wialon.events(id)
      ON DELETE SET NULL;
  END IF;
END;
$$;

CREATE INDEX IF NOT EXISTS idx_wifi_targets_enabled
  ON wialon.wifi_targets (enabled);

CREATE INDEX IF NOT EXISTS idx_wifi_targets_valid_range
  ON wialon.wifi_targets (valid_from, valid_to);

CREATE INDEX IF NOT EXISTS idx_wifi_sessions_imei_first_seen
  ON wialon.wifi_sessions (imei, first_seen_ts DESC);

CREATE INDEX IF NOT EXISTS idx_wifi_sessions_ap_first_seen
  ON wialon.wifi_sessions (ap_bssid, first_seen_ts DESC);

CREATE INDEX IF NOT EXISTS idx_wifi_sessions_state
  ON wialon.wifi_sessions (state);

CREATE INDEX IF NOT EXISTS idx_wifi_sessions_state_last_seen
  ON wialon.wifi_sessions (state, last_seen_ts DESC);

CREATE UNIQUE INDEX IF NOT EXISTS ux_wifi_sessions_natural
  ON wialon.wifi_sessions (imei, ap_bssid, first_seen_ts);

CREATE INDEX IF NOT EXISTS idx_wifi_events_transport_ts
  ON wialon.wifi_events_transport (ts DESC);

CREATE INDEX IF NOT EXISTS idx_wifi_events_transport_ap_ts
  ON wialon.wifi_events_transport (ap_bssid, ts DESC);

CREATE INDEX IF NOT EXISTS idx_wifi_events_transport_imei_ts
  ON wialon.wifi_events_transport (imei, ts DESC);

CREATE INDEX IF NOT EXISTS idx_wifi_events_transport_event_type_ts
  ON wialon.wifi_events_transport (event_type, ts DESC);

CREATE INDEX IF NOT EXISTS idx_wifi_events_transport_session
  ON wialon.wifi_events_transport (session_id);

CREATE INDEX IF NOT EXISTS idx_wifi_events_transport_raw_event
  ON wialon.wifi_events_transport (raw_event_id)
  WHERE raw_event_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS ux_wifi_events_transport_dedup
  ON wialon.wifi_events_transport (imei, ap_bssid, event_type, ts);

COMMIT;
