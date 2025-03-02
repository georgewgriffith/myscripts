#!/bin/bash

# Configuration
DB_NAME="your_db"
DB_USER="your_user"
DB_HOST="localhost"
JTL_BASE_DIR="/path/to/jmeter/results"
ENVIRONMENT=${ENVIRONMENT:=Unknown}
LOG_FILE="/var/log/jmeter_stream.log"
TABLE_NAME="jmeter_results"

# Service management
STATUS_FILE="/tmp/jmeter_stream.status"
LOCK_FILE="/tmp/jmeter_stream.lock"
JMETER_CHECK_CACHE="/tmp/jmeter_running"
CACHE_TIMEOUT=5

# Array to track background PIDs
declare -a BG_PIDS=()

# Logging function
log_message() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Enhanced cleanup function
cleanup() {
    log_message "Cleaning up and exiting..."
    
    # Kill all background processes
    for pid in "${BG_PIDS[@]}"; do
        kill $pid 2>/dev/null
    done
    
    # Remove temporary files
    rm -f "$LOCK_FILE" "$STATUS_FILE" "$JMETER_CHECK_CACHE"
    find /tmp -name "jmeter_position_*" -delete
    
    # Final cleanup of any remaining temp files
    [ -n "$TEMP_CSV" ] && rm -f "$TEMP_CSV"
    
    exit 0
}

# Enhanced error handling
handle_error() {
    log_message "Error occurred in script at line $1"
    cleanup
}

# Set up trap for cleanup and error handling
trap cleanup SIGTERM SIGINT SIGQUIT
trap 'handle_error ${LINENO}' ERR

# Ensure single instance with timeout
exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
    log_message "Another instance is running"
    exit 1
fi

# Atomic status update function
update_status() {
    echo "$1" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
}

# Capture Environment Variables
ENVIRONMENT=${ENVIRONMENT:=Unknown}  # POSIX-compliant parameter expansion
TEST_RUN_ID=${TEST_RUN_ID:=$(date +%Y%m%d%H%M%S)}  # More compatible date format

# Function to check if JMeter is running (cached for 5 seconds)
is_jmeter_running() {
    current_time=$(date +%s)
    if [ -f "$JMETER_CHECK_CACHE" ]; then
        cache_time=$(stat -c %Y "$JMETER_CHECK_CACHE")
        if [ $((current_time - cache_time)) -lt $CACHE_TIMEOUT ]; then
            return $(cat "$JMETER_CHECK_CACHE")
        fi
    fi
    
    if ps -ef | grep "[A]pacheJMeter" >/dev/null 2>&1; then
        echo 0 > "$JMETER_CHECK_CACHE"
        return 0
    else
        echo 1 > "$JMETER_CHECK_CACHE"
        return 1
    fi
}

# Function to check PostgreSQL connection
check_postgres() {
    if ! psql -U "$DB_USER" -d "$DB_NAME" -h "$DB_HOST" -c "\q" >/dev/null 2>&1; then
        log_message "Error: Cannot connect to PostgreSQL database"
        exit 1
    fi
}

# Initial PostgreSQL connection check
check_postgres

# Function to get available memory in MB
get_available_memory() {
    free -m | awk 'NR==2 {print $7}'
}

# Function to get CPU cores
get_cpu_cores() {
    nproc
}

# Function to get PostgreSQL max_connections
get_pg_max_connections() {
    psql -U "$DB_USER" -d "$DB_NAME" -h "$DB_HOST" -t -c "SHOW max_connections;" 2>/dev/null || echo "100"
}

# Calculate optimal batch size
calculate_batch_size() {
    local mem_mb=$(get_available_memory)
    local cpu_cores=$(get_cpu_cores)
    local pg_max_conn=$(get_pg_max_connections)
    
    # Base calculation:
    # - Use 10% of available memory (in MB) as a factor
    # - Multiply by number of CPU cores
    # - Divide by estimated record size (assume 500 bytes per record)
    # - Consider PostgreSQL max_connections (leave 20% for other operations)
    
    local mem_factor=$((mem_mb / 10))
    local conn_limit=$((pg_max_conn * 80 / 100))
    
    # Calculate batch size with all factors
    local calculated_size=$((mem_factor * cpu_cores / 5))
    
    # Apply boundaries
    local min_batch=50
    local max_batch=10000
    
    # Ensure we don't exceed connection limit
    if [ $calculated_size -gt $conn_limit ]; then
        calculated_size=$conn_limit
    fi
    
    # Apply min/max boundaries
    if [ $calculated_size -lt $min_batch ]; then
        calculated_size=$min_batch
    elif [ $calculated_size -gt $max_batch ]; then
        calculated_size=$max_batch
    fi
    
    echo $calculated_size
}

# Determine optimal batch size
BATCH_SIZE=$(calculate_batch_size)
log_message "Calculated optimal batch size: $BATCH_SIZE records"
log_message "System details:"
log_message "- Available memory: $(get_available_memory) MB"
log_message "- CPU cores: $(get_cpu_cores)"
log_message "- PostgreSQL max connections: $(get_pg_max_connections)"

# Create temporary files for batching
TEMP_CSV=$(mktemp) || { log_message "Failed to create temp file"; exit 1; }
trap 'rm -f $TEMP_CSV' EXIT

# Create position tracking file
POSITION_FILE="/tmp/jmeter_position_${TEST_RUN_ID}"
echo "0" > "$POSITION_FILE"
trap 'rm -f $TEMP_CSV $POSITION_FILE' EXIT

# Function to read chunks efficiently
read_chunk() {
    local jtl_file="$1"
    local position_file="$2"
    local last_pos=$(cat "$position_file")
    local current_size=$(stat -c %s "$jtl_file" 2>/dev/null || echo "$last_pos")
    local chunk_size=$((1024 * 64))  # 64KB chunks
    
    if [ "$current_size" -gt "$last_pos" ]; then
        dd if="$jtl_file" bs=1 skip="$last_pos" count=$((current_size - last_pos)) 2>/dev/null
        echo "$current_size" > "$position_file"
    fi
}

# Install required package if missing
if ! command -v inotifywait >/dev/null 2>&1; then
    log_message "Installing inotify-tools..."
    yum install -y inotify-tools >/dev/null 2>&1 || {
        log_message "Error: Failed to install inotify-tools. Falling back to polling mode."
        USE_INOTIFY=0
    }
else
    USE_INOTIFY=1
fi

log_message "Monitoring JMeter and streaming results when active..."

# Function to find active JTL files (modified in last 5 minutes)
find_active_jtl_files() {
    find "$JTL_BASE_DIR" -name "*.jtl" -mmin -5 2>/dev/null
}

# Enhanced process management function
manage_background_process() {
    local pid=$1
    BG_PIDS+=($pid)
}

# PostgreSQL operations
process_batch() {
    local csv_file="$1"
    local jtl_file="$2"
    if [ -s "$csv_file" ]; then
        if ! psql -U "$DB_USER" -d "$DB_NAME" -h "$DB_HOST" -c "\COPY $TABLE_NAME FROM '$csv_file' WITH (FORMAT csv);" 2>/dev/null; then
            log_message "Error: Failed to copy data to PostgreSQL for $jtl_file"
            check_postgres
            return 1
        fi
        echo -n > "$csv_file"
    fi
}

# Data processing pipeline
process_data() {
    local input="$1"
    local test_run_id="$2"
    awk -F',' -v env="$ENVIRONMENT" -v run_id="$test_run_id" '
    BEGIN { OFS="," }
    !/timeStamp/ && NF > 12 {
        gsub("'\''", "'\'\''", $3);
        gsub("'\''", "'\'\''", $5);
        print $1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,env,run_id
    }'
}

# File monitoring function
monitor_file() {
    local jtl_file="$1"
    local test_run_id="$2"
    local temp_csv="$3"
    local record_count=0
    local position_file="/tmp/jmeter_position_${test_run_id}"
    
    echo "0" > "$position_file"
    
    if [ "$USE_INOTIFY" -eq 1 ]; then
        while inotifywait -q -e modify "$jtl_file" >/dev/null 2>&1; do
            process_file_chunk "$jtl_file" "$test_run_id" "$temp_csv" "$position_file"
            [ $? -ne 0 ] && break
        done
    else
        while is_jmeter_running; do
            process_file_chunk "$jtl_file" "$test_run_id" "$temp_csv" "$position_file"
            [ $? -ne 0 ] && break
            sleep 0.1
        done
    fi
    
    # Final batch
    process_batch "$temp_csv" "$jtl_file"
    rm -f "$position_file"
}

# Process file chunk
process_file_chunk() {
    local jtl_file="$1"
    local test_run_id="$2"
    local temp_csv="$3"
    local position_file="$4"
    local record_count=0
    
    read_chunk "$jtl_file" "$position_file" | \
    process_data "$test_run_id" | \
    while read -r line; do
        echo "$line" >> "$temp_csv"
        ((record_count++))
        
        if [ $record_count -ge $BATCH_SIZE ]; then
            process_batch "$temp_csv" "$jtl_file" &
            manage_background_process $!
            record_count=0
        fi
        
        if ! is_jmeter_running; then
            return 1
        fi
    done
}

# Validate directories and permissions
validate_environment() {
    # Check JTL directory exists and is readable
    if [ ! -d "$JTL_BASE_DIR" ]; then
        log_message "Error: JTL directory $JTL_BASE_DIR does not exist"
        exit 1
    fi

    # Check if table exists
    if ! psql -U "$DB_USER" -d "$DB_NAME" -h "$DB_HOST" -t -c "\dt $TABLE_NAME" | grep -q "$TABLE_NAME"; then
        log_message "Error: Table $TABLE_NAME does not exist"
        exit 1
    fi

    # Validate write permissions for temp directories
    if [ ! -w "/tmp" ]; then
        log_message "Error: No write permission in /tmp directory"
        exit 1
    fi
}

# Resource monitoring function
monitor_resources() {
    local mem_usage=$(get_available_memory)
    local cpu_usage=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}')
    
    if [ "$mem_usage" -lt 100 ]; then  # Less than 100MB available
        log_message "Warning: Low memory available: ${mem_usage}MB"
    fi
    
    if [ "${cpu_usage%.*}" -gt 90 ]; then  # CPU usage above 90%
        log_message "Warning: High CPU usage: ${cpu_usage}%"
    fi
}

# Main script
validate_environment

# Main monitoring loop
update_status "running"

while true; do
    monitor_resources
    
    active_files=$(find_active_jtl_files)
    
    if [ -n "$active_files" ]; then
        update_status "active"
        
        for JTL_FILE in $active_files; do
            [ ! -r "$JTL_FILE" ] && continue
            
            TEST_RUN_ID=$(basename "$JTL_FILE" .jtl)
            [ -f "/tmp/jmeter_position_${TEST_RUN_ID}" ] && continue
            
            TEMP_CSV=$(mktemp) || { log_message "Failed to create temp file"; continue; }
            
            (monitor_file "$JTL_FILE" "$TEST_RUN_ID" "$TEMP_CSV") &
            manage_background_process $!
        done
    else
        update_status "idle"
        sleep 10
    fi
    
    # Clean up completed processes
    for pid in "${BG_PIDS[@]}"; do
        if ! kill -0 $pid 2>/dev/null; then
            BG_PIDS=("${BG_PIDS[@]/$pid}")
        fi
    done
done
