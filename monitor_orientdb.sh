#!/bin/bash

# ================== COLOR DEFINITIONS ==================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# ================== CORE FUNCTIONS ==================
log_message() {
    local level=$1
    local message=$2
    echo "$(date +"%Y-%m-%d %H:%M:%S") [$level] $message" | tee -a "$LOG_FILE"
}

debug_log() {
    [[ "$DEBUG" == "true" ]] && log_message "DEBUG" "$1"
    return 0
}

handle_error() {
    local error_code=$1
    local error_msg=$2
    local fatal=${3:-false}

    case $error_code in
        1) level="ERROR"   # Fatal errors
           color=$RED ;;
        2) level="WARNING" # Recoverable errors
           color=$YELLOW ;;
        *) level="INFO"    # Information messages
           color=$GREEN ;;
    esac

    log_message "$level" "${color}${error_msg}${NC}"
    
    if [[ "$fatal" == "true" ]]; then
        log_message "FATAL" "Script terminated due to fatal error"
        cleanup
        exit $error_code
    fi
    return $error_code
}

generate_summary() {
    log_message "INFO" "Summary of collected data:"
    log_message "INFO" "Collected $total_iterations data points."
}

cleanup() {
    generate_summary
    log_message "INFO" "Monitoring stopped. Cleaning up..."
    exit 0
}

validate_config() {
    [[ $INTERVAL -lt 1 ]] && { log_message "ERROR" "Invalid interval value"; exit 1; }
    [[ $DURATION_HOURS -lt 1 ]] && { log_message "ERROR" "Invalid duration value"; exit 1; }
    [[ ! -b "/dev/$DISK_DEVICE" ]] && { log_message "ERROR" "Invalid disk device"; exit 1; }
    [[ ! -d "/sys/class/net/$NETWORK_INTERFACE" ]] && { log_message "ERROR" "Invalid network interface"; exit 1; }
}

check_system_resources() {
    local pid=$1
    local threshold_percent=90
    local min_free_mem_mb=1024

    # Check system memory
    local mem_info=$(free -m)
    local total_mem=$(echo "$mem_info" | awk '/Mem:/ {print $2}')
    local used_mem=$(echo "$mem_info" | awk '/Mem:/ {print $3}')
    local free_mem=$(echo "$mem_info" | awk '/Mem:/ {print $4}')
    local mem_percent=$(echo "scale=2; $used_mem * 100 / $total_mem" | bc)

    if (( $(echo "$mem_percent > $threshold_percent" | bc -l) )); then
        handle_error 1 "System memory usage critical: ${mem_percent}%" true
        return 1
    fi

    if (( $(echo "$free_mem < $min_free_mem_mb" | bc -l) )); then
        handle_error 1 "Free memory below threshold: ${free_mem}MB" true
        return 1
    fi

    # Check OrientDB memory
    if [[ -n "$pid" ]]; then
        local process_mem=$(ps -o rss= -p "$pid" | awk '{print $1/1024}')
        if (( $(echo "$process_mem > ($total_mem * 0.8)" | bc -l) )); then
            handle_error 1 "OrientDB memory usage too high: ${process_mem}MB" true
            return 1
        fi
    fi

    # Check disk space with reserve
    local disk_usage=$(df -m "$OUTPUT_DIR" | awk 'NR==2 {print $5}' | tr -d '%')
    if (( $(echo "$disk_usage > $threshold_percent" | bc -l) )); then
        handle_error 1 "Disk space critical: ${disk_usage}%" true
        return 1
    fi

    # Check inode usage
    local inode_usage=$(df -i "$OUTPUT_DIR" | awk 'NR==2 {print $5}' | tr -d '%')
    if (( $(echo "$inode_usage > $threshold_percent" | bc -l) )); then
        handle_error 1 "Inode usage critical: ${inode_usage}%" true
        return 1
    fi

    # Check load average
    local load_1min=$(awk '{print $1}' /proc/loadavg)
    local num_cpus=$(nproc)
    if (( $(echo "$load_1min > $num_cpus * 2" | bc -l) )); then
        handle_error 1 "System load too high: $load_1min" true
        return 1
    fi

    return 0
}

cleanup_old_files() {
    local max_age_days=7
    local max_logs=1000
    
    # Remove old log files
    find "$OUTPUT_DIR" -name "*.log" -type f -mtime +$max_age_days -delete 2>/dev/null
    
    # Compress old CSV files
    find "$OUTPUT_DIR" -name "*.csv" -type f -mtime +1 -exec gzip {} \; 2>/dev/null
    
    # Rotate if too many files
    local log_count=$(find "$OUTPUT_DIR" -type f | wc -l)
    if [[ $log_count -gt $max_logs ]]; then
        find "$OUTPUT_DIR" -type f -printf '%T+ %p\n' | \
            sort | head -n $(($log_count - $max_logs)) | \
            cut -d' ' -f2- | xargs rm -f
    fi
}

detect_system_config() {
    local detected_config=()

    # Detect primary network interface
    if command -v ip >/dev/null 2>&1; then
        # Try to find the default route interface
        DETECTED_NIC=$(ip route | grep default | awk '{print $5}' | head -n1)
        # Fallback to first non-loopback interface
        [[ -z "$DETECTED_NIC" ]] && DETECTED_NIC=$(ip link show | grep -v 'lo:' | grep 'state UP' | head -n1 | awk -F: '{print $2}' | tr -d ' ')
    else
        # Fallback to ifconfig
        DETECTED_NIC=$(route -n | grep '^0.0.0.0' | awk '{print $8}' | head -n1)
    fi

    # Detect primary disk device
    if [[ -d "/sys/block" ]]; then
        # Look for NVMe drives first
        DETECTED_DISK=$(ls /sys/block/ | grep -E '^nvme[0-9]+n[0-9]+$' | head -n1)
        # Fallback to standard SATA/SAS drives
        [[ -z "$DETECTED_DISK" ]] && DETECTED_DISK=$(ls /sys/block/ | grep -E '^sd[a-z]+$' | head -n1)
    fi

    # Detect available memory and set optimal interval
    local total_mem=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    if [[ $total_mem -gt 32000000 ]]; then  # More than 32GB
        SUGGESTED_INTERVAL=30
    elif [[ $total_mem -gt 16000000 ]]; then  # More than 16GB
        SUGGESTED_INTERVAL=45
    else
        SUGGESTED_INTERVAL=60
    fi

    # Detect CPU cores and set monitoring parameters
    local cpu_cores=$(nproc)
    SUGGESTED_THREADS=$((cpu_cores / 2))
    [[ $SUGGESTED_THREADS -lt 1 ]] && SUGGESTED_THREADS=1

    # Check disk type and set I/O parameters
    if [[ -n "$DETECTED_DISK" ]]; then
        local rotational
        rotational=$(cat "/sys/block/$DETECTED_DISK/queue/rotational")
        if [[ "$rotational" == "0" ]]; then
            DISK_TYPE="SSD/NVMe"
            IO_SCHEDULER="none"
        else
            DISK_TYPE="HDD"
            IO_SCHEDULER="cfq"
        fi
    fi

    # Log detected configuration just once
    if [[ "$SKIP_CONFIG_LOG" != "true" ]]; then
        log_message "INFO" "System Configuration Detected:"
        log_message "INFO" "- Network Interface: $DETECTED_NIC"
        log_message "INFO" "- Disk Device: $DETECTED_DISK ($DISK_TYPE)"
        log_message "INFO" "- CPU Cores: $cpu_cores (Using $SUGGESTED_THREADS threads)"
        log_message "INFO" "- Memory: $((total_mem/1024/1024))GB"
        log_message "INFO" "- Suggested Interval: ${SUGGESTED_INTERVAL}s"
        SKIP_CONFIG_LOG="true"
    fi

    # Automatically use detected values
    NETWORK_INTERFACE="${NETWORK_INTERFACE:-$DETECTED_NIC}"
    DISK_DEVICE="${DISK_DEVICE:-$DETECTED_DISK}"
    INTERVAL="${INTERVAL:-$SUGGESTED_INTERVAL}"
}

optimize_system() {
    if [[ $EUID -eq 0 ]]; then  # Only if running as root
        # Optimize disk I/O
        if [[ -n "$DISK_DEVICE" ]]; then
            echo "$IO_SCHEDULER" > "/sys/block/$DISK_DEVICE/queue/scheduler" 2>/dev/null
            echo "2" > "/sys/block/$DISK_DEVICE/queue/rq_affinity" 2>/dev/null
        fi

        # Optimize network
        if [[ -n "$NETWORK_INTERFACE" ]]; then
            # Enable TCP BBR if available
            if grep -q bbr /proc/sys/net/ipv4/tcp_available_congestion_control; then
                echo "bbr" > /proc/sys/net/ipv4/tcp_congestion_control
            fi
            # Optimize network interface
            ethtool -G "$NETWORK_INTERFACE" rx 4096 tx 4096 2>/dev/null
        fi

        # Optimize system limits for OrientDB
        cat >> /etc/sysctl.conf << EOF
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.core.somaxconn = 65535
EOF
        sysctl -p >/dev/null 2>&1
    else
        log_message "WARNING" "Not running as root, skipping system optimizations"
    fi
}

check_disk_space() {
    local available_space=$(df -BM "$OUTPUT_DIR" | awk 'NR==2 {print $4}' | tr -d 'M')
    if [[ $available_space -lt $SAFE_DISK_THRESHOLD_MB ]]; then
        log_message "ERROR" "Insufficient disk space. Available: ${available_space}MB"
        cleanup
    fi
}

check_dependencies() {
    # Detect OS type and version
    if [ -f /etc/redhat-release ]; then
        OS_TYPE="rhel"
        OS_VERSION=$(rpm -q --queryformat '%{VERSION}' centos-release)
    elif [ -f /etc/debian_version ]; then
        OS_TYPE="debian"
        OS_VERSION=$(cat /etc/debian_version)
    else
        OS_TYPE="unknown"
    fi

    local missing_deps=()
    
    # Required tools array - add RHEL7+ alternatives
    local required_tools=(
        "vmstat:sysstat"
        "iostat:sysstat"
        "sar:sysstat"
        "top:procps"
        "awk:gawk"
        "iotop:iotop"
        "dstat:dstat"
        "netstat:net-tools"
        "bc:bc"
    )

    # Check for Java tools with RHEL7+ support
    if ! command -v jcmd >/dev/null 2>&1 || ! command -v jstat >/dev/null 2>&1; then
        echo -e "\n${RED}Java tools (jcmd/jstat) not found${NC}"
        echo -e "\nInstall JDK using:"
        if [ "$OS_TYPE" = "rhel" ] && [ "$OS_VERSION" -ge 7 ]; then
            echo -e "${YELLOW}RHEL/CentOS 7+:${NC}"
            echo "sudo yum install -y java-11-openjdk-devel"
            echo "# or for Java 8"
            echo "sudo yum install -y java-1.8.0-openjdk-devel"
        else
            echo -e "${YELLOW}Debian/Ubuntu:${NC}"
            echo "sudo apt-get install -y openjdk-8-jdk"
        fi
        exit 1
    fi

    for tool in "${required_tools[@]}"; do
        local cmd="${tool%%:*}"
        local pkg="${tool##*:}"
        
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_deps+=("$pkg")
        fi
    done

    if [ ${#missing_deps[@]} -ne 0 ]; then
        echo "Missing required dependencies: ${missing_deps[*]}"
        echo "To install on Debian/Ubuntu:"
        echo "sudo apt-get update"
        echo "sudo apt-get install -y ${missing_deps[*]}"
        echo ""
        echo "To install on RHEL/CentOS:"
        echo "sudo yum install -y ${missing_deps[*]}"
        exit 1
    fi
}

find_orientdb_pid() {
    local pid=""
    
    # Method 1: Check server.pid file
    if [[ -f "$ORIENTDB_HOME/bin/server.pid" ]]; then
        pid=$(cat "$ORIENTDB_HOME/bin/server.pid")
        if kill -0 "$pid" 2>/dev/null; then
            echo "$pid"
            return 0
        fi
    fi

    # Method 2: Use ps with extended patterns
    for pattern in "${ORIENTDB_PATTERNS[@]}"; do
        pid=$(ps -ef | grep -v grep | grep "$pattern" | awk '{print $2}' | head -n1)
        if [[ -n "$pid" ]]; then
            echo "$pid"
            return 0
        fi
    done

    # Method 3: Check Java processes
    pid=$(ps -ef | grep java | grep -i orientdb | grep -v grep | awk '{print $2}' | head -n1)
    if [[ -n "$pid" ]]; then
        echo "$pid"
        return 0
    fi

    # Method 4: Use jcmd as last resort
    pid=$(jcmd | grep -i "orientdb" | cut -d' ' -f1 | head -n1)
    if [[ -n "$pid" ]]; then
        echo "$pid"
        return 0
    fi

    return 1
}

check_jmx_connection() {
    local pid=$1
    local found_port=0

    # Try to find JMX port from multiple sources
    log_message "INFO" "Looking for JMX port..."

    # 1. Check if port is already in use by JMX
    if netstat -tlpn 2>/dev/null | grep -q ":${JMX_PORT}.*LISTEN.*java"; then
        log_message "INFO" "Found active JMX port: $JMX_PORT"
        found_port=1
    fi

    # 2. Try to get port from process arguments
    if [[ $found_port -eq 0 ]]; then
        local jvm_args
        jvm_args=$(ps -fp "$pid" -o args 2>/dev/null | grep -o "jmxremote.port=[0-9]*")
        if [[ "$jvm_args" =~ jmxremote.port=([0-9]+) ]]; then
            JMX_PORT="${BASH_REMATCH[1]}"
            log_message "INFO" "Found JMX port from process args: $JMX_PORT"
            found_port=1
        fi
    fi

    # 3. Try to get port from jcmd
    if [[ $found_port -eq 0 ]]; then
        local jcmd_args
        jcmd_args=$(jcmd "$pid" VM.command_line 2>/dev/null | grep -o "jmxremote.port=[0-9]*")
        if [[ "$jcmd_args" =~ jmxremote.port=([0-9]+) ]]; then
            JMX_PORT="${BASH_REMATCH[1]}"
            log_message "INFO" "Found JMX port from jcmd: $JMX_PORT"
            found_port=1
        fi
    fi

    # 4. Scan common JMX ports if still not found
    if [[ $found_port -eq 0 ]]; then
        log_message "INFO" "Scanning common JMX ports..."
        for port in 1099 9999 9010 7199; do
            if nc -z localhost "$port" 2>/dev/null; then
                JMX_PORT=$port
                log_message "INFO" "Found active JMX port: $JMX_PORT"
                found_port=1
                break
            fi
        done
    fi

    # Verify JMX connection with better formatted messages
    if ! nc -z localhost "$JMX_PORT" 2>/dev/null; then
        log_message "ERROR" "JMX Connection Failed"
        echo -e "\n${YELLOW}Troubleshooting Steps:${NC}\n"
        echo -e "1. ${GREEN}Verify OrientDB JMX Configuration:${NC}"
        echo "   Check $ORIENTDB_HOME/config/orientdb-server-config.xml contains:"
        echo '   <entry name="metrics.jmx.enabled" value="true"/>'
        echo '   <entry name="metrics.jmx.port" value="1099"/>'
        echo -e "\n2. ${GREEN}Verify JMX Runtime Settings:${NC}"
        echo "   export ORIENTDB_OPTS=\"-Dcom.sun.management.jmxremote"
        echo "                        -Dcom.sun.management.jmxremote.port=$JMX_PORT"
        echo "                        -Dcom.sun.management.jmxremote.local.only=false"
        echo "                        -Dcom.sun.management.jmxremote.authenticate=false"
        echo "                        -Dcom.sun.management.jmxremote.ssl=false\""
        echo -e "\n3. ${GREEN}Check Network Access:${NC}"
        if [ "$OS_TYPE" = "rhel" ] && [ "$OS_VERSION" -ge 7 ]; then
            echo "   sudo firewall-cmd --permanent --add-port=$JMX_PORT/tcp"
            echo "   sudo firewall-cmd --reload"
        else
            echo "   sudo ufw allow $JMX_PORT/tcp"
        fi
        echo -e "\n4. ${GREEN}Verify Port Availability:${NC}"
        echo "   sudo netstat -tlpn | grep $JMX_PORT"
        echo -e "\n5. ${GREEN}Restart OrientDB:${NC}"
        echo "   $ORIENTDB_HOME/bin/server.sh stop"
        echo "   sleep 5"
        echo -e "   $ORIENTDB_HOME/bin/server.sh start\n"
        return 1
    fi

    # Test JMX connection
    if ! jcmd "$pid" VM.check_commercial_features >/dev/null 2>&1; then
        log_message "ERROR" "JMX connection test failed"
        return 1
    fi

    log_message "INFO" "Successfully connected to JMX on port $JMX_PORT"
    return 0
}

protect_system() {
    local pid=$1
    [[ -z "$pid" ]] && return 1
    
    # Set nice level if possible
    renice 10 -p "$pid" >/dev/null 2>&1
    
    # Set I/O priority if ionice is available
    if command -v ionice >/dev/null 2>&1; then
        ionice -c 2 -n 7 -p "$pid" >/dev/null 2>&1
    fi
    
    # Set CPU limits if cpulimit is available
    if command -v cpulimit >/dev/null 2>&1; then
        cpulimit -p "$pid" -l 80 -b >/dev/null 2>&1 &
    fi

    # Configure OOM score if we have permission
    if [[ -w "/proc/$pid/oom_score_adj" ]]; then
        echo 300 > "/proc/$pid/oom_score_adj"
    fi

    # Only try to set resource limits if we have root privileges
    if command -v prlimit >/dev/null 2>&1 && [[ $EUID -eq 0 ]]; then
        prlimit --pid "$pid" --fsize=10737418240 2>/dev/null  # 10GB max file size
        prlimit --pid "$pid" --nofile=65535 2>/dev/null       # Max open files
    fi

    return 0
}

validate_metric() {
    local metric_name=$1
    local metric_value=$2
    local min_value=${3:-0}
    local max_value=${4:-100}
    
    # Remove any non-numeric characters except decimal point
    metric_value=$(echo "$metric_value" | tr -cd '0-9.\n')
    
    # Check if empty or invalid
    if [[ -z "$metric_value" ]] || ! echo "$metric_value" | grep -qE '^[0-9]+\.?[0-9]*$'; then
        echo "0.0"
        return 1
    fi
    
    # Use bc for floating point comparisons
    if (( $(echo "$metric_value < $min_value" | bc -l) )); then
        printf "%.2f" "$min_value"
        return 1
    fi
    
    if (( $(echo "$metric_value > $max_value" | bc -l) )); then
        printf "%.2f" "$max_value"
        return 1
    fi
    
    printf "%.2f" "$metric_value"
    return 0
}

initialize_metrics() {
    local metrics=("$@")
    for metric in "${metrics[@]}"; do
        eval "$metric=0.0"
    done
}

# ================== METRIC COLLECTION FUNCTIONS ==================
validate_and_format_number() {
    local value=$1
    local default=${2:-0.0}
    
    # Clean and validate numeric input
    value=$(echo "$value" | tr -cd '0-9.\n')
    
    if [[ ! "$value" =~ ^[0-9]+\.?[0-9]*$ ]]; then
        echo "$default"
        return 1
    fi
    
    printf "%.2f" "$value"
    return 0
}

collect_metric() {
    local command=$1
    local pattern=$2
    local default=${3:-0.0}
    
    local result
    if result=$(eval "$command" 2>/dev/null); then
        if [[ -n "$pattern" ]]; then
            result=$(echo "$result" | awk "$pattern")
        fi
        validate_and_format_number "$result" "$default"
    else
        echo "$default"
    fi
}

fetch_metrics() {
    local metric_name=$1
    local command=$2
    local pattern=$3
    local default=${4:-0.0}
    
    debug_log "Collecting metric: $metric_name"
    local value
    value=$(collect_metric "$command" "$pattern" "$default")
    eval "$metric_name=$value"
    debug_log "$metric_name = $value"
}

fetch_cpu_metrics() {
    fetch_metrics "CPU_USAGE" \
        "top -bn2 -d 0.5 | grep '^%Cpu' | tail -n1" \
        '{print 100-$8}'
    
    if [[ "$CPU_USAGE" == "0.0" ]]; then
        fetch_metrics "CPU_USAGE" \
            "vmstat 1 2 | tail -n1" \
            '{print 100-$15}'
    fi
}

fetch_disk_metrics() {
    local device=$1
    local dev_name=${device#/dev/}  # Remove /dev/ prefix if present
    
    debug_log "Fetching disk metrics for device: $dev_name"
    
    if command -v iostat >/dev/null 2>&1; then
        # Get raw iostat output with explicit column headers
        local raw_output
        raw_output=$(LANG=C iostat -xk "$dev_name" 1 2)
        debug_log "Raw iostat output: $raw_output"
        
        # Get the actual data line (last line containing device name)
        local data_line
        data_line=$(echo "$raw_output" | grep "$dev_name" | tail -n1)
        debug_log "Data line: $data_line"
        
        if [[ -n "$data_line" ]]; then
            # For standard iostat output, r/s is column 4 and w/s is column 5
            DISK_READ_IOPS=$(echo "$data_line" | awk '{printf "%.2f", $4}')
            DISK_WRITE_IOPS=$(echo "$data_line" | awk '{printf "%.2f", $5}')
            
            # Validate the values
            if [[ -n "$DISK_READ_IOPS" && -n "$DISK_WRITE_IOPS" ]]; then
                debug_log "Parsed IOPS directly - Read: $DISK_READ_IOPS, Write: $DISK_WRITE_IOPS"
                return 0
            fi
        fi
        
        debug_log "Failed to parse iostat output, falling back to /proc/diskstats"
    fi
    
    # Fallback to /proc/diskstats
    local stats_file="/proc/diskstats"
    if [[ -f "$stats_file" ]]; then
        debug_log "Using /proc/diskstats for metrics"
        local start_stats
        local end_stats
        
        start_stats=$(grep -w "$dev_name" "$stats_file")
        sleep 1
        end_stats=$(grep -w "$dev_name" "$stats_file")
        
        if [[ -n "$start_stats" && -n "$end_stats" ]]; then
            local start_reads=$(echo "$start_stats" | awk '{print $4}')
            local start_writes=$(echo "$start_stats" | awk '{print $8}')
            local end_reads=$(echo "$end_stats" | awk '{print $4}')
            local end_writes=$(echo "$end_stats" | awk '{print $8}')
            
            DISK_READ_IOPS=$(echo "scale=2; ($end_reads - $start_reads)" | bc)
            DISK_WRITE_IOPS=$(echo "scale=2; ($end_writes - $start_writes)" | bc)
            debug_log "Parsed diskstats IOPS - Read: $DISK_READ_IOPS, Write: $DISK_WRITE_IOPS"
            return 0
        fi
    fi
    
    log_message "WARNING" "Failed to collect disk metrics for device: $dev_name"
    DISK_READ_IOPS="0.0"
    DISK_WRITE_IOPS="0.0"
    return 1
}

fetch_network_metrics() {
    local interface=$1
    local stats_file="/proc/net/dev"
    
    # Method 1: Try sar command
    if command -v sar >/dev/null 2>&1; then
        local sar_out=$(sar -n DEV 1 1 | grep "$interface" | tail -n1)
        if [[ -n "$sar_out" ]]; then
            NET_RX=$(echo "$sar_out" | awk '{printf "%.2f", $5/1024}')
            NET_TX=$(echo "$sar_out" | awk '{printf "%.2f", $6/1024}')
            return 0
        fi
    fi
    
    # Method 2: Direct interface stats
    if [[ -f "$stats_file" ]]; then
        local start_stats=$(grep "$interface" "$stats_file")
        sleep 1
        local end_stats=$(grep "$interface" "$stats_file")
        
        if [[ -n "$start_stats" && -n "$end_stats" ]]; then
            local start_rx=$(echo "$start_stats" | awk '{print $2}')
            local start_tx=$(echo "$start_stats" | awk '{print $10}')
            local end_rx=$(echo "$end_stats" | awk '{print $2}')
            local end_tx=$(echo "$end_stats" | awk '{print $10}')
            
            NET_RX=$(echo "scale=2; ($end_rx - $start_rx)/1024" | bc)
            NET_TX=$(echo "scale=2; ($end_tx - $start_tx)/1024" | bc)
            return 0
        fi
    fi
    
    log_message "WARNING" "Failed to collect network metrics for $interface"
    NET_RX="0.0"
    NET_TX="0.0"
    return 1
}

fetch_jmx_metrics() {
    CACHE_HIT_RATIO="N/A"
    HEAP_MEMORY="N/A"
    GC_COUNT="N/A"
    ACTIVE_TX="N/A"
    ORIENT_DISK_CACHE="N/A"
    ORIENT_RECORD_CACHE="N/A"
    ORIENT_PAGES_PER_SEC="N/A"
    ORIENT_DIRTY_PAGES="N/A"
    ORIENT_READ_OPS="N/A"
    ORIENT_WRITE_OPS="N/A"
    ORIENT_RECORD_VERSIONS="N/A"
    ORIENT_LIVE_QUERIES="N/A"

    # Cache metrics collection function
    fetch_cache_metrics() {
        local pid=$1
        local cache_ratio="N/A"

        # Method 1: Try JMX DataCache metrics
        if [[ -n "$JMX_STATS" ]]; then
            cache_ratio=$(echo "$JMX_STATS" | awk '/DataCache HitRatio/ {getline; print $1}')
        fi

        # Method 2: Try JMX MemoryCache metrics if DataCache failed
        if [[ "$cache_ratio" == "N/A" && -n "$JMX_STATS" ]]; then
            cache_ratio=$(echo "$JMX_STATS" | awk '/MemoryCache Size/ {getline; print $1}')
        fi

        # Method 3: Calculate from process memory stats
        if [[ "$cache_ratio" == "N/A" ]]; then
            local total_mem=$(grep -i "vmsize" "/proc/$pid/status" 2>/dev/null | awk '{print $2}')
            local res_mem=$(grep -i "vmrss" "/proc/$pid/status" 2>/dev/null | awk '{print $2}')
            if [[ -n "$total_mem" && -n "$res_mem" && "$total_mem" != "0" ]]; then
                cache_ratio=$(echo "scale=2; ($total_mem - $res_mem) * 100 / $total_mem" | bc)
            fi
        fi

        # Method 4: Use JVM buffer pool stats
        if [[ "$cache_ratio" == "N/A" ]]; then
            local buffer_stats=$(jcmd "$pid" GC.class_histogram 2>/dev/null | grep -i "buffer" | awk '{sum+=$3} END {print sum}')
            local heap_stats=$(jstat -gc "$pid" 2>/dev/null | tail -n1 | awk '{print $3+$4}')
            if [[ -n "$buffer_stats" && -n "$heap_stats" && "$heap_stats" != "0" ]]; then
                cache_ratio=$(echo "scale=2; $buffer_stats * 100 / $heap_stats" | bc)
            fi
        fi

        echo "$cache_ratio"
    }

    # Find OrientDB process using new function
    local pid=$(find_orientdb_pid)
    if [[ -z "$pid" ]]; then
        log_message "ERROR" "OrientDB process not found. Check if:"
        log_message "ERROR" "1. OrientDB is running"
        log_message "ERROR" "2. ORIENTDB_HOME is set correctly (current: $ORIENTDB_HOME)"
        log_message "ERROR" "3. Process is running with current user permissions"
        return 1
    fi

    log_message "INFO" "Found OrientDB process with PID: $pid"

    # Check JMX connection before proceeding
    if ! check_jmx_connection "$pid"; then
        # Fallback to process-based metrics
        log_message "WARNING" "Using fallback metrics collection"
        
        # Get heap memory from process stats
        HEAP_MEMORY=$(ps -o rss= -p "$pid" | awk '{print $1*1024}')
        
        # Get GC info using jstat if available
        if command -v jstat >/dev/null 2>&1; then
            GC_COUNT=$(jstat -gc "$pid" 2>/dev/null | tail -n1 | awk '{print $13+$17}')
        fi
        
        # Get active transactions from thread count
        ACTIVE_TX=$(ps -o nlwp= -p "$pid" | awk '{print $1}')
        
        # Get cache info from /proc
        if [[ -d "/proc/$pid" ]]; then
            local cache_size=$(grep -i "cache" "/proc/$pid/status" 2>/dev/null | awk '{print $2}')
            [[ -n "$cache_size" ]] && CACHE_HIT_RATIO="$cache_size"
        fi
        
        return 0
    fi

    # Create JMX queries file
    local tmp_queries="/tmp/jmx_queries.txt"
    cat > "$tmp_queries" << EOF
open $JMX_HOST:$JMX_PORT
get com.orientechnologies.orient.core.storage.impl.local:type=DataCache HitRatio
get com.orientechnologies.orient.core.storage.impl.local:type=RecordCache Size
get com.orientechnologies.orient.server:type=StorageMetrics PagesPerSecond
get com.orientechnologies.orient.server:type=StorageMetrics DirtyPages
get com.orientechnologies.orient.server:type=StorageMetrics ReadOperationsPerSecond
get com.orientechnologies.orient.server:type=StorageMetrics WriteOperationsPerSecond
get com.orientechnologies.orient.server:type=RecordMetrics VersionsPerRecord
get com.orientechnologies.orient.server:type=QueryManager LiveQueries
get java.lang:type=Memory HeapMemoryUsage
get java.lang:type=GarbageCollector,name=* CollectionCount
quit
EOF

    local JMX_STATS
    if JMX_STATS=$(jmxterm -v silent -i "$tmp_queries" 2>/dev/null); then
        # Parse OrientDB specific metrics
        ORIENT_DISK_CACHE=$(echo "$JMX_STATS" | grep -A1 "HitRatio" | tail -n1)
        ORIENT_RECORD_CACHE=$(echo "$JMX_STATS" | grep -A1 "Size" | tail -n1)
        ORIENT_PAGES_PER_SEC=$(echo "$JMX_STATS" | grep -A1 "PagesPerSecond" | tail -n1)
        ORIENT_DIRTY_PAGES=$(echo "$JMX_STATS" | grep -A1 "DirtyPages" | tail -n1)
        ORIENT_READ_OPS=$(echo "$JMX_STATS" | grep -A1 "ReadOperationsPerSecond" | tail -n1)
        ORIENT_WRITE_OPS=$(echo "$JMX_STATS" | grep -A1 "WriteOperationsPerSecond" | tail -n1)
        ORIENT_RECORD_VERSIONS=$(echo "$JMX_STATS" | grep -A1 "VersionsPerRecord" | tail -n1)
        ORIENT_LIVE_QUERIES=$(echo "$JMX_STATS" | grep -A1 "LiveQueries" | tail -n1)

        # Parse standard JMX metrics
        HEAP_MEMORY=$(echo "$JMX_STATS" | grep -A1 "HeapMemoryUsage" | tail -n1 | awk '{print $2}' | cut -d';' -f3)
        
        # Parse GC metrics with improved collection
        local gc_total=0
        while read -r line; do
            if [[ "$line" =~ CollectionCount[[:space:]]*=[[:space:]]*([0-9]+) ]]; then
                gc_total=$((gc_total + ${BASH_REMATCH[1]}))
            fi
        done < <(jstat -gc "$(find_orientdb_pid)" 2>/dev/null)
        
        # If jstat failed, try alternative GC collection methods
        if [[ $gc_total -eq 0 ]]; then
            # Try jcmd GC.stat
            gc_total=$(jcmd "$(find_orientdb_pid)" GC.stat 2>/dev/null | grep -i "gc.count" | awk '{sum+=$3} END {print sum}')
            
            # If jcmd failed, try parsing from JMX output
            if [[ -z "$gc_total" ]]; then
                gc_total=$(echo "$JMX_STATS" | grep -A1 "CollectionCount" | tail -n1 | awk '{sum+=$1} END {print sum}')
            fi
        fi
        
        GC_COUNT=${gc_total:-"N/A"}
    fi
    rm -f "$tmp_queries"

    # Fetch cache metrics
    CACHE_HIT_RATIO=$(fetch_cache_metrics "$pid")
    log_message "INFO" "Cache hit ratio: $CACHE_HIT_RATIO"
}

fetch_iotop_metrics() {
    IO_READ="0.0"
    IO_WRITE="0.0"
    
    local pid=$(find_orientdb_pid)
    if [[ -z "$pid" ]]; then
        log_message "WARNING" "OrientDB process not found for iotop metrics"
        return 1
    fi
    
    if command -v iotop >/dev/null 2>&1; then
        # Try running iotop with sudo if available
        local iotop_cmd="iotop"
        if [[ $EUID -ne 0 ]] && command -v sudo >/dev/null 2>&1; then
            iotop_cmd="sudo iotop"
        fi
        
        local iotop_output
        iotop_output=$($iotop_cmd -b -n 1 -p "$pid" 2>/dev/null)
        if [[ -n "$iotop_output" ]]; then
            IO_READ=$(echo "$iotop_output" | awk '/Total DISK READ/ {gsub("K|M|B/s","",$4); print $4}')
            IO_WRITE=$(echo "$iotop_output" | awk '/Total DISK WRITE/ {gsub("K|M|B/s","",$4); print $4}')
            
            # Convert to consistent units (KB/s)
            [[ "$iotop_output" =~ "M/s" ]] && IO_READ=$(echo "$IO_READ * 1024" | bc)
            [[ "$iotop_output" =~ "M/s" ]] && IO_WRITE=$(echo "$IO_WRITE * 1024" | bc)
        fi
    else
        log_message "WARNING" "iotop not available"
        return 1
    fi
}

fetch_dstat_metrics() {
    DSTAT_CPU="N/A"
    DSTAT_MEM="N/A"
    DSTAT_DISK="N/A"
    DSTAT_NET="N/A"
    DSTAT_LOAD="N/A"

    if ! command -v dstat >/dev/null 2>&1; then
        log_message "WARNING" "dstat not available"
        return 1
    fi

    # Run dstat for a single update with CPU, memory, disk, net, and load metrics
    local dstat_output
    dstat_output=$(dstat -c -m -d -n -l 1 1 --nocolor 2>/dev/null | tail -n 1)
    
    if [[ -n "$dstat_output" ]]; then
        # Parse dstat output (format varies by version, adjust awk if needed)
        DSTAT_CPU=$(echo "$dstat_output" | awk '{print $1+$2+$3}')
        DSTAT_MEM=$(echo "$dstat_output" | awk '{print $5}')
        DSTAT_DISK=$(echo "$dstat_output" | awk '{print $8"/"$9}')
        DSTAT_NET=$(echo "$dstat_output" | awk '{print $10"/"$11}')
        DSTAT_LOAD=$(echo "$dstat_output" | awk '{print $NF}')
    fi
}

fetch_file_descriptors() {
    FD_COUNT="N/A"
    if command -v lsof >/dev/null 2>&1; then
        local pid=$(find_orientdb_pid)
        if [[ -n "$pid" ]]; then
            FD_COUNT=$(lsof -p "$pid" | wc -l)
        fi
    fi
}

fetch_advanced_metrics() {
    # Calculate suggested vCPUs based on load average
    local load_avg=$(awk '{print $1}' /proc/loadavg)
    SUGGESTED_VCPUS=$(echo "scale=0; ($load_avg + 1.5)/1" | bc)

    # Calculate network throughput recommendation (in Mbps)
    local rx_bytes=$(cat /sys/class/net/$NETWORK_INTERFACE/statistics/rx_bytes)
    local tx_bytes=$(cat /sys/class/net/$NETWORK_INTERFACE/statistics/tx_bytes)
    NETWORK_THROUGHPUT=$(echo "scale=2; ($rx_bytes + $tx_bytes) * 8 / 1000000" | bc)
}

# ================== DISPLAY FUNCTIONS ==================
format_metric_line() {
    local label=$1
    local value=$2
    local format=${3:-"%s"}
    printf "%-25s: $format\n" "$label" "$value"
}

display_metrics() {
    local timestamp=$1
    printf "\n${GREEN}====== OrientDB Metrics at ${timestamp} ======${NC}\n"
    
    format_metric_line "CPU Usage" "${CPU_USAGE}%"
    format_metric_line "Disk I/O" "$DISK_READ_IOPS read/s, $DISK_WRITE_IOPS write/s"
    format_metric_line "Network Traffic" "RX ${NET_RX} KB/s, TX ${NET_TX} KB/s"
    
    printf "\n${YELLOW}=== IOPS Summary ===${NC}\n"
    local total_read_iops=$(echo "${DISK_READ_IOPS:-0}" | bc)
    local total_write_iops=$(echo "${DISK_WRITE_IOPS:-0}" | bc)
    local total_iops=$(echo "$total_read_iops + $total_write_iops" | bc)

    printf "%-25s: %.2f read/s, %.2f write/s (total: %.2f)\n" "iostat IOPS" \
        "$total_read_iops" "$total_write_iops" "$total_iops"

    local io_read=$(echo "${IO_READ/B*/}" | sed 's/[^0-9.]//g')
    local io_write=$(echo "${IO_WRITE/B*/}" | sed 's/[^0-9.]//g')
    local io_total=$(echo "${io_read:-0} + ${io_write:-0}" | bc)
    
    printf "%-25s: %.2f read/s, %.2f write/s (total: %.2f)\n" "iotop IOPS" \
        "${io_read:-0}" "${io_write:-0}" "$io_total"
    
    printf "\n${GREEN}=== Database Metrics ===${NC}\n"
    printf "%-25s: %s\n" "Cache Hit Ratio" "$CACHE_HIT_RATIO"
    printf "%-25s: %s\n" "Heap Memory Usage" "$HEAP_MEMORY"
    printf "%-25s: %s\n" "GC Count" "$GC_COUNT"
    printf "%-25s: %s\n" "Active Transactions" "$ACTIVE_TX"
    printf "%-25s: %s\n" "I/O Read" "$IO_READ"
    printf "%-25s: %s\n" "I/O Write" "$IO_WRITE"
    printf "%-25s: %s%%\n" "Dstat CPU Usage" "$DSTAT_CPU"
    printf "%-25s: %s\n" "Dstat Memory Used" "$DSTAT_MEM"
    printf "%-25s: %s\n" "Dstat Disk Activity" "$DSTAT_DISK"
    printf "%-25s: %s\n" "Dstat Network" "$DSTAT_NET"
    printf "%-25s: %s\n" "Dstat System Load" "$DSTAT_LOAD"
    printf "\n${YELLOW}=== System Sizing Recommendations ===${NC}\n"
    printf "%-25s: %s\n" "Open File Descriptors" "$FD_COUNT"
    printf "%-25s: %s\n" "Suggested vCPUs" "$SUGGESTED_VCPUS"
    printf "%-25s: %s Mbps\n" "Network Throughput" "$NETWORK_THROUGHPUT"
    printf "\n${YELLOW}=== OrientDB Storage Metrics ===${NC}\n"
    printf "%-25s: %s\n" "Disk Cache Hit Ratio" "$ORIENT_DISK_CACHE"
    printf "%-25s: %s\n" "Record Cache Size" "$ORIENT_RECORD_CACHE"
    printf "%-25s: %s\n" "Pages/Second" "$ORIENT_PAGES_PER_SEC"
    printf "%-25s: %s\n" "Dirty Pages" "$ORIENT_DIRTY_PAGES"
    printf "%-25s: %s\n" "Read Ops/Second" "$ORIENT_READ_OPS"
    printf "%-25s: %s\n" "Write Ops/Second" "$ORIENT_WRITE_OPS"
    printf "%-25s: %s\n" "Record Versions" "$ORIENT_RECORD_VERSIONS"
    printf "%-25s: %s\n" "Live Queries" "$ORIENT_LIVE_QUERIES"
    printf "${GREEN}========================================${NC}\n"
}

# ================== INITIALIZATION ==================
# Initialize counters and variables
total_iterations=0
DETECTED_NIC=""
DETECTED_DISK=""
SUGGESTED_INTERVAL=60
SUGGESTED_THREADS=1
DISK_TYPE=""
IO_SCHEDULER=""

# Set default values
DISK_DEVICE=""
NETWORK_INTERFACE=""
INTERVAL=60
DURATION_HOURS=6
OUTPUT_DIR="$HOME/orientdb_metrics"
JMX_HOST="localhost"
JMX_PORT="1099"
ORIENTDB_HOME="${ORIENTDB_HOME:-/opt/orientdb}"

# Create required directories
mkdir -p "$OUTPUT_DIR"

# Initialize log files
LOG_FILE="$OUTPUT_DIR/monitor.log"
OUTPUT_FILE="$OUTPUT_DIR/metrics.csv"

# Parse command line arguments
while getopts "d:n:i:t:o:h" opt; do
    case $opt in
        d) DISK_DEVICE="$OPTARG" ;;
        n) NETWORK_INTERFACE="$OPTARG" ;;
        i) INTERVAL="$OPTARG" ;;
        t) DURATION_HOURS="$OPTARG" ;;
        o) OUTPUT_DIR="$OPTARG" ;;
        h) usage ;;
        \?) usage ;;
    esac
done

# Run system detection
detect_system_config

# Set final values and calculate end time
DISK_DEVICE="${DISK_DEVICE:-$DETECTED_DISK}"
NETWORK_INTERFACE="${NETWORK_INTERFACE:-$DETECTED_NIC}"
INTERVAL="${INTERVAL:-$SUGGESTED_INTERVAL}"
END_TIME=$(( $(date +%s) + DURATION_HOURS * 3600 ))

# Validate configuration
validate_config

# Set up signal handlers
trap cleanup SIGINT SIGTERM

# Initialize metrics
initialize_metrics \
    CPU_USAGE DISK_READ_IOPS DISK_WRITE_IOPS \
    NET_RX NET_TX IO_READ IO_WRITE \
    CACHE_HIT_RATIO HEAP_MEMORY GC_COUNT

# Start monitoring loop
while [ "$(date +%s)" -lt "$END_TIME" ]; do
    # Add system protection checks
    if ! check_system_resources "$(find_orientdb_pid)"; then
        log_message "ERROR" "System protection check failed"
        cleanup
        exit 1
    fi

    # Protect system resources
    protect_system "$(find_orientdb_pid)"

    # Cleanup old files periodically (every hour)
    if [ $((total_iterations % 60)) -eq 0 ]; then    # Fixed syntax
        cleanup_old_files
    fi

    # Check disk space
    check_disk_space
    
    # Get timestamp
    TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
    
    # Collect all metrics
    fetch_cpu_metrics
    fetch_disk_metrics "$DISK_DEVICE"
    fetch_network_metrics "$NETWORK_INTERFACE"
    fetch_jmx_metrics
    fetch_iotop_metrics
    fetch_dstat_metrics
    fetch_file_descriptors
    fetch_advanced_metrics

    # Validate all collected metrics
    for metric in CPU_USAGE DISK_READ_IOPS DISK_WRITE_IOPS NET_RX NET_TX IO_READ IO_WRITE; do
        eval "$metric=\$(validate_metric \"$metric\" \"\$$metric\")"
    done

    # Display current metrics
    display_metrics "$TIMESTAMP"
    
    # Write to CSV file
    echo "$TIMESTAMP,$CPU_USAGE,$DISK_READ_IOPS,$DISK_WRITE_IOPS,$NET_RX,$NET_TX,$CACHE_HIT_RATIO,$HEAP_MEMORY,$GC_COUNT,$ACTIVE_TX,$IO_READ,$IO_WRITE,$DSTAT_CPU,$DSTAT_MEM,$DSTAT_DISK,$DSTAT_NET,$DSTAT_LOAD,$FD_COUNT,$SUGGESTED_VCPUS,$NETWORK_THROUGHPUT,$ORIENT_DISK_CACHE,$ORIENT_RECORD_CACHE,$ORIENT_PAGES_PER_SEC,$ORIENT_DIRTY_PAGES,$ORIENT_READ_OPS,$ORIENT_WRITE_OPS,$ORIENT_RECORD_VERSIONS,$ORIENT_LIVE_QUERIES" >> "$OUTPUT_FILE" || {
        log_message "ERROR" "Failed to write to output file"
        cleanup
    }

    # Update counters and sleep
    total_iterations=$((total_iterations + 1))
    debug_log "Completed monitoring iteration $total_iterations"
    sleep "$INTERVAL"
done

cleanup
