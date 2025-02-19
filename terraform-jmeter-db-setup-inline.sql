\set ECHO none 
\set ON_ERROR_STOP on 
\timing on 
\connect jmeter 
\set ON_ERROR_STOP on 
SET client_min_messages TO WARNING;
BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Create test_runs table first since it's referenced by many other tables
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

CREATE OR REPLACE FUNCTION create_standard_jmeter_table(table_name TEXT, additional_columns TEXT) RETURNS void AS $$
BEGIN
    EXECUTE FORMAT('
        CREATE TABLE IF NOT EXISTS %I (
            id BIGSERIAL,
            timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
            test_run_id UUID NOT NULL REFERENCES test_runs(id) ON DELETE CASCADE,
            %s,
            PRIMARY KEY(timestamp, id)
        )', table_name, additional_columns);
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION create_standard_indices(table_name TEXT) RETURNS void AS $$
BEGIN
    EXECUTE FORMAT('CREATE INDEX IF NOT EXISTS idx_%s_test_run ON %I(test_run_id)', table_name, table_name);
    EXECUTE FORMAT('CREATE INDEX IF NOT EXISTS idx_%s_timestamp ON %I(timestamp DESC)', table_name, table_name);
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION create_standard_table(table_name TEXT, additional_columns TEXT) RETURNS void AS $$
BEGIN
    EXECUTE FORMAT('
        CREATE TABLE IF NOT EXISTS %I (
            id BIGSERIAL PRIMARY KEY,
            timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
            test_run_id UUID NOT NULL REFERENCES test_runs(id) ON DELETE CASCADE,
            %s
        )', table_name, additional_columns);
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Error creating table %: %', table_name, SQLERRM;
    RAISE;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION delete_old_data(table_name TEXT, timestamp_column TEXT, months INTEGER) RETURNS INTEGER AS $$
DECLARE
    rows_deleted INTEGER;
BEGIN
    EXECUTE FORMAT('DELETE FROM %I WHERE %I < CURRENT_DATE - ($1 * INTERVAL ''1 month'')', 
        table_name, timestamp_column) 
    USING months;
    GET DIAGNOSTICS rows_deleted = ROW_COUNT;
    RETURN rows_deleted;
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Error deleting from %: %', table_name, SQLERRM;
    RETURN -1;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION cleanup_table_partitions(table_name TEXT) RETURNS void AS $$
BEGIN
    EXECUTE FORMAT('
        DROP TABLE IF EXISTS %s_%s', 
        table_name,
        TO_CHAR(CURRENT_DATE - INTERVAL '12 months', 'YYYY_MM')
    );
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Error cleaning up partitions for %: %', table_name, SQLERRM;
END;
$$ LANGUAGE plpgsql;

DROP TABLE IF EXISTS jmeter_results CASCADE;
CREATE TABLE jmeter_results (
    id BIGSERIAL,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    test_run_id UUID NOT NULL REFERENCES test_runs(id) ON DELETE CASCADE,
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
    environment VARCHAR(50) NOT NULL,
    PRIMARY KEY(timestamp, id)
) PARTITION BY RANGE(timestamp);

DROP TABLE IF NOT EXISTS jmeter_errors CASCADE;
CREATE TABLE jmeter_errors (
    id BIGSERIAL,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    test_run_id UUID NOT NULL REFERENCES test_runs(id) ON DELETE CASCADE,
    sample_label VARCHAR(255) NOT NULL,
    error_message TEXT,
    response_code VARCHAR(10),
    thread_name VARCHAR(255),
    stack_trace TEXT,
    PRIMARY KEY(timestamp, id)
) PARTITION BY RANGE(timestamp);

SELECT create_standard_indices('jmeter_results');
SELECT create_standard_indices('jmeter_errors');

CREATE TABLE IF NOT EXISTS jmeter_live_metrics(
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    test_run_id UUID NOT NULL REFERENCES test_runs(id) ON DELETE CASCADE,
    active_threads INTEGER,
    throughput NUMERIC(10,2),
    error_rate NUMERIC(5,2),
    avg_response_time NUMERIC(10,2),
    CONSTRAINT pk_live_metrics PRIMARY KEY(timestamp,test_run_id)
);

CREATE TABLE IF NOT EXISTS jmeter_assertions(
    id BIGSERIAL PRIMARY KEY,
    test_run_id UUID NOT NULL REFERENCES test_runs(id) ON DELETE CASCADE,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    sample_label VARCHAR(255) NOT NULL,
    assertion_name VARCHAR(255) NOT NULL,
    success BOOLEAN NOT NULL,
    failure_message TEXT
);

CREATE TABLE IF NOT EXISTS jmeter_sub_results(
    id BIGSERIAL PRIMARY KEY,
    parent_sample_id BIGINT NOT NULL,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    test_run_id UUID NOT NULL REFERENCES test_runs(id) ON DELETE CASCADE,
    sample_label VARCHAR(255) NOT NULL,
    response_time INTEGER NOT NULL,
    success BOOLEAN NOT NULL,
    response_code VARCHAR(10),
    response_message TEXT
);

CREATE TABLE IF NOT EXISTS test_configurations(
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    test_run_id UUID NOT NULL REFERENCES test_runs(id) ON DELETE CASCADE,
    thread_group VARCHAR(255) NOT NULL,
    num_threads INTEGER NOT NULL,
    ramp_up INTEGER,
    duration INTEGER,
    target_throughput NUMERIC(10,2),
    properties JSONB
);

CREATE TABLE IF NOT EXISTS test_variables(
    id BIGSERIAL PRIMARY KEY,
    test_run_id UUID NOT NULL REFERENCES test_runs(id) ON DELETE CASCADE,
    variable_name VARCHAR(255) NOT NULL,
    variable_value TEXT,
    scope VARCHAR(50)
);

CREATE TABLE IF NOT EXISTS jmeter_timers(
    id BIGSERIAL PRIMARY KEY,
    test_run_id UUID NOT NULL REFERENCES test_runs(id) ON DELETE CASCADE,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    timer_name VARCHAR(255) NOT NULL,
    delay INTEGER NOT NULL,
    thread_group VARCHAR(255) NOT NULL,
    thread_name VARCHAR(255)
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
    test_run_id UUID NOT NULL REFERENCES test_runs(id) ON DELETE CASCADE,
    sample_label VARCHAR(255) NOT NULL,
    headers JSONB,
    cookies JSONB,
    response_data TEXT,
    PRIMARY KEY(timestamp, id)
) PARTITION BY RANGE(timestamp);

CREATE TABLE IF NOT EXISTS variables_history(
    id BIGSERIAL,
    test_run_id UUID NOT NULL REFERENCES test_runs(id) ON DELETE CASCADE,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    variable_name VARCHAR(255) NOT NULL,
    old_value TEXT,
    new_value TEXT,
    thread_name VARCHAR(255),
    iteration INTEGER,
    PRIMARY KEY(timestamp, id)
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
    test_run_id UUID NOT NULL REFERENCES test_runs(id) ON DELETE CASCADE,
    metric_name VARCHAR(255) NOT NULL,
    metric_value NUMERIC,
    tags JSONB,
    PRIMARY KEY(timestamp, id)
) PARTITION BY RANGE(timestamp);

CREATE TABLE IF NOT EXISTS jmeter_regex_results(
    id BIGSERIAL PRIMARY KEY,
    test_run_id UUID NOT NULL REFERENCES test_runs(id) ON DELETE CASCADE,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    sample_label VARCHAR(255) NOT NULL,
    regex_name VARCHAR(255) NOT NULL,
    regex_pattern TEXT,
    matched_value TEXT,
    match_number INTEGER,
    thread_name VARCHAR(255)
);

CREATE TABLE IF NOT EXISTS jmeter_connection_pools(
    id BIGSERIAL PRIMARY KEY,
    test_run_id UUID NOT NULL REFERENCES test_runs(id) ON DELETE CASCADE,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    pool_name VARCHAR(255) NOT NULL,
    active_connections INTEGER,
    idle_connections INTEGER,
    waiting_threads INTEGER,
    max_active INTEGER,
    max_idle INTEGER
);

CREATE TABLE IF NOT EXISTS jmeter_csv_data(
    id BIGSERIAL PRIMARY KEY,
    test_run_id UUID NOT NULL REFERENCES test_runs(id) ON DELETE CASCADE,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    thread_name VARCHAR(255),
    csv_file_name VARCHAR(255) NOT NULL,
    row_number INTEGER,
    values JSONB
);

CREATE TABLE IF NOT EXISTS jmeter_script_results(
    id BIGSERIAL PRIMARY KEY,
    test_run_id UUID NOT NULL REFERENCES test_runs(id) ON DELETE CASCADE,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    script_name VARCHAR(255) NOT NULL,
    script_type VARCHAR(50),
    parameters JSONB,
    result TEXT,
    execution_time INTEGER,
    success BOOLEAN,
    error_message TEXT
);

CREATE TABLE IF NOT EXISTS jmeter_url_modifications(
    id BIGSERIAL PRIMARY KEY,
    test_run_id UUID NOT NULL REFERENCES test_runs(id) ON DELETE CASCADE,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    sample_label VARCHAR(255) NOT NULL,
    original_url TEXT,
    modified_url TEXT,
    parameters_added JSONB,
    thread_name VARCHAR(255)
);

CREATE TABLE IF NOT EXISTS jmeter_auth_data(
    id BIGSERIAL PRIMARY KEY,
    test_run_id UUID NOT NULL REFERENCES test_runs(id) ON DELETE CASCADE,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    url_pattern TEXT NOT NULL,
    username VARCHAR(255),
    mechanism VARCHAR(50),
    realm VARCHAR(255),
    parameters JSONB
);

CREATE TABLE IF NOT EXISTS jmeter_dns_cache(
    id BIGSERIAL PRIMARY KEY,
    test_run_id UUID NOT NULL REFERENCES test_runs(id) ON DELETE CASCADE,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    hostname VARCHAR(255) NOT NULL,
    ip_addresses TEXT[],
    ttl INTEGER,
    expiry TIMESTAMP WITH TIME ZONE
);

CREATE TABLE IF NOT EXISTS jmeter_file_uploads(
    id BIGSERIAL PRIMARY KEY,
    test_run_id UUID NOT NULL REFERENCES test_runs(id) ON DELETE CASCADE,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    sample_label VARCHAR(255) NOT NULL,
    file_name VARCHAR(255) NOT NULL,
    file_size BIGINT,
    mime_type VARCHAR(255),
    parameter_name VARCHAR(255),
    success BOOLEAN
);

CREATE TABLE IF NOT EXISTS jmeter_jdbc_requests(
    id BIGSERIAL,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    test_run_id UUID NOT NULL REFERENCES test_runs(id) ON DELETE CASCADE,
    sample_label VARCHAR(255) NOT NULL,
    query_type VARCHAR(50),
    query TEXT,
    parameters JSONB,
    rows_affected INTEGER,
    execution_time INTEGER,
    success BOOLEAN,
    error_message TEXT,
    PRIMARY KEY(timestamp, id)
) PARTITION BY RANGE(timestamp);

CREATE TABLE IF NOT EXISTS jmeter_transactions(
    id BIGSERIAL PRIMARY KEY,
    test_run_id UUID NOT NULL REFERENCES test_runs(id) ON DELETE CASCADE,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    transaction_name VARCHAR(255) NOT NULL,
    parent_transaction VARCHAR(255),
    duration INTEGER NOT NULL,
    success BOOLEAN NOT NULL,
    nested_samples INTEGER,
    thread_group VARCHAR(255)
);

CREATE TABLE IF NOT EXISTS jmeter_websocket_metrics(
    id BIGSERIAL,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    test_run_id UUID NOT NULL REFERENCES test_runs(id) ON DELETE CASCADE,
    connection_id VARCHAR(255),
    message_type VARCHAR(50),
    message_size BIGINT,
    connected_time INTEGER,
    status VARCHAR(50),
    close_code INTEGER,
    close_reason TEXT,
    PRIMARY KEY(timestamp, id)
) PARTITION BY RANGE(timestamp);

CREATE TABLE IF NOT EXISTS jmeter_soap_requests(
    id BIGSERIAL,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    test_run_id UUID NOT NULL REFERENCES test_runs(id) ON DELETE CASCADE,
    sample_label VARCHAR(255) NOT NULL,
    wsdl_url TEXT,
    soap_method VARCHAR(255),
    soap_version VARCHAR(10),
    request_payload TEXT,
    response_payload TEXT,
    namespace TEXT,
    success BOOLEAN,
    error_message TEXT,
    PRIMARY KEY(timestamp, id)
) PARTITION BY RANGE(timestamp);

CREATE TABLE IF NOT EXISTS jmeter_form_data(
    id BIGSERIAL PRIMARY KEY,
    test_run_id UUID NOT NULL REFERENCES test_runs(id) ON DELETE CASCADE,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    sample_label VARCHAR(255) NOT NULL,
    form_name VARCHAR(255),
    field_name VARCHAR(255),
    field_value TEXT,
    field_type VARCHAR(50),
    is_file BOOLEAN DEFAULT FALSE,
    encoding VARCHAR(50)
);

CREATE TABLE IF NOT EXISTS jmeter_jms_messages(
    id BIGSERIAL,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    test_run_id UUID NOT NULL REFERENCES test_runs(id) ON DELETE CASCADE,
    sample_label VARCHAR(255) NOT NULL,
    destination_name VARCHAR(255),
    message_type VARCHAR(50),
    correlation_id VARCHAR(255),
    message_id VARCHAR(255),
    message_body TEXT,
    headers JSONB,
    properties JSONB,
    success BOOLEAN,
    PRIMARY KEY(timestamp, id)
) PARTITION BY RANGE(timestamp);

CREATE TABLE IF NOT EXISTS jmeter_oauth_tokens(
    id BIGSERIAL PRIMARY KEY,
    test_run_id UUID NOT NULL REFERENCES test_runs(id) ON DELETE CASCADE,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    token_type VARCHAR(50),
    access_token TEXT,
    refresh_token TEXT,
    expires_at TIMESTAMP WITH TIME ZONE,
    scope TEXT,
    thread_name VARCHAR(255)
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
    test_run_id UUID NOT NULL REFERENCES test_runs(id) ON DELETE CASCADE,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    cache_manager_name VARCHAR(255) NOT NULL,
    hits INTEGER,
    misses INTEGER,
    total_entries INTEGER,
    max_size INTEGER,
    clear_count INTEGER
);

CREATE TABLE IF NOT EXISTS jmeter_property_modifications(
    id BIGSERIAL PRIMARY KEY,
    test_run_id UUID NOT NULL REFERENCES test_runs(id) ON DELETE CASCADE,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    property_name VARCHAR(255) NOT NULL,
    old_value TEXT,
    new_value TEXT,
    modifier_type VARCHAR(50),
    thread_name VARCHAR(255)
);

CREATE TABLE IF NOT EXISTS jmeter_http2_metrics(
    id BIGSERIAL,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    test_run_id UUID NOT NULL REFERENCES test_runs(id) ON DELETE CASCADE,
    stream_id INTEGER,
    parent_stream_id INTEGER,
    weight INTEGER,
    exclusive BOOLEAN,
    dependent_streams INTEGER[],
    frame_type VARCHAR(50),
    window_size INTEGER,
    window_update INTEGER,
    PRIMARY KEY(timestamp, id)
) PARTITION BY RANGE(timestamp);

CREATE TABLE IF NOT EXISTS jmeter_assertions_detail(
    id BIGSERIAL,
    test_run_id UUID NOT NULL REFERENCES test_runs(id) ON DELETE CASCADE,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    assertion_type VARCHAR(50) NOT NULL,
    sample_label VARCHAR(255) NOT NULL,
    assertion_path TEXT,
    expected_value TEXT,
    actual_value TEXT,
    success BOOLEAN NOT NULL,
    failure_message TEXT,
    PRIMARY KEY(timestamp, id)
) PARTITION BY RANGE(timestamp);

CREATE TABLE IF NOT EXISTS jmeter_ssl_info(
    id BIGSERIAL PRIMARY KEY,
    test_run_id UUID NOT NULL REFERENCES test_runs(id) ON DELETE CASCADE,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    hostname VARCHAR(255) NOT NULL,
    protocol VARCHAR(50),
    cipher_suite VARCHAR(255),
    certificate_info JSONB,
    session_reused BOOLEAN,
    handshake_time INTEGER
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

CREATE OR REPLACE FUNCTION create_monthly_partitions(table_names TEXT[]) RETURNS void AS $$
DECLARE
    table_name TEXT;
    sd DATE := DATE_TRUNC('month', CURRENT_DATE);
    pd DATE;
    pn TEXT;
BEGIN
    FOREACH table_name IN ARRAY table_names LOOP
        FOR i IN 0..11 LOOP
            pd := sd + (i * INTERVAL '1 month');
            pn := table_name || '_' || TO_CHAR(pd, 'YYYY_MM');
            EXECUTE FORMAT('CREATE TABLE IF NOT EXISTS %I PARTITION OF %I FOR VALUES FROM (%L) TO (%L)',
                pn, table_name, pd, pd + INTERVAL '1 month');
            EXECUTE FORMAT('CREATE INDEX IF NOT EXISTS idx_%s_test_run ON %I(test_run_id)', pn, pn);
            EXECUTE FORMAT('CREATE INDEX IF NOT EXISTS idx_%s_timestamp ON %I(timestamp DESC)', pn, pn);
        END LOOP;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

SELECT create_monthly_partitions(ARRAY['jmeter_results', 'system_metrics', 'jmeter_responses', 'jmeter_errors']);

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

CREATE OR REPLACE FUNCTION maintain_partitions() 
RETURNS void AS $$
DECLARE 
    fd DATE;
    pn TEXT;
    error_count INT := 0;
    error_message TEXT;
    tables TEXT[] := ARRAY['jmeter_results', 'system_metrics', 'jmeter_responses', 'jmeter_errors', 
                          'jmeter_jdbc_requests', 'jmeter_websocket_metrics', 'jmeter_soap_requests', 
                          'jmeter_jms_messages', 'jmeter_http2_metrics', 'jmeter_assertions_detail', 'variables_history', 'backend_metrics', 'jmeter_plugin_metrics'];
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
EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'Error in maintain_partitions: %', SQLERRM;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION cleanup_old_data(rm INTEGER) RETURNS void AS $$
DECLARE
    table_record RECORD;
BEGIN 
    FOR table_record IN 
        SELECT table_name 
        FROM information_schema.tables 
        WHERE table_schema = 'public' 
        AND table_name LIKE 'jmeter_%'
        OR table_name IN ('system_metrics', 'test_runs')
    LOOP
        PERFORM delete_old_data(table_record.table_name, 
            CASE 
                WHEN table_record.table_name = 'test_runs' THEN 'start_time'
                ELSE 'timestamp'
            END, 
            rm);
    END LOOP;
END;
$$ LANGUAGE plpgsql;

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

-- Add trigger for test_environments updated_at
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$ language 'plpgsql';

CREATE TRIGGER update_test_environments_updated_at
    BEFORE UPDATE ON test_environments
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

-- Add grants for functions
DO $$
BEGIN
    GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO __JMETER_DB_USER__;
    GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO __GRAFANA_DB_USER__;
END$$;

-- Add schema version tracking
CREATE TABLE IF NOT EXISTS schema_version (
    version INTEGER PRIMARY KEY,
    applied_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    description TEXT
);

-- Add database validation
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'jmeter') THEN
        RAISE EXCEPTION 'Database "jmeter" does not exist';
    END IF;
END$$;

-- Add final status check
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_tables WHERE tablename = 'test_runs') THEN
        RAISE EXCEPTION 'Schema setup failed - core tables missing';
    END IF;
END$$;

-- Add analyze after setup
VACUUM ANALYZE;

-- Add support for JMeter Backend Listener specific tables
CREATE TABLE IF NOT EXISTS backend_metrics (
    id BIGSERIAL,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    test_run_id UUID NOT NULL REFERENCES test_runs(id) ON DELETE CASCADE,
    metric_name VARCHAR(255) NOT NULL,
    metric_type VARCHAR(50) NOT NULL,
    value NUMERIC(20,2),
    PRIMARY KEY(timestamp, id)
) PARTITION BY RANGE(timestamp);

-- Add support for JMeter variables and properties tracking
CREATE TABLE IF NOT EXISTS jmeter_runtime_info (
    id BIGSERIAL PRIMARY KEY,
    test_run_id UUID NOT NULL REFERENCES test_runs(id) ON DELETE CASCADE,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    jmeter_version VARCHAR(50),
    java_version VARCHAR(100),
    system_properties JSONB,
    jmeter_properties JSONB,
    user_properties JSONB
);

-- Add support for JMeter distributed testing
CREATE TABLE IF NOT EXISTS jmeter_remote_engines (
    id BIGSERIAL PRIMARY KEY,
    test_run_id UUID NOT NULL REFERENCES test_runs(id) ON DELETE CASCADE,
    hostname VARCHAR(255) NOT NULL,
    port INTEGER,
    status VARCHAR(50),
    last_check TIMESTAMP WITH TIME ZONE,
    jmeter_version VARCHAR(50),
    system_info JSONB
);

-- Add support for JMeter plugin metrics
CREATE TABLE IF NOT EXISTS jmeter_plugin_metrics (
    id BIGSERIAL,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    test_run_id UUID NOT NULL REFERENCES test_runs(id) ON DELETE CASCADE,
    plugin_name VARCHAR(255) NOT NULL,
    metric_name VARCHAR(255) NOT NULL,
    metric_value NUMERIC,
    metadata JSONB,
    PRIMARY KEY(timestamp, id)
) PARTITION BY RANGE(timestamp);

-- Add support for Test Fragment tracking
CREATE TABLE IF NOT EXISTS jmeter_test_fragments (
    id BIGSERIAL PRIMARY KEY,
    test_run_id UUID NOT NULL REFERENCES test_runs(id) ON DELETE CASCADE,
    fragment_name VARCHAR(255) NOT NULL,
    enabled BOOLEAN DEFAULT true,
    parameters JSONB,
    content TEXT
);

-- Add helper function for plugin metrics
CREATE OR REPLACE FUNCTION record_plugin_metric(
    p_test_run_id UUID,
    p_plugin_name VARCHAR,
    p_metric_name VARCHAR,
    p_value NUMERIC,
    p_metadata JSONB DEFAULT NULL
) RETURNS VOID AS $$
BEGIN
    INSERT INTO jmeter_plugin_metrics (
        timestamp, test_run_id, plugin_name, metric_name, metric_value, metadata
    ) VALUES (
        CURRENT_TIMESTAMP, p_test_run_id, p_plugin_name, p_metric_name, p_value, p_metadata
    );
END;
$$ LANGUAGE plpgsql;

-- Add indices for new tables
CREATE INDEX IF NOT EXISTS idx_backend_metrics_name ON backend_metrics(metric_name);
CREATE INDEX IF NOT EXISTS idx_backend_metrics_type ON backend_metrics(metric_type);
CREATE INDEX IF NOT EXISTS idx_plugin_metrics_name ON jmeter_plugin_metrics(plugin_name, metric_name);
CREATE INDEX IF NOT EXISTS idx_remote_engines_host ON jmeter_remote_engines(hostname);

-- Add support for JMeter module data (e.g. groovy, beanshell, etc.)
CREATE TABLE IF NOT EXISTS jmeter_module_data (
    id BIGSERIAL PRIMARY KEY,
    test_run_id UUID NOT NULL REFERENCES test_runs(id) ON DELETE CASCADE,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    module_type VARCHAR(50) NOT NULL,
    module_name VARCHAR(255) NOT NULL,
    script_content TEXT,
    parameters JSONB,
    compiled_cache TEXT,
    execution_result TEXT
);

-- Add support for JMeter test plan structure
CREATE TABLE IF NOT EXISTS jmeter_test_plan_structure (
    id BIGSERIAL PRIMARY KEY,
    test_run_id UUID NOT NULL REFERENCES test_runs(id) ON DELETE CASCADE,
    element_id VARCHAR(255) NOT NULL,
    parent_id VARCHAR(255),
    element_type VARCHAR(100) NOT NULL,
    element_name VARCHAR(255) NOT NULL,
    enabled BOOLEAN DEFAULT true,
    configuration JSONB,
    execution_order INTEGER
);

-- Add support for JMeter library management
CREATE TABLE IF NOT EXISTS jmeter_libraries (
    id BIGSERIAL PRIMARY KEY,
    test_run_id UUID NOT NULL REFERENCES test_runs(id) ON DELETE CASCADE,
    library_path VARCHAR(255) NOT NULL,
    library_type VARCHAR(50) NOT NULL,
    version VARCHAR(50),
    loaded_timestamp TIMESTAMP WITH TIME ZONE,
    status VARCHAR(50),
    error_message TEXT
);

-- Add support for JMeter user defined variables
CREATE TABLE IF NOT EXISTS jmeter_user_variables (
    id BIGSERIAL PRIMARY KEY,
    test_run_id UUID NOT NULL REFERENCES test_runs(id) ON DELETE CASCADE,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    variable_namespace VARCHAR(100),
    variable_name VARCHAR(255) NOT NULL,
    variable_value TEXT,
    scope VARCHAR(50),
    thread_name VARCHAR(255),
    modification_source VARCHAR(100)
);

-- Add composite indices for common queries
CREATE INDEX IF NOT EXISTS idx_module_data_composite ON jmeter_module_data(test_run_id, module_type, timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_test_plan_tree ON jmeter_test_plan_structure(test_run_id, parent_id);
CREATE INDEX IF NOT EXISTS idx_libraries_status ON jmeter_libraries(test_run_id, status);
CREATE INDEX IF NOT EXISTS idx_user_vars_namespace ON jmeter_user_variables(test_run_id, variable_namespace);

-- Add support for controller execution tracking
CREATE TABLE IF NOT EXISTS jmeter_controller_data (
    id BIGSERIAL PRIMARY KEY,
    test_run_id UUID NOT NULL REFERENCES test_runs(id) ON DELETE CASCADE,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    controller_name VARCHAR(255) NOT NULL,
    controller_type VARCHAR(100) NOT NULL,
    iteration_count INTEGER,
    current_index INTEGER,
    condition_result BOOLEAN,
    next_index INTEGER,
    runtime_vars JSONB
);

-- Add these to partition maintenance
CREATE OR REPLACE FUNCTION maintain_partitions() 
RETURNS void AS $$
DECLARE 
    fd DATE;
    pn TEXT;
    error_count INT := 0;
    error_message TEXT;
    tables TEXT[] := ARRAY['jmeter_results', 'system_metrics', 'jmeter_responses', 'jmeter_errors', 
                          'jmeter_jdbc_requests', 'jmeter_websocket_metrics', 'jmeter_soap_requests', 
                          'jmeter_jms_messages', 'jmeter_http2_metrics', 'jmeter_assertions_detail', 'variables_history', 'backend_metrics', 'jmeter_plugin_metrics'];
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
EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'Error in maintain_partitions: %', SQLERRM;
END;
$$ LANGUAGE plpgsql;

-- Add helper function for test plan structure
CREATE OR REPLACE FUNCTION update_test_plan_structure(
    p_test_run_id UUID,
    p_elements JSONB
) RETURNS void AS $$
BEGIN
    -- Delete existing structure for this test run
    DELETE FROM jmeter_test_plan_structure WHERE test_run_id = p_test_run_id;
    
    -- Insert new structure
    INSERT INTO jmeter_test_plan_structure (
        test_run_id, element_id, parent_id, element_type, element_name, 
        enabled, configuration, execution_order
    )
    SELECT 
        p_test_run_id,
        (elem->>'elementId')::VARCHAR,
        (elem->>'parentId')::VARCHAR,
        (elem->>'elementType')::VARCHAR,
        (elem->>'elementName')::VARCHAR,
        COALESCE((elem->>'enabled')::BOOLEAN, true),
        (elem->>'configuration')::JSONB,
        COALESCE((elem->>'executionOrder')::INTEGER, 0)
    FROM jsonb_array_elements(p_elements) AS elem;
END;
$$ LANGUAGE plpgsql;

-- Add support for JMeter preprocessors and postprocessors
CREATE TABLE IF NOT EXISTS jmeter_processor_results (
    id BIGSERIAL PRIMARY KEY,
    test_run_id UUID NOT NULL REFERENCES test_runs(id) ON DELETE CASCADE,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    processor_type VARCHAR(50) NOT NULL,  -- 'PRE' or 'POST'
    processor_name VARCHAR(255) NOT NULL,
    sample_label VARCHAR(255) NOT NULL,
    modified_data TEXT,
    variables_modified JSONB,
    execution_time INTEGER
);

-- Add support for JMeter proxy recorder data
CREATE TABLE IF NOT EXISTS jmeter_recorder_events (
    id BIGSERIAL PRIMARY KEY,
    test_run_id UUID NOT NULL REFERENCES test_runs(id) ON DELETE CASCADE,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    recorded_url TEXT NOT NULL,
    request_method VARCHAR(10),
    request_headers JSONB,
    request_body TEXT,
    response_code VARCHAR(10),
    generated_sample_name VARCHAR(255),
    filters_applied JSONB
);

-- Add support for JMeter throughput controller data
CREATE TABLE IF NOT EXISTS jmeter_throughput_control (
    id BIGSERIAL PRIMARY KEY,
    test_run_id UUID NOT NULL REFERENCES test_runs(id) ON DELETE CASCADE,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    controller_name VARCHAR(255) NOT NULL,
    percent_execution NUMERIC(5,2),
    execution_count INTEGER,
    total_executions INTEGER,
    thread_name VARCHAR(255)
);

-- Add support for JMeter function helper data
CREATE TABLE IF NOT EXISTS jmeter_function_calls (
    id BIGSERIAL PRIMARY KEY,
    test_run_id UUID NOT NULL REFERENCES test_runs(id) ON DELETE CASCADE,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    function_name VARCHAR(255) NOT NULL,
    parameters JSONB,
    result TEXT,
    cache_hit BOOLEAN,
    execution_time INTEGER,
    thread_name VARCHAR(255)
);

-- Add indices for new tables
CREATE INDEX IF NOT EXISTS idx_processor_results_comp ON jmeter_processor_results(test_run_id, processor_type, timestamp);
CREATE INDEX IF NOT EXISTS idx_recorder_events_url ON jmeter_recorder_events(recorded_url);
CREATE INDEX IF NOT EXISTS idx_throughput_ctrl_name ON jmeter_throughput_control(controller_name);
CREATE INDEX IF NOT EXISTS idx_function_calls_name ON jmeter_function_calls(function_name);

-- Add function for recording function calls
CREATE OR REPLACE FUNCTION record_function_call(
    p_test_run_id UUID,
    p_function_name VARCHAR,
    p_parameters JSONB,
    p_result TEXT,
    p_cache_hit BOOLEAN,
    p_execution_time INTEGER,
    p_thread_name VARCHAR
) RETURNS void AS $$
BEGIN
    INSERT INTO jmeter_function_calls (
        test_run_id, timestamp, function_name, parameters, result, 
        cache_hit, execution_time, thread_name
    ) VALUES (
        p_test_run_id, CURRENT_TIMESTAMP, p_function_name, p_parameters, 
        p_result, p_cache_hit, p_execution_time, p_thread_name
    );
END;
$$ LANGUAGE plpgsql;

-- Add view for preprocessor/postprocessor analysis
CREATE OR REPLACE VIEW vw_processor_analysis AS
SELECT 
    pr.*,
    tr.test_name,
    tr.environment,
    COUNT(*) OVER (PARTITION BY pr.test_run_id, pr.processor_name) as total_executions,
    AVG(pr.execution_time) OVER (PARTITION BY pr.test_run_id, pr.processor_name) as avg_execution_time
FROM jmeter_processor_results pr
JOIN test_runs tr ON tr.id = pr.test_run_id;

-- Grant permissions for new objects
DO $$
BEGIN
    GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO __JMETER_DB_USER__;
    GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO __GRAFANA_DB_USER__;
END$$;

-- Add support for JMeter JSR223 script variables
CREATE TABLE IF NOT EXISTS jmeter_jsr223_vars (
    id BIGSERIAL PRIMARY KEY,
    test_run_id UUID NOT NULL REFERENCES test_runs(id) ON DELETE CASCADE,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    script_language VARCHAR(50) NOT NULL,
    variable_name VARCHAR(255) NOT NULL,
    variable_type VARCHAR(100),
    variable_value TEXT,
    scope VARCHAR(50),
    thread_name VARCHAR(255)
);

-- Add support for JMeter Listen-Talk-Switch Protocol
CREATE TABLE IF NOT EXISTS jmeter_ltsp_data (
    id BIGSERIAL PRIMARY KEY,
    test_run_id UUID NOT NULL REFERENCES test_runs(id) ON DELETE CASCADE,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    protocol_phase VARCHAR(50),
    message_type VARCHAR(50),
    payload TEXT,
    status VARCHAR(50),
    response_time INTEGER
);

-- Add support for JMeter property file handling
CREATE TABLE IF NOT EXISTS jmeter_property_files (
    id BIGSERIAL PRIMARY KEY,
    test_run_id UUID NOT NULL REFERENCES test_runs(id) ON DELETE CASCADE,
    file_path VARCHAR(255) NOT NULL,
    file_content TEXT,
    loaded_timestamp TIMESTAMP WITH TIME ZONE,
    properties_count INTEGER,
    checksum VARCHAR(64)
);

-- Add indices for new tables
CREATE INDEX IF NOT EXISTS idx_jsr223_vars_script ON jmeter_jsr223_vars(script_language, variable_name);
CREATE INDEX IF NOT EXISTS idx_ltsp_data_phase ON jmeter_ltsp_data(protocol_phase, message_type);
CREATE INDEX IF NOT EXISTS idx_property_files_path ON jmeter_property_files(file_path);

-- Add support for JMeter Random Variables
CREATE TABLE IF NOT EXISTS jmeter_random_vars (
    id BIGSERIAL PRIMARY KEY,
    test_run_id UUID NOT NULL REFERENCES test_runs(id) ON DELETE CASCADE,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    variable_name VARCHAR(255) NOT NULL,
    minimum_value NUMERIC,
    maximum_value NUMERIC,
    seed BIGINT,
    per_thread BOOLEAN,
    generated_value NUMERIC
);

-- Add support for JMeter Critical Section Controller
CREATE TABLE IF NOT EXISTS jmeter_critical_sections (
    id BIGSERIAL PRIMARY KEY,
    test_run_id UUID NOT NULL REFERENCES test_runs(id) ON DELETE CASCADE,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    section_name VARCHAR(255) NOT NULL,
    thread_name VARCHAR(255),
    entry_time TIMESTAMP WITH TIME ZONE,
    exit_time TIMESTAMP WITH TIME ZONE,
    lock_time INTEGER,
    wait_time INTEGER
);

-- Add support for JMeter BeanShell Server
CREATE TABLE IF NOT EXISTS jmeter_beanshell_server (
    id BIGSERIAL PRIMARY KEY,
    test_run_id UUID NOT NULL REFERENCES test_runs(id) ON DELETE CASCADE,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    server_port INTEGER,
    server_name VARCHAR(255),
    script_name VARCHAR(255),
    properties JSONB,
    connection_count INTEGER
);

-- Add indices for new tables
CREATE INDEX IF NOT EXISTS idx_random_vars_name ON jmeter_random_vars(variable_name);
CREATE INDEX IF NOT EXISTS idx_critical_sections_name ON jmeter_critical_sections(section_name);
CREATE INDEX IF NOT EXISTS idx_beanshell_server_port ON jmeter_beanshell_server(server_port);

-- Add support for JMeter Switch Controller conditions
CREATE TABLE IF NOT EXISTS jmeter_switch_conditions (
    id BIGSERIAL PRIMARY KEY,
    test_run_id UUID NOT NULL REFERENCES test_runs(id) ON DELETE CASCADE,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    controller_name VARCHAR(255) NOT NULL,
    selected_value TEXT,
    matched_condition TEXT,
    default_used BOOLEAN,
    execution_path TEXT[]
);

-- Add support for JMeter HTML report assets
CREATE TABLE IF NOT EXISTS jmeter_report_assets (
    id BIGSERIAL PRIMARY KEY,
    test_run_id UUID NOT NULL REFERENCES test_runs(id) ON DELETE CASCADE,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    asset_type VARCHAR(50) NOT NULL,
    asset_name VARCHAR(255) NOT NULL,
    content_type VARCHAR(100),
    asset_content BYTEA,
    checksum VARCHAR(64)
);

-- Add support for JMeter parameter value tracking
CREATE TABLE IF NOT EXISTS jmeter_parameter_values (
    id BIGSERIAL PRIMARY KEY,
    test_run_id UUID NOT NULL REFERENCES test_runs(id) ON DELETE CASCADE,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    parameter_name VARCHAR(255) NOT NULL,
    parameter_value TEXT,
    source_element VARCHAR(255),
    thread_name VARCHAR(255),
    iteration INTEGER
);

-- Add indices for new tables
CREATE INDEX IF NOT EXISTS idx_switch_conditions_name ON jmeter_switch_conditions(controller_name);
CREATE INDEX IF NOT EXISTS idx_report_assets_type ON jmeter_report_assets(asset_type, asset_name);
CREATE INDEX IF NOT EXISTS idx_parameter_values_name ON jmeter_parameter_values(parameter_name);

-- Add support for JMeter module script compilation cache
CREATE TABLE IF NOT EXISTS jmeter_script_cache (
    id BIGSERIAL PRIMARY KEY,
    test_run_id UUID NOT NULL REFERENCES test_runs(id) ON DELETE CASCADE,
    script_path VARCHAR(255) NOT NULL,
    script_type VARCHAR(50) NOT NULL,
    compiled_content BYTEA,
    compilation_timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    hash VARCHAR(64) NOT NULL,
    compiler_version VARCHAR(50),
    UNIQUE(script_path, hash)
);

-- Add support for JMeter CSV data validation results
CREATE TABLE IF NOT EXISTS jmeter_csv_validation (
    id BIGSERIAL PRIMARY KEY,
    test_run_id UUID NOT NULL REFERENCES test_runs(id) ON DELETE CASCADE,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    csv_file VARCHAR(255) NOT NULL,
    row_number INTEGER,
    column_name VARCHAR(255),
    validation_rule TEXT,
    is_valid BOOLEAN,
    error_message TEXT
);

-- Add support for JMeter Cookie Manager detailed tracking
CREATE TABLE IF NOT EXISTS jmeter_cookie_details (
    id BIGSERIAL PRIMARY KEY,
    test_run_id UUID NOT NULL REFERENCES test_runs(id) ON DELETE CASCADE,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    cookie_name VARCHAR(255) NOT NULL,
    cookie_value TEXT,
    domain VARCHAR(255),
    path VARCHAR(255),
    secure BOOLEAN,
    expires TIMESTAMP WITH TIME ZONE,
    thread_name VARCHAR(255)
);

-- Add indices for new tables
CREATE INDEX IF NOT EXISTS idx_script_cache_path ON jmeter_script_cache(script_path, hash);
CREATE INDEX IF NOT EXISTS idx_csv_validation_file ON jmeter_csv_validation(csv_file, row_number);
CREATE INDEX IF NOT EXISTS idx_cookie_details_name ON jmeter_cookie_details(cookie_name, domain);

-- Add support for JMeter Java Request class tracking
CREATE TABLE IF NOT EXISTS jmeter_java_requests (
    id BIGSERIAL PRIMARY KEY,
    test_run_id UUID NOT NULL REFERENCES test_runs(id) ON DELETE CASCADE,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    class_name VARCHAR(255) NOT NULL,
    method_name VARCHAR(255) NOT NULL,
    parameters JSONB,
    compilation_status VARCHAR(50),
    heap_usage BIGINT,
    execution_time INTEGER,
    thread_name VARCHAR(255)
);

-- Add support for JMeter if controller expression cache
CREATE TABLE IF NOT EXISTS jmeter_if_controller_cache (
    id BIGSERIAL PRIMARY KEY,
    test_run_id UUID NOT NULL REFERENCES test_runs(id) ON DELETE CASCADE,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    expression TEXT NOT NULL,
    compiled_expression BYTEA,
    evaluation_count INTEGER,
    last_result BOOLEAN,
    variables_used TEXT[],
    thread_name VARCHAR(255)
);

-- Add support for JMeter JSON Path extractor details
CREATE TABLE IF NOT EXISTS jmeter_jsonpath_data (
    id BIGSERIAL PRIMARY KEY,
    test_run_id UUID NOT NULL REFERENCES test_runs(id) ON DELETE CASCADE,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    sample_label VARCHAR(255) NOT NULL,
    json_path VARCHAR(255) NOT NULL,
    match_number INTEGER,
    default_value TEXT,
    matched_values JSONB,
    success BOOLEAN,
    error_message TEXT
);

-- Add indices for new tables
CREATE INDEX IF NOT EXISTS idx_java_requests_class ON jmeter_java_requests(class_name, method_name);
CREATE INDEX IF NOT EXISTS idx_if_controller_expr ON jmeter_if_controller_cache(expression);
CREATE INDEX IF NOT EXISTS idx_jsonpath_data_path ON jmeter_jsonpath_data(json_path);

-- Update maintain_partitions function to include new partitioned tables if any
DO $$
BEGIN
    IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='__JMETER_DB_USER__') THEN 
        CREATE ROLE __JMETER_DB_USER__ WITH LOGIN PASSWORD '__JMETER_DB_PASSWORD__';
        GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO __JMETER_DB_USER__;
        GRANT ALL PRIVILEGES ON DATABASE jmeter TO __JMETER_DB_USER__;
        GRANT ALL PRIVILEGES ON DATABASE grafana TO __JMETER_DB_USER__;
        GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO __JMETER_DB_USER__;
        ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL PRIVILEGES ON TABLES TO __JMETER_DB_USER__;
        ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL PRIVILEGES ON SEQUENCES TO __JMETER_DB_USER__;
    END IF;
END$$;

-- Grant permissions for new objects
DO $$
BEGIN
    GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO __JMETER_DB_USER__;
    GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO __GRAFANA_DB_USER__;
END$$;

COMMIT;