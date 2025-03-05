CREATE TABLE IF NOT EXISTS jmeter_results (
    id BIGSERIAL PRIMARY KEY,
    ci_job_id VARCHAR(100),
    timeStamp VARCHAR(50),
    timestamp_tz TIMESTAMPTZ,  -- Regular column, not generated
    inserted_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    elapsed BIGINT,
    label VARCHAR(255),
    responseCode VARCHAR(10),
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
    
    -- Basic calculated columns that are safe (numeric operations)
    network_time BIGINT GENERATED ALWAYS AS (elapsed - Latency) STORED,
    success_bool BOOLEAN GENERATED ALWAYS AS (success IN ('true', 'TRUE')) STORED,
    
    -- Response time categorization (numeric bounds are immutable)
    response_category VARCHAR(20) GENERATED ALWAYS AS (
        CASE 
            WHEN elapsed < 500 THEN 'Fast (<500ms)'
            WHEN elapsed BETWEEN 500 AND 1000 THEN 'Medium (500-1000ms)'
            WHEN elapsed BETWEEN 1001 AND 3000 THEN 'Slow (1-3s)'
            ELSE 'Very Slow (>3s)'
        END
    ) STORED,
    
    -- The following columns might not be immutable due to pattern matching
    -- Adding as regular columns to be filled by INSERT statements
    error_type VARCHAR(20),
    hour_of_day INT,
    minute_of_hour INT,
    day_of_week INT,
    is_transaction BOOLEAN,
    
    -- These numeric calculations are safe
    apdex_value NUMERIC(3,2) GENERATED ALWAYS AS (
        CASE 
            WHEN elapsed <= 500 THEN 1.0  -- Satisfied
            WHEN elapsed <= 1500 THEN 0.5  -- Tolerating
            ELSE 0.0  -- Frustrated
        END
    ) STORED,
    
    meets_slo BOOLEAN GENERATED ALWAYS AS (
        CASE
            WHEN success IN ('true', 'TRUE') AND elapsed < 1000 THEN true
            ELSE false
        END
    ) STORED,
    
    -- Pattern matching is not immutable, use regular column
    endpoint_category VARCHAR(30),
    
    -- Percentage calculations are safe
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
    
    -- Size categories based on numeric bounds are immutable
    response_size_category VARCHAR(20) GENERATED ALWAYS AS (
        CASE
            WHEN bytes < 1024 THEN 'Tiny (<1KB)'
            WHEN bytes BETWEEN 1024 AND 10240 THEN 'Small (1-10KB)'
            WHEN bytes BETWEEN 10241 AND 102400 THEN 'Medium (10-100KB)'
            WHEN bytes BETWEEN 102401 AND 1048576 THEN 'Large (100KB-1MB)'
            ELSE 'Very Large (>1MB)'
        END
    ) STORED,
    
    -- Numeric bounds are immutable
    is_slow_outlier BOOLEAN GENERATED ALWAYS AS (
        CASE
            WHEN elapsed > 3000 AND success IN ('true', 'TRUE') THEN true
            ELSE false
        END
    ) STORED,

    -- Numeric bounds for throughput bins are immutable
    throughput_bin VARCHAR(20) GENERATED ALWAYS AS (
        CASE
            WHEN elapsed = 0 THEN '0 ms'
            WHEN elapsed < 100 THEN '<100 ms'
            WHEN elapsed < 500 THEN '100-500 ms'
            WHEN elapsed < 1000 THEN '500-1000 ms'
            WHEN elapsed < 5000 THEN '1-5 sec'
            ELSE '>5 sec'
        END
    ) STORED,

    -- Pattern matching is not immutable, use regular columns
    is_sampler BOOLEAN,
    is_controller BOOLEAN,
    request_type VARCHAR(20)
);

-- Indexes for better query performance
CREATE INDEX IF NOT EXISTS idx_jmeter_results_timestamp_tz ON jmeter_results (timestamp_tz);
CREATE INDEX IF NOT EXISTS idx_jmeter_results_ci_job_id ON jmeter_results (ci_job_id);
CREATE INDEX IF NOT EXISTS idx_jmeter_results_label ON jmeter_results (label);
CREATE INDEX IF NOT EXISTS idx_jmeter_results_success_bool ON jmeter_results (success_bool);
CREATE INDEX IF NOT EXISTS idx_jmeter_results_response_category ON jmeter_results (response_category);
CREATE INDEX IF NOT EXISTS idx_jmeter_results_error_type ON jmeter_results (error_type);
CREATE INDEX IF NOT EXISTS idx_jmeter_results_hour_of_day ON jmeter_results (hour_of_day);

-- Additional indexes for new columns
CREATE INDEX IF NOT EXISTS idx_jmeter_results_apdex_value ON jmeter_results (apdex_value);
CREATE INDEX IF NOT EXISTS idx_jmeter_results_meets_slo ON jmeter_results (meets_slo);
CREATE INDEX IF NOT EXISTS idx_jmeter_results_endpoint_category ON jmeter_results (endpoint_category);
CREATE INDEX IF NOT EXISTS idx_jmeter_results_is_slow_outlier ON jmeter_results (is_slow_outlier);

-- Add indexes for JMeter HTML report queries
CREATE INDEX IF NOT EXISTS idx_jmeter_results_is_sampler ON jmeter_results (is_sampler);
CREATE INDEX IF NOT EXISTS idx_jmeter_results_throughput_bin ON jmeter_results (throughput_bin);
CREATE INDEX IF NOT EXISTS idx_jmeter_results_request_type ON jmeter_results (request_type);

-- Add check for uniqueness constraint
ALTER TABLE jmeter_results ADD CONSTRAINT jmeter_results_ci_job_id_timestamp_label_uk 
  UNIQUE (ci_job_id, timestamp_tz, label, elapsed)
  WHERE NOT is_transaction;
