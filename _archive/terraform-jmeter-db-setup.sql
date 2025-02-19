/*
 * JMeter Database Setup Script for Azure PostgreSQL
 * ----------------------------------------------
 * This script sets up the complete database schema for JMeter test results
 * including partitioning, maintenance functions, and monitoring capabilities.
 * 
 * Requirements:
 * - Azure PostgreSQL 14+
 * - Azure AD authentication
 * - azure_pg_admin privileges
 */

-- Disable output of commands
\set ECHO none
\set ON_ERROR_STOP on

-- Show execution plan
\timing on

-- Connect to postgres first to create databases if they don't exist
\connect postgres

-- Create required databases
DO $$ 
BEGIN
    IF NOT EXISTS (SELECT FROM pg_database WHERE datname = 'jmeter') THEN
        CREATE DATABASE jmeter;
    END IF;
    IF NOT EXISTS (SELECT FROM pg_database WHERE datname = 'grafana') THEN
        CREATE DATABASE grafana;
    END IF;
END $$;

-- Connect to jmeter database for main setup
\connect jmeter

-- Enable proper error handling
\set ON_ERROR_STOP on

-- Set proper session parameters for Azure PostgreSQL
SET SESSION AUTHORIZATION azure_pg_admin;
SET client_min_messages TO WARNING;

-- Begin initial setup transaction
BEGIN;

-- Create metrics schema
DO $$ 
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'metrics') THEN
        CREATE SCHEMA metrics;
    END IF;
END $$;

-- Create system logging table first (required for all operations)
CREATE TABLE IF NOT EXISTS metrics.system_logs (
    id BIGSERIAL PRIMARY KEY,
    timestamp TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    hostname TEXT,
    source TEXT,
    log_level TEXT,
    message TEXT
);

-- Create necessary indexes for system logs
CREATE INDEX IF NOT EXISTS idx_system_logs_timestamp 
ON metrics.system_logs(timestamp DESC);

-- Create system metrics table for direct logging
CREATE TABLE IF NOT EXISTS metrics.system_metrics (
    id BIGSERIAL PRIMARY KEY,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    hostname TEXT NOT NULL,
    measurement TEXT NOT NULL,
    value NUMERIC(10,2) NOT NULL,
    tags JSONB
);

-- Create index for system metrics
CREATE INDEX IF NOT EXISTS idx_system_metrics_timestamp 
ON metrics.system_metrics(timestamp DESC);

CREATE INDEX IF NOT EXISTS idx_system_metrics_hostname 
ON metrics.system_metrics(hostname);

CREATE INDEX IF NOT EXISTS idx_system_metrics_measurement 
ON metrics.system_metrics USING btree (measurement, timestamp DESC);

CREATE INDEX IF NOT EXISTS idx_system_metrics_tags 
ON metrics.system_metrics USING GIN (tags);

/*
 * Main JMeter Results Table
 * ------------------------
 * Partitioned by timestamp for better performance with large datasets
 * Each partition represents one month of data
 */
CREATE TABLE IF NOT EXISTS metrics.jmeter_results (
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
) PARTITION BY RANGE (timestamp);

/*
 * Supporting Tables
 * ---------------
 * test_runs: Stores test execution metadata
 * jmeter_live_metrics: Real-time metrics during test execution
 * jmeter_errors: Detailed error tracking
 */
CREATE TABLE IF NOT EXISTS metrics.test_runs (
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

CREATE TABLE IF NOT EXISTS metrics.jmeter_live_metrics (
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    test_run_id UUID NOT NULL,
    active_threads INTEGER,
    throughput NUMERIC(10,2),
    error_rate NUMERIC(5,2),
    avg_response_time NUMERIC(10,2),
    CONSTRAINT pk_live_metrics PRIMARY KEY (timestamp, test_run_id)
);

CREATE TABLE IF NOT EXISTS metrics.jmeter_errors (
    id BIGSERIAL PRIMARY KEY,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    test_run_id UUID NOT NULL,
    sample_label VARCHAR(255) NOT NULL,
    error_message TEXT,
    response_code VARCHAR(10),
    thread_name VARCHAR(255),
    stack_trace TEXT
);

-- Add missing JMeter results tables
CREATE TABLE IF NOT EXISTS metrics.jmeter_assertions (
    id BIGSERIAL PRIMARY KEY,
    test_run_id UUID NOT NULL REFERENCES metrics.test_runs(id),
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    sample_label VARCHAR(255) NOT NULL,
    assertion_name VARCHAR(255) NOT NULL,
    success BOOLEAN NOT NULL,
    failure_message TEXT,
    CONSTRAINT fk_assertion_test_run FOREIGN KEY (test_run_id) 
        REFERENCES metrics.test_runs(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS metrics.jmeter_sub_results (
    id BIGSERIAL PRIMARY KEY,
    parent_sample_id BIGINT NOT NULL,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    test_run_id UUID NOT NULL,
    sample_label VARCHAR(255) NOT NULL,
    response_time INTEGER NOT NULL,
    success BOOLEAN NOT NULL,
    response_code VARCHAR(10),
    response_message TEXT,
    CONSTRAINT fk_subresult_test_run FOREIGN KEY (test_run_id) 
        REFERENCES metrics.test_runs(id) ON DELETE CASCADE
);

-- Add test configuration tracking
CREATE TABLE IF NOT EXISTS metrics.test_configurations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    test_run_id UUID NOT NULL,
    thread_group VARCHAR(255) NOT NULL,
    num_threads INTEGER NOT NULL,
    ramp_up INTEGER,
    duration INTEGER,
    target_throughput NUMERIC(10,2),
    properties JSONB,
    CONSTRAINT fk_config_test_run FOREIGN KEY (test_run_id) 
        REFERENCES metrics.test_runs(id) ON DELETE CASCADE
);

-- Add test variables tracking
CREATE TABLE IF NOT EXISTS metrics.test_variables (
    id BIGSERIAL PRIMARY KEY,
    test_run_id UUID NOT NULL,
    variable_name VARCHAR(255) NOT NULL,
    variable_value TEXT,
    scope VARCHAR(50),
    CONSTRAINT fk_variable_test_run FOREIGN KEY (test_run_id) 
        REFERENCES metrics.test_runs(id) ON DELETE CASCADE
);

/*
 * Partition Management
 * ------------------
 * Creates 12 months of partitions plus management functions
 * Automatically creates new partitions and drops old ones
 */
DO $$ 
DECLARE
    start_date DATE := DATE_TRUNC('month', CURRENT_DATE);
    partition_date DATE;
    partition_name TEXT;
    sql TEXT;
BEGIN
    FOR i IN 0..11 LOOP
        partition_date := start_date + (i * INTERVAL '1 month');
        partition_name := 'jmeter_results_' || TO_CHAR(partition_date, 'YYYY_MM');
        
        -- Create partition
        sql := FORMAT(
            'CREATE TABLE IF NOT EXISTS metrics.%I PARTITION OF metrics.jmeter_results 
            FOR VALUES FROM (%L) TO (%L)',
            partition_name,
            partition_date,
            partition_date + INTERVAL '1 month'
        );
        EXECUTE sql;
        
        -- Create indexes
        EXECUTE FORMAT(
            'CREATE INDEX IF NOT EXISTS %I ON metrics.%I USING btree (timestamp, test_name, thread_group)',
            'idx_' || partition_name || '_main',
            partition_name
        );
        
        EXECUTE FORMAT(
            'CREATE INDEX IF NOT EXISTS %I ON metrics.%I USING btree (test_run_id)',
            'idx_' || partition_name || '_run',
            partition_name
        );
    END LOOP;
END $$;

/*
 * Maintenance Functions
 * -------------------
 * maintain_partitions: Creates future partitions and cleans old ones
 * cleanup_old_data: Removes data older than specified retention period
 * yearly_cleanup: Annual cleanup of old partitions and data
 * calculate_test_metrics: Computes test statistics
 */
CREATE OR REPLACE FUNCTION metrics.maintain_partitions() 
RETURNS void
AS $func$
DECLARE
    future_date DATE;
    partition_name TEXT;
    sql TEXT;
BEGIN
    -- Create next month's partition
    future_date := DATE_TRUNC('month', CURRENT_DATE + INTERVAL '2 months');
    partition_name := 'jmeter_results_' || TO_CHAR(future_date, 'YYYY_MM');
    
    -- Create partition
    sql := FORMAT(
        'CREATE TABLE IF NOT EXISTS metrics.%I PARTITION OF metrics.jmeter_results
        FOR VALUES FROM (%L) TO (%L)',
        partition_name,
        future_date,
        future_date + INTERVAL '1 month'
    );
    EXECUTE sql;
    
    -- Create indexes
    EXECUTE FORMAT(
        'CREATE INDEX IF NOT EXISTS %I ON metrics.%I USING btree (timestamp, test_name, thread_group)',
        'idx_' || partition_name || '_main',
        partition_name
    );
    
    EXECUTE FORMAT(
        'CREATE INDEX IF NOT EXISTS %I ON metrics.%I USING btree (test_run_id)',
        'idx_' || partition_name || '_run',
        partition_name
    );
    
    -- Drop old partitions
    sql := FORMAT(
        'DROP TABLE IF EXISTS metrics.jmeter_results_%s',
        TO_CHAR(CURRENT_DATE - INTERVAL '12 months', 'YYYY_MM')
    );
    EXECUTE sql;
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'Error in maintain_partitions: %', SQLERRM;
        RAISE;
END;
$func$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION metrics.cleanup_old_data(retention_months INTEGER) 
RETURNS void
AS $func$
BEGIN
    -- Clean old data
    DELETE FROM metrics.jmeter_results 
    WHERE timestamp < CURRENT_DATE - (retention_months * INTERVAL '1 month');
    
    DELETE FROM metrics.test_runs 
    WHERE start_time < CURRENT_DATE - (retention_months * INTERVAL '1 month');
    
    DELETE FROM metrics.jmeter_errors 
    WHERE timestamp < CURRENT_DATE - (retention_months * INTERVAL '1 month');
    
    -- Keep shorter retention for live metrics
    DELETE FROM metrics.jmeter_live_metrics 
    WHERE timestamp < CURRENT_DATE - INTERVAL '1 month';
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'Error in cleanup_old_data: %', SQLERRM;
        RAISE;
END;
$func$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION metrics.yearly_cleanup() 
RETURNS void
AS $func$
DECLARE
    min_retention_months CONSTANT INTEGER := 12;
    cutoff_date DATE;
    partition_name TEXT;
BEGIN
    -- Set cutoff date to one year ago
    cutoff_date := CURRENT_DATE - INTERVAL '1 year';
    
    -- Drop partitions older than one year
    FOR partition_name IN 
        SELECT tablename 
        FROM pg_tables 
        WHERE schemaname = 'metrics' 
          AND tablename LIKE 'jmeter_results_%'
          AND TO_DATE(SUBSTRING(tablename FROM 15), 'YYYY_MM') < cutoff_date
    LOOP
        EXECUTE FORMAT('DROP TABLE IF NOT EXISTS metrics.%I', partition_name);
    END LOOP;

    -- Clean up related data
    PERFORM metrics.cleanup_old_data(min_retention_months);

    -- Log cleanup
    INSERT INTO metrics.system_logs (source, log_level, message)
    VALUES ('yearly_cleanup', 'INFO', 'Completed yearly cleanup of data older than ' || cutoff_date);
EXCEPTION
    WHEN OTHERS THEN
        RAISE WARNING 'Error in yearly_cleanup: %', SQLERRM;
        -- Log error
        INSERT INTO metrics.system_logs (source, log_level, message)
        VALUES ('yearly_cleanup', 'ERROR', 'Failed to cleanup: ' || SQLERRM);
        RAISE;
END;
$func$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION metrics.calculate_test_metrics(p_test_run_id UUID) 
RETURNS void
AS $func$
BEGIN
    UPDATE metrics.test_runs tr
    SET 
        total_samples = stats.total_samples,
        error_count = stats.error_count,
        avg_response_time = stats.avg_response_time,
        p90_response_time = stats.p90,
        p95_response_time = stats.p95,
        p99_response_time = stats.p99,
        throughput = stats.throughput
    FROM (
        SELECT 
            COUNT(*) as total_samples,
            COUNT(*) FILTER (WHERE NOT success) as error_count,
            AVG(response_time) as avg_response_time,
            percentile_cont(0.90) WITHIN GROUP (ORDER BY response_time) as p90,
            percentile_cont(0.95) WITHIN GROUP (ORDER BY response_time) as p95,
            percentile_cont(0.99) WITHIN GROUP (ORDER BY response_time) as p99,
            COUNT(*) / EXTRACT(EPOCH FROM (MAX(timestamp) - MIN(timestamp))) as throughput
        FROM metrics.jmeter_results
        WHERE test_run_id = p_test_run_id
    ) stats
    WHERE tr.id = p_test_run_id;
END;
$func$ LANGUAGE plpgsql;

/*
 * Test Analysis Functions
 * ---------------------
 * summarize_test_run: Provides detailed test execution summary
 * Includes:
 * - Total samples processed
 * - Error rates
 * - Response time statistics
 * - Throughput calculations
 */
CREATE OR REPLACE FUNCTION metrics.summarize_test_run(p_test_run_id UUID)
RETURNS TABLE (
    metric_name TEXT,
    metric_value NUMERIC,
    metric_unit TEXT
) AS $func$
BEGIN
    RETURN QUERY
    WITH test_metrics AS (
        SELECT
            COUNT(*) as total_samples,
            COUNT(*) FILTER (WHERE NOT success) as error_count,
            AVG(response_time) as avg_response,
            MAX(response_time) as max_response,
            MIN(response_time) as min_response,
            percentile_cont(0.95) WITHIN GROUP (ORDER BY response_time) as p95,
            SUM(bytes) as total_bytes,
            MAX(timestamp) - MIN(timestamp) as duration
        FROM metrics.jmeter_results
        WHERE test_run_id = p_test_run_id
    )
    SELECT 'Total Samples'::TEXT, total_samples::NUMERIC, 'count'::TEXT
    FROM test_metrics
    UNION ALL
    SELECT 'Error Rate', ROUND((error_count::NUMERIC / NULLIF(total_samples, 0)) * 100, 2), 'percent'
    FROM test_metrics
    UNION ALL
    SELECT 'Average Response Time', ROUND(avg_response::NUMERIC, 2), 'ms'
    FROM test_metrics
    UNION ALL
    SELECT 'P95 Response Time', ROUND(p95::NUMERIC, 2), 'ms'
    FROM test_metrics
    UNION ALL
    SELECT 'Throughput', 
           ROUND((total_samples::NUMERIC / NULLIF(EXTRACT(EPOCH FROM duration), 0))::NUMERIC, 2),
           'requests/sec'
    FROM test_metrics;
END;
$func$ LANGUAGE plpgsql;

/*
 * Performance Optimization Indexes
 * -----------------------------
 * Indexes for common query patterns and performance optimization
 */
CREATE INDEX IF NOT EXISTS idx_test_runs_test_name ON metrics.test_runs USING btree (test_name, start_time);
CREATE INDEX IF NOT EXISTS idx_test_runs_environment ON metrics.test_runs USING btree (environment, start_time);
CREATE INDEX IF NOT EXISTS idx_jmeter_errors_test_run ON metrics.jmeter_errors USING btree (test_run_id, timestamp);
CREATE INDEX IF NOT EXISTS idx_live_metrics_test_run ON metrics.jmeter_live_metrics USING btree (test_run_id);

-- Add indexes for new tables
CREATE INDEX IF NOT EXISTS idx_assertions_test_run 
ON metrics.jmeter_assertions(test_run_id, timestamp);

CREATE INDEX IF NOT EXISTS idx_subresults_parent 
ON metrics.jmeter_sub_results(parent_sample_id);

CREATE INDEX IF NOT EXISTS idx_subresults_test_run 
ON metrics.jmeter_sub_results(test_run_id, timestamp);

CREATE INDEX IF NOT EXISTS idx_test_config_test_run 
ON metrics.test_configurations(test_run_id);

CREATE INDEX IF NOT EXISTS idx_test_variables_lookup 
ON metrics.test_variables(test_run_id, variable_name);

/*
 * Test Results Analysis View
 * ------------------------
 * Provides a comprehensive view of test execution results
 * Including performance metrics and success rates
 */
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
            WHEN tr.total_samples > 0 THEN 
                ROUND((tr.error_count::NUMERIC / tr.total_samples) * 100, 2)
            ELSE 0 
        END as error_rate,
        CASE 
            WHEN EXTRACT(EPOCH FROM (tr.end_time - tr.start_time)) > 0 THEN
                ROUND(tr.total_samples::NUMERIC / EXTRACT(EPOCH FROM (tr.end_time - tr.start_time)), 2)
            ELSE 0
        END as actual_throughput,
        tr.p90_response_time,
        tr.p99_response_time,
        CASE 
            WHEN tr.total_samples > 0 THEN 
                ROUND((tr.total_samples - tr.error_count)::NUMERIC / tr.total_samples * 100, 2)
            ELSE 0
        END as success_rate,
        metadata
    FROM metrics.test_runs tr
    WHERE tr.end_time IS NOT NULL
)
SELECT * FROM stats;

/*
 * Security and Permissions
 * ----------------------
 * Sets up required roles and permissions for JMeter data access
 */
DO $$ 
BEGIN
    -- Create metrics role if not exists
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'metrics_user') THEN
        CREATE ROLE metrics_user WITH LOGIN;
    END IF;

    -- Grant necessary permissions
    GRANT USAGE ON SCHEMA metrics TO metrics_user;
    GRANT SELECT, INSERT ON metrics.system_metrics TO metrics_user;
    GRANT SELECT, INSERT ON metrics.system_logs TO metrics_user;
    GRANT SELECT, INSERT ON metrics.jmeter_results TO metrics_user;
    GRANT SELECT, INSERT ON metrics.jmeter_errors TO metrics_user;
    GRANT SELECT, INSERT ON metrics.test_runs TO metrics_user;
    GRANT SELECT, INSERT ON metrics.jmeter_live_metrics TO metrics_user;
END $$;

/*
 * Service Account Creation and Database Access
 * -----------------------------------------
 * Creates service accounts and grants full database access
 */
DO $$ 
BEGIN
    -- Create JMeter service account
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'svc_at20109_jmeter_uat') THEN
        CREATE ROLE svc_at20109_jmeter_uat WITH LOGIN PASSWORD 'CHANGEME';
        
        -- Grant metrics schema permissions
        GRANT USAGE ON SCHEMA metrics TO svc_at20109_jmeter_uat;
        GRANT SELECT, INSERT ON ALL TABLES IN SCHEMA metrics TO svc_at20109_jmeter_uat;
        
        -- Grant full access to jmeter database
        GRANT ALL PRIVILEGES ON DATABASE jmeter TO svc_at20109_jmeter_uat;
        GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO svc_at20109_jmeter_uat;
        GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO svc_at20109_jmeter_uat;
        GRANT USAGE ON SCHEMA public TO svc_at20109_jmeter_uat;
        
        -- Set default privileges for future objects in jmeter database
        ALTER DEFAULT PRIVILEGES IN SCHEMA public 
        GRANT ALL PRIVILEGES ON TABLES TO svc_at20109_jmeter_uat;
        
        ALTER DEFAULT PRIVILEGES IN SCHEMA public 
        GRANT ALL PRIVILEGES ON SEQUENCES TO svc_at20109_jmeter_uat;
    END IF;

    -- Create Grafana service account
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'svc_at20109_grafana_uat') THEN
        CREATE ROLE svc_at20109_grafana_uat WITH LOGIN PASSWORD 'CHANGEME';
        
        -- Grant metrics schema permissions (read-only)
        GRANT USAGE ON SCHEMA metrics TO svc_at20109_grafana_uat;
        GRANT SELECT ON ALL TABLES IN SCHEMA metrics TO svc_at20109_grafana_uat;
        
        -- Grant full access to grafana database
        GRANT ALL PRIVILEGES ON DATABASE grafana TO svc_at20109_grafana_uat;
        GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO svc_at20109_grafana_uat;
        GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO svc_at20109_grafana_uat;
        GRANT USAGE ON SCHEMA public TO svc_at20109_grafana_uat;
        
        -- Set default privileges for future objects in grafana database
        ALTER DEFAULT PRIVILEGES IN SCHEMA public 
        GRANT ALL PRIVILEGES ON TABLES TO svc_at20109_grafana_uat;
        
        ALTER DEFAULT PRIVILEGES IN SCHEMA public 
        GRANT ALL PRIVILEGES ON SEQUENCES TO svc_at20109_grafana_uat;
        
        -- Ensure future tables in metrics schema are readable
        ALTER DEFAULT PRIVILEGES IN SCHEMA metrics 
        GRANT SELECT ON TABLES TO svc_at20109_grafana_uat;
    END IF;
END $$;

-- Connect to grafana database for its setup
\connect grafana

-- Create grafana schema if needed
DO $$ 
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'public') THEN
        CREATE SCHEMA public;
    END IF;
END $$;

-- Return to jmeter database for remaining operations
\connect jmeter

-- Log successful setup completion
INSERT INTO metrics.system_logs (source, log_level, message)
VALUES ('db_setup', 'INFO', 'Database setup completed successfully');

COMMIT;

-- Show completion status
\echo 'Database setup completed successfully'
