BEGIN;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'wialon_wifi') THEN
    CREATE ROLE wialon_wifi NOLOGIN;
  END IF;
END;
$$;

GRANT USAGE ON SCHEMA wialon TO wialon_wifi;

GRANT SELECT, INSERT, UPDATE ON TABLE wialon.wifi_targets TO wialon_wifi;
GRANT SELECT, INSERT, UPDATE ON TABLE wialon.wifi_sessions TO wialon_wifi;
GRANT SELECT, INSERT, UPDATE ON TABLE wialon.wifi_events_transport TO wialon_wifi;

GRANT SELECT ON TABLE wialon.v_transport_presence_current TO wialon_wifi;
GRANT SELECT ON TABLE wialon.v_transport_events_enriched TO wialon_wifi;

GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA wialon TO wialon_wifi;

COMMIT;
