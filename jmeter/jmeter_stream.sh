#!/bin/bash

# Configuration
DB_NAME="your_db"
DB_USER="your_user"
DB_HOST="localhost"
JTL_BASE_DIR="/path/to/jmeter/results"
ENVIRONMENT=${ENVIRONMENT:=Unknown}

# Service management
STATUS_FILE="/tmp/jmeter_stream.status"
LOCK_FILE="/tmp/jmeter_stream.lock"
JMETER_CHECK_CACHE="/tmp/jmeter_running"
CACHE_TIMEOUT=5

# Array to track background PIDs
declare -a BG_PIDS=()

# Enhanced cleanup function
cleanup() {
    echo "Cleaning up and exiting..."
    
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
    echo "Error occurred in script at line $1"
    cleanup
}

# Set up trap for cleanup and error handling
trap cleanup SIGTERM SIGINT SIGQUIT
trap 'handle_error ${LINENO}' ERR

# Ensure single instance with timeout
exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
    echo "Another instance is running"
    exit 1
fi

# Atomic status update function
update_status() {
    echo "$1" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
}

# PostgreSQL Credentials
DB_NAME="your_db"
DB_USER="your_user"
DB_HOST="localhost"
JTL_FILE="/path/to/results.jtl"

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
        echo "Error: Cannot connect to PostgreSQL database"
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
echo "Calculated optimal batch size: $BATCH_SIZE records"
echo "System details:"
echo "- Available memory: $(get_available_memory) MB"
echo "- CPU cores: $(get_cpu_cores)"
echo "- PostgreSQL max connections: $(get_pg_max_connections)"

# Create temporary files for batching
TEMP_CSV=$(mktemp) || { echo "Failed to create temp file"; exit 1; }
trap 'rm -f $TEMP_CSV' EXIT

# Create position tracking file
POSITION_FILE="/tmp/jmeter_position_${TEST_RUN_ID}"
echo "0" > "$POSITION_FILE"
trap 'rm -f $TEMP_CSV $POSITION_FILE' EXIT

# Function to read chunks efficiently
read_chunk() {
    local last_pos=$(cat "$POSITION_FILE")
    local current_size=$(stat -c %s "$JTL_FILE" 2>/dev/null || echo "$last_pos")
    local chunk_size=$((1024 * 64))  # 64KB chunks
    
    if [ "$current_size" -gt "$last_pos" ]; then
        dd if="$JTL_FILE" bs=1 skip="$last_pos" count=$((current_size - last_pos)) 2>/dev/null
        echo "$current_size" > "$POSITION_FILE"
    fi
}

# Install required package if missing
if ! command -v inotifywait >/dev/null 2>&1; then
    echo "Installing inotify-tools..."
    yum install -y inotify-tools >/dev/null 2>&1 || {
        echo "Error: Failed to install inotify-tools. Falling back to polling mode."
        USE_INOTIFY=0
    }
else
    USE_INOTIFY=1
fi

echo "Monitoring JMeter and streaming results when active..."

# Function to find active JTL files (modified in last 5 minutes)
find_active_jtl_files() {
    find "$JTL_BASE_DIR" -name "*.jtl" -mmin -5 2>/dev/null
}

# Enhanced process management function
manage_background_process() {
    local pid=$1
    BG_PIDS+=($pid)
}

# Main monitoring loop
update_status "running"

while true; do
    active_files=$(find_active_jtl_files)
    
    if [ -n "$active_files" ]; then
        update_status "active"
        
        for JTL_FILE in $active_files; do
            # Validate file exists and is readable
            [ ! -r "$JTL_FILE" ] && continue
            
            TEST_RUN_ID=$(basename "$JTL_FILE" .jtl)
            POSITION_FILE="/tmp/jmeter_position_${TEST_RUN_ID}"
            
            [ -f "$POSITION_FILE" ] && continue
            
            # Process file in background with error handling
            (
                if is_jmeter_running; then
                    echo "JMeter detected. Streaming results with ENVIRONMENT=$ENVIRONMENT, TEST_RUN_ID=$TEST_RUN_ID..."
                    record_count=0
                    
                    # Monitor file changes
                    if [ "$USE_INOTIFY" -eq 1 ]; then
                        while inotifywait -q -e modify "$JTL_FILE" >/dev/null 2>&1; do
                            read_chunk | awk -F',' '
                            BEGIN { OFS=","; }
                            !/timeStamp/ && NF > 12 {
                                gsub("'\''", "'\'\''", $3);
                                gsub("'\''", "'\'\''", $5);
                                print $1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,"'"$ENVIRONMENT"'","'"$TEST_RUN_ID"'"
                            }' | while read -r line; do
                                echo "$line" >> "$TEMP_CSV"
                                ((record_count++))
                                
                                if [ $record_count -ge $BATCH_SIZE ]; then
                                    # Process in background to prevent blocking
                                    (
                                        if [ -s "$TEMP_CSV" ]; then
                                            if ! psql -U "$DB_USER" -d "$DB_NAME" -h "$DB_HOST" -c "\COPY jmeter_results FROM '$TEMP_CSV' WITH (FORMAT csv);" 2>/dev/null; then
                                                echo "Error: Failed to copy data to PostgreSQL for $JTL_FILE"
                                                check_postgres
                                            fi
                                            echo -n > "$TEMP_CSV"
                                        fi
                                    ) &
                                    record_count=0
                                fi
                                
                                if ! is_jmeter_running; then
                                    break 2
                                fi
                            done
                        done
                    else
                        # Fallback polling mode
                        while is_jmeter_running; do
                            read_chunk | awk -F',' '
                            BEGIN { OFS=","; }
                            !/timeStamp/ && NF > 12 {
                                gsub("'\''", "'\'\''", $3);
                                gsub("'\''", "'\'\''", $5);
                                print $1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,"'"$ENVIRONMENT"'","'"$TEST_RUN_ID"'"
                            }' | while read -r line; do
                                echo "$line" >> "$TEMP_CSV"
                                ((record_count++))
                                
                                if [ $record_count -ge $BATCH_SIZE ]; then
                                    # Process in background to prevent blocking
                                    (
                                        if [ -s "$TEMP_CSV" ]; then
                                            if ! psql -U "$DB_USER" -d "$DB_NAME" -h "$DB_HOST" -c "\COPY jmeter_results FROM '$TEMP_CSV' WITH (FORMAT csv);" 2>/dev/null; then
                                                echo "Error: Failed to copy data to PostgreSQL for $JTL_FILE"
                                                check_postgres
                                            fi
                                            echo -n > "$TEMP_CSV"
                                        fi
                                    ) &
                                    record_count=0
                                fi
                                
                                if ! is_jmeter_running; then
                                    break 2
                                fi
                            done
                            sleep 0.1
                        done
                    fi
                    
                    # Final batch processing
                    if [ -s "$TEMP_CSV" ]; then
                        if ! psql -U "$DB_USER" -d "$DB_NAME" -h "$DB_HOST" -c "\COPY jmeter_results FROM '$TEMP_CSV' WITH (FORMAT csv);" 2>/dev/null; then
                            echo "Error: Failed to copy data to PostgreSQL for $JTL_FILE"
                            check_postgres
                        fi
                    fi
                else
                    echo "JMeter not running. Waiting..."
                    sleep 5
                fi
                # Clean up position file when done
                rm -f "$POSITION_FILE"
            ) &
            
            # Track background process
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
