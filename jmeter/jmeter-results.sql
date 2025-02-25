/*
 * JMeter Results Schema v1.0.0
 * For Azure Database for PostgreSQL 14+
 */

\set ON_ERROR_STOP on
\set VERBOSITY verbose

-- Validate database context
DO $$ 
BEGIN
    IF NOT current_database()='jmeter' THEN
        RAISE EXCEPTION 'Wrong database context: %. Please connect to jmeter database.', current_database();
    END IF;

    IF current_setting('server_version_num')::int < 140000 THEN
        RAISE EXCEPTION 'PostgreSQL 14 or higher is required';
    END IF;
END $$;

BEGIN;

-- Create table
DO $$ 
BEGIN
    IF NOT EXISTS (SELECT FROM pg_tables WHERE tablename = 'jmeter_results') THEN
        CREATE TABLE jmeter_results (
            id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
            testPlanName VARCHAR NOT NULL,
            testPlanDate VARCHAR NOT NULL,
            testPlanDescription VARCHAR,
            timeStamp BIGINT NOT NULL CHECK (timeStamp > 0 AND timeStamp < 253402300799999),
            timestamp_date TIMESTAMP GENERATED ALWAYS AS 
                (to_timestamp(timeStamp / 1000.0)) STORED,
            elapsed INTEGER NOT NULL,
            label TEXT NOT NULL,
            responseCode VARCHAR(10) NOT NULL,
            responseMessage TEXT,
            threadName TEXT NOT NULL,
            dataType VARCHAR(50),
            success BOOLEAN NOT NULL,
            failureMessage TEXT,
            bytes BIGINT NOT NULL,
            sentBytes BIGINT NOT NULL,
            grpThreads INTEGER NOT NULL CHECK (grpThreads >= 0),
            allThreads INTEGER NOT NULL CHECK (allThreads >= 0),
            latency INTEGER NOT NULL CHECK (latency >= 0),
            idleTime INTEGER NOT NULL CHECK (idleTime >= 0),
            connect INTEGER NOT NULL CHECK (connect >= 0),
            created_at TIMESTAMP DEFAULT NOW()
        );

        -- Add table documentation
        COMMENT ON TABLE jmeter_results IS 'Stores JMeter performance test results';
        COMMENT ON COLUMN jmeter_results.testPlanName IS 'Name of the JMeter test plan';
        COMMENT ON COLUMN jmeter_results.testPlanDate IS 'Date when the test plan was executed';
        COMMENT ON COLUMN jmeter_results.timeStamp IS 'Unix epoch timestamp in milliseconds';
        COMMENT ON COLUMN jmeter_results.timestamp_date IS 'Computed datetime from timestamp';
        COMMENT ON COLUMN jmeter_results.success IS 'Whether the request was successful';
        COMMENT ON COLUMN jmeter_results.elapsed IS 'Response time in milliseconds, used for performance tracking';
        COMMENT ON COLUMN jmeter_results.latency IS 'Network latency in milliseconds';
        COMMENT ON COLUMN jmeter_results.connect IS 'Connection establishment time in milliseconds';
    END IF;
END $$;

COMMIT;

-- Create indexes optimized for Azure
DO LANGUAGE plpgsql $$
BEGIN
    -- Azure-optimized memory settings
    SET LOCAL maintenance_work_mem = '256MB';  -- Reduced for Azure
    SET LOCAL work_mem = '64MB';              -- Reduced for Azure

    -- Replace BRIN with B-tree for better Azure performance
    IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_jmeter_timestamp') THEN
        CREATE INDEX CONCURRENTLY idx_jmeter_timestamp ON jmeter_results(timestamp_date DESC);
    END IF;

    -- Add Azure monitoring-friendly indexes
    IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_jmeter_perf_metrics') THEN
        CREATE INDEX CONCURRENTLY idx_jmeter_perf_metrics 
        ON jmeter_results(timestamp_date, elapsed, latency, connect)
        WHERE success = true;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_jmeter_label') THEN
        CREATE INDEX CONCURRENTLY idx_jmeter_label ON jmeter_results(label, timestamp_date);
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_jmeter_testplan') THEN
        CREATE INDEX CONCURRENTLY idx_jmeter_testplan ON jmeter_results(testPlanName, testPlanDate);
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_jmeter_response') THEN
        CREATE INDEX CONCURRENTLY idx_jmeter_response ON jmeter_results(responseCode, success);
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'idx_jmeter_success') THEN
        CREATE INDEX CONCURRENTLY idx_jmeter_success ON jmeter_results(success, timestamp_date) WHERE NOT success;
    END IF;

    -- Validate indexes
    IF NOT EXISTS (
        SELECT FROM pg_indexes 
        WHERE tablename = 'jmeter_results' 
        AND indexname = ANY(ARRAY[
            'idx_jmeter_timestamp',
            'idx_jmeter_label',
            'idx_jmeter_testplan',
            'idx_jmeter_response',
            'idx_jmeter_success',
            'idx_jmeter_perf_metrics'
        ])
    ) THEN
        RAISE WARNING 'Some indexes are missing. Please check the index creation.';
    END IF;
END $$;

-- Azure-optimized table parameters
ALTER TABLE IF EXISTS jmeter_results SET (
    autovacuum_vacuum_scale_factor = 0.05,    -- Azure-recommended value
    autovacuum_analyze_scale_factor = 0.02,   -- Azure-recommended value
    parallel_workers = 2                       -- Limited for Azure
);

-- Create statistics for Azure query optimizer
ANALYZE jmeter_results;