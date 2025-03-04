#!/bin/bash

# Parse command line arguments
usage() {
    echo "Usage: $0 <ci_job_id>"
    echo "Example: $0 123456"
    exit 1
}

# Configuration
JMETER_HOME="${JMETER_HOME:-/opt/jmeter}"
EXPORT_DIR="/opt/jmeter/export"
REPORT_DIR="/tmp/report_${CI_JOB_ID}"

# Create export directory if it doesn't exist
mkdir -p "${EXPORT_DIR}"

# Function to generate and archive HTML report
generate_report() {
    local jtl_file="$1"
    local job_id="$2"
    
    echo "Generating HTML report for job ${job_id}..."
    
    # Create fresh report directory
    rm -rf "${REPORT_DIR}"
    mkdir -p "${REPORT_DIR}"
    
    # Generate HTML report
    if ! "${JMETER_HOME}/bin/jmeter.sh" -g "${jtl_file}" -o "${REPORT_DIR}"; then
        echo "Error: Failed to generate HTML report"
        return 1
    fi
    
    # Create zip archives
    local report_archive="${EXPORT_DIR}/report_${job_id}.zip"
    local results_archive="${EXPORT_DIR}/results_${job_id}.zip"
    
    # Archive HTML report
    if ! (cd "${REPORT_DIR}" && zip -r "${report_archive}" .); then
        echo "Error: Failed to create HTML report archive"
        return 1
    fi
    
    # Archive JTL file
    if ! zip -j "${results_archive}" "${jtl_file}"; then
        echo "Error: Failed to create results archive"
        return 1
    fi
    
    # Cleanup report directory
    rm -rf "${REPORT_DIR}"
    
    echo "Report generated and archived to: ${report_archive}"
    echo "Results archived to: ${results_archive}"
    return 0
}

# Validate arguments
if [ $# -ne 1 ]; then
    echo "Error: CI job ID parameter is required"
    usage
fi

CI_JOB_ID="$1"
if [ -z "$CI_JOB_ID" ]; then
    echo "Error: CI job ID cannot be empty"
    usage
fi

# Set filename and timeout values
RESULTS_FILE="${CI_JOB_ID}.jtl"
MAX_WAIT_SECONDS=300  # 5 minutes timeout
WAIT_INTERVAL=5       # Check every 5 seconds

# Wait for results file to appear
echo "Waiting for ${RESULTS_FILE} to appear..."
wait_time=0
while [ ! -f "${RESULTS_FILE}" ]; do
    if [ $wait_time -ge $MAX_WAIT_SECONDS ]; then
        echo "Error: Timeout waiting for ${RESULTS_FILE}"
        exit 1
    fi
    sleep $WAIT_INTERVAL
    wait_time=$((wait_time + WAIT_INTERVAL))
    echo "Still waiting... (${wait_time}s/${MAX_WAIT_SECONDS}s)"
done

echo "Found ${RESULTS_FILE}, starting to stream results..."

# Function to check if JMeter is running
is_jmeter_running() {
    pgrep -f "ApacheJMeter" >/dev/null
    return $?
}

# Function to process and insert a line
process_line() {
    local line="$1"
    # Skip header line
    if [[ $line == *"timeStamp"* ]]; then
        return
    fi
    
    # Convert the line to PostgreSQL INSERT statement
    echo "$line" | awk -F',' -v ci_job="$CI_JOB_ID" '
    {
        # Save original field separator
        FPAT = "([^,]+)|(\"[^\"]+\")"
        
        # Remove surrounding quotes and escape internal quotes
        for (i=1; i<=NF; i++) {
            gsub(/^"|"$/, "", $i)
            gsub(/"/, "\"\"", $i)
        }
        
        printf "INSERT INTO jmeter_results (\
ci_job_id, timeStamp, elapsed, label, responseCode, \
responseMessage, threadName, dataType, success, failureMessage, \
bytes, sentBytes, grpThreads, allThreads, Latency, IdleTime, Connect\
) VALUES (\
'"'"'%s'"'"', '"'"'%s'"'"', %s, '"'"'%s'"'"', '"'"'%s'"'"', \
'"'"'%s'"'"', '"'"'%s'"'"', '"'"'%s'"'"', '"'"'%s'"'"', \
'"'"'%s'"'"', %s, %s, %s, %s, %s, %s, %s);\n", \
        ci_job, $1, $2, $3, $4, $5, $6, $7, $8, $9, \
        $10, $11, $12, $13, $14, $15, $16
    }' | psql -q
}

# Stream the file with JMeter process monitoring
{
    tail -n +1 -f "${RESULTS_FILE}" | while IFS= read -r line; do
        process_line "$line"
        
        # Check if JMeter is still running
        if ! is_jmeter_running; then
            # Wait a bit to ensure all results are processed
            sleep 5
            if [ -s "${RESULTS_FILE}" ]; then
                last_modified=$(stat -c %Y "${RESULTS_FILE}")
                current_time=$(date +%s)
                # If file hasn't been modified in last 5 seconds and JMeter is not running
                if [ $((current_time - last_modified)) -gt 5 ]; then
                    echo "JMeter process completed and results processing finished."
                    exit 0
                fi
            fi
        fi
    done
} &

# Monitor the background tail process
tail_pid=$!
while kill -0 $tail_pid 2>/dev/null; do
    if ! is_jmeter_running; then
        sleep 5  # Give tail process time to process remaining lines
        kill $tail_pid 2>/dev/null
        echo "JMeter process completed. Streaming terminated."
        
        # After streaming completes, generate report
        if ! generate_report "${RESULTS_FILE}" "${CI_JOB_ID}"; then
            echo "Warning: Report generation failed"
            exit 1
        fi

        echo "JMeter results processing and report generation completed successfully."
        exit 0
    fi
    sleep 5
done