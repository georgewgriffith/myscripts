# Understanding Grafana Dashboard Provisioning

This document explains how Grafana dashboard provisioning works, so you can add or modify dashboards as needed.

## Directory Structure

Grafana uses a specific directory structure for provisioning:

```
/etc/grafana/provisioning/
├── dashboards/        # Dashboard provider configurations
└── datasources/       # Datasource configurations
```

The actual dashboard JSON files are typically stored in:
```
/var/lib/grafana/dashboards/
```

## How Provisioning Works

1. **Datasources**: Grafana reads YAML files in the `provisioning/datasources` directory to create datasources.

2. **Dashboard Providers**: Grafana reads YAML files in `provisioning/dashboards` to set up dashboard providers.

3. **Dashboard Files**: The dashboard providers load dashboard JSON files from configured paths.

## Adding a New Dashboard

To add a new JMeter dashboard:

1. Create your dashboard JSON file
2. Place it in `/var/lib/grafana/dashboards/`
3. Grafana will automatically detect and load it

## Dashboard Provider Configuration

The dashboard provider configuration (`jmeter-dashboards.yml`) tells Grafana:
- Where to look for dashboard files
- How to organize them in the UI
- Whether users can modify them

Key settings:
- `path`: Directory containing dashboard JSON files
- `allowUiUpdates`: Whether users can save changes to dashboards
- `foldersFromFilesStructure`: Whether to create folders based on file structure

## Using Environment Variables in Provisioning

You can use environment variables in your provisioning files to make them more flexible:

```yaml
datasources:
  - name: jmeter-postgres
    url: ${POSTGRES_HOST}:${POSTGRES_PORT}
```

This allows you to change settings without modifying the provisioning files.

## Best Practices

1. **Version Control**: Keep your dashboard JSON files in version control
2. **Templating**: Use Grafana variables to make dashboards reusable
3. **Consistent Naming**: Use a consistent naming scheme for dashboards
4. **Documentation**: Include descriptions in dashboard JSON
5. **Testing**: Test dashboards with sample data before deploying
