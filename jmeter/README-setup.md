# Setting Up Grafana with JMeter Dashboards

This guide explains how to set up Grafana with pre-configured JMeter performance dashboards.

## Quick Setup Using Docker Compose

The easiest way to get started is using the provided Docker Compose configuration:

```bash
cd /c:/repos/myscripts/jmeter
docker-compose up -d
```

This will:
1. Start a PostgreSQL database for storing JMeter results
2. Launch Grafana with the JMeter dashboards pre-loaded
3. Configure the necessary datasources automatically

## Manual Setup

If you're installing Grafana directly on a host system, follow these steps:

1. Install Grafana according to the [official documentation](https://grafana.com/docs/grafana/latest/installation/)

2. Run the setup script:
   ```bash
   bash /c:/repos/myscripts/jmeter/grafana_setup.sh
   ```

3. Adjust the PostgreSQL connection settings in `/etc/grafana/provisioning/datasources/jmeter-postgres.yml`

4. Restart Grafana:
   ```bash
   systemctl restart grafana-server
   ```

## Environment Variables

You can customize the setup using these environment variables:

- `POSTGRES_HOST` - PostgreSQL hostname (default: postgres)
- `POSTGRES_PORT` - PostgreSQL port (default: 5432)
- `POSTGRES_DB` - Database name (default: jmeter)
- `POSTGRES_USER` - Database user (default: jmeter)
- `POSTGRES_PASSWORD` - Database password (default: password)
- `POSTGRES_SSL_MODE` - SSL mode for PostgreSQL (default: disable)

## Verifying the Installation

1. Access Grafana at [http://localhost:3000](http://localhost:3000)
2. Log in with admin/admin (change the password when prompted)
3. Navigate to Dashboards > JMeter
4. The JMeter Comprehensive Performance Dashboard should be available

## Next Steps

1. Configure your JMeter tests to store results in the PostgreSQL database
2. Use the CI Job ID variable in the dashboard to filter results by test run
3. Customize the dashboard as needed for your specific metrics
