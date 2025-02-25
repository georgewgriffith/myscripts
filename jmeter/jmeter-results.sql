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

-- Set memory parameters for better index creation
SET maintenance_work_mem = '256MB';  -- Azure-optimized
SET work_mem = '64MB';              -- Azure-optimized

BEGIN;

DO $$ 
BEGIN
    IF NOT EXISTS (SELECT FROM pg_tables WHERE tablename = 'jmeter_results') THEN
        -- Create table
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

        -- Create all indexes immediately
        CREATE INDEX idx_jmeter_timestamp ON jmeter_results(timestamp_date DESC);
        CREATE INDEX idx_jmeter_perf_metrics 
            ON jmeter_results(timestamp_date, elapsed, latency, connect)
            WHERE success = true;
        CREATE INDEX idx_jmeter_label ON jmeter_results(label, timestamp_date);
        CREATE INDEX idx_jmeter_testplan ON jmeter_results(testPlanName, testPlanDate);
        CREATE INDEX idx_jmeter_response ON jmeter_results(responseCode, success);
        CREATE INDEX idx_jmeter_success ON jmeter_results(success, timestamp_date) 
            WHERE NOT success;

        -- Set table parameters
        ALTER TABLE jmeter_results SET (
            autovacuum_vacuum_scale_factor = 0.05,
            autovacuum_analyze_scale_factor = 0.02,
            parallel_workers = 2
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

        -- Create initial statistics
        ANALYZE jmeter_results;
    END IF;
END $$;

COMMIT;

-- Validate final structure
DO $$ 
BEGIN
    IF (SELECT count(*) FROM pg_indexes WHERE tablename = 'jmeter_results') < 6 THEN
        RAISE WARNING 'Expected 6 indexes but found %. Check table creation.', 
            (SELECT count(*) FROM pg_indexes WHERE tablename = 'jmeter_results');
    END IF;
END $$;