BEGIN;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'wialon_wifi') THEN
    CREATE ROLE wialon_wifi NOLOGIN;
  END IF;
END;
$$;

GRANT USAGE ON SCHEMA wialon TO wialon_wifi;

GRANT SELECT, INSERT ON TABLE wialon.ips_frames TO wialon_wifi;
GRANT SELECT ON TABLE wialon.observations TO wialon_wifi;
GRANT SELECT ON TABLE wialon.events TO wialon_wifi;
GRANT SELECT, INSERT, UPDATE ON TABLE wialon.allowlist TO wialon_wifi;
GRANT SELECT ON TABLE wialon.retention_policy TO wialon_wifi;

GRANT EXECUTE ON FUNCTION wialon.run_retention(TIMESTAMPTZ) TO wialon_wifi;
GRANT EXECUTE ON FUNCTION wialon.trg_parse_sd_from_raw() TO wialon_wifi;

GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA wialon TO wialon_wifi;

ALTER DEFAULT PRIVILEGES IN SCHEMA wialon
GRANT SELECT, INSERT ON TABLES TO wialon_wifi;

ALTER DEFAULT PRIVILEGES IN SCHEMA wialon
GRANT USAGE, SELECT ON SEQUENCES TO wialon_wifi;

COMMIT;
