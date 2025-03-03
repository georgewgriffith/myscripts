#!/bin/bash

if [ -z "$1" ]; then
    echo "Usage: $0 \"10.0.0.1,10.0.0.2,10.0.0.3\""
    exit 1
fi

# Convert the comma-separated list into an array
IFS=',' read -r -a worker_ips <<< "$1"

# Function to get hostname from IP
get_hostname() {
    local ip=$1
    local hostname=$(nslookup "$ip" 2>/dev/null | awk '/name = / {print $4}' | sed 's/\.$//')
    if [ -z "$hostname" ]; then
        echo "${ip//./_}"  # replace dots with underscores in IP
    else
        echo "$hostname"
    fi
}

# Start the datasources configuration
cat << EOF > grafana-datasources.yml
apiVersion: 1

datasources:
EOF

# Generate a datasource for each worker
for i in "${!worker_ips[@]}"; do
    hostname=$(get_hostname "${worker_ips[i]}")
    cat << EOF >> grafana-datasources.yml
  - name: "${hostname}"
    type: prometheus
    access: proxy
    url: "http://${worker_ips[i]}:9090"
    isDefault: ${(i == 0) && "true" || "false"}
    editable: true
    jsonData:
      timeInterval: "5s"
      queryTimeout: "30s"
      httpMethod: "POST"
      manageAlerts: true
      prometheusType: "Prometheus"
      prometheusVersion: "2.50.1"
      cacheLevel: "Strong"
      tlsSkipVerify: true
      exemplarTraceIdDestinations:
        - name: trace_id
          datasourceUid: "${hostname}"
    version: 1

EOF
done

echo "✅ Generated Grafana datasources configuration for ${#worker_ips[@]} workers!"
