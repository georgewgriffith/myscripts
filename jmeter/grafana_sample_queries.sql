
-- 1. Response time percentiles by label 
-- (Use in Grafana Time Series with multiple queries and transform to table)
SELECT 
    $__timeGroup(timestamp_tz, '1m') as time,
    label,
    percentile_cont(0.5) WITHIN GROUP (ORDER BY elapsed) as "p50",
    percentile_cont(0.9) WITHIN GROUP (ORDER BY elapsed) as "p90",
    percentile_cont(0.95) WITHIN GROUP (ORDER BY elapsed) as "p95"
FROM jmeter_results 
WHERE 
    timestamp_tz BETWEEN $__timeFrom() AND $__timeTo()
    AND ci_job_id = ${ci_job_id}
    AND NOT is_transaction
GROUP BY time, label
ORDER BY time;

-- 2. Error rate by endpoint
-- (Use in Grafana Time Series)
SELECT
    $__timeGroup(timestamp_tz, '1m') as time,
    label,
    (COUNT(*) FILTER (WHERE NOT success_bool) * 100.0 / COUNT(*)) as error_rate
FROM jmeter_results
WHERE 
    timestamp_tz BETWEEN $__timeFrom() AND $__timeTo()
    AND ci_job_id = ${ci_job_id}
    AND NOT is_transaction
GROUP BY time, label
ORDER BY time;

-- 3. Response times by category 
-- (Use in Grafana Pie Chart or Bar Gauge)
SELECT 
    response_category,
    COUNT(*) as count
FROM jmeter_results
WHERE 
    timestamp_tz BETWEEN $__timeFrom() AND $__timeTo()
    AND ci_job_id = ${ci_job_id}
    AND NOT is_transaction
GROUP BY response_category
ORDER BY 
    CASE response_category 
        WHEN 'Fast (<500ms)' THEN 1
        WHEN 'Medium (500-1000ms)' THEN 2
        WHEN 'Slow (1-3s)' THEN 3
        WHEN 'Very Slow (>3s)' THEN 4
    END;

-- 4. Errors by type 
-- (Use in Grafana Pie Chart)
SELECT 
    error_type,
    COUNT(*) as count
FROM jmeter_results
WHERE 
    timestamp_tz BETWEEN $__timeFrom() AND $__timeTo()
    AND ci_job_id = ${ci_job_id}
    AND NOT is_transaction
GROUP BY error_type;

-- 5. Request volume by hour of day 
-- (Use in Grafana Heat Map)
SELECT 
    hour_of_day,
    day_of_week,
    COUNT(*) as requests
FROM jmeter_results
WHERE 
    timestamp_tz BETWEEN $__timeFrom() AND $__timeTo()
    AND ci_job_id = ${ci_job_id}
    AND NOT is_transaction
GROUP BY hour_of_day, day_of_week
ORDER BY day_of_week, hour_of_day;

-- 6. Network vs Processing time comparison 
-- (Use in Grafana Time Series)
SELECT
    $__timeGroup(timestamp_tz, '1m') as time,
    AVG(Latency) as "Processing Time (ms)",
    AVG(network_time) as "Network Time (ms)"
FROM jmeter_results
WHERE 
    timestamp_tz BETWEEN $__timeFrom() AND $__timeTo()
    AND ci_job_id = ${ci_job_id}
    AND NOT is_transaction
GROUP BY time
ORDER BY time;

-- 7. Throughput by endpoint
-- (Use in Grafana Bar Gauge)
SELECT
    label,
    COUNT(*) / (EXTRACT(EPOCH FROM ($__timeTo() - $__timeFrom())) / 60) as "Requests per Minute"
FROM jmeter_results
WHERE 
    timestamp_tz BETWEEN $__timeFrom() AND $__timeTo()
    AND ci_job_id = ${ci_job_id}
    AND NOT is_transaction
GROUP BY label
ORDER BY "Requests per Minute" DESC;
