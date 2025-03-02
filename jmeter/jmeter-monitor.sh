#!/bin/bash

# Load configuration
[ -f /etc/jmeter-monitor/config ] && source /etc/jmeter-monitor/config

# Service status file
STATUS_FILE="/var/run/jmeter-monitor.status"
LOCK_FILE="/var/run/jmeter-monitor.lock"

# Signal handling
cleanup() {
    logger -t jmeter-monitor "Service stopping..."
    rm -f "$LOCK_FILE" "$STATUS_FILE"
    exit 0
}

trap cleanup SIGTERM SIGINT SIGQUIT

# Ensure single instance
if ! mkdir "$LOCK_FILE" 2>/dev/null; then
    logger -t jmeter-monitor "Another instance is running"
    exit 1
fi

# Service startup
logger -t jmeter-monitor "Service starting with ENVIRONMENT=$ENVIRONMENT"
echo "running" > "$STATUS_FILE"

# ...existing PostgreSQL connection check code...

# Function to find active JMeter result files
find_active_jtl_files() {
    find "$JTL_BASE_DIR" -name "*.jtl" -mmin -5
}

# Main service loop
while true; do
    active_files=$(find_active_jtl_files)
    
    if [ -n "$active_files" ]; then
        echo "active" > "$STATUS_FILE"
        logger -t jmeter-monitor "Found active JTL files: $active_files"
        
        for JTL_FILE in $active_files; do
            TEST_RUN_ID=$(basename "$JTL_FILE" .jtl)
            
            # Skip if already processing this file
            [ -f "/tmp/jmeter_position_${TEST_RUN_ID}" ] && continue
            
            # Process new JTL file
            logger -t jmeter-monitor "Processing new JTL file: $JTL_FILE"
            
            # ...existing batch size calculation code...
            
            # Create position tracking file
            POSITION_FILE="/tmp/jmeter_position_${TEST_RUN_ID}"
            echo "0" > "$POSITION_FILE"
            
            # Monitor this specific file
            if [ "$USE_INOTIFY" -eq 1 ]; then
                # ...existing inotify monitoring code...
            else
                # ...existing polling code...
            fi
        done
    else
        echo "idle" > "$STATUS_FILE"
        sleep 10
    fi
done
