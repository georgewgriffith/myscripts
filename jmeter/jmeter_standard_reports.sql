-- 1. Over Time Reports (Similar to JMeter's "Over Time" graphs)
-- Average Response Times Over Time
SELECT 
    $__timeGroup(timestamp_tz, '10s') as time,
    label,
    AVG(elapsed) as avg_response_time
FROM jmeter_results
WHERE 
    timestamp_tz BETWEEN $__timeFrom() AND $__timeTo()
    AND ci_job_id = ${ci_job_id}
    AND NOT is_transaction
GROUP BY time, label
ORDER BY time;

-- Transactions Per Second (TPS)
SELECT 
    $__timeGroup(timestamp_tz, '1s') as time,
    COUNT(*) as tps
FROM jmeter_results
WHERE 
    timestamp_tz BETWEEN $__timeFrom() AND $__timeTo()
    AND ci_job_id = ${ci_job_id}
    AND NOT is_transaction
GROUP BY time
ORDER BY time;

-- Active Threads Over Time
SELECT 
    $__timeGroup(timestamp_tz, '1s') as time,
    MAX(allThreads) as active_threads
FROM jmeter_results
WHERE 
    timestamp_tz BETWEEN $__timeFrom() AND $__timeTo()
    AND ci_job_id = ${ci_job_id}
GROUP BY time
ORDER BY time;

-- 2. Response Times Distribution (Similar to JMeter's "Response Time Distribution")
SELECT 
    WIDTH_BUCKET(elapsed, 0, 5000, 50) * 100 as response_time_ms,
    COUNT(*) as count
FROM jmeter_results
WHERE 
    timestamp_tz BETWEEN $__timeFrom() AND $__timeTo()
    AND ci_job_id = ${ci_job_id}
    AND NOT is_transaction
GROUP BY response_time_ms
ORDER BY response_time_ms;

-- 3. Response Times Percentiles (Similar to JMeter's "Response Time Percentiles")
WITH percentile_data AS (
    SELECT 
        elapsed,
        PERCENT_RANK() OVER (ORDER BY elapsed) * 100 as percentile
    FROM jmeter_results
    WHERE 
        timestamp_tz BETWEEN $__timeFrom() AND $__timeTo()
        AND ci_job_id = ${ci_job_id}
        AND NOT is_transaction
        AND elapsed IS NOT NULL  -- Add NULL check
)
SELECT 
    percentile,
    MAX(elapsed) as response_time
FROM percentile_data
GROUP BY percentile
ORDER BY percentile;

-- 4. Response Times Overview (Similar to JMeter's "Summary Report")
SELECT 
    label,
    COUNT(*) as samples,
    AVG(elapsed) as average,
    MIN(elapsed) as min,
    MAX(elapsed) as max,
    percentile_cont(0.5) WITHIN GROUP (ORDER BY elapsed) as median,
    percentile_cont(0.9) WITHIN GROUP (ORDER BY elapsed) as p90,
    percentile_cont(0.95) WITHIN GROUP (ORDER BY elapsed) as p95,
    percentile_cont(0.99) WITHIN GROUP (ORDER BY elapsed) as p99,
    COUNT(*) FILTER(WHERE NOT success_bool) as errors,
    (COUNT(*) FILTER(WHERE NOT success_bool) * 100.0 / NULLIF(COUNT(*), 0)) as error_percentage,
    (COUNT(*) * 1.0) / NULLIF(EXTRACT(EPOCH FROM (MAX(timestamp_tz) - MIN(timestamp_tz))), 0) as throughput
FROM jmeter_results
WHERE 
    timestamp_tz BETWEEN $__timeFrom() AND $__timeTo()
    AND ci_job_id = ${ci_job_id}
    AND NOT is_transaction
GROUP BY label
ORDER BY label;

-- 5. Top 5 Errors (Similar to JMeter's "Errors" tab)
SELECT 
    responseCode,
    responseMessage,
    COUNT(*) as count,
    (COUNT(*) * 100.0 / (
        SELECT COUNT(*) FROM jmeter_results
        WHERE timestamp_tz BETWEEN $__timeFrom() AND $__timeTo()
        AND ci_job_id = ${ci_job_id}
        AND NOT success_bool
        AND NOT is_transaction
    )) as percentage
FROM jmeter_results
WHERE 
    timestamp_tz BETWEEN $__timeFrom() AND $__timeTo()
    AND ci_job_id = ${ci_job_id}
    AND NOT success_bool
    AND NOT is_transaction
GROUP BY responseCode, responseMessage
ORDER BY count DESC
LIMIT 5;

-- 6. Response Size Over Time (Similar to JMeter's "Response Size" tab)
SELECT 
    $__timeGroup(timestamp_tz, '10s') as time,
    AVG(bytes) as avg_bytes,
    MAX(bytes) as max_bytes,
    MIN(bytes) as min_bytes
FROM jmeter_results
WHERE 
    timestamp_tz BETWEEN $__timeFrom() AND $__timeTo()
    AND ci_job_id = ${ci_job_id}
    AND NOT is_transaction
GROUP BY time
ORDER BY time;

-- 7. Latency Breakdown (Similar to JMeter's "Times" tab)
SELECT 
    label,
    AVG(Connect) as avg_connect,
    AVG(Latency - Connect) as avg_processing,
    AVG(elapsed - Latency) as avg_network
FROM jmeter_results
WHERE 
    timestamp_tz BETWEEN $__timeFrom() AND $__timeTo()
    AND ci_job_id = ${ci_job_id}
    AND NOT is_transaction
GROUP BY label
ORDER BY avg_processing DESC;

-- 8. Throughput vs Threads (For JMeter's "Response Times vs Threads" equivalent)
WITH thread_throughput AS (
    SELECT 
        allThreads, 
        COUNT(*) as sample_count,
        MAX(timestamp_tz) - MIN(timestamp_tz) as duration
    FROM jmeter_results
    WHERE 
        timestamp_tz BETWEEN $__timeFrom() AND $__timeTo()
        AND ci_job_id = ${ci_job_id}
        AND NOT is_transaction
    GROUP BY allThreads
)
SELECT 
    allThreads as thread_count,
    (sample_count::float / EXTRACT(EPOCH FROM duration)) as throughput_per_second,
    AVG(elapsed) as avg_response_time
FROM thread_throughput t
JOIN jmeter_results r ON t.allThreads = r.allThreads
WHERE 
    r.timestamp_tz BETWEEN $__timeFrom() AND $__timeTo()
    AND r.ci_job_id = ${ci_job_id}
    AND NOT r.is_transaction
GROUP BY thread_count, throughput_per_second
ORDER BY thread_count;

-- 9. Transaction Summary (JMeter's "Transactions" report)
SELECT 
    label,
    AVG(elapsed) as avg_elapsed,
    MIN(elapsed) as min_elapsed,
    MAX(elapsed) as max_elapsed,
    COUNT(*) as total_count,
    COUNT(*) FILTER(WHERE success_bool) as success_count,
    (COUNT(*) FILTER(WHERE success_bool) * 100.0 / COUNT(*)) as success_rate
FROM jmeter_results
WHERE 
    timestamp_tz BETWEEN $__timeFrom() AND $__timeTo()
    AND ci_job_id = ${ci_job_id}
    AND is_transaction
GROUP BY label
ORDER BY avg_elapsed DESC;
