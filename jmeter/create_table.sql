CREATE TABLE IF NOT EXISTS jmeter_results (
    id BIGSERIAL PRIMARY KEY,
    ci_job_id VARCHAR(100),
    timeStamp VARCHAR(50),
    timestamp_tz TIMESTAMPTZ GENERATED ALWAYS AS (to_timestamp(timeStamp, 'YYYY/MM/DD HH24:MI:SS')) STORED,
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
    Connect BIGINT
);

-- Indexes for better query performance
CREATE INDEX IF NOT EXISTS idx_jmeter_results_timestamp_tz ON jmeter_results (timestamp_tz);
CREATE INDEX IF NOT EXISTS idx_jmeter_results_ci_job_id ON jmeter_results (ci_job_id);
CREATE INDEX IF NOT EXISTS idx_jmeter_results_label ON jmeter_results (label);
CREATE INDEX IF NOT EXISTS idx_jmeter_results_success ON jmeter_results (success);
