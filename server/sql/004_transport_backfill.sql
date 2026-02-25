BEGIN;

-- Assumption:
-- Existing table wialon.events contains event_type in ('appeared','disappeared').
-- Existing table wialon.observations may contain optional RSSI/frame_ts for enrichment.

WITH src_events AS (
  SELECT
    e.id AS raw_event_id,
    e.event_ts AS ts,
    e.imei,
    upper(e.bssid) AS ap_bssid,
    CASE
      WHEN e.event_type = 'appeared' THEN 'ENTER'
      WHEN e.event_type = 'disappeared' THEN 'EXIT'
      ELSE NULL
    END AS event_type,
    e.raw_last_id,
    e.details AS raw_details,
    o.rssi_dbm AS rssi,
    t.vehicle_id,
    t.route_id
  FROM wialon.events e
  LEFT JOIN wialon.observations o
    ON o.raw_frame_id = e.raw_last_id
  LEFT JOIN LATERAL (
    SELECT wt.vehicle_id, wt.route_id
    FROM wialon.wifi_targets wt
    WHERE wt.ap_bssid = upper(e.bssid)
      AND wt.enabled = TRUE
      AND (wt.valid_from IS NULL OR wt.valid_from <= e.event_ts)
      AND (wt.valid_to IS NULL OR wt.valid_to >= e.event_ts)
    ORDER BY wt.valid_from DESC NULLS LAST
    LIMIT 1
  ) t ON TRUE
  WHERE e.event_type IN ('appeared', 'disappeared')
    AND e.imei IS NOT NULL
    AND e.bssid IS NOT NULL
), ins_events AS (
  INSERT INTO wialon.wifi_events_transport (
    ts,
    event_type,
    imei,
    ap_bssid,
    vehicle_id,
    route_id,
    rssi,
    duration_ms,
    session_id,
    raw_event_id,
    details
  )
  SELECT
    s.ts,
    s.event_type,
    s.imei,
    s.ap_bssid,
    s.vehicle_id,
    s.route_id,
    s.rssi,
    NULL::BIGINT,
    NULL::BIGINT,
    s.raw_event_id,
    jsonb_strip_nulls(
      coalesce(s.raw_details, '{}'::jsonb) ||
      jsonb_build_object(
        'source_table', 'wialon.events',
        'source_event_type', s.event_type,
        'raw_last_id', s.raw_last_id
      )
    )
  FROM src_events s
  WHERE s.event_type IS NOT NULL
  ON CONFLICT (imei, ap_bssid, event_type, ts) DO UPDATE
    SET raw_event_id = COALESCE(wialon.wifi_events_transport.raw_event_id, EXCLUDED.raw_event_id),
        vehicle_id = COALESCE(wialon.wifi_events_transport.vehicle_id, EXCLUDED.vehicle_id),
        route_id = COALESCE(wialon.wifi_events_transport.route_id, EXCLUDED.route_id),
        rssi = COALESCE(wialon.wifi_events_transport.rssi, EXCLUDED.rssi),
        details = COALESCE(wialon.wifi_events_transport.details, '{}'::jsonb) || COALESCE(EXCLUDED.details, '{}'::jsonb)
  RETURNING id
)
SELECT count(*) AS upserted_transport_events
FROM ins_events;

WITH ordered_enters AS (
  SELECT
    et.id,
    et.ts,
    et.imei,
    et.ap_bssid,
    row_number() OVER (PARTITION BY et.imei, et.ap_bssid ORDER BY et.ts, et.id) AS rn
  FROM wialon.wifi_events_transport et
  WHERE et.event_type = 'ENTER'
), ordered_exits AS (
  SELECT
    et.id,
    et.ts,
    et.imei,
    et.ap_bssid,
    row_number() OVER (PARTITION BY et.imei, et.ap_bssid ORDER BY et.ts, et.id) AS rn
  FROM wialon.wifi_events_transport et
  WHERE et.event_type = 'EXIT'
), enter_sessions AS (
  SELECT
    en.imei,
    en.ap_bssid,
    en.ts AS first_seen_ts,
    ex.ts AS exit_ts,
    CASE
      WHEN ex.ts IS NOT NULL AND ex.ts >= en.ts THEN 'CLOSED'
      ELSE 'PRESENT'
    END AS state
  FROM ordered_enters en
  LEFT JOIN ordered_exits ex
    ON ex.imei = en.imei
   AND ex.ap_bssid = en.ap_bssid
   AND ex.rn = en.rn
), orphan_exit_sessions AS (
  SELECT
    ex.imei,
    ex.ap_bssid,
    ex.ts AS first_seen_ts,
    ex.ts AS exit_ts,
    'ABSENT'::TEXT AS state
  FROM ordered_exits ex
  LEFT JOIN ordered_enters en
    ON en.imei = ex.imei
   AND en.ap_bssid = ex.ap_bssid
   AND en.rn = ex.rn
  WHERE en.id IS NULL
), session_base AS (
  SELECT * FROM enter_sessions
  UNION ALL
  SELECT * FROM orphan_exit_sessions
), session_stats AS (
  SELECT
    sb.imei,
    sb.ap_bssid,
    sb.first_seen_ts,
    CASE
      WHEN sb.state = 'PRESENT' THEN COALESCE(obs.max_seen_ts, sb.first_seen_ts)
      WHEN sb.exit_ts IS NOT NULL AND sb.exit_ts >= sb.first_seen_ts THEN sb.exit_ts
      ELSE sb.first_seen_ts
    END AS last_seen_ts,
    obs.max_rssi,
    GREATEST(COALESCE(obs.seen_count, 0), 1)::INTEGER AS seen_count,
    sb.state,
    CASE
      WHEN sb.state = 'CLOSED' AND sb.exit_ts IS NOT NULL AND sb.exit_ts >= sb.first_seen_ts
        THEN (extract(epoch FROM (sb.exit_ts - sb.first_seen_ts)) * 1000)::BIGINT
      ELSE NULL::BIGINT
    END AS duration_ms
  FROM session_base sb
  LEFT JOIN LATERAL (
    SELECT
      count(*)::BIGINT AS seen_count,
      max(o.rssi_dbm) AS max_rssi,
      max(coalesce(o.frame_ts, o.received_at)) AS max_seen_ts
    FROM wialon.observations o
    WHERE o.imei = sb.imei
      AND upper(o.bssid) = sb.ap_bssid
      AND coalesce(o.frame_ts, o.received_at) >= sb.first_seen_ts
      AND (
        sb.state = 'PRESENT'
        OR coalesce(o.frame_ts, o.received_at) <= COALESCE(sb.exit_ts, sb.first_seen_ts)
      )
  ) obs ON TRUE
), ins_sessions AS (
  INSERT INTO wialon.wifi_sessions (
    imei,
    ap_bssid,
    first_seen_ts,
    last_seen_ts,
    max_rssi,
    seen_count,
    state,
    duration_ms,
    created_at,
    updated_at
  )
  SELECT
    ss.imei,
    ss.ap_bssid,
    ss.first_seen_ts,
    ss.last_seen_ts,
    ss.max_rssi,
    ss.seen_count,
    ss.state,
    ss.duration_ms,
    now(),
    now()
  FROM session_stats ss
  ON CONFLICT (imei, ap_bssid, first_seen_ts) DO UPDATE
    SET last_seen_ts = EXCLUDED.last_seen_ts,
        max_rssi = EXCLUDED.max_rssi,
        seen_count = EXCLUDED.seen_count,
        state = EXCLUDED.state,
        duration_ms = EXCLUDED.duration_ms,
        updated_at = now()
  RETURNING id
)
SELECT count(*) AS upserted_transport_sessions
FROM ins_sessions;

WITH candidate_session AS (
  SELECT
    et.id AS event_id,
    (
      SELECT s.id
      FROM wialon.wifi_sessions s
      WHERE s.imei = et.imei
        AND s.ap_bssid = et.ap_bssid
        AND s.first_seen_ts <= et.ts
        AND (
          s.state = 'PRESENT'
          OR et.ts <= s.last_seen_ts
        )
      ORDER BY s.first_seen_ts DESC, s.id DESC
      LIMIT 1
    ) AS session_id
  FROM wialon.wifi_events_transport et
), upd_events AS (
  UPDATE wialon.wifi_events_transport et
  SET session_id = cs.session_id,
      duration_ms = CASE
        WHEN et.event_type = 'EXIT' THEN COALESCE(et.duration_ms, s.duration_ms)
        ELSE et.duration_ms
      END
  FROM candidate_session cs
  LEFT JOIN wialon.wifi_sessions s ON s.id = cs.session_id
  WHERE et.id = cs.event_id
    AND cs.session_id IS NOT NULL
    AND (
      et.session_id IS DISTINCT FROM cs.session_id
      OR (
        et.event_type = 'EXIT'
        AND et.duration_ms IS DISTINCT FROM s.duration_ms
      )
    )
  RETURNING et.id
)
SELECT count(*) AS relinked_transport_events
FROM upd_events;

COMMIT;
