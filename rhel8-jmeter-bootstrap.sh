#!/bin/bash

# Enable strict error handling
set -euo pipefail
trap 'error "An error occurred on line $LINENO. Exit code: $?"' ERR

export DB_HOST="${DB_HOST}"
export DB_PORT="${DB_PORT}"
export DB_PASSWORD="${DB_PASSWORD}"
export VMSS_NAME="${VMSS_NAME}"
export ENVIRONMENT="${ENVIRONMENT}"
export TEST_TARGET_HOST="${TEST_TARGET_HOST}"
export CONTROLLER_IPS="${CONTROLLER_IPS}"
export JMETER_RMI_PORT="${JMETER_RMI_PORT}"
export JMETER_SERVER_PORT="${JMETER_SERVER_PORT}"

# Verify required variables
[[ -z "${DB_HOST}" ]] && { echo "DB_HOST is required"; exit 1; }
[[ -z "${DB_PASSWORD}" ]] && { echo "DB_PASSWORD is required"; exit 1; }
[[ -z "${VMSS_NAME}" ]] && { echo "VMSS_NAME is required"; exit 1; }
[[ -z "${ENVIRONMENT}" ]] && { echo "ENVIRONMENT is required"; exit 1; }

# Set defaults for optional variables
DB_PORT="${DB_PORT:-5432}"
DB_SSL_MODE="${DB_SSL_MODE:-require}"
TEST_TARGET_HOST="${TEST_TARGET_HOST:-localhost}"
CONTROLLER_IPS="${CONTROLLER_IPS:-*}"  # Default to all IPs if not specified
JMETER_RMI_PORT="${JMETER_RMI_PORT:-1099}"
JMETER_SERVER_PORT="${JMETER_SERVER_PORT:-4445}"

# Constants and configurations
readonly JMETER_VERSION="5.6.3"
readonly MIN_MEMORY_MB=4096
readonly MIN_DISK_SPACE_KB=10485760
readonly STATE_FILE="/opt/jmeter/bootstrap.state"
readonly LOCK_FILE="/opt/jmeter/bootstrap.lock"
readonly INSTALL_DIR="/opt/jmeter"
readonly LOG_DIR="/var/log/jmeter"

# Plugin definitions
declare -A PLUGINS=(
    ["jpgc-functions"]="2.1"
    ["jpgc-casutg"]="2.10"
    ["jpgc-perfmon"]="2.1"
)

# State management functions
save_state() { echo "$1" > "$STATE_FILE"; }
get_state() { [ -f "$STATE_FILE" ] && cat "$STATE_FILE" || echo "NOT_STARTED"; }
acquire_lock() {
    if [ -f "$LOCK_FILE" ]; then
        pid=$(cat "$LOCK_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            log "Another instance is running with PID $pid"
            exit 1
        fi
    fi
    echo $$ > "$LOCK_FILE"
}
release_lock() { rm -f "$LOCK_FILE"; }

# Logging functions
log() { 
    local message="$*"
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] INFO: $message"
    db_log "bootstrap" "INFO" "$message"
}
error() {
    local message="$*"
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $message" >&2
    db_log "bootstrap" "ERROR" "$message"
    exit 1
}
warn() {
    local message="$*"
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] WARN: $message" >&2
    db_log "bootstrap" "WARN" "$message"
}
db_log() {
    # Use managed identity or service principal for authentication
    PGPASSWORD="${DB_PASSWORD}" PGSSLMODE=verify-full psql \
        -h "$DB_HOST" \
        -U telegraf@"${DB_HOST}" \
        -d metrics \
        -c "INSERT INTO metrics.system_logs (hostname, source, log_level, message) 
            VALUES ('$(hostname)', '$1', '$2', '$3');"
}

# Installation step function
install_step() {
    local step=$1
    local current_state=$(get_state)
    if [[ "$current_state" < "$step" ]]; then
        log "Executing step: $step"
        shift
        "$@"
        save_state "$step"
    else
        log "Skipping completed step: $step"
    fi
}

# Installation functions
setup_basic_requirements() {
    log "Setting up basic requirements..."
    systemctl stop firewalld
    systemctl disable firewalld

    dnf update -y
    dnf install -y epel-release
    dnf install -y wget curl unzip tar sysstat htop iotop bc

    # Install PostgreSQL client
    dnf install -y postgresql postgresql-devel

    # Install Azure CLI
    rpm --import https://packages.microsoft.com/keys/microsoft.asc
    dnf install -y https://packages.microsoft.com/config/rhel/8/packages-microsoft-prod.rpm
    dnf install -y azure-cli
}

setup_java() {
    log "Installing Java..."
    dnf install -y java-11-openjdk-devel
    java -version || error "Java installation failed"
    
    # Set JAVA_HOME
    echo "export JAVA_HOME=/usr/lib/jvm/java-11" >> /etc/profile.d/java.sh
    source /etc/profile.d/java.sh
}

setup_jmeter() {
    log "Installing JMeter..."
    # Add wget options for SSL handling
    local WGET_OPTS="--no-check-certificate --tries=3 --timeout=60"
    
    wget $WGET_OPTS "https://dlcdn.apache.org/jmeter/binaries/apache-jmeter-${JMETER_VERSION}.tgz"
    if [[ $? -ne 0 ]]; then
        error "Failed to download JMeter"
    fi

    tar -xzf "apache-jmeter-${JMETER_VERSION}.tgz" -C /opt/
    ln -s "/opt/apache-jmeter-${JMETER_VERSION}" "${INSTALL_DIR}"
    rm "apache-jmeter-${JMETER_VERSION}.tgz"

    # Install plugins
    wget -O "${INSTALL_DIR}/lib/ext/plugins-manager.jar" https://jmeter-plugins.org/get/
    java -cp "${INSTALL_DIR}/lib/ext/plugins-manager.jar" org.jmeterplugins.repository.PluginManagerCMDInstaller
    
    # Improve plugin installation error handling
    for plugin in "${!PLUGINS[@]}"; do
        log "Installing plugin: ${plugin}=${PLUGINS[$plugin]}"
        if ! "${INSTALL_DIR}/bin/PluginsManagerCMD.sh" install "${plugin}=${PLUGINS[$plugin]}"; then
            if [[ "$plugin" == "jpgc-functions" ]]; then
                error "Critical plugin installation failed: $plugin"
            else
                warn "Non-critical plugin installation failed: $plugin"
            fi
        fi
    done

    # Setup environment
    cat > /etc/profile.d/jmeter.sh << 'EOL'
export JMETER_HOME=/opt/jmeter
export PATH=$PATH:$JMETER_HOME/bin
EOL
    source /etc/profile.d/jmeter.sh
}

configure_system() {
    log "Configuring system..."
    
    # Configure Telegraf
    cat > /etc/yum.repos.d/influxdb.repo << 'EOL'
[influxdb]
name = InfluxDB Repository
baseurl = https://repos.influxdata.com/rhel/$releasever/$basearch/stable
enabled = 1
gpgcheck = 1
gpgkey = https://repos.influxdata.com/influxdb.key
EOL

    dnf install -y telegraf

    # Configure PostgreSQL outputs for Telegraf
    cat > /etc/telegraf/telegraf.conf << EOL
[global_tags]
  host = "${HOSTNAME}"
  vmss = "${VMSS_NAME}"
  environment = "${ENVIRONMENT}"

[agent]
  interval = "10s"
  round_interval = true
  metric_batch_size = 1000
  metric_buffer_limit = 10000
  collection_jitter = "0s"
  flush_interval = "10s"
  flush_jitter = "0s"
  precision = ""
  hostname = ""
  omit_hostname = false

[[outputs.postgresql]]
  connection = "host=${DB_HOST} user=telegraf@${DB_HOST} password=${DB_PASSWORD} dbname=metrics sslmode=verify-full"
  schema = "metrics"
  table = "system_metrics"
  table_template = "CREATE TABLE IF NOT EXISTS {{ .table }} (time timestamp with time zone,hostname text,measurement text,value float8,tags jsonb)"
  tag_template = "CREATE INDEX IF NOT EXISTS idx_{{ .table }}_tags ON {{ .table }} USING GIN(tags)"
  time_template = "CREATE INDEX IF NOT EXISTS idx_{{ .table }}_time ON {{ .table }} (time DESC)"

[[inputs.cpu]]
[[inputs.disk]]
[[inputs.diskio]]
[[inputs.mem]]
[[inputs.net]]
[[inputs.system]]
[[inputs.processes]]
[[inputs.jmeter]]
  interval = "10s"
  jmeter_mode = "server"
  port = 4445
[[inputs.swap]]
EOL

    # System optimizations
    cat > /etc/sysctl.conf << 'EOL'
# Network optimizations
net.core.wmem_max = 16777216
net.core.rmem_max = 16777216
net.ipv4.tcp_wmem = 4096 87380 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 1024 65000
net.ipv4.tcp_max_tw_buckets = 1440000
net.ipv4.tcp_max_syn_backlog = 3240000
net.ipv4.tcp_max_orphans = 300000
net.ipv4.tcp_syncookies = 1
net.core.somaxconn = 16384
net.core.netdev_max_backlog = 2500

# Memory optimizations
vm.swappiness = 10
vm.dirty_ratio = 60
vm.dirty_background_ratio = 2
vm.max_map_count = 262144

# File system optimizations
fs.file-max = 2097152
fs.nr_open = 2097152
EOL
    sysctl -p

    # Process limits
    cat > /etc/security/limits.d/jmeter.conf << 'EOL'
*       soft    nofile          1048576
*       hard    nofile          1048576
*       soft    nproc           unlimited
*       hard    nproc           unlimited
*       soft    memlock         unlimited
*       hard    memlock         unlimited
EOL

    # Disable swap
    swapoff -a
    sed -i '/ swap / s/^/#/' /etc/fstab

    # Add JMeter server configuration
    cat > "${INSTALL_DIR}/bin/jmeter.properties" << EOL
server.rmi.ssl.disable=true
server.rmi.localport=${JMETER_RMI_PORT}
server.rmi.create_server=true
server_port=${JMETER_SERVER_PORT}
server.rmi.remote_servers=${CONTROLLER_IPS}
EOL

    # Configure firewall rules for JMeter ports if firewall is enabled
    if systemctl is-active --quiet firewalld; then
        firewall-cmd --permanent --add-port=${JMETER_RMI_PORT}/tcp
        firewall-cmd --permanent --add-port=${JMETER_SERVER_PORT}/tcp
        firewall-cmd --reload
    fi
}

setup_services() {
    log "Setting up services..."
    
    # Calculate JVM memory (70% of total RAM) with error handling
    TOTAL_RAM=$(free -m | grep Mem | awk '{print $2}') || error "Failed to get total RAM"
    JVM_MEMORY=$(echo "scale=0; ${TOTAL_RAM} * 0.7 / 1" | bc) || error "Failed to calculate JVM memory"
    [[ -z "$JVM_MEMORY" ]] && error "Invalid JVM memory calculation"

    # Create JMeter service
    cat > /etc/systemd/system/jmeter.service << EOL
[Unit]
Description=Apache JMeter Runner Service
After=network.target

[Service]
Type=simple
Environment="HEAP=-Xms${JVM_MEMORY}m -Xmx${JVM_MEMORY}m"
Environment="JMETER_HOME=${INSTALL_DIR}"
Environment="JVM_ARGS=-XX:+UseG1GC -XX:MaxGCPauseMillis=100 -XX:G1ReservePercent=20 -Djava.security.egd=file:/dev/./urandom -XX:+HeapDumpOnOutOfMemoryError -XX:HeapDumpPath=${LOG_DIR} -Dserver.rmi.ssl.disable=true -Dserver_port=${JMETER_SERVER_PORT} -Dserver.rmi.localport=${JMETER_RMI_PORT}"
ExecStart=${INSTALL_DIR}/bin/jmeter-server -Djava.rmi.server.hostname=$(hostname -I | awk '{print $1}')
User=root
LimitNOFILE=1048576
LimitNPROC=unlimited
LimitMEMLOCK=unlimited
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOL

    systemctl daemon-reload
    systemctl enable jmeter
    systemctl start jmeter
    systemctl enable telegraf
    systemctl start telegraf
}

health_check() {
    log "Performing runner health check..."
    jmeter -v >/dev/null 2>&1 || error "JMeter not responding"
    java -version >/dev/null 2>&1 || error "Java not responding"
    nc -z localhost ${JMETER_SERVER_PORT} || error "JMeter server port not listening"
    nc -z localhost ${JMETER_RMI_PORT} || error "JMeter RMI port not listening"
    telegraf -test >/dev/null 2>&1 || warn "Telegraf test failed"
}

setup_autorecovery() {
    log "Setting up auto-recovery..."
    cat > /etc/cron.d/jmeter-recovery << 'EOL'
@reboot root /bin/bash -c 'test "$(systemctl is-active jmeter)" != "active" && /c:/repos/myscripts/rhel8-jmeter-bootstrap.sh'
*/5 * * * * root /bin/bash -c 'test "$(systemctl is-active jmeter)" != "active" && /c:/repos/myscripts/rhel8-jmeter-bootstrap.sh'
EOL
}

# Add new function for database schema creation
setup_database_schema() {
    log "Creating database schema..."
    # Use managed identity or service principal
    PGPASSWORD="${DB_PASSWORD}" PGSSLMODE=verify-full \
    psql -h "${DB_HOST}" -U telegraf@"${DB_HOST}" -d metrics -f /c:/repos/myscripts/jmeter-prerequisites-azure.sql
}

# Add network connectivity test function
test_connectivity() {
    log "Testing network connectivity..."
    declare -a targets
    targets=(
        "${DB_HOST}:${DB_PORT}"
        "${TEST_TARGET_HOST}:443"
        "jmeter-plugins.org:443"
        "downloads.apache.org:443"
        "packages.microsoft.com:443"
    )

    for target in "${targets[@]}"; do
        local host port
        host=$(echo "$target" | cut -d: -f1)
        port=$(echo "$target" | cut -d: -f2)
        if ! timeout 5 nc -zv "$host" "$port" 2>&1; then
            warn "Connectivity test failed for $target"
        fi
    done
}

# Add enhanced monitoring function
setup_enhanced_monitoring() {
    log "Setting up enhanced monitoring..."
    
    # Add JMeter plugin monitoring
    cat >> /etc/telegraf/telegraf.conf << EOL

[[inputs.exec]]
  commands = ["${INSTALL_DIR}/bin/JMeterPluginsCMD.sh --generate-png /dev/null --plugin-type ThreadsStateOverTime --width 800 --height 600 --stats-only"]
  interval = "30s"
  timeout = "5s"
  data_format = "csv"
  csv_header_row_count = 1
  name_override = "jmeter_threads"

[[inputs.exec]]
  commands = ["/usr/bin/ss -tun | wc -l"]
  interval = "10s"
  timeout = "5s"
  data_format = "value"
  data_type = "integer"
  name_override = "tcp_connections"

[[inputs.net_response]]
  protocol = "tcp"
  address = "${TEST_TARGET_HOST}:443"
  interval = "10s"

[[inputs.ping]]
  urls = ["${TEST_TARGET_HOST}"]
  count = 4
  ping_interval = 1.0
  timeout = 2.0
EOL

    # Add enhanced logging for JMeter
    cat > "${INSTALL_DIR}/bin/user.properties" << EOL
jmeter.save.saveservice.output_format=csv
jmeter.save.saveservice.assertion_results=all
jmeter.save.saveservice.bytes=true
jmeter.save.saveservice.sent_bytes=true
jmeter.save.saveservice.hostname=true
jmeter.save.saveservice.thread_counts=true
jmeter.save.saveservice.sample_count=true
jmeter.save.saveservice.idle_time=true
EOL
}

# Add command dependency checks right after variables section
check_dependencies() {
    local deps=(nc wget curl java psql systemctl)
    for cmd in "${deps[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            case "$cmd" in
                nc) dnf install -y nmap-ncat ;;
                psql) dnf install -y postgresql ;;
                *) error "Required command not found: $cmd" ;;
            esac
        fi
    done
}

verify_system_requirements() {
    log "Verifying system requirements..."
    
    # Check memory
    local total_mem=$(free -m | awk '/^Mem:/{print $2}')
    if [[ $total_mem -lt $MIN_MEMORY_MB ]]; then
        error "Insufficient memory: ${total_mem}MB < ${MIN_MEMORY_MB}MB required"
    fi

    # Check disk space
    local disk_space=$(df -k /opt | awk 'NR==2 {print $4}')
    if [[ $disk_space -lt $MIN_DISK_SPACE_KB ]]; then
        error "Insufficient disk space: ${disk_space}KB < ${MIN_DISK_SPACE_KB}KB required"
    fi

    # Validate hostname
    if ! hostname | grep -qE '^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$'; then
        error "Invalid hostname format. Must be RFC 1123 compliant"
    fi
}

main() {
    # Create log directory first
    mkdir -p "${LOG_DIR}" || error "Failed to create log directory: ${LOG_DIR}"
    
    # Setup logging after ensuring directory exists
    exec 1> >(tee -a "${LOG_DIR}/bootstrap.log")
    exec 2> >(tee -a "${LOG_DIR}/bootstrap.log" >&2)

    # Create other required directories
    mkdir -p "${INSTALL_DIR}" || error "Failed to create install directory: ${INSTALL_DIR}"

    # Acquire lock
    acquire_lock
    trap 'release_lock; exit' INT TERM EXIT

    # Add dependency and system requirement checks
    check_dependencies
    verify_system_requirements

    if [[ "$(get_state)" != "COMPLETED" ]]; then
        test_connectivity
        install_step "01_INIT" setup_basic_requirements
        install_step "02_JAVA" setup_java
        install_step "03_JMETER" setup_jmeter
        install_step "04_CONFIG" configure_system
        install_step "05_DB" setup_database_schema
        install_step "06_MONITOR" setup_enhanced_monitoring
        install_step "07_SERVICES" setup_services
        setup_autorecovery
        save_state "COMPLETED"
    else
        log "Bootstrap already completed. Running health check..."
        health_check
    fi
}

# Start installation
main
