#!/bin/bash

# Install prerequisites
yum install -y wget tar postgresql-server postgresql-contrib

# Initialize PostgreSQL
postgresql-setup initdb
systemctl enable postgresql
systemctl start postgresql

# Create Grafana database and user
sudo -u postgres psql <<EOF
CREATE DATABASE grafana;
CREATE USER grafana WITH PASSWORD 'grafana';
GRANT ALL PRIVILEGES ON DATABASE grafana TO grafana;
EOF

# Download and extract Grafana
GRAFANA_VERSION="9.5.2"
wget https://dl.grafana.com/oss/release/grafana-${GRAFANA_VERSION}.linux-amd64.tar.gz
tar -zxvf grafana-${GRAFANA_VERSION}.linux-amd64.tar.gz
mv grafana-${GRAFANA_VERSION} /opt/grafana

# Create Grafana user
useradd --system --no-create-home grafana

# Set permissions
chown -R grafana:grafana /opt/grafana

# Copy configuration file
cp grafana.ini /opt/grafana/conf/custom.ini

# Copy systemd service file
cp grafana.service /etc/systemd/system/

# Reload systemd and start Grafana
systemctl daemon-reload
systemctl enable grafana
systemctl start grafana
