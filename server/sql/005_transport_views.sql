BEGIN;

CREATE OR REPLACE VIEW wialon.v_transport_presence_current AS
SELECT
  s.id AS session_id,
  s.imei,
  s.ap_bssid,
  s.first_seen_ts,
  s.last_seen_ts,
  s.max_rssi,
  s.seen_count,
  s.state,
  s.duration_ms,
  t.vehicle_id,
  t.route_id,
  t.enabled AS target_enabled,
  t.valid_from,
  t.valid_to,
  t.meta AS target_meta,
  s.created_at,
  s.updated_at
FROM wialon.wifi_sessions s
LEFT JOIN LATERAL (
  SELECT wt.*
  FROM wialon.wifi_targets wt
  WHERE wt.ap_bssid = s.ap_bssid
    AND wt.enabled = TRUE
    AND (wt.valid_from IS NULL OR wt.valid_from <= now())
    AND (wt.valid_to IS NULL OR wt.valid_to >= now())
  ORDER BY wt.valid_from DESC NULLS LAST
  LIMIT 1
) t ON TRUE
WHERE s.state = 'PRESENT';

CREATE OR REPLACE VIEW wialon.v_transport_events_enriched AS
SELECT
  et.id,
  et.ts,
  et.event_type,
  et.imei,
  et.ap_bssid,
  COALESCE(et.vehicle_id, t.vehicle_id) AS vehicle_id,
  COALESCE(et.route_id, t.route_id) AS route_id,
  et.rssi,
  et.duration_ms,
  et.session_id,
  et.raw_event_id,
  et.details,
  et.created_at,
  t.enabled AS target_enabled,
  t.valid_from AS target_valid_from,
  t.valid_to AS target_valid_to,
  t.meta AS target_meta
FROM wialon.wifi_events_transport et
LEFT JOIN LATERAL (
  SELECT wt.*
  FROM wialon.wifi_targets wt
  WHERE wt.ap_bssid = et.ap_bssid
    AND (wt.valid_from IS NULL OR wt.valid_from <= et.ts)
    AND (wt.valid_to IS NULL OR wt.valid_to >= et.ts)
  ORDER BY wt.valid_from DESC NULLS LAST
  LIMIT 1
) t ON TRUE;

COMMIT;
