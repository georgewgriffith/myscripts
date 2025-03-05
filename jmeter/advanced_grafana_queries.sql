-- 1. Apdex Score Over Time
-- (Use in Grafana Time Series)
SELECT
    $__timeGroup(timestamp_tz, '1m') as time,
    endpoint_category,
    AVG(apdex_value) as apdex
FROM jmeter_results
WHERE 
    timestamp_tz BETWEEN $__timeFrom() AND $__timeTo()
    AND ci_job_id = ${ci_job_id}
    AND NOT is_transaction
GROUP BY time, endpoint_category
ORDER BY time;

-- 2. SLO Compliance
-- (Use in Grafana Stat or Gauge panels)
SELECT
    COUNT(*) FILTER(WHERE meets_slo) * 100.0 / COUNT(*) as slo_compliance_percent
FROM jmeter_results
WHERE 
    timestamp_tz BETWEEN $__timeFrom() AND $__timeTo()
    AND ci_job_id = ${ci_job_id}
    AND NOT is_transaction;

-- 3. Performance Breakdown by Endpoint Category
-- (Use in Grafana Bar Chart)
SELECT
    endpoint_category,
    AVG(elapsed) as avg_response_time,
    COUNT(*) FILTER(WHERE success_bool) * 100.0 / COUNT(*) as success_rate,
    AVG(apdex_value) as apdex,
    COUNT(*) as requests
FROM jmeter_results
WHERE 
    timestamp_tz BETWEEN $__timeFrom() AND $__timeTo()
    AND ci_job_id = ${ci_job_id}
    AND NOT is_transaction
GROUP BY endpoint_category
ORDER BY avg_response_time DESC;

-- 4. Response Time Composition
-- (Use in Grafana Stacked Bar Chart)
SELECT
    $__timeGroup(timestamp_tz, '1m') as time,
    AVG(Connect) as "Connection Time",
    AVG(Latency - Connect) as "Processing Time",
    AVG(elapsed - Latency) as "Network Time"
FROM jmeter_results
WHERE 
    timestamp_tz BETWEEN $__timeFrom() AND $__timeTo()
    AND ci_job_id = ${ci_job_id}
    AND NOT is_transaction
GROUP BY time
ORDER BY time;

-- 5. Slow Outlier Analysis
-- (Use in Grafana Table)
SELECT
    timestamp_tz,
    label,
    elapsed,
    responseCode,
    Latency,
    Connect,
    threadName
FROM jmeter_results
WHERE 
    timestamp_tz BETWEEN $__timeFrom() AND $__timeTo()
    AND ci_job_id = ${ci_job_id}
    AND is_slow_outlier
ORDER BY elapsed DESC
LIMIT 100;

-- 6. Response Size Distribution
-- (Use in Grafana Pie Chart)
SELECT
    response_size_category,
    COUNT(*) as count
FROM jmeter_results
WHERE 
    timestamp_tz BETWEEN $__timeFrom() AND $__timeTo()
    AND ci_job_id = ${ci_job_id}
    AND NOT is_transaction
GROUP BY response_size_category
ORDER BY count DESC;

-- 7. Virtual User Count vs Response Time
-- (Use in Grafana Graph with two Y-axes)
SELECT
    $__timeGroup(timestamp_tz, '1m') as time,
    AVG(allThreads) as "Virtual Users",
    AVG(elapsed) as "Avg Response Time"
FROM jmeter_results
WHERE 
    timestamp_tz BETWEEN $__timeFrom() AND $__timeTo()
    AND ci_job_id = ${ci_job_id}
    AND NOT is_transaction
GROUP BY time
ORDER BY time;

-- 8. Current Test Progress Indicator
-- (Use in Grafana Gauge or stat panel with thresholds)
SELECT
    CASE 
        WHEN MAX(timestamp_tz) IS NULL OR MIN(timestamp_tz) IS NULL THEN 0
        ELSE EXTRACT(EPOCH FROM (now() - MIN(timestamp_tz))) * 100.0 / 
             GREATEST(EXTRACT(EPOCH FROM (MAX(timestamp_tz) - MIN(timestamp_tz))), 1) 
    END as test_progress_pct
FROM jmeter_results
WHERE ci_job_id = ${ci_job_id};

-- 9. Success Rate Heatmap by Hour and Endpoint Category
-- (Use in Grafana Heatmap or Table)
SELECT
    hour_of_day,
    endpoint_category,
    COUNT(*) FILTER(WHERE success_bool) * 100.0 / GREATEST(COUNT(*), 1) as success_rate
FROM jmeter_results
WHERE 
    timestamp_tz BETWEEN $__timeFrom() AND $__timeTo()
    AND ci_job_id = ${ci_job_id}
    AND NOT is_transaction
GROUP BY hour_of_day, endpoint_category
ORDER BY hour_of_day, endpoint_category;
