\set ECHO none 
\set ON_ERROR_STOP on 
\timing on 
\connect postgres 
DO $$BEGIN 
    IF NOT EXISTS(SELECT FROM pg_database WHERE datname='jmeter') THEN 
        CREATE DATABASE jmeter;
    END IF;
    IF NOT EXISTS(SELECT FROM pg_database WHERE datname='grafana') THEN 
        CREATE DATABASE grafana;
    END IF;
END$$;

\connect jmeter 
\set ON_ERROR_STOP on 
SET SESSION AUTHORIZATION azure_pg_admin;
SET client_min_messages TO WARNING;
BEGIN;
DO $$BEGIN 
    IF NOT EXISTS(SELECT 1 FROM pg_namespace WHERE nspname='metrics') THEN 
        CREATE SCHEMA metrics;
    END IF;
END$$;

CREATE TABLE IF NOT EXISTS metrics.system_logs(
    id BIGSERIAL PRIMARY KEY,
    timestamp TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    hostname TEXT,
    source TEXT,
    log_level TEXT,
    message TEXT
);
CREATE INDEX IF NOT EXISTS idx_system_logs_timestamp ON metrics.system_logs(timestamp DESC);

CREATE TABLE IF NOT EXISTS metrics.system_metrics(
    id BIGSERIAL PRIMARY KEY,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    hostname TEXT NOT NULL,
    measurement TEXT NOT NULL,
    value NUMERIC(10,2) NOT NULL,
    tags JSONB
);
CREATE INDEX IF NOT EXISTS idx_system_metrics_timestamp ON metrics.system_metrics(timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_system_metrics_hostname ON metrics.system_metrics(hostname);
CREATE INDEX IF NOT EXISTS idx_system_metrics_measurement ON metrics.system_metrics USING btree(measurement,timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_system_metrics_tags ON metrics.system_metrics USING GIN(tags);

CREATE TABLE IF NOT EXISTS metrics.jmeter_results(
    id BIGSERIAL PRIMARY KEY,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    test_name VARCHAR(255) NOT NULL,
    thread_group VARCHAR(255) NOT NULL,
    sample_label VARCHAR(255) NOT NULL,
    response_time INTEGER NOT NULL,
    latency INTEGER NOT NULL,
    connect_time INTEGER,
    bytes BIGINT,
    sent_bytes BIGINT,
    success BOOLEAN NOT NULL,
    response_code VARCHAR(10),
    response_message TEXT,
    failure_message TEXT,
    thread_name VARCHAR(255),
    data_type VARCHAR(50),
    hostname VARCHAR(255) NOT NULL,
    test_run_id UUID NOT NULL,
    environment VARCHAR(50) NOT NULL
) PARTITION BY RANGE(timestamp);

CREATE TABLE IF NOT EXISTS metrics.test_runs(
    id UUID PRIMARY KEY,
    test_name VARCHAR(255) NOT NULL,
    environment VARCHAR(50) NOT NULL,
    start_time TIMESTAMP WITH TIME ZONE NOT NULL,
    end_time TIMESTAMP WITH TIME ZONE,
    status VARCHAR(20) NOT NULL,
    total_samples BIGINT,
    error_count BIGINT,
    avg_response_time NUMERIC(10,2),
    p90_response_time NUMERIC(10,2),
    p95_response_time NUMERIC(10,2),
    p99_response_time NUMERIC(10,2),
    throughput NUMERIC(10,2),
    test_plan TEXT,
    metadata JSONB
);

CREATE TABLE IF NOT EXISTS metrics.jmeter_live_metrics(
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    test_run_id UUID NOT NULL,
    active_threads INTEGER,
    throughput NUMERIC(10,2),
    error_rate NUMERIC(5,2),
    avg_response_time NUMERIC(10,2),
    CONSTRAINT pk_live_metrics PRIMARY KEY(timestamp,test_run_id)
);

CREATE TABLE IF NOT EXISTS metrics.jmeter_errors(
    id BIGSERIAL PRIMARY KEY,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    test_run_id UUID NOT NULL,
    sample_label VARCHAR(255) NOT NULL,
    error_message TEXT,
    response_code VARCHAR(10),
    thread_name VARCHAR(255),
    stack_trace TEXT
);

CREATE TABLE IF NOT EXISTS metrics.jmeter_assertions(
    id BIGSERIAL PRIMARY KEY,
    test_run_id UUID NOT NULL REFERENCES metrics.test_runs(id),
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    sample_label VARCHAR(255) NOT NULL,
    assertion_name VARCHAR(255) NOT NULL,
    success BOOLEAN NOT NULL,
    failure_message TEXT,
    CONSTRAINT fk_assertion_test_run FOREIGN KEY(test_run_id) REFERENCES metrics.test_runs(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS metrics.jmeter_sub_results(
    id BIGSERIAL PRIMARY KEY,
    parent_sample_id BIGINT NOT NULL,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    test_run_id UUID NOT NULL,
    sample_label VARCHAR(255) NOT NULL,
    response_time INTEGER NOT NULL,
    success BOOLEAN NOT NULL,
    response_code VARCHAR(10),
    response_message TEXT,
    CONSTRAINT fk_subresult_test_run FOREIGN KEY(test_run_id) REFERENCES metrics.test_runs(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS metrics.test_configurations(
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    test_run_id UUID NOT NULL,
    thread_group VARCHAR(255) NOT NULL,
    num_threads INTEGER NOT NULL,
    ramp_up INTEGER,
    duration INTEGER,
    target_throughput NUMERIC(10,2),
    properties JSONB,
    CONSTRAINT fk_config_test_run FOREIGN KEY(test_run_id) REFERENCES metrics.test_runs(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS metrics.test_variables(
    id BIGSERIAL PRIMARY KEY,
    test_run_id UUID NOT NULL,
    variable_name VARCHAR(255) NOT NULL,
    variable_value TEXT,
    scope VARCHAR(50),
    CONSTRAINT fk_variable_test_run FOREIGN KEY(test_run_id) REFERENCES metrics.test_runs(id) ON DELETE CASCADE
);

DO $$DECLARE 
    sd DATE := DATE_TRUNC('month', CURRENT_DATE);
    pd DATE;
    pn TEXT;
    sq TEXT;
BEGIN 
    FOR i IN 0..11 LOOP 
        pd := sd + (i * INTERVAL '1 month');
        pn := 'jmeter_results_' || TO_CHAR(pd, 'YYYY_MM');
        EXECUTE FORMAT('CREATE TABLE IF NOT EXISTS metrics.%I PARTITION OF metrics.jmeter_results FOR VALUES FROM (%L) TO (%L)', pn, pd, pd + INTERVAL '1 month');
        EXECUTE FORMAT('CREATE INDEX IF NOT EXISTS %I ON metrics.%I USING btree(timestamp, test_name, thread_group)', 'idx_' || pn || '_main', pn);
        EXECUTE FORMAT('CREATE INDEX IF NOT EXISTS %I ON metrics.%I USING btree(test_run_id)', 'idx_' || pn || '_run', pn);
    END LOOP;
END$$;

CREATE OR REPLACE FUNCTION metrics.maintain_partitions() RETURNS void AS $$DECLARE 
    fd DATE;
    pn TEXT;
    sq TEXT;
BEGIN 
    fd := DATE_TRUNC('month', CURRENT_DATE + INTERVAL '2 months');
    pn := 'jmeter_results_' || TO_CHAR(fd, 'YYYY_MM');
    EXECUTE FORMAT('CREATE TABLE IF NOT EXISTS metrics.%I PARTITION OF metrics.jmeter_results FOR VALUES FROM (%L) TO (%L)', pn, fd, fd + INTERVAL '1 month');
    EXECUTE FORMAT('CREATE INDEX IF NOT EXISTS %I ON metrics.%I USING btree(timestamp, test_name, thread_group)', 'idx_' || pn || '_main', pn);
    EXECUTE FORMAT('CREATE INDEX IF NOT EXISTS %I ON metrics.%I USING btree(test_run_id)', 'idx_' || pn || '_run', pn);
    EXECUTE FORMAT('DROP TABLE IF EXISTS metrics.jmeter_results_%s', TO_CHAR(CURRENT_DATE - INTERVAL '12 months', 'YYYY_MM'));
END;$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION metrics.cleanup_old_data(rm INTEGER) RETURNS void AS $$BEGIN 
    DELETE FROM metrics.jmeter_results WHERE timestamp < CURRENT_DATE - (rm * INTERVAL '1 month');
    DELETE FROM metrics.test_runs WHERE start_time < CURRENT_DATE - (rm * INTERVAL '1 month');
    DELETE FROM metrics.jmeter_errors WHERE timestamp < CURRENT_DATE - (rm * INTERVAL '1 month');
    DELETE FROM metrics.jmeter_live_metrics WHERE timestamp < CURRENT_DATE - INTERVAL '1 month';
END;$$ LANGUAGE plpgsql;

CREATE OR REPLACE VIEW metrics.vw_test_summary AS 
WITH stats AS (
    SELECT 
        tr.id as test_run_id,
        tr.test_name,
        tr.environment,
        tr.start_time,
        tr.end_time,
        tr.total_samples,
        tr.error_count,
        tr.avg_response_time,
        tr.p95_response_time,
        CASE 
            WHEN tr.total_samples > 0 THEN ROUND((tr.error_count::NUMERIC / tr.total_samples) * 100, 2)
            ELSE 0 
        END as error_rate,
        CASE 
            WHEN EXTRACT(EPOCH FROM (tr.end_time - tr.start_time)) > 0 THEN ROUND(tr.total_samples::NUMERIC / EXTRACT(EPOCH FROM (tr.end_time - tr.start_time)), 2)
            ELSE 0 
        END as actual_throughput,
        tr.p90_response_time,
        tr.p99_response_time,
        CASE 
            WHEN tr.total_samples > 0 THEN ROUND((tr.total_samples - tr.error_count)::NUMERIC / tr.total_samples * 100, 2)
            ELSE 0 
        END as success_rate,
        metadata 
    FROM metrics.test_runs tr 
    WHERE tr.end_time IS NOT NULL
)
SELECT * FROM stats;

DO $$BEGIN 
    IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='svc_at20109_jmeter_uat') THEN 
        CREATE ROLE svc_at20109_jmeter_uat WITH LOGIN PASSWORD 'CHANGEME';
        GRANT USAGE ON SCHEMA metrics TO svc_at20109_jmeter_uat;
        GRANT SELECT, INSERT ON ALL TABLES IN SCHEMA metrics TO svc_at20109_jmeter_uat;
        GRANT ALL PRIVILEGES ON DATABASE jmeter TO svc_at20109_jmeter_uat;
        GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO svc_at20109_jmeter_uat;
        GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO svc_at20109_jmeter_uat;
        ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL PRIVILEGES ON TABLES TO svc_at20109_jmeter_uat;
        ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL PRIVILEGES ON SEQUENCES TO svc_at20109_jmeter_uat;
    END IF;
    IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='svc_at20109_grafana_uat') THEN 
        CREATE ROLE svc_at20109_grafana_uat WITH LOGIN PASSWORD 'CHANGEME';
        GRANT USAGE ON SCHEMA metrics TO svc_at20109_grafana_uat;
        GRANT SELECT ON ALL TABLES IN SCHEMA metrics TO svc_at20109_grafana_uat;
        GRANT ALL PRIVILEGES ON DATABASE grafana TO svc_at20109_grafana_uat;
        ALTER DEFAULT PRIVILEGES IN SCHEMA metrics GRANT SELECT ON TABLES TO svc_at20109_grafana_uat;
    END IF;
END$$;

\connect grafana 
DO $$BEGIN 
    IF NOT EXISTS(SELECT 1 FROM pg_namespace WHERE nspname='public') THEN 
        CREATE SCHEMA public;
    END IF;
END$$;

\connect jmeter 
INSERT INTO metrics.system_logs(source,log_level,message) VALUES('db_setup','INFO','Database setup completed successfully');
COMMIT;
\echo 'Database setup completed successfully'
