#!/bin/bash

# Check if the script received an argument
if [ -z "$1" ]; then
    echo "Usage: $0 \"10.0.0.1,10.0.0.2,10.0.0.3\""
    exit 1
fi

# Convert the comma-separated list into an array
IFS=',' read -r -a worker_ips <<< "$1"

# Path to Prometheus config file (modify if needed)
PROMETHEUS_CONFIG="/etc/prometheus/prometheus.yml"

# Backup existing Prometheus config
cp "$PROMETHEUS_CONFIG" "$PROMETHEUS_CONFIG.bak"

# Start writing the new YAML configuration
CONFIG="\n  # 📌 Monitor JMeter Workers (Runners)\n  - job_name: 'jmeter-workers'\n    static_configs:\n      - targets:\n"
for ip in "${worker_ips[@]}"; do
    CONFIG+="          - '${ip}:9270'\n"
done

CONFIG+="\n  # 📌 Monitor System Metrics on Workers (Node Exporter on Each Worker)\n  - job_name: 'worker-node-metrics'\n    static_configs:\n      - targets:\n"
for ip in "${worker_ips[@]}"; do
    CONFIG+="          - '${ip}:9100'\n"
done

# Append the generated configuration to Prometheus config file
echo -e "$CONFIG" >> "$PROMETHEUS_CONFIG"

# Restart Prometheus to apply changes
systemctl restart prometheus

echo "✅ Prometheus config updated and restarted successfully!"
