#!/bin/bash

if [ -z "$1" ]; then
    echo "Usage: $0 \"10.0.0.1,10.0.0.2,10.0.0.3\" [output_path]"
    echo "Default output path: /etc/grafana/provisioning/datasources/"
    exit 1
fi

# Set output path
OUTPUT_PATH="${2:-/etc/grafana/provisioning/datasources}"
OUTPUT_FILE="$OUTPUT_PATH/prometheus-datasources.yml"

# Create directory if it doesn't exist
mkdir -p "$OUTPUT_PATH" || {
    echo "❌ Error: Cannot create directory $OUTPUT_PATH"
    exit 1
}

# Ensure we can write to the output file
touch "$OUTPUT_FILE" 2>/dev/null || {
    echo "❌ Error: Cannot write to $OUTPUT_FILE"
    echo "Try running with sudo or check permissions"
    exit 1
}

# Convert the comma-separated list into an array
IFS=',' read -r -a worker_ips <<< "$1"

# Function to get hostname from IP
get_hostname() {
    local ip=$1
    local hostname=$(nslookup "$ip" 2>/dev/null | awk '/name = / {print $4}' | sed 's/\.$//')
    if [ -z "$hostname" ]; then
        echo "${ip//./_}"
    else
        echo "$hostname" | cut -d'.' -f1
    fi
}

# Change output file in printf commands
printf "apiVersion: 1\n\ndatasources:\n" > "$OUTPUT_FILE"

# Generate a datasource for each worker
for i in "${!worker_ips[@]}"; do
    hostname=$(get_hostname "${worker_ips[i]}")
    printf "  - name: \"%s\"\n" "$hostname" >> "$OUTPUT_FILE"
    printf "    type: prometheus\n" >> "$OUTPUT_FILE"
    printf "    access: proxy\n" >> "$OUTPUT_FILE"
    printf "    url: \"http://%s:9090\"\n" "${worker_ips[i]}" >> "$OUTPUT_FILE"
    printf "    isDefault: %s\n" "$([[ $i == 0 ]] && echo "true" || echo "false")" >> "$OUTPUT_FILE"
    printf "    editable: true\n" >> "$OUTPUT_FILE"
    printf "    jsonData:\n" >> "$OUTPUT_FILE"
    printf "      timeInterval: \"5s\"\n" >> "$OUTPUT_FILE"
    printf "      queryTimeout: \"30s\"\n" >> "$OUTPUT_FILE"
    printf "      httpMethod: \"POST\"\n" >> "$OUTPUT_FILE"
    printf "      manageAlerts: true\n" >> "$OUTPUT_FILE"
    printf "      prometheusType: \"Prometheus\"\n" >> "$OUTPUT_FILE"
    printf "      prometheusVersion: \"2.50.1\"\n" >> "$OUTPUT_FILE"
    printf "      cacheLevel: \"Strong\"\n" >> "$OUTPUT_FILE"
    printf "      tlsSkipVerify: true\n" >> "$OUTPUT_FILE"
    printf "      exemplarTraceIdDestinations:\n" >> "$OUTPUT_FILE"
    printf "        - name: trace_id\n" >> "$OUTPUT_FILE"
    printf "          datasourceUid: \"%s\"\n" "$hostname" >> "$OUTPUT_FILE"
    printf "    version: 1\n\n" >> "$OUTPUT_FILE"
done

echo "✅ Generated Grafana datasources configuration at $OUTPUT_FILE"
echo "👉 Restart Grafana service to apply changes"
