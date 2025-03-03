#!/bin/bash

if [ -z "\$1" ]; then
    echo "Usage: \$0 \"10.0.0.1,10.0.0.2,10.0.0.3\""
    exit 1
fi

# Convert the comma-separated list into an array
IFS=',' read -r -a worker_ips <<< "\$1"

# Function to get hostname from IP
get_hostname() {
    local ip=\$1
    local hostname=\$(nslookup "\$ip" 2>/dev/null | awk '/name = / {print \$4}' | sed 's/\.$//')
    if [ -z "\$hostname" ]; then
        echo "\${ip//./_}"
    else
        echo "\$hostname"
    fi
}

printf "apiVersion: 1\n\ndatasources:\n" > grafana-datasources.yml

# Generate a datasource for each worker
for i in "\${!worker_ips[@]}"; do
    hostname=\$(get_hostname "\${worker_ips[i]}")
    printf "  - name: \"%s\"\n" "\$hostname" >> grafana-datasources.yml
    printf "    type: prometheus\n" >> grafana-datasources.yml
    printf "    access: proxy\n" >> grafana-datasources.yml
    printf "    url: \"http://%s:9090\"\n" "\${worker_ips[i]}" >> grafana-datasources.yml
    printf "    isDefault: %s\n" "\$([[ \$i == 0 ]] && echo "true" || echo "false")" >> grafana-datasources.yml
    printf "    editable: true\n" >> grafana-datasources.yml
    printf "    jsonData:\n" >> grafana-datasources.yml
    printf "      timeInterval: \"5s\"\n" >> grafana-datasources.yml
    printf "      queryTimeout: \"30s\"\n" >> grafana-datasources.yml
    printf "      httpMethod: \"POST\"\n" >> grafana-datasources.yml
    printf "      manageAlerts: true\n" >> grafana-datasources.yml
    printf "      prometheusType: \"Prometheus\"\n" >> grafana-datasources.yml
    printf "      prometheusVersion: \"2.50.1\"\n" >> grafana-datasources.yml
    printf "      cacheLevel: \"Strong\"\n" >> grafana-datasources.yml
    printf "      tlsSkipVerify: true\n" >> grafana-datasources.yml
    printf "      exemplarTraceIdDestinations:\n" >> grafana-datasources.yml
    printf "        - name: trace_id\n" >> grafana-datasources.yml
    printf "          datasourceUid: \"%s\"\n" "\$hostname" >> grafana-datasources.yml
    printf "    version: 1\n\n" >> grafana-datasources.yml
done

echo "✅ Generated Grafana datasources configuration for \${#worker_ips[@]} workers!"
