BEGIN;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'wialon_app') THEN
        CREATE ROLE wialon_app NOLOGIN;
    END IF;
END;
$$;

GRANT USAGE ON SCHEMA wialon TO wialon_app;

GRANT SELECT, INSERT ON TABLE wialon.ips_frames TO wialon_app;
GRANT SELECT, INSERT ON TABLE wialon.sd_parsed TO wialon_app;
GRANT SELECT, INSERT ON TABLE wialon.wifi_events TO wialon_app;
GRANT SELECT ON TABLE wialon.retention_policy TO wialon_app;

GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA wialon TO wialon_app;

REVOKE UPDATE, DELETE, TRUNCATE ON TABLE wialon.ips_frames FROM wialon_app;
REVOKE UPDATE, DELETE, TRUNCATE ON TABLE wialon.sd_parsed FROM wialon_app;
REVOKE UPDATE, DELETE, TRUNCATE ON TABLE wialon.wifi_events FROM wialon_app;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON TABLE wialon.retention_policy FROM wialon_app;

ALTER DEFAULT PRIVILEGES IN SCHEMA wialon
GRANT SELECT, INSERT ON TABLES TO wialon_app;

ALTER DEFAULT PRIVILEGES IN SCHEMA wialon
GRANT USAGE, SELECT ON SEQUENCES TO wialon_app;

COMMIT;
