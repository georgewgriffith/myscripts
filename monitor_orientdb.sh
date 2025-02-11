#!/bin/bash

# ================== CONFIGURATION ==================
OUTPUT_DIR="$HOME/orientdb_metrics"
mkdir -p "$OUTPUT_DIR"

INTERVAL=60  # Data collection interval in seconds
DURATION_HOURS=6  # Monitoring duration
END_TIME=$((SECONDS + DURATION_HOURS * 3600))

JMX_HOST="localhost"
JMX_PORT="1099"

# Define safe memory and disk thresholds
SAFE_MEMORY_THRESHOLD_MB=200  # Minimum free memory to continue execution
SAFE_DISK_THRESHOLD_MB=500  # Minimum free disk space required

# Initialize accumulators for averages
total_cpu=0
total_memory=0
total_disk_read=0
total_disk_write=0
total_net_rx=0
total_net_tx=0
total_iterations=0

# ================== FUNCTION: CHECK DEPENDENCIES ==================
check_command() {
    command -v "$1" >/dev/null 2>&1 || { echo "ERROR: $1 is not installed. Exiting."; exit 1; }
}

# Verify all required commands exist
check_command iostat
check_command vmstat
check_command sar
check_command iotop
check_command jmxterm
check_command awk
check_command bc

# ================== MONITORING LOOP ==================
while [ $SECONDS -lt $END_TIME ]; do
    TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")

    # ================== RESOURCE SAFETY CHECKS ==================
    FREE_MEM_MB=$(free -m | awk '/Mem:/ {print $4}')
    if [[ "$FREE_MEM_MB" -lt "$SAFE_MEMORY_THRESHOLD_MB" ]]; then
        echo "WARNING: Low memory ($FREE_MEM_MB MB). Skipping this cycle to prevent OOM."
        sleep "$INTERVAL"
        continue
    fi

    FREE_DISK_MB=$(df -m "$OUTPUT_DIR" | awk 'NR==2 {print $4}')
    if [[ "$FREE_DISK_MB" -lt "$SAFE_DISK_THRESHOLD_MB" ]]; then
        echo "WARNING: Low disk space ($FREE_DISK_MB MB). Skipping this cycle."
        sleep "$INTERVAL"
        continue
    fi

    # ================== SYSTEM METRICS COLLECTION ==================
    DISK_STATS=$(iostat -dx 1 1 | awk '/sda/ {print $4, $5}')
    DISK_READ=$(echo "$DISK_STATS" | awk '{print $1}')
    DISK_WRITE=$(echo "$DISK_STATS" | awk '{print $2}')
    total_disk_read=$(echo "$total_disk_read + $DISK_READ" | bc)
    total_disk_write=$(echo "$total_disk_write + $DISK_WRITE" | bc)

    VM_STATS=$(vmstat 1 1 | awk 'NR==3 {print $13, $14, $4}')
    CPU_USER=$(echo "$VM_STATS" | awk '{print $1}')
    CPU_SYSTEM=$(echo "$VM_STATS" | awk '{print $2}')
    MEMORY_FREE=$(echo "$VM_STATS" | awk '{print $3}')
    total_cpu=$(echo "$total_cpu + $CPU_USER + $CPU_SYSTEM" | bc)
    total_memory=$(echo "$total_memory + $MEMORY_FREE" | bc)

    NET_STATS=$(sar -n DEV 1 1 | awk '/eth0/ {print $5, $6}')
    NET_RX=$(echo "$NET_STATS" | awk '{print $1}')
    NET_TX=$(echo "$NET_STATS" | awk '{print $2}')
    total_net_rx=$(echo "$total_net_rx + $NET_RX" | bc)
    total_net_tx=$(echo "$total_net_tx + $NET_TX" | bc)

    total_iterations=$((total_iterations + 1))

    # ================== ORIENTDB METRICS VIA JMX ==================
    CACHE_HIT_RATIO="N/A"
    JMX_STATS=$(echo "open $JMX_HOST:$JMX_PORT
get com.orientechnologies.orient.server:type=OSharedContextCache HitRatio
quit" | jmxterm 2>/dev/null | grep "HitRatio" | awk '{print $NF}')
    if [[ "$JMX_STATS" =~ ^[0-9.]+$ ]]; then
        CACHE_HIT_RATIO="$JMX_STATS"
    fi

    # ================== SUGGESTED AZURE POSTGRESQL VALUES ==================
    SUGGESTED_VCPUS="$(echo "scale=0; ($total_cpu / $total_iterations) / 25 + 1" | bc)vCPUs"
    SUGGESTED_NETWORK_THROUGHPUT="$(echo "scale=2; ($total_net_rx + $total_net_tx) / $total_iterations" | bc) Mbps"
    RECOMMENDED_EXTENSIONS="pg_stat_statements,pg_cron,pg_partman"

    # ================== OUTPUT TO JSON ==================
    echo "{
        \"timestamp\": \"$TIMESTAMP\",
        \"cpu_avg\": \"$(echo "$total_cpu / $total_iterations" | bc)\",
        \"memory_avg\": \"$(echo "$total_memory / $total_iterations" | bc)\",
        \"disk_read_avg\": \"$(echo "$total_disk_read / $total_iterations" | bc)\",
        \"disk_write_avg\": \"$(echo "$total_disk_write / $total_iterations" | bc)\",
        \"net_rx_avg\": \"$(echo "$total_net_rx / $total_iterations" | bc)\",
        \"net_tx_avg\": \"$(echo "$total_net_tx / $total_iterations" | bc)\",
        \"cache_hit_ratio\": \"$CACHE_HIT_RATIO\",
        \"suggested_vcpus\": \"$SUGGESTED_VCPUS\",
        \"suggested_network_throughput\": \"$SUGGESTED_NETWORK_THROUGHPUT\",
        \"recommended_postgresql_extensions\": \"$RECOMMENDED_EXTENSIONS\"
    }" > "$OUTPUT_DIR/metrics_$TIMESTAMP.json"

    sleep "$INTERVAL"
done
