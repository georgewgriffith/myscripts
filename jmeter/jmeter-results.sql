\set ON_ERROR_STOP on
\set VERBOSITY verbose

-- Connect to jmeter database
\c jmeter;

-- Validate database context
DO $$ 
BEGIN
    IF NOT current_database()='jmeter' THEN
        RAISE EXCEPTION 'Wrong database context: %. Please connect to jmeter database.', current_database();
    END IF;

    -- Check PostgreSQL version
    IF current_setting('server_version_num')::int < 140000 THEN
        RAISE EXCEPTION 'PostgreSQL 14 or higher is required';
    END IF;

    -- Check if user has proper permissions
    IF NOT (
        pg_has_role(current_user, 'CREATE') OR 
        has_database_privilege(current_database(), 'CREATE')
    ) THEN
        RAISE EXCEPTION 'User % lacks required CREATE privileges on database %', 
            current_user, current_database();
    END IF;
END $$;

BEGIN;

-- Create table only if it doesn't exist
DO $$ 
BEGIN
    IF NOT EXISTS (SELECT FROM pg_tables WHERE tablename = 'jmeter_results') THEN
        CREATE TABLE jmeter_results (
            id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
            testPlanName VARCHAR NOT NULL,      -- Name of the test plan
            testPlanDate VARCHAR NOT NULL,      -- Date of test plan execution
            testPlanDescription VARCHAR,        -- Description of the test plan
            timeStamp BIGINT NOT NULL CHECK (timeStamp > 0 AND timeStamp < 253402300799999),  -- Validates timestamps until year 9999
            timestamp_date TIMESTAMP GENERATED ALWAYS AS 
                (to_timestamp(LEAST(timeStamp / 1000.0, 253402300799.999))) STORED,  -- Prevent overflow
            elapsed INTEGER NOT NULL,   -- Response time in milliseconds
            label TEXT NOT NULL,        -- Sampler label
            responseCode VARCHAR(10) NOT NULL, -- HTTP response code (e.g., 200, 404)
            responseMessage TEXT,        -- Response message (e.g., OK)
            threadName TEXT NOT NULL,    -- Name of the thread
            dataType VARCHAR(50),        -- Data type (e.g., text, json)
            success BOOLEAN NOT NULL,    -- Whether the request was successful
            failureMessage TEXT,         -- Error message if request failed
            bytes BIGINT NOT NULL,       -- Bytes received in response
            sentBytes BIGINT NOT NULL,   -- Bytes sent in the request
            grpThreads INTEGER NOT NULL CHECK (grpThreads >= 0), -- Active threads in this group
            allThreads INTEGER NOT NULL CHECK (allThreads >= 0), -- Total active threads across groups
            latency INTEGER NOT NULL CHECK (latency >= 0),       -- Time to first response byte
            idleTime INTEGER NOT NULL CHECK (idleTime >= 0),     -- Time the thread was idle
            connect INTEGER NOT NULL CHECK (connect >= 0),       -- Time taken to establish connection
            created_at TIMESTAMP DEFAULT NOW()  -- Timestamp when row was inserted
        ) PARTITION BY RANGE (timestamp_date);
        
        -- Create default partition only if table was just created
        CREATE TABLE jmeter_results_default 
            PARTITION OF jmeter_results 
            FOR VALUES FROM (MINVALUE) TO (CURRENT_DATE - INTERVAL '12 months');
            
        -- Set initial table parameters
        ALTER TABLE jmeter_results SET (
            autovacuum_vacuum_scale_factor = 0.01,
            autovacuum_analyze_scale_factor = 0.005,
            parallel_workers = 4
        );
        
        -- Add table comments only if table was just created
        COMMENT ON TABLE jmeter_results IS 'Stores JMeter performance test results, partitioned by month';
        COMMENT ON COLUMN jmeter_results.testPlanName IS 'Name of the JMeter test plan';
        COMMENT ON COLUMN jmeter_results.testPlanDate IS 'Date when the test plan was executed';
        COMMENT ON COLUMN jmeter_results.testPlanDescription IS 'Description of the test plan purpose and configuration';
        COMMENT ON COLUMN jmeter_results.timeStamp IS 'Unix epoch timestamp in milliseconds when the request was made';
        COMMENT ON COLUMN jmeter_results.elapsed IS 'Total time taken for the request in milliseconds';
        COMMENT ON COLUMN jmeter_results.latency IS 'Time to first byte in milliseconds';
        COMMENT ON COLUMN jmeter_results.timestamp_date IS 'Computed timestamp for partitioning';
    END IF;
END $$;

-- Create partitions only if they don't exist
DO LANGUAGE plpgsql $$
DECLARE
    start_date TIMESTAMP;
    end_date TIMESTAMP;
    partition_name TEXT;
    partition_count INT := 0;
BEGIN
    -- Validate date ranges
    IF CURRENT_DATE + interval '12 months' > timestamp '9999-12-31' THEN
        RAISE EXCEPTION 'Partition dates would exceed maximum timestamp';
    END IF;
    
    start_date := date_trunc('month', CURRENT_DATE - interval '12 months');
    end_date := date_trunc('month', CURRENT_DATE + interval '12 months');
    
    WHILE start_date < end_date LOOP
        partition_name := 'jmeter_results_p' || to_char(start_date, 'YYYY_MM');
        
        -- Check if partition exists before creating
        IF NOT EXISTS (SELECT FROM pg_tables WHERE tablename = partition_name) THEN
            BEGIN
                EXECUTE format('CREATE TABLE %I PARTITION OF jmeter_results
                    FOR VALUES FROM (%L) TO (%L)',
                    partition_name,
                    start_date,
                    start_date + interval '1 month');
                    
                -- Create Azure-optimized local indexes
                EXECUTE format('CREATE INDEX IF NOT EXISTS %I ON %I USING BRIN (timestamp_date)',
                    'idx_' || partition_name || '_timestamp_brin', partition_name);
                
                EXECUTE format('CREATE INDEX IF NOT EXISTS %I ON %I (label, timestamp_date)',
                    'idx_' || partition_name || '_label', partition_name);
                
                partition_count := partition_count + 1;
                RAISE NOTICE 'Created partition: %', partition_name;
            EXCEPTION 
                WHEN duplicate_table THEN
                    RAISE NOTICE 'Partition already exists: %', partition_name;
            END;
        END IF;
        
        start_date := start_date + interval '1 month';
    END LOOP;
    
    RAISE NOTICE 'Created % new partitions', partition_count;
END $$;

CREATE OR REPLACE VIEW v_jmeter_partitions AS
SELECT 
    nmsp_parent.nspname AS parent_schema,
    parent.relname AS parent,
    nmsp_child.nspname AS child_schema,
    child.relname AS child,
    pg_get_expr(child.relpartbound, child.oid) AS partition_expression
FROM pg_inherits
    JOIN pg_class parent ON pg_inherits.inhparent = parent.oid
    JOIN pg_class child ON pg_inherits.inhrelid = child.oid
    JOIN pg_namespace nmsp_parent ON nmsp_parent.oid = parent.relnamespace
    JOIN pg_namespace nmsp_child ON nmsp_child.oid = child.relnamespace
WHERE parent.relname = 'jmeter_results'
ORDER BY child.relname;

COMMIT;

-- Create global indexes if they don't exist
DO LANGUAGE plpgsql $$
BEGIN
    SET LOCAL maintenance_work_mem = '1GB';
    SET LOCAL work_mem = '256MB';
    
    -- Create global indexes without dropping anything
    EXECUTE 'CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_jmeter_testplan 
        ON jmeter_results(testPlanName, testPlanDate)';
    EXECUTE 'CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_jmeter_response_code 
        ON jmeter_results(responseCode, success, timestamp_date)';
END $$;

-- Validate structure without raising errors
DO $$ 
BEGIN
    IF NOT EXISTS (
        SELECT FROM pg_indexes 
        WHERE tablename = 'jmeter_results' 
        AND indexname = 'idx_jmeter_testplan'
    ) THEN
        RAISE NOTICE 'Warning: Some indexes may be missing';
    END IF;
END $$;

COMMIT;
