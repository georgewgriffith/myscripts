#!/bin/bash

# Parse command line arguments
usage() {
    echo "Usage: $0 <ci_job_id>"
    echo "Example: $0 123456"
    exit 1
}

# Check required commands
for cmd in pgrep psql zip awk tail mkdir rm; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Error: Required command '$cmd' not found"
        exit 1
    fi
done

# Configuration
JMETER_BIN="/opt/jmeter/bin/jmeter"
EXPORT_DIR="/opt/jmeter/export"

# Check JMeter binary
if [ ! -x "${JMETER_BIN}" ]; then
    echo "Error: JMeter binary not found or not executable at ${JMETER_BIN}"
    exit 1
fi

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

# Now we can safely define REPORT_DIR
REPORT_DIR="/tmp/report_${CI_JOB_ID}"

# Create export directory if it doesn't exist
if ! mkdir -p "${EXPORT_DIR}"; then
    echo "Error: Failed to create export directory ${EXPORT_DIR}"
    exit 1
fi

# Function to generate and archive HTML report
generate_report() {
    local jtl_file="$1"
    local job_id="$2"
    
    echo "Generating HTML report for job ${job_id}..."
    
    # Create fresh report directory
    rm -rf "${REPORT_DIR}"
    mkdir -p "${REPORT_DIR}"
    
    # Generate HTML report using explicit jmeter binary
    if ! "${JMETER_BIN}" -g "${jtl_file}" -o "${REPORT_DIR}"; then
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

# Set filename and timeout values
RESULTS_FILE="/opt/jmeter/results/${CI_JOB_ID}.jtl"
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

# Function to process and insert a line - FIX QUOTES ISSUE HERE
process_line() {
    local line="$1"
    # Skip header line
    if [[ $line == *"timeStamp"* ]]; then
        return
    fi
    
    # Use a simpler approach to avoid quote escaping issues in CI/CD pipeline
    echo "$line" | awk -v FPAT='([^,]+)|(\"[^\"]+\")' -v ci_job="$CI_JOB_ID" '{
        # Ensure we have all fields, pad with empty strings if needed
        for (i=1; i<=16; i++) {
            if (i > NF) $i = ""
        }
        
        # Remove outer quotes from all fields
        for (i=1; i<=NF; i++) {
            gsub(/^"|"$/, "", $i)
        }

        # Calculate values for fields that were moved from generated columns
        is_transact = ($5 ~ /number of samples in transaction/) ? "true" : "false"
        
        # Error type determination
        error_type = "Success"
        if ($8 == "false" || $8 == "FALSE") {
            if ($4 ~ /^5/) error_type = "Server Error"
            else if ($4 ~ /^4/) error_type = "Client Error"
            else error_type = "Other Error"
        }
        
        # Endpoint category determination
        endpoint_cat = "Other"
        if ($3 ~ /\/api\//) endpoint_cat = "API"
        else if ($3 ~ /\/login/) endpoint_cat = "Authentication"
        else if ($3 ~ /\/assets\//) endpoint_cat = "Static Assets"
        else if ($3 ~ /\.js/) endpoint_cat = "Static Assets"
        else if ($3 ~ /\.css/) endpoint_cat = "Static Assets"
        
        # Request type determination
        req_type = "Other"
        if ($3 ~ /\.css/) req_type = "CSS"
        else if ($3 ~ /\.js/) req_type = "JavaScript"
        else if ($3 ~ /\.jpg/ || $3 ~ /\.png/ || $3 ~ /\.gif/) req_type = "Image"
        else if ($3 ~ /\.html/ || $3 ~ /\.htm/) req_type = "HTML"
        else if ($3 ~ /\/api\//) req_type = "API"
        
        # Is sampler/controller determination
        is_samp = (is_transact == "false" && !($3 ~ /overall/)) ? "true" : "false"
        is_cont = ($3 ~ /controller/ || $3 ~ /-all/ || $3 ~ /overall/) ? "true" : "false"
        
        # Define functions inline to avoid quoting issues
        function normalize_number(val) {
            return (val == "" || val ~ /[^0-9]/) ? "0" : val
        }
        
        # Clean and prepare values
        ts = $1
        elapsed = normalize_number($2)
        label = $3
        respCode = $4
        respMsg = $5
        threadName = $6
        dataType = $7
        success = toupper($8)
        failMsg = $9
        bytes = normalize_number($10)
        sentBytes = normalize_number($11)
        grpThreads = normalize_number($12)
        allThreads = normalize_number($13)
        latency = normalize_number($14)
        idleTime = normalize_number($15)
        connect = normalize_number($16)
        
        # Print simpler SQL instead of the complex multi-line format
        printf "INSERT INTO jmeter_results (ci_job_id, timeStamp, timestamp_tz, elapsed, label, responseCode, responseMessage, threadName, dataType, success, failureMessage, bytes, sentBytes, grpThreads, allThreads, Latency, IdleTime, Connect, error_type, endpoint_category, is_transaction, is_sampler, is_controller, request_type, hour_of_day, minute_of_hour, day_of_week) VALUES ('"'"'%s'"'"', '"'"'%s'"'"', to_timestamp('"'"'%s'"'"', '"'"'YYYY/MM/DD HH24:MI:SS'"'"'), %s, '"'"'%s'"'"', '"'"'%s'"'"', '"'"'%s'"'"', '"'"'%s'"'"', '"'"'%s'"'"', '"'"'%s'"'"', '"'"'%s'"'"', %s, %s, %s, %s, %s, %s, %s, '"'"'%s'"'"', '"'"'%s'"'"', %s, %s, %s, '"'"'%s'"'"', EXTRACT(HOUR FROM to_timestamp('"'"'%s'"'"', '"'"'YYYY/MM/DD HH24:MI:SS'"'"')), EXTRACT(MINUTE FROM to_timestamp('"'"'%s'"'"', '"'"'YYYY/MM/DD HH24:MI:SS'"'"')), EXTRACT(DOW FROM to_timestamp('"'"'%s'"'"', '"'"'YYYY/MM/DD HH24:MI:SS'"'"')));\n", 
          ci_job, ts, ts, elapsed, label, respCode, respMsg, threadName, dataType, 
          success, failMsg, bytes, sentBytes, grpThreads, allThreads, latency, 
          idleTime, connect, error_type, endpoint_cat, is_transact, is_samp, 
          is_cont, req_type, ts, ts, ts)
    }' | PGPASSWORD=${DB_PASSWORD:-postgres} psql -h ${DB_HOST:-localhost} -U ${DB_USER:-postgres} -d ${DB_NAME:-jmeter} -q
}

# Before streaming starts, add environment variable usage for DB connection
echo "Connecting to database: ${DB_HOST:-localhost}/${DB_NAME:-jmeter} as ${DB_USER:-postgres}"

# Stream the file with JMeter process monitoring
{
    sudo tail -n +1 -f "${RESULTS_FILE}" | while IFS= read -r line; do
        # Add error handling for pipeline execution
        set +e
        process_line "$line"
        status=$?
        set -e
        
        # Log any processing errors for debugging in CI/CD
        if [ $status -ne 0 ]; then
            echo "Error processing line: $line" >&2
        fi
        
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