CREATE TABLE IF NOT EXISTS jmeter_results (
    id SERIAL PRIMARY KEY,
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    elapsed INTEGER,
    label VARCHAR(250),
    responseCode VARCHAR(10),
    responseMessage VARCHAR(250),
    threadName VARCHAR(100),
    dataType VARCHAR(50),
    success BOOLEAN,
    failureMessage VARCHAR(250),
    bytes BIGINT,
    sentBytes BIGINT,
    grpThreads INTEGER,
    allThreads INTEGER,
    URL VARCHAR(250),
    latency INTEGER,
    idleTime INTEGER,
    Connect INTEGER,
    test_name VARCHAR(250),
    Hostname VARCHAR(250)
) PARTITION BY RANGE (timestamp);

-- Create partitions for next 12 months
DO $$
BEGIN
    FOR i IN 0..11 LOOP
        EXECUTE format('CREATE TABLE IF NOT EXISTS jmeter_results_%s 
            PARTITION OF jmeter_results 
            FOR VALUES FROM (%L) TO (%L)',
            to_char(CURRENT_DATE + (interval '1 month' * i), 'YYYY_MM'),
            date_trunc('month', CURRENT_DATE + (interval '1 month' * i)),
            date_trunc('month', CURRENT_DATE + (interval '1 month' * (i + 1)))
        );
    END LOOP;
END $$;

-- Function to create future partitions
CREATE OR REPLACE FUNCTION create_jmeter_partition_future()
RETURNS trigger AS $$
DECLARE
    partition_name text;
BEGIN
    partition_name := 'jmeter_results_' || 
                     date_part('year', NEW.timestamp)::text || '_' ||
                     to_char(NEW.timestamp, 'MM');
    
    EXECUTE format(
        'CREATE TABLE IF NOT EXISTS %I PARTITION OF jmeter_results
        FOR VALUES FROM (%L) TO (%L)',
        partition_name,
        date_trunc('month', NEW.timestamp),
        date_trunc('month', NEW.timestamp + interval '1 month')
    );
    RETURN NEW;
EXCEPTION WHEN duplicate_table THEN
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Trigger to automatically create partitions
CREATE TRIGGER create_jmeter_partition_trigger
    BEFORE INSERT ON jmeter_results
    FOR EACH ROW
    EXECUTE PROCEDURE create_jmeter_partition_future();

CREATE INDEX IF NOT EXISTS idx_jmeter_results_timestamp ON jmeter_results(timestamp);
CREATE INDEX IF NOT EXISTS idx_jmeter_results_label ON jmeter_results(label);
CREATE INDEX IF NOT EXISTS idx_jmeter_results_test_name ON jmeter_results(test_name);
CREATE INDEX IF NOT EXISTS idx_jmeter_results_success ON jmeter_results(success);

-- Grant permissions to JMeter user
GRANT ALL PRIVILEGES ON TABLE jmeter_results TO __JMETER_DB_USER__;
GRANT USAGE, SELECT ON SEQUENCE jmeter_results_id_seq TO __JMETER_DB_USER__;
