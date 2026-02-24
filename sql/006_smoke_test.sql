-- Smoke-test script.
-- Runs in transaction and rolls back to keep DB clean.

BEGIN;

INSERT INTO wialon.ips_frames (received_at, remote_addr, imei, frame_type, frame)
VALUES (now(), '127.0.0.1:9901', '865546046250136', 'login', '#L#865546046250136,***');

INSERT INTO wialon.ips_frames (received_at, remote_addr, imei, frame_type, frame)
VALUES (
  now(),
  '127.0.0.1:9901',
  '865546046250136',
  'sd',
  '#SD#1700000000,59.9000,30.3000,0,0,wifi_bssid:AA:BB:CC:DD:EE:FF;wifi_rssi:-55;wifi_chan:6;wifi_event:appeared'
);

INSERT INTO wialon.ips_frames (received_at, remote_addr, imei, frame_type, frame)
VALUES (
  now(),
  '127.0.0.1:9901',
  '865546046250136',
  'sd',
  '#SD#1700000060,59.9010,30.3010,0,0,wifi_bssid:AA:BB:CC:DD:EE:FF;wifi_rssi:-70;wifi_chan:6;wifi_event:disappeared'
);

SELECT id, received_at, imei, frame_type, frame
FROM wialon.ips_frames
WHERE remote_addr = '127.0.0.1:9901'
ORDER BY id DESC;

SELECT id, raw_frame_id, imei, bssid, frame_ts, rssi_dbm, chan, extra
FROM wialon.observations
WHERE raw_frame_id IN (
  SELECT id FROM wialon.ips_frames WHERE remote_addr = '127.0.0.1:9901'
)
ORDER BY id DESC;

SELECT id, event_ts, imei, bssid, event_type, source, raw_last_id
FROM wialon.events
WHERE raw_last_id IN (
  SELECT id FROM wialon.ips_frames WHERE remote_addr = '127.0.0.1:9901'
)
ORDER BY id DESC;

SELECT * FROM wialon.run_retention(now());

ROLLBACK;
