CREATE TABLE IF NOT EXISTS jmeter_results (
    id BIGSERIAL PRIMARY KEY,
    ci_job_id VARCHAR(100),
    
    timeStamp VARCHAR(50),
    timestamp_tz TIMESTAMPTZ,
    inserted_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    
    elapsed BIGINT,
    label VARCHAR(255),
    responseCode VARCHAR(50),
    responseMessage TEXT,
    threadName VARCHAR(255),
    dataType VARCHAR(50),
    success VARCHAR(5),
    failureMessage TEXT,
    bytes BIGINT,
    sentBytes BIGINT,
    grpThreads BIGINT,
    allThreads BIGINT,
    Latency BIGINT,
    IdleTime BIGINT,
    Connect BIGINT,
    
    error_type VARCHAR(20),
    hour_of_day INT,
    minute_of_hour INT,
    day_of_week INT,
    is_transaction BOOLEAN,
    endpoint_category VARCHAR(30),
    is_sampler BOOLEAN,
    is_controller BOOLEAN,
    request_type VARCHAR(20),
    
    network_time BIGINT GENERATED ALWAYS AS (elapsed - Latency) STORED,
    success_bool BOOLEAN GENERATED ALWAYS AS (success IN ('true', 'TRUE')) STORED,
    response_category VARCHAR(20) GENERATED ALWAYS AS (
        CASE 
            WHEN elapsed < 500 THEN 'Fast (<500ms)'
            WHEN elapsed BETWEEN 500 AND 1000 THEN 'Medium (500-1000ms)'
            WHEN elapsed BETWEEN 1001 AND 3000 THEN 'Slow (1-3s)'
            ELSE 'Very Slow (>3s)'
        END
    ) STORED,
    apdex_value NUMERIC(3,2) GENERATED ALWAYS AS (
        CASE 
            WHEN elapsed <= 500 THEN 1.0
            WHEN elapsed <= 1500 THEN 0.5
            ELSE 0.0
        END
    ) STORED,
    meets_slo BOOLEAN GENERATED ALWAYS AS (
        CASE
            WHEN success IN ('true', 'TRUE') AND elapsed < 1000 THEN true
            ELSE false
        END
    ) STORED,
    latency_percentage NUMERIC(5,2) GENERATED ALWAYS AS (
        CASE 
            WHEN elapsed > 0 THEN (Latency::NUMERIC / elapsed) * 100 
            ELSE 0 
        END
    ) STORED,
    connect_percentage NUMERIC(5,2) GENERATED ALWAYS AS (
        CASE 
            WHEN elapsed > 0 THEN (Connect::NUMERIC / elapsed) * 100 
            ELSE 0 
        END
    ) STORED,
    response_size_category VARCHAR(20) GENERATED ALWAYS AS (
        CASE
            WHEN bytes < 1024 THEN 'Tiny (<1KB)'
            WHEN bytes BETWEEN 1024 AND 10240 THEN 'Small (1-10KB)'
            WHEN bytes BETWEEN 10241 AND 102400 THEN 'Medium (10-100KB)'
            WHEN bytes BETWEEN 102401 AND 1048576 THEN 'Large (100KB-1MB)'
            ELSE 'Very Large (>1MB)'
        END
    ) STORED,
    is_slow_outlier BOOLEAN GENERATED ALWAYS AS (
        CASE
            WHEN elapsed > 3000 AND success IN ('true', 'TRUE') THEN true
            ELSE false
        END
    ) STORED,
    throughput_bin VARCHAR(20) GENERATED ALWAYS AS (
        CASE
            WHEN elapsed = 0 THEN '0 ms'
            WHEN elapsed < 100 THEN '<100 ms'
            WHEN elapsed < 500 THEN '100-500 ms'
            WHEN elapsed < 1000 THEN '500-1000 ms'
            WHEN elapsed < 5000 THEN '1-5 sec'
            ELSE '>5 sec'
        END
    ) STORED
);

CREATE INDEX IF NOT EXISTS idx_jmeter_results_timestamp_tz ON jmeter_results (timestamp_tz);
CREATE INDEX IF NOT EXISTS idx_jmeter_results_ci_job_id ON jmeter_results (ci_job_id);
CREATE INDEX IF NOT EXISTS idx_jmeter_results_label ON jmeter_results (label);
CREATE INDEX IF NOT EXISTS idx_jmeter_results_success_bool ON jmeter_results (success_bool);

CREATE INDEX IF NOT EXISTS idx_jmeter_results_hour_of_day ON jmeter_results (hour_of_day);

CREATE INDEX IF NOT EXISTS idx_jmeter_results_response_category ON jmeter_results (response_category);
CREATE INDEX IF NOT EXISTS idx_jmeter_results_error_type ON jmeter_results (error_type);
CREATE INDEX IF NOT EXISTS idx_jmeter_results_endpoint_category ON jmeter_results (endpoint_category);
CREATE INDEX IF NOT EXISTS idx_jmeter_results_request_type ON jmeter_results (request_type);

CREATE INDEX IF NOT EXISTS idx_jmeter_results_apdex_value ON jmeter_results (apdex_value);
CREATE INDEX IF NOT EXISTS idx_jmeter_results_meets_slo ON jmeter_results (meets_slo);
CREATE INDEX IF NOT EXISTS idx_jmeter_results_is_slow_outlier ON jmeter_results (is_slow_outlier);
CREATE INDEX IF NOT EXISTS idx_jmeter_results_throughput_bin ON jmeter_results (throughput_bin);

CREATE INDEX IF NOT EXISTS idx_jmeter_results_is_sampler ON jmeter_results (is_sampler);

-- Add permissions for the sequence and table
DO $$
DECLARE
    db_user TEXT;
BEGIN
    -- Get the current user
    SELECT current_user INTO db_user;
    
    -- Grant permissions to the sequence
    EXECUTE format('GRANT USAGE, SELECT, UPDATE ON SEQUENCE jmeter_results_id_seq TO %I', db_user);
    
    -- Grant full permissions to the table
    EXECUTE format('GRANT ALL PRIVILEGES ON TABLE jmeter_results TO %I', db_user);
END
$$;