<?php

/**
 * Configuration file for Nexus2 to Nexus3 migration
 * 
 * Contains:
 * - PostgreSQL database connection details for Nexus2
 * - Nexus3 API connection details
 * 
 * Update these values according to your environment
 */
return [
    // PostgreSQL database connection details
    'db' => [
        'host' => 'localhost',      // Database server hostname
        'dbname' => 'nexus2_db',    // Nexus2 database name
        'user' => 'your_db_user',   // Database username
        'password' => 'your_db_password' // Database password
    ],
    
    // Nexus3 API connection details
    'nexus3' => [
        'baseUrl' => 'http://localhost:8081', // Nexus3 server URL
        'username' => 'admin',       // Nexus3 admin username
        'password' => 'admin123',    // Nexus3 admin password
    ]
];
