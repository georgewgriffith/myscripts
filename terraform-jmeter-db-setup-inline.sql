\set ECHO none 
\set ON_ERROR_STOP on 
\timing on 
\connect jmeter 
\set ON_ERROR_STOP on 
SET client_min_messages TO WARNING;
BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE IF NOT EXISTS system_logs(
    id BIGSERIAL PRIMARY KEY,
    timestamp TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    hostname TEXT,
    source TEXT,
    log_level TEXT,
    message TEXT
);
CREATE INDEX IF NOT EXISTS idx_system_logs_timestamp ON system_logs(timestamp DESC);

CREATE TABLE IF NOT EXISTS system_metrics(
    id BIGSERIAL,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    hostname TEXT NOT NULL,
    measurement TEXT NOT NULL,
    value NUMERIC(10,2) NOT NULL,
    tags JSONB,
    PRIMARY KEY(timestamp, id)
) PARTITION BY RANGE(timestamp);

CREATE INDEX IF NOT EXISTS idx_system_metrics_hostname ON system_metrics(hostname);
CREATE INDEX IF NOT EXISTS idx_system_metrics_measurement ON system_metrics USING btree(measurement,timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_system_metrics_tags ON system_metrics USING GIN(tags);

CREATE TABLE IF NOT EXISTS jmeter_results(
    id BIGSERIAL,
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
    environment VARCHAR(50) NOT NULL,
    PRIMARY KEY(timestamp, id)
) PARTITION BY RANGE(timestamp);

CREATE TABLE IF NOT EXISTS test_runs(
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

CREATE TABLE IF NOT EXISTS jmeter_live_metrics(
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    test_run_id UUID NOT NULL,
    active_threads INTEGER,
    throughput NUMERIC(10,2),
    error_rate NUMERIC(5,2),
    avg_response_time NUMERIC(10,2),
    CONSTRAINT pk_live_metrics PRIMARY KEY(timestamp,test_run_id)
);

CREATE TABLE IF NOT EXISTS jmeter_errors(
    id BIGSERIAL,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    test_run_id UUID NOT NULL,
    sample_label VARCHAR(255) NOT NULL,
    error_message TEXT,
    response_code VARCHAR(10),
    thread_name VARCHAR(255),
    stack_trace TEXT,
    PRIMARY KEY(timestamp, id),
    CONSTRAINT fk_errors_test_run FOREIGN KEY(test_run_id) REFERENCES test_runs(id) ON DELETE CASCADE
) PARTITION BY RANGE(timestamp);

CREATE TABLE IF NOT EXISTS jmeter_assertions(
    id BIGSERIAL PRIMARY KEY,
    test_run_id UUID NOT NULL REFERENCES test_runs(id),
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    sample_label VARCHAR(255) NOT NULL,
    assertion_name VARCHAR(255) NOT NULL,
    success BOOLEAN NOT NULL,
    failure_message TEXT,
    CONSTRAINT fk_assertion_test_run FOREIGN KEY(test_run_id) REFERENCES test_runs(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS jmeter_sub_results(
    id BIGSERIAL PRIMARY KEY,
    parent_sample_id BIGINT NOT NULL,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    test_run_id UUID NOT NULL,
    sample_label VARCHAR(255) NOT NULL,
    response_time INTEGER NOT NULL,
    success BOOLEAN NOT NULL,
    response_code VARCHAR(10),
    response_message TEXT,
    CONSTRAINT fk_subresult_test_run FOREIGN KEY(test_run_id) REFERENCES test_runs(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS test_configurations(
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    test_run_id UUID NOT NULL,
    thread_group VARCHAR(255) NOT NULL,
    num_threads INTEGER NOT NULL,
    ramp_up INTEGER,
    duration INTEGER,
    target_throughput NUMERIC(10,2),
    properties JSONB,
    CONSTRAINT fk_config_test_run FOREIGN KEY(test_run_id) REFERENCES test_runs(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS test_variables(
    id BIGSERIAL PRIMARY KEY,
    test_run_id UUID NOT NULL,
    variable_name VARCHAR(255) NOT NULL,
    variable_value TEXT,
    scope VARCHAR(50),
    CONSTRAINT fk_variable_test_run FOREIGN KEY(test_run_id) REFERENCES test_runs(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS jmeter_timers(
    id BIGSERIAL PRIMARY KEY,
    test_run_id UUID NOT NULL,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    timer_name VARCHAR(255) NOT NULL,
    delay INTEGER NOT NULL,
    thread_group VARCHAR(255) NOT NULL,
    thread_name VARCHAR(255),
    CONSTRAINT fk_timer_test_run FOREIGN KEY(test_run_id) REFERENCES test_runs(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS test_environments(
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name VARCHAR(50) NOT NULL UNIQUE,
    base_url TEXT,
    description TEXT,
    properties JSONB,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS jmeter_responses(
    id BIGSERIAL,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    test_run_id UUID NOT NULL,
    sample_label VARCHAR(255) NOT NULL,
    headers JSONB,
    cookies JSONB,
    response_data TEXT,
    PRIMARY KEY(timestamp, id),
    CONSTRAINT fk_response_test_run FOREIGN KEY(test_run_id) REFERENCES test_runs(id) ON DELETE CASCADE
) PARTITION BY RANGE(timestamp);

CREATE TABLE IF NOT EXISTS variables_history(
    id BIGSERIAL,
    test_run_id UUID NOT NULL,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    variable_name VARCHAR(255) NOT NULL,
    old_value TEXT,
    new_value TEXT,
    thread_name VARCHAR(255),
    iteration INTEGER,
    PRIMARY KEY(timestamp, id),
    CONSTRAINT fk_varhistory_test_run FOREIGN KEY(test_run_id) REFERENCES test_runs(id) ON DELETE CASCADE
) PARTITION BY RANGE(timestamp);

CREATE INDEX IF NOT EXISTS idx_jmeter_timers_test_run ON jmeter_timers(test_run_id);
CREATE INDEX IF NOT EXISTS idx_jmeter_timers_timestamp ON jmeter_timers(timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_jmeter_responses_test_run ON jmeter_responses(test_run_id);
CREATE INDEX IF NOT EXISTS idx_jmeter_responses_timestamp ON jmeter_responses(timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_variables_history_test_run ON variables_history(test_run_id);
CREATE INDEX IF NOT EXISTS idx_variables_history_timestamp ON variables_history(timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_variables_history_name ON variables_history(variable_name);

CREATE TABLE IF NOT EXISTS jmeter_custom_metrics(
    id BIGSERIAL,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    test_run_id UUID NOT NULL,
    metric_name VARCHAR(255) NOT NULL,
    metric_value NUMERIC,
    tags JSONB,
    PRIMARY KEY(timestamp, id),
    CONSTRAINT fk_custom_metrics_test_run FOREIGN KEY(test_run_id) REFERENCES test_runs(id) ON DELETE CASCADE
) PARTITION BY RANGE(timestamp);

CREATE TABLE IF NOT EXISTS jmeter_regex_results(
    id BIGSERIAL PRIMARY KEY,
    test_run_id UUID NOT NULL,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    sample_label VARCHAR(255) NOT NULL,
    regex_name VARCHAR(255) NOT NULL,
    regex_pattern TEXT,
    matched_value TEXT,
    match_number INTEGER,
    thread_name VARCHAR(255),
    CONSTRAINT fk_regex_test_run FOREIGN KEY(test_run_id) REFERENCES test_runs(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS jmeter_connection_pools(
    id BIGSERIAL PRIMARY KEY,
    test_run_id UUID NOT NULL,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    pool_name VARCHAR(255) NOT NULL,
    active_connections INTEGER,
    idle_connections INTEGER,
    waiting_threads INTEGER,
    max_active INTEGER,
    max_idle INTEGER,
    CONSTRAINT fk_pool_test_run FOREIGN KEY(test_run_id) REFERENCES test_runs(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS jmeter_csv_data(
    id BIGSERIAL PRIMARY KEY,
    test_run_id UUID NOT NULL,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    thread_name VARCHAR(255),
    csv_file_name VARCHAR(255) NOT NULL,
    row_number INTEGER,
    values JSONB,
    CONSTRAINT fk_csv_test_run FOREIGN KEY(test_run_id) REFERENCES test_runs(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS jmeter_script_results(
    id BIGSERIAL PRIMARY KEY,
    test_run_id UUID NOT NULL,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    script_name VARCHAR(255) NOT NULL,
    script_type VARCHAR(50),
    parameters JSONB,
    result TEXT,
    execution_time INTEGER,
    success BOOLEAN,
    error_message TEXT,
    CONSTRAINT fk_script_test_run FOREIGN KEY(test_run_id) REFERENCES test_runs(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS jmeter_url_modifications(
    id BIGSERIAL PRIMARY KEY,
    test_run_id UUID NOT NULL,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    sample_label VARCHAR(255) NOT NULL,
    original_url TEXT,
    modified_url TEXT,
    parameters_added JSONB,
    thread_name VARCHAR(255),
    CONSTRAINT fk_urlmod_test_run FOREIGN KEY(test_run_id) REFERENCES test_runs(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS jmeter_auth_data(
    id BIGSERIAL PRIMARY KEY,
    test_run_id UUID NOT NULL,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    url_pattern TEXT NOT NULL,
    username VARCHAR(255),
    mechanism VARCHAR(50),
    realm VARCHAR(255),
    parameters JSONB,
    CONSTRAINT fk_auth_test_run FOREIGN KEY(test_run_id) REFERENCES test_runs(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS jmeter_dns_cache(
    id BIGSERIAL PRIMARY KEY,
    test_run_id UUID NOT NULL,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    hostname VARCHAR(255) NOT NULL,
    ip_addresses TEXT[],
    ttl INTEGER,
    expiry TIMESTAMP WITH TIME ZONE,
    CONSTRAINT fk_dns_test_run FOREIGN KEY(test_run_id) REFERENCES test_runs(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS jmeter_file_uploads(
    id BIGSERIAL PRIMARY KEY,
    test_run_id UUID NOT NULL,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    sample_label VARCHAR(255) NOT NULL,
    file_name VARCHAR(255) NOT NULL,
    file_size BIGINT,
    mime_type VARCHAR(255),
    parameter_name VARCHAR(255),
    success BOOLEAN,
    CONSTRAINT fk_upload_test_run FOREIGN KEY(test_run_id) REFERENCES test_runs(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS jmeter_jdbc_requests(
    id BIGSERIAL,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    test_run_id UUID NOT NULL,
    sample_label VARCHAR(255) NOT NULL,
    query_type VARCHAR(50),
    query TEXT,
    parameters JSONB,
    rows_affected INTEGER,
    execution_time INTEGER,
    success BOOLEAN,
    error_message TEXT,
    PRIMARY KEY(timestamp, id),
    CONSTRAINT fk_jdbc_test_run FOREIGN KEY(test_run_id) REFERENCES test_runs(id) ON DELETE CASCADE
) PARTITION BY RANGE(timestamp);

CREATE TABLE IF NOT EXISTS jmeter_transactions(
    id BIGSERIAL PRIMARY KEY,
    test_run_id UUID NOT NULL,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    transaction_name VARCHAR(255) NOT NULL,
    parent_transaction VARCHAR(255),
    duration INTEGER NOT NULL,
    success BOOLEAN NOT NULL,
    nested_samples INTEGER,
    thread_group VARCHAR(255),
    CONSTRAINT fk_transaction_test_run FOREIGN KEY(test_run_id) REFERENCES test_runs(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS jmeter_websocket_metrics(
    id BIGSERIAL,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    test_run_id UUID NOT NULL,
    connection_id VARCHAR(255),
    message_type VARCHAR(50),
    message_size BIGINT,
    connected_time INTEGER,
    status VARCHAR(50),
    close_code INTEGER,
    close_reason TEXT,
    PRIMARY KEY(timestamp, id),
    CONSTRAINT fk_websocket_test_run FOREIGN KEY(test_run_id) REFERENCES test_runs(id) ON DELETE CASCADE
) PARTITION BY RANGE(timestamp);

CREATE TABLE IF NOT EXISTS jmeter_soap_requests(
    id BIGSERIAL,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    test_run_id UUID NOT NULL,
    sample_label VARCHAR(255) NOT NULL,
    wsdl_url TEXT,
    soap_method VARCHAR(255),
    soap_version VARCHAR(10),
    request_payload TEXT,
    response_payload TEXT,
    namespace TEXT,
    success BOOLEAN,
    error_message TEXT,
    PRIMARY KEY(timestamp, id),
    CONSTRAINT fk_soap_test_run FOREIGN KEY(test_run_id) REFERENCES test_runs(id) ON DELETE CASCADE
) PARTITION BY RANGE(timestamp);

CREATE TABLE IF NOT EXISTS jmeter_form_data(
    id BIGSERIAL PRIMARY KEY,
    test_run_id UUID NOT NULL,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    sample_label VARCHAR(255) NOT NULL,
    form_name VARCHAR(255),
    field_name VARCHAR(255),
    field_value TEXT,
    field_type VARCHAR(50),
    is_file BOOLEAN DEFAULT FALSE,
    encoding VARCHAR(50),
    CONSTRAINT fk_form_test_run FOREIGN KEY(test_run_id) REFERENCES test_runs(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS jmeter_jms_messages(
    id BIGSERIAL,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    test_run_id UUID NOT NULL,
    sample_label VARCHAR(255) NOT NULL,
    destination_name VARCHAR(255),
    message_type VARCHAR(50),
    correlation_id VARCHAR(255),
    message_id VARCHAR(255),
    message_body TEXT,
    headers JSONB,
    properties JSONB,
    success BOOLEAN,
    PRIMARY KEY(timestamp, id),
    CONSTRAINT fk_jms_test_run FOREIGN KEY(test_run_id) REFERENCES test_runs(id) ON DELETE CASCADE
) PARTITION BY RANGE(timestamp);

CREATE TABLE IF NOT EXISTS jmeter_oauth_tokens(
    id BIGSERIAL PRIMARY KEY,
    test_run_id UUID NOT NULL,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    token_type VARCHAR(50),
    access_token TEXT,
    refresh_token TEXT,
    expires_at TIMESTAMP WITH TIME ZONE,
    scope TEXT,
    thread_name VARCHAR(255),
    CONSTRAINT fk_oauth_test_run FOREIGN KEY(test_run_id) REFERENCES test_runs(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_csv_data_test_run ON jmeter_csv_data(test_run_id);
CREATE INDEX IF NOT EXISTS idx_csv_data_filename ON jmeter_csv_data(csv_file_name);
CREATE INDEX IF NOT EXISTS idx_script_results_test_run ON jmeter_script_results(test_run_id);
CREATE INDEX IF NOT EXISTS idx_script_results_name ON jmeter_script_results(script_name);
CREATE INDEX IF NOT EXISTS idx_url_modifications_test_run ON jmeter_url_modifications(test_run_id);
CREATE INDEX IF NOT EXISTS idx_auth_data_url ON jmeter_auth_data(url_pattern);
CREATE INDEX IF NOT EXISTS idx_dns_cache_hostname ON jmeter_dns_cache(hostname);
CREATE INDEX IF NOT EXISTS idx_file_uploads_name ON jmeter_file_uploads(file_name);
CREATE INDEX IF NOT EXISTS idx_transactions_name ON jmeter_transactions(transaction_name);
CREATE INDEX IF NOT EXISTS idx_transactions_parent ON jmeter_transactions(parent_transaction);
CREATE INDEX IF NOT EXISTS idx_websocket_conn ON jmeter_websocket_metrics(connection_id);

CREATE INDEX IF NOT EXISTS idx_soap_requests_method ON jmeter_soap_requests(soap_method);
CREATE INDEX IF NOT EXISTS idx_form_data_form ON jmeter_form_data(form_name);
CREATE INDEX IF NOT EXISTS idx_form_data_field ON jmeter_form_data(field_name);
CREATE INDEX IF NOT EXISTS idx_jms_correlation ON jmeter_jms_messages(correlation_id);
CREATE INDEX IF NOT EXISTS idx_jms_message_id ON jmeter_jms_messages(message_id);
CREATE INDEX IF NOT EXISTS idx_oauth_token_type ON jmeter_oauth_tokens(token_type);
CREATE INDEX IF NOT EXISTS idx_oauth_expires ON jmeter_oauth_tokens(expires_at);

CREATE TABLE IF NOT EXISTS jmeter_cache_stats(
    id BIGSERIAL PRIMARY KEY,
    test_run_id UUID NOT NULL,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    cache_manager_name VARCHAR(255) NOT NULL,
    hits INTEGER,
    misses INTEGER,
    total_entries INTEGER,
    max_size INTEGER,
    clear_count INTEGER,
    CONSTRAINT fk_cache_test_run FOREIGN KEY(test_run_id) REFERENCES test_runs(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS jmeter_property_modifications(
    id BIGSERIAL PRIMARY KEY,
    test_run_id UUID NOT NULL,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    property_name VARCHAR(255) NOT NULL,
    old_value TEXT,
    new_value TEXT,
    modifier_type VARCHAR(50),
    thread_name VARCHAR(255),
    CONSTRAINT fk_property_test_run FOREIGN KEY(test_run_id) REFERENCES test_runs(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS jmeter_http2_metrics(
    id BIGSERIAL,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    test_run_id UUID NOT NULL,
    stream_id INTEGER,
    parent_stream_id INTEGER,
    weight INTEGER,
    exclusive BOOLEAN,
    dependent_streams INTEGER[],
    frame_type VARCHAR(50),
    window_size INTEGER,
    window_update INTEGER,
    PRIMARY KEY(timestamp, id),
    CONSTRAINT fk_http2_test_run FOREIGN KEY(test_run_id) REFERENCES test_runs(id) ON DELETE CASCADE
) PARTITION BY RANGE(timestamp);

CREATE TABLE IF NOT EXISTS jmeter_assertions_detail(
    id BIGSERIAL,
    test_run_id UUID NOT NULL,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    assertion_type VARCHAR(50) NOT NULL,
    sample_label VARCHAR(255) NOT NULL,
    assertion_path TEXT,
    expected_value TEXT,
    actual_value TEXT,
    success BOOLEAN NOT NULL,
    failure_message TEXT,
    PRIMARY KEY(timestamp, id),
    CONSTRAINT fk_assertion_detail_test_run FOREIGN KEY(test_run_id) REFERENCES test_runs(id) ON DELETE CASCADE
) PARTITION BY RANGE(timestamp);

CREATE TABLE IF NOT EXISTS jmeter_ssl_info(
    id BIGSERIAL PRIMARY KEY,
    test_run_id UUID NOT NULL,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    hostname VARCHAR(255) NOT NULL,
    protocol VARCHAR(50),
    cipher_suite VARCHAR(255),
    certificate_info JSONB,
    session_reused BOOLEAN,
    handshake_time INTEGER,
    CONSTRAINT fk_ssl_test_run FOREIGN KEY(test_run_id) REFERENCES test_runs(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_cache_stats_name ON jmeter_cache_stats(cache_manager_name);
CREATE INDEX IF NOT EXISTS idx_property_mods_name ON jmeter_property_modifications(property_name);
CREATE INDEX IF NOT EXISTS idx_http2_stream ON jmeter_http2_metrics(stream_id);
CREATE INDEX IF NOT EXISTS idx_assertions_detail_type ON jmeter_assertions_detail(assertion_type);
CREATE INDEX IF NOT EXISTS idx_ssl_hostname ON jmeter_ssl_info(hostname);

CREATE INDEX IF NOT EXISTS idx_jmeter_results_success ON jmeter_results(success) WHERE NOT success;
CREATE INDEX IF NOT EXISTS idx_jmeter_results_label ON jmeter_results(sample_label, timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_system_metrics_composite ON system_metrics(hostname, measurement, timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_jmeter_responses_test_label ON jmeter_responses(test_run_id, sample_label);
CREATE INDEX IF NOT EXISTS idx_assertions_detail_composite ON jmeter_assertions_detail(test_run_id, assertion_type, success);
CREATE INDEX IF NOT EXISTS idx_variables_history_composite ON variables_history(test_run_id, variable_name, timestamp DESC);

DO $$DECLARE 
    sd DATE := DATE_TRUNC('month', CURRENT_DATE);
    pd DATE;
    pn TEXT;
    sq TEXT;
BEGIN 
    FOR i IN 0..11 LOOP 
        pd := sd + (i * INTERVAL '1 month');
        pn := 'jmeter_results_' || TO_CHAR(pd, 'YYYY_MM');
        EXECUTE FORMAT('CREATE TABLE IF NOT EXISTS %I PARTITION OF jmeter_results FOR VALUES FROM (%L) TO (%L)', pn, pd, pd + INTERVAL '1 month');
        EXECUTE FORMAT('CREATE INDEX IF NOT EXISTS %I ON %I USING btree(timestamp, test_name, thread_group)', 'idx_' || pn || '_main', pn);
        EXECUTE FORMAT('CREATE INDEX IF NOT EXISTS %I ON %I USING btree(test_run_id)', 'idx_' || pn || '_run', pn);
    END LOOP;
END$$;

DO $$DECLARE 
    tables TEXT[] := ARRAY['system_metrics', 'jmeter_responses', 'jmeter_errors', 'jmeter_jdbc_requests', 'jmeter_websocket_metrics', 'jmeter_soap_requests', 'jmeter_jms_messages', 'jmeter_http2_metrics', 'jmeter_assertions_detail', 'variables_history'];
    sd DATE := DATE_TRUNC('month', CURRENT_DATE);
    pd DATE;
    pn TEXT;
    tbl TEXT;
BEGIN 
    FOREACH tbl IN ARRAY tables LOOP
        FOR i IN 0..11 LOOP 
            pd := sd + (i * INTERVAL '1 month');
            pn := tbl || '_' || TO_CHAR(pd, 'YYYY_MM');
            EXECUTE FORMAT('CREATE TABLE IF NOT EXISTS %I PARTITION OF %I FOR VALUES FROM (%L) TO (%L)', 
                pn, tbl, pd, pd + INTERVAL '1 month');
            EXECUTE FORMAT('CREATE INDEX IF NOT EXISTS idx_%s_test_run ON %I(test_run_id)', pn, pn);
            EXECUTE FORMAT('CREATE INDEX IF NOT EXISTS idx_%s_timestamp ON %I(timestamp DESC)', pn, pn);
        END LOOP;
    END LOOP;
END$$;

DO $$BEGIN
    IF 'jmeter_custom_metrics' = ANY(SELECT tablename FROM pg_tables) THEN
        ALTER TABLE jmeter_custom_metrics ADD COLUMN IF NOT EXISTS group_name VARCHAR(255);
        CREATE INDEX IF NOT EXISTS idx_custom_metrics_name ON jmeter_custom_metrics(metric_name);
        CREATE INDEX IF NOT EXISTS idx_custom_metrics_tags ON jmeter_custom_metrics USING GIN(tags);
    END IF;
END$$;

DO $$
BEGIN
    EXECUTE 'ALTER TABLE jmeter_custom_metrics SET UNLOGGED';
    EXECUTE 'ALTER TABLE jmeter_connection_pools SET UNLOGGED';
END$$;

CREATE OR REPLACE FUNCTION maintain_partitions() RETURNS void AS $$DECLARE 
    fd DATE;
    pn TEXT;
    tables TEXT[] := ARRAY['jmeter_results', 'system_metrics', 'jmeter_responses', 'jmeter_errors', 
                          'jmeter_jdbc_requests', 'jmeter_websocket_metrics', 'jmeter_soap_requests', 
                          'jmeter_jms_messages', 'jmeter_http2_metrics', 'jmeter_assertions_detail', 'variables_history'];
BEGIN 
    fd := DATE_TRUNC('month', CURRENT_DATE + INTERVAL '2 months');
    FOREACH tbl IN ARRAY tables LOOP
        pn := tbl || '_' || TO_CHAR(fd, 'YYYY_MM');
        EXECUTE FORMAT('CREATE TABLE IF NOT EXISTS %I PARTITION OF %I FOR VALUES FROM (%L) TO (%L)', 
            pn, tbl, fd, fd + INTERVAL '1 month');
        EXECUTE FORMAT('CREATE INDEX IF NOT EXISTS idx_%s_test_run ON %I(test_run_id)', pn, pn);
        EXECUTE FORMAT('CREATE INDEX IF NOT EXISTS idx_%s_timestamp ON %I(timestamp DESC)', pn, pn);
        -- Drop old partitions
        EXECUTE FORMAT('DROP TABLE IF EXISTS %s_%s', 
            tbl, TO_CHAR(CURRENT_DATE - INTERVAL '12 months', 'YYYY_MM'));
    END LOOP;
END;$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION cleanup_old_data(rm INTEGER) RETURNS void AS $$BEGIN 
    DELETE FROM jmeter_results WHERE timestamp < CURRENT_DATE - (rm * INTERVAL '1 month');
    DELETE FROM system_metrics WHERE timestamp < CURRENT_DATE - (rm * INTERVAL '1 month');
    DELETE FROM jmeter_responses WHERE timestamp < CURRENT_DATE - (rm * INTERVAL '1 month');
    DELETE FROM jmeter_errors WHERE timestamp < CURRENT_DATE - (rm * INTERVAL '1 month');
    DELETE FROM test_runs WHERE start_time < CURRENT_DATE - (rm * INTERVAL '1 month');
    DELETE FROM jmeter_live_metrics WHERE timestamp < CURRENT_DATE - INTERVAL '1 month';
    DELETE FROM jmeter_custom_metrics WHERE timestamp < CURRENT_DATE - (rm * INTERVAL '1 month');
    DELETE FROM jmeter_regex_results WHERE timestamp < CURRENT_DATE - (rm * INTERVAL '1 month');
    DELETE FROM jmeter_connection_pools WHERE timestamp < CURRENT_DATE - (rm * INTERVAL '1 month');
    DELETE FROM jmeter_csv_data WHERE timestamp < CURRENT_DATE - (rm * INTERVAL '1 month');
    DELETE FROM jmeter_script_results WHERE timestamp < CURRENT_DATE - (rm * INTERVAL '1 month');
    DELETE FROM jmeter_url_modifications WHERE timestamp < CURRENT_DATE - (rm * INTERVAL '1 month');
    DELETE FROM jmeter_auth_data WHERE timestamp < CURRENT_DATE - (rm * INTERVAL '1 month');
    DELETE FROM jmeter_dns_cache WHERE timestamp < CURRENT_DATE - (rm * INTERVAL '1 month');
    DELETE FROM jmeter_file_uploads WHERE timestamp < CURRENT_DATE - (rm * INTERVAL '1 month');
    DELETE FROM jmeter_jdbc_requests WHERE timestamp < CURRENT_DATE - (rm * INTERVAL '1 month');
    DELETE FROM jmeter_transactions WHERE timestamp < CURRENT_DATE - (rm * INTERVAL '1 month');
    DELETE FROM jmeter_websocket_metrics WHERE timestamp < CURRENT_DATE - (rm * INTERVAL '1 month');
    DELETE FROM jmeter_soap_requests WHERE timestamp < CURRENT_DATE - (rm * INTERVAL '1 month');
    DELETE FROM jmeter_form_data WHERE timestamp < CURRENT_DATE - (rm * INTERVAL '1 month');
    DELETE FROM jmeter_jms_messages WHERE timestamp < CURRENT_DATE - (rm * INTERVAL '1 month');
    DELETE FROM jmeter_oauth_tokens WHERE timestamp < CURRENT_DATE - (rm * INTERVAL '1 month');
    DELETE FROM jmeter_cache_stats WHERE timestamp < CURRENT_DATE - (rm * INTERVAL '1 month');
    DELETE FROM jmeter_property_modifications WHERE timestamp < CURRENT_DATE - (rm * INTERVAL '1 month');
    DELETE FROM jmeter_http2_metrics WHERE timestamp < CURRENT_DATE - (rm * INTERVAL '1 month');
    DELETE FROM jmeter_assertions_detail WHERE timestamp < CURRENT_DATE - (rm * INTERVAL '1 month');
    DELETE FROM jmeter_ssl_info WHERE timestamp < CURRENT_DATE - (rm * INTERVAL '1 month');
END;$$ LANGUAGE plpgsql;

CREATE OR REPLACE VIEW vw_test_summary AS 
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
    FROM test_runs tr 
    WHERE tr.end_time IS NOT NULL
)
SELECT * FROM stats;

CREATE OR REPLACE VIEW vw_transaction_percentiles AS
WITH percentiles AS (
    SELECT 
        test_run_id,
        sample_label,
        PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY response_time) as p50,
        PERCENTILE_CONT(0.90) WITHIN GROUP (ORDER BY response_time) as p90,
        PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY response_time) as p95,
        PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY response_time) as p99,
        COUNT(*) as samples,
        COUNT(*) FILTER (WHERE NOT success) as errors
    FROM jmeter_results
    GROUP BY test_run_id, sample_label
)
SELECT 
    p.*,
    tr.test_name,
    tr.environment,
    tr.start_time,
    ROUND((p.errors::NUMERIC / p.samples) * 100, 2) as error_rate
FROM percentiles p
JOIN test_runs tr ON tr.id = p.test_run_id;

CREATE OR REPLACE VIEW vw_thread_group_analysis AS
WITH thread_stats AS (
    SELECT 
        test_run_id,
        thread_group,
        COUNT(*) as total_samples,
        COUNT(*) FILTER (WHERE success) as successful_samples,
        ROUND(AVG(response_time)::NUMERIC, 2) as avg_response_time,
        MAX(response_time) as max_response_time,
        MIN(response_time) as min_response_time,
        percentile_cont(0.95) WITHIN GROUP (ORDER BY response_time) as p95_response_time
    FROM jmeter_results
    GROUP BY test_run_id, thread_group
)
SELECT 
    ts.*,
    tr.test_name,
    tr.environment,
    tr.start_time,
    ROUND(((ts.total_samples - ts.successful_samples)::NUMERIC / ts.total_samples) * 100, 2) as error_rate
FROM thread_stats ts
JOIN test_runs tr ON tr.id = ts.test_run_id;

CREATE OR REPLACE VIEW vw_error_analysis AS
WITH error_stats AS (
    SELECT 
        test_run_id,
        sample_label,
        response_code,
        COUNT(*) as error_count,
        MAX(timestamp) as last_occurrence,
        MIN(timestamp) as first_occurrence,
        array_agg(DISTINCT failure_message) as unique_messages
    FROM jmeter_results
    WHERE NOT success
    GROUP BY test_run_id, sample_label, response_code
)
SELECT 
    es.*,
    tr.test_name,
    tr.environment,
    tr.start_time
FROM error_stats es
JOIN test_runs tr ON tr.id = es.test_run_id
ORDER BY error_count DESC;

CREATE OR REPLACE VIEW vw_transaction_hierarchy AS
WITH RECURSIVE transaction_tree AS (
    SELECT 
        id,
        test_run_id,
        transaction_name,
        parent_transaction,
        duration,
        success,
        1 as level,
        ARRAY[transaction_name] as path
    FROM jmeter_transactions
    WHERE parent_transaction IS NULL
    UNION ALL
    SELECT 
        t.id,
        t.test_run_id,
        t.transaction_name,
        t.parent_transaction,
        t.duration,
        t.success,
        tt.level + 1,
        tt.path || t.transaction_name
    FROM jmeter_transactions t
    JOIN transaction_tree tt ON t.parent_transaction = tt.transaction_name
    AND t.test_run_id = tt.test_run_id
)
SELECT 
    tt.*,
    tr.test_name,
    tr.environment
FROM transaction_tree tt
JOIN test_runs tr ON tr.id = tt.test_run_id
ORDER BY path;

CREATE OR REPLACE VIEW vw_transaction_trace AS
WITH RECURSIVE transaction_path AS (
    SELECT 
        t.id,
        t.test_run_id,
        t.transaction_name,
        t.parent_transaction,
        t.duration,
        t.timestamp,
        ARRAY[t.transaction_name] as path,
        t.duration as total_time,
        1 as depth
    FROM jmeter_transactions t
    WHERE parent_transaction IS NULL
    UNION ALL
    SELECT 
        c.id,
        c.test_run_id,
        c.transaction_name,
        c.parent_transaction,
        c.duration,
        c.timestamp,
        p.path || c.transaction_name,
        p.total_time + c.duration,
        p.depth + 1
    FROM jmeter_transactions c
    JOIN transaction_path p ON c.parent_transaction = p.transaction_name
    AND c.test_run_id = p.test_run_id
)
SELECT 
    tp.*,
    tr.test_name,
    tr.environment,
    array_to_string(tp.path, ' → ') as transaction_path
FROM transaction_path tp
JOIN test_runs tr ON tr.id = tp.test_run_id
ORDER BY tp.timestamp, tp.path;

DO $$BEGIN 
    IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='__JMETER_DB_USER__') THEN 
        CREATE ROLE __JMETER_DB_USER__ WITH LOGIN PASSWORD '__JMETER_DB_PASSWORD__';
        GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO __JMETER_DB_USER__;
        GRANT ALL PRIVILEGES ON DATABASE jmeter TO __JMETER_DB_USER__;
        GRANT ALL PRIVILEGES ON DATABASE grafana TO __JMETER_DB_USER__;
        GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO __JMETER_DB_USER__;
        ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL PRIVILEGES ON TABLES TO __JMETER_DB_USER__;
        ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL PRIVILEGES ON SEQUENCES TO __JMETER_DB_USER__;
    END IF;
    IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='__GRAFANA_DB_USER__') THEN 
        CREATE ROLE __GRAFANA_DB_USER__ WITH LOGIN PASSWORD '__GRAFANA_DB_PASSWORD__';
        GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO __GRAFANA_DB_USER__;
        GRANT ALL PRIVILEGES ON DATABASE grafana TO __GRAFANA_DB_USER__;
        GRANT ALL PRIVILEGES ON DATABASE jmeter TO __GRAFANA_DB_USER__;
        GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO __GRAFANA_DB_USER__;
        ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL PRIVILEGES ON TABLES TO __GRAFANA_DB_USER__;
        ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL PRIVILEGES ON SEQUENCES TO __GRAFANA_DB_USER__;
    END IF;
END$$;

\connect jmeter 
INSERT INTO system_logs(source,log_level,message) VALUES('db_setup','INFO','Database setup completed successfully');
COMMIT;