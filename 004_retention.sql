BEGIN;

CREATE TABLE IF NOT EXISTS wialon.retention_policy (
    target_table TEXT PRIMARY KEY,
    keep_interval INTERVAL NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT retention_policy_positive_interval CHECK (keep_interval > INTERVAL '0')
);

INSERT INTO wialon.retention_policy (target_table, keep_interval)
VALUES
    ('wialon.ips_frames', INTERVAL '30 days'),
    ('wialon.sd_parsed', INTERVAL '30 days'),
    ('wialon.wifi_events', INTERVAL '180 days')
ON CONFLICT (target_table) DO UPDATE
SET keep_interval = EXCLUDED.keep_interval,
    updated_at = now();

CREATE OR REPLACE FUNCTION wialon.run_retention(p_run_at TIMESTAMPTZ DEFAULT now())
RETURNS TABLE (target_table TEXT, deleted_rows BIGINT)
LANGUAGE plpgsql
AS $$
DECLARE
    v_raw_keep INTERVAL;
    v_sd_keep INTERVAL;
    v_events_keep INTERVAL;
    v_rows BIGINT;
BEGIN
    SELECT keep_interval INTO v_raw_keep
    FROM wialon.retention_policy
    WHERE target_table = 'wialon.ips_frames';

    SELECT keep_interval INTO v_sd_keep
    FROM wialon.retention_policy
    WHERE target_table = 'wialon.sd_parsed';

    SELECT keep_interval INTO v_events_keep
    FROM wialon.retention_policy
    WHERE target_table = 'wialon.wifi_events';

    IF v_raw_keep IS NULL THEN
        v_raw_keep := INTERVAL '30 days';
    END IF;

    IF v_sd_keep IS NULL THEN
        v_sd_keep := INTERVAL '30 days';
    END IF;

    IF v_events_keep IS NULL THEN
        v_events_keep := INTERVAL '180 days';
    END IF;

    DELETE FROM wialon.wifi_events
    WHERE event_ts < (p_run_at - v_events_keep);

    GET DIAGNOSTICS v_rows = ROW_COUNT;
    target_table := 'wialon.wifi_events';
    deleted_rows := v_rows;
    RETURN NEXT;

    DELETE FROM wialon.sd_parsed
    WHERE frame_ts < (p_run_at - v_sd_keep);

    GET DIAGNOSTICS v_rows = ROW_COUNT;
    target_table := 'wialon.sd_parsed';
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

COMMENT ON FUNCTION wialon.run_retention(TIMESTAMPTZ)
    IS 'Run from scheduler (cron/pg_cron/external): SELECT * FROM wialon.run_retention();';

COMMIT;
