<?php

/**
 * Configuration Settings for Nexus Migration
 * 
 * This file manages all configurable settings for the migration process.
 * Settings are grouped by category and support environment variable overrides.
 * 
 * Configuration Categories:
 * 
 * Database Settings:
 * - host: Database server location (default: localhost)
 * - dbname: Name of Nexus2 database (default: nexus2)
 * - user: Database username (default: postgres)
 * - password: Database password (from env)
 * - port: Database port (default: 5432)
 * - schema: Database schema (default: public)
 * 
 * Nexus3 API Settings:
 * - baseUrl: Nexus3 server URL (default: http://localhost:8081)
 * - username: API authentication username (default: admin)
 * - password: API authentication password (from env)
 * - timeout: API request timeout in seconds (default: 30)
 * - verify_ssl: SSL verification flag (default: false)
 * 
 * Migration Settings:
 * - batch_size: Items per batch (default: 50)
 * - default_password: Default password for migrated users
 * - blob_store: Default blob store name
 * - cache_ttl: Cache duration in minutes
 * - debug: Debug mode flag
 * 
 * Environment Variables:
 * DB_HOST: Override database host
 * DB_NAME: Override database name
 * DB_USER: Override database username
 * DB_PASS: Set database password
 * DB_PORT: Override database port
 * NEXUS3_URL: Override Nexus3 URL
 * NEXUS3_USER: Override Nexus3 username
 * NEXUS3_PASS: Set Nexus3 password
 */

return [
    // Database connection settings
    'db' => [
        'host' => getenv('DB_HOST') ?: 'localhost',
        'dbname' => getenv('DB_NAME') ?: 'nexus2',
        'user' => getenv('DB_USER') ?: 'postgres',
        'password' => getenv('DB_PASS') ?: '',
        'port' => getenv('DB_PORT') ?: 5432,
        'schema' => 'public'
    ],

    // Nexus 3 connection settings
    'nexus3' => [
        'baseUrl' => getenv('NEXUS3_URL') ?: 'http://localhost:8081',
        'username' => getenv('NEXUS3_USER') ?: 'admin',
        'password' => getenv('NEXUS3_PASS') ?: 'admin123',
        'timeout' => 30,
        'verify_ssl' => false
    ],

    // Migration settings
    'settings' => [
        'batch_size' => 50,
        'default_password' => 'changeme123',
        'blob_store' => 'default',
        'cache_ttl' => 1440,
        'debug' => true
    ]
];
