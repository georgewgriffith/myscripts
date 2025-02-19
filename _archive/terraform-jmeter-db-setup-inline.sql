\set ECHO none 
\set ON_ERROR_STOP on
\timing on

-- Check if database exists
SELECT 'CREATE DATABASE jmeter'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'jmeter');

\connect jmeter

SET client_min_messages TO WARNING;

-- Begin transaction for schema setup
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
            
            -- Create appropriate indices based on table type
            IF table_name = 'system_metrics' THEN
                EXECUTE FORMAT('CREATE INDEX IF NOT EXISTS idx_%s_timestamp ON %I(timestamp DESC)', pn, pn);
            ELSE
                -- For JMeter related tables that have test_run_id
                EXECUTE FORMAT('CREATE INDEX IF NOT EXISTS idx_%s_test_run ON %I(test_run_id)', pn, pn);
                EXECUTE FORMAT('CREATE INDEX IF NOT EXISTS idx_%s_timestamp ON %I(timestamp DESC)', pn, pn);
            END IF;
        END LOOP;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- Add support for JMeter variables interpolation tracking
CREATE TABLE IF NOT EXISTS jmeter_variable_interpolations (
    id BIGSERIAL PRIMARY KEY,
    test_run_id UUID NOT NULL REFERENCES test_runs(id) ON DELETE CASCADE,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    original_string TEXT NOT NULL,
    interpolated_string TEXT NOT NULL,
    variables_used TEXT[],
    sample_label VARCHAR(255),
    thread_name VARCHAR(255)
);

-- Add support for JMeter DNS resolver configuration
CREATE TABLE IF NOT EXISTS jmeter_dns_resolver_config (
    id BIGSERIAL PRIMARY KEY,
    test_run_id UUID NOT NULL REFERENCES test_runs(id) ON DELETE CASCADE,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    custom_resolver BOOLEAN,
    nameservers TEXT[],
    search_domains TEXT[],
    resolve_timeout INTEGER,
    cache_enabled BOOLEAN,
    cache_ttl INTEGER
);

-- Add support for JMeter header manager configurations
CREATE TABLE IF NOT EXISTS jmeter_header_configs (
    id BIGSERIAL PRIMARY KEY,
    test_run_id UUID NOT NULL REFERENCES test_runs(id) ON DELETE CASCADE,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    header_name VARCHAR(255) NOT NULL,
    header_value TEXT,
    sample_label VARCHAR(255),
    scope VARCHAR(50),
    enabled BOOLEAN DEFAULT true
);

-- Add support for Constant Throughput Timer data
CREATE TABLE IF NOT EXISTS jmeter_throughput_timer (
    id BIGSERIAL PRIMARY KEY,
    test_run_id UUID NOT NULL REFERENCES test_runs(id) ON DELETE CASCADE,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    thread_group VARCHAR(255) NOT NULL,
    target_throughput NUMERIC(10,2),
    actual_throughput NUMERIC(10,2),
    delay_adjustment INTEGER,
    calculated_pause_time INTEGER
);

-- Add support for BeanShell/JSR223 Pre/Post Processor variables
CREATE TABLE IF NOT EXISTS jmeter_script_variables (
    id BIGSERIAL PRIMARY KEY,
    test_run_id UUID NOT NULL REFERENCES test_runs(id) ON DELETE CASCADE,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    processor_type VARCHAR(50) NOT NULL,
    script_type VARCHAR(50) NOT NULL,
    variable_name VARCHAR(255) NOT NULL,
    variable_value TEXT,
    script_name VARCHAR(255)
);

-- Add support for HTTP URL Rewriting Modifier
CREATE TABLE IF NOT EXISTS jmeter_url_rewriting (
    id BIGSERIAL PRIMARY KEY,
    test_run_id UUID NOT NULL REFERENCES test_runs(id) ON DELETE CASCADE,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    sample_label VARCHAR(255) NOT NULL,
    parameter_name VARCHAR(255) NOT NULL,
    path_extension BOOLEAN,
    path_extension_no_equals BOOLEAN,
    cache_value BOOLEAN
);

-- Add support for JMeter property function calls
CREATE TABLE IF NOT EXISTS jmeter_property_functions (
    id BIGSERIAL PRIMARY KEY,
    test_run_id UUID NOT NULL REFERENCES test_runs(id) ON DELETE CASCADE,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    function_name VARCHAR(255) NOT NULL,
    property_name VARCHAR(255) NOT NULL,
    default_value TEXT,
    resolved_value TEXT,
    thread_name VARCHAR(255)
);

-- Add support for JMeter Random Controller execution paths
CREATE TABLE IF NOT EXISTS jmeter_random_controller (
    id BIGSERIAL PRIMARY KEY,
    test_run_id UUID NOT NULL REFERENCES test_runs(id) ON DELETE CASCADE,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    controller_name VARCHAR(255) NOT NULL,
    num_children INTEGER,
    selected_child INTEGER,
    thread_name VARCHAR(255)
);

-- Add support for Target Rate Controller metrics
CREATE TABLE IF NOT EXISTS jmeter_target_rate_metrics (
    id BIGSERIAL PRIMARY KEY,
    test_run_id UUID NOT NULL REFERENCES test_runs(id) ON DELETE CASCADE,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    controller_name VARCHAR(255) NOT NULL,
    target_rate NUMERIC(10,2),
    actual_rate NUMERIC(10,2),
    period INTEGER,
    thread_name VARCHAR(255)
);

-- Add indices for new tables
CREATE INDEX IF NOT EXISTS idx_variable_interpolations_test ON jmeter_variable_interpolations(test_run_id);
CREATE INDEX IF NOT EXISTS idx_dns_resolver_config_test ON jmeter_dns_resolver_config(test_run_id);
CREATE INDEX IF NOT EXISTS idx_header_configs_name ON jmeter_header_configs(header_name);
CREATE INDEX IF NOT EXISTS idx_throughput_timer_test ON jmeter_throughput_timer(test_run_id);
CREATE INDEX IF NOT EXISTS idx_script_variables_test ON jmeter_script_variables(test_run_id);
CREATE INDEX IF NOT EXISTS idx_url_rewriting_test ON jmeter_url_rewriting(test_run_id);
CREATE INDEX IF NOT EXISTS idx_property_functions_name ON jmeter_property_functions(function_name);
CREATE INDEX IF NOT EXISTS idx_random_controller_name ON jmeter_random_controller(controller_name);
CREATE INDEX IF NOT EXISTS idx_target_rate_metrics_test ON jmeter_target_rate_metrics(test_run_id);

-- Add view for comprehensive script variable analysis
CREATE OR REPLACE VIEW vw_script_variable_analysis AS
WITH var_stats AS (
    SELECT 
        test_run_id,
        processor_type,
        script_type,
        COUNT(DISTINCT variable_name) as unique_vars,
        COUNT(*) as total_modifications
    FROM jmeter_script_variables
    GROUP BY test_run_id, processor_type, script_type
)
SELECT 
    vs.*,
    tr.test_name,
    tr.environment,
    tr.start_time
FROM var_stats vs
JOIN test_runs tr ON tr.id = vs.test_run_id;

-- Grant permissions for new objects
DO $$
BEGIN
    GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO __JMETER_DB_USER__;
    GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO __GRAFANA_DB_USER__;
END$$;

CREATE OR REPLACE FUNCTION maintain_partitions() 
RETURNS void AS $$
DECLARE 
    tables TEXT[] := ARRAY[
        'system_metrics',
        'jmeter_results',
        'jmeter_errors',
        'jmeter_responses',
        'variables_history',
        'jmeter_custom_metrics',
        'jmeter_jdbc_requests',
        'jmeter_transactions',
        'jmeter_websocket_metrics',
        'jmeter_soap_requests',
        'jmeter_jms_messages',
        'jmeter_http2_metrics',
        'jmeter_assertions_detail',
        'jmeter_target_rate_metrics',
        'jmeter_property_functions',
        'jmeter_random_controller',
        'jmeter_throughput_timer',
        'jmeter_script_variables',
        'jmeter_url_rewriting'
    ];
    sd DATE := DATE_TRUNC('month', CURRENT_DATE);
    pd DATE;
    pn TEXT;
BEGIN
    FOREACH table_name IN ARRAY tables LOOP
        FOR i IN 0..11 LOOP
            pd := sd + (i * INTERVAL '1 month');
            pn := table_name || '_' || TO_CHAR(pd, 'YYYY_MM');
            EXECUTE FORMAT('CREATE TABLE IF NOT EXISTS %I PARTITION OF %I FOR VALUES FROM (%L) TO (%L)',
                pn, table_name, pd, pd + INTERVAL '1 month');
            
            -- Create appropriate indices based on table type
            IF table_name = 'system_metrics' THEN
                EXECUTE FORMAT('CREATE INDEX IF NOT EXISTS idx_%s_timestamp ON %I(timestamp DESC)', pn, pn);
            ELSE
                -- For JMeter related tables that have test_run_id
                EXECUTE FORMAT('CREATE INDEX IF NOT EXISTS idx_%s_test_run ON %I(test_run_id)', pn, pn);
                EXECUTE FORMAT('CREATE INDEX IF NOT EXISTS idx_%s_timestamp ON %I(timestamp DESC)', pn, pn);
            END IF;
        END LOOP;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

COMMIT;