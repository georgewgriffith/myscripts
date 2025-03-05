# JMeter Comprehensive Performance Dashboard

This Grafana dashboard provides a complete view of JMeter performance test metrics. It's designed to help you analyze and troubleshoot performance issues with unparalleled visibility.

## Dashboard Sections

### Test Overview
- **Success Rate**: Percentage of successful requests
- **Average Response Time**: Mean response time in milliseconds
- **95th Percentile Response Time**: Response time threshold at which 95% of requests complete
- **Throughput**: Requests per second
- **Error Rate**: Percentage of failed requests

### Response Time Trends
- **Response Time Distribution**: Shows average, median, 95th percentile, 99th percentile and maximum response times over time
- **Throughput Over Time**: Shows the requests per second over the test duration

### Transaction Performance
- **Transaction Performance Summary**: Table showing key metrics for transaction labels:
  - Transaction name
  - Request count
  - Success rate
  - Average response time
  - 90th percentile
  - Min/max times

### Error Analysis
- **Error Distribution by Response Code**: Breakdown of errors by HTTP response code
- **Errors Over Time**: Chart showing the error count over time

### Resource Utilization
- **Response Size Over Time**: Shows the average response size in bytes
- **Network Latency Over Time**: Shows network latency separate from total response time

## How to Use This Dashboard

1. Enter your CI job ID in the variable field at the top
2. The dashboard will automatically refresh every 5 seconds
3. Investigate spikes in response time or error rates
4. Compare different transaction types to identify bottlenecks
5. Use the error analysis section to troubleshoot specific issues

## Requirements

The dashboard requires:
- A PostgreSQL datasource named "jmeter-postgres"
- JMeter results stored with the following schema fields:
  - timestamp_tz
  - ci_job_id
  - label
  - elapsed
  - success_bool
  - is_transaction
  - response_code
  - response_message
  - bytes
  - latency

## Additional Configuration

For advanced monitoring needs, consider adding:
- Correlation with infrastructure metrics (CPU, memory usage)
- Custom thresholds for specific endpoints
- Alerting on performance degradation
