#!/bin/bash

# Default database connection parameters
DB_HOST=${DB_HOST:-localhost}
DB_PORT=${DB_PORT:-5432}
DB_NAME=${DB_NAME:-jmeter}
DB_USER=${DB_USER:-postgres}
DB_PASSWORD=${DB_PASSWORD:-postgres}

# Check required commands
if ! command -v psql >/dev/null 2>&1; then
    echo "Error: Required command 'psql' not found"
    exit 1
fi

echo "Setting up permissions for JMeter database..."
echo "Database: $DB_HOST:$DB_PORT/$DB_NAME"

# Create the database if it doesn't exist
PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -c "CREATE DATABASE $DB_NAME;" postgres || true

# Apply the schema
PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -f "$(dirname "$0")/create_table.sql"

# Set sequence permissions explicitly
PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" <<EOF
ALTER SEQUENCE jmeter_results_id_seq OWNER TO $DB_USER;
GRANT ALL PRIVILEGES ON SEQUENCE jmeter_results_id_seq TO $DB_USER;

-- For tables
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO $DB_USER;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO $DB_USER;
EOF

echo "Database setup complete!"
echo "To run streaming: DB_HOST=$DB_HOST DB_NAME=$DB_NAME DB_USER=$DB_USER DB_PASSWORD=***** ./jmeter_stream.sh <job_id>"

exit 0
