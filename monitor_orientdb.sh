#!/bin/bash

# ================== CONFIGURATION ==================
OUTPUT_DIR="$HOME/orientdb_metrics"
mkdir -p "$OUTPUT_DIR"

INTERVAL=60  # Data collection interval in seconds
DURATION_HOURS=6  # Monitoring duration
END_TIME=$((SECONDS + DURATION_HOURS * 3600))

JMX_HOST="localhost"
JMX_PORT="1099"
DISK_DEVICE="sda"  # Default disk device
NETWORK_INTERFACE="eth0"  # Default network interface
LOG_FILE="$OUTPUT_DIR/monitor.log"
OUTPUT_FORMAT="json"  # Default format

# Allow customization via script parameters
while getopts "d:n:i:t:o:f:h" opt; do
    case ${opt} in
        d ) DISK_DEVICE=$OPTARG ;;  # Custom disk device
        n ) NETWORK_INTERFACE=$OPTARG ;;  # Custom network interface
        i ) INTERVAL=$OPTARG ;;  # Custom interval
        t ) DURATION_HOURS=$OPTARG ;;  # Custom duration
        o ) OUTPUT_DIR=$OPTARG ;;  # Custom output directory
        f ) OUTPUT_FORMAT=$OPTARG ;;  # Custom output format (json, csv, xml)
        h ) echo "Usage: $0 [-d disk_device] [-n network_interface] [-i interval] [-t duration_hours] [-o output_dir] [-f output_format]"; exit 0 ;;
        * ) echo "Invalid option"; exit 1 ;;
    esac
done

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
    command -v "$1" >/dev/null 2>&1 || { echo "ERROR: $1 is not installed. Exiting." | tee -a "$LOG_FILE"; exit 1; }
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
echo "$(date) - Monitoring started" | tee -a "$LOG_FILE"
while [ $SECONDS -lt $END_TIME ]; do
    TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")

    # ================== RESOURCE SAFETY CHECKS ==================
    FREE_MEM_MB=$(free -m | awk '/Mem:/ {print $4}')
    if [[ "$FREE_MEM_MB" -lt "$SAFE_MEMORY_THRESHOLD_MB" ]]; then
        echo "$(date) - WARNING: Low memory ($FREE_MEM_MB MB). Skipping this cycle to prevent OOM." | tee -a "$LOG_FILE"
        sleep "$INTERVAL"
        continue
    fi

    FREE_DISK_MB=$(df -m "$OUTPUT_DIR" | awk 'NR==2 {print $4}')
    if [[ "$FREE_DISK_MB" -lt "$SAFE_DISK_THRESHOLD_MB" ]]; then
        echo "$(date) - WARNING: Low disk space ($FREE_DISK_MB MB). Skipping this cycle." | tee -a "$LOG_FILE"
        sleep "$INTERVAL"
        continue
    fi

    # ================== SYSTEM LOAD MONITORING ==================
    LOAD_AVG=$(awk '{print $1, $2, $3}' /proc/loadavg)

    # ================== DISK IOPS MONITORING ==================
    DISK_STATS=$(iostat -dx 1 1 | awk -v disk="$DISK_DEVICE" '$1 == disk {print $4, $5}')
    DISK_READ=$(echo "$DISK_STATS" | awk '{print $1}')
    DISK_WRITE=$(echo "$DISK_STATS" | awk '{print $2}')
    total_disk_read=$(echo "$total_disk_read + $DISK_READ" | bc)
    total_disk_write=$(echo "$total_disk_write + $DISK_WRITE" | bc)

    # ================== NETWORK MONITORING ==================
    NET_STATS=$(sar -n DEV 1 1 | awk -v iface="$NETWORK_INTERFACE" '$2 == iface {print $5, $6}')
    NET_RX=$(echo "$NET_STATS" | awk '{print $1}')
    NET_TX=$(echo "$NET_STATS" | awk '{print $2}')
    total_net_rx=$(echo "$total_net_rx + $NET_RX" | bc)
    total_net_tx=$(echo "$total_net_tx + $NET_TX" | bc)

    total_iterations=$((total_iterations + 1))

    # ================== ORIENTDB CACHE HIT RATIO VIA JMX ==================
    CACHE_HIT_RATIO="N/A"
    JMX_STATS=$(echo "open $JMX_HOST:$JMX_PORT
get com.orientechnologies.orient.server:type=OSharedContextCache HitRatio
quit" | jmxterm 2>/dev/null | grep "HitRatio" | awk '{print $NF}')
    if [[ "$JMX_STATS" =~ ^[0-9.]+$ ]]; then
        CACHE_HIT_RATIO="$JMX_STATS"
    fi

    # ================== AZURE POSTGRESQL SUGGESTED VALUES ==================
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
