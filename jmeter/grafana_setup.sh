#!/bin/bash

# Exit on error
set -e

echo "Setting up Grafana with JMeter dashboards..."

# Create necessary directories for Grafana provisioning
mkdir -p /etc/grafana/provisioning/dashboards
mkdir -p /etc/grafana/provisioning/datasources
mkdir -p /var/lib/grafana/dashboards

# Copy JMeter dashboard to Grafana dashboards directory
cp /c:/repos/myscripts/jmeter/grafana_dashboard.json /var/lib/grafana/dashboards/jmeter_dashboard.json

# Create datasource configuration
cat > /etc/grafana/provisioning/datasources/jmeter-postgres.yml << EOF
apiVersion: 1

datasources:
  - name: jmeter-postgres
    type: postgres
    url: ${POSTGRES_HOST:-postgres}:${POSTGRES_PORT:-5432}
    database: ${POSTGRES_DB:-jmeter}
    user: ${POSTGRES_USER:-jmeter}
    secureJsonData:
      password: ${POSTGRES_PASSWORD:-password}
    jsonData:
      sslmode: ${POSTGRES_SSL_MODE:-disable}
      maxOpenConns: 100
      maxIdleConns: 100
      connMaxLifetime: 14400
      postgresVersion: 1000
      timescaledb: false
EOF

# Create dashboard provider configuration
cat > /etc/grafana/provisioning/dashboards/jmeter-dashboards.yml << EOF
apiVersion: 1

providers:
  - name: 'JMeter Dashboards'
    orgId: 1
    folder: 'JMeter'
    type: file
    disableDeletion: false
    updateIntervalSeconds: 10
    allowUiUpdates: true
    options:
      path: /var/lib/grafana/dashboards
      foldersFromFilesStructure: true
EOF

echo "Grafana setup completed!"
