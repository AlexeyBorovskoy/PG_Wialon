BEGIN;

CREATE SCHEMA IF NOT EXISTS wialon;

CREATE TABLE IF NOT EXISTS wialon.ips_frames (
  id BIGSERIAL PRIMARY KEY,
  received_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  remote_addr TEXT NOT NULL,
  imei TEXT,
  frame_type TEXT NOT NULL,
  frame TEXT NOT NULL,
  CONSTRAINT ips_frames_frame_type_not_empty CHECK (length(trim(frame_type)) > 0),
  CONSTRAINT ips_frames_frame_not_empty CHECK (length(frame) > 0)
);

CREATE TABLE IF NOT EXISTS wialon.allowlist (
  bssid TEXT PRIMARY KEY,
  channel_2g SMALLINT NOT NULL,
  enabled BOOLEAN NOT NULL DEFAULT TRUE,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT allowlist_channel_2g_check CHECK (channel_2g BETWEEN 1 AND 14)
);

CREATE TABLE IF NOT EXISTS wialon.observations (
  id BIGSERIAL PRIMARY KEY,
  received_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  frame_ts TIMESTAMPTZ,
  remote_addr TEXT NOT NULL,
  imei TEXT NOT NULL,
  bssid TEXT NOT NULL,
  rssi_dbm INTEGER,
  chan INTEGER,
  freq_mhz INTEGER,
  ssid TEXT,
  frame_type TEXT NOT NULL DEFAULT 'sd',
  raw_frame_id BIGINT,
  extra JSONB NOT NULL DEFAULT '{}'::jsonb
);

CREATE TABLE IF NOT EXISTS wialon.events (
  id BIGSERIAL PRIMARY KEY,
  event_ts TIMESTAMPTZ NOT NULL,
  received_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  imei TEXT NOT NULL,
  bssid TEXT NOT NULL,
  event_type TEXT NOT NULL,
  source TEXT NOT NULL,
  first_observation_id BIGINT,
  last_observation_id BIGINT,
  raw_first_id BIGINT,
  raw_last_id BIGINT,
  details JSONB NOT NULL DEFAULT '{}'::jsonb
);

CREATE TABLE IF NOT EXISTS wialon.retention_policy (
  target_table TEXT PRIMARY KEY,
  keep_interval INTERVAL NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT retention_policy_positive_interval CHECK (keep_interval > INTERVAL '0')
);

COMMIT;
