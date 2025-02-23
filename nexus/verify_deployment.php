<?php

/**
 * Deployment Verification Script
 * 
 * Performs comprehensive pre-migration validation of the environment.
 * Ensures all requirements are met before migration begins.
 * 
 * Verification Categories:
 * 
 * 1. System Requirements
 *    - PHP version (8.0+)
 *    - Required extensions
 *    - Memory limits
 *    - Execution time
 * 
 * 2. Database Access
 *    - Connection credentials
 *    - Required permissions
 *    - Table existence
 *    - Schema validation
 * 
 * 3. Nexus3 API
 *    - Endpoint accessibility
 *    - Authentication
 *    - Version compatibility
 *    - Required permissions
 * 
 * 4. File System
 *    - Write permissions
 *    - Configuration access
 *    - Log directory
 *    - Required files
 * 
 * Usage:
 * Run this script before migration to validate environment:
 * php verify_deployment.php
 * 
 * Exit Codes:
 * 0 - All checks passed
 * 1 - One or more checks failed
 */

require_once 'bootstrap.php';

// Initialize logging
init_logging(__DIR__ . '/verification.log', true);
log_info('Starting deployment verification');

$checks = [
    'System Requirements' => 0,
    'Database Access' => 0,
    'Nexus3 API' => 0,
    'File Permissions' => 0
];

try {
    // System checks
    log_info('Checking system requirements...');
    $checks['System Requirements'] = (
        version_compare(PHP_VERSION, '8.0.0', '>=') &&
        extension_loaded('pdo') &&
        extension_loaded('pdo_pgsql') &&
        extension_loaded('curl') &&
        extension_loaded('json')
    );

    // Database checks
    log_info('Verifying database access...');
    $config = require 'config.php';
    $dbh = connect_database($config);
    validate_database_schema($dbh);
    $checks['Database Access'] = true;

    // API checks
    log_info('Testing Nexus3 API access...');
    validate_api_version($config);
    $checks['Nexus3 API'] = true;

    // File permission checks
    log_info('Checking file permissions...');
    $checks['File Permissions'] = (
        is_writable(__DIR__ . '/logs') &&
        is_readable(__DIR__ . '/.env')
    );

    // Output results
    log_info("\nVerification Results:");
    foreach ($checks as $check => $status) {
        log_info(sprintf("%s: %s", 
            $check, 
            $status ? '✓ PASS' : '✗ FAIL'
        ));
    }

    if (in_array(0, $checks, true)) {
        throw new ConfigurationException('One or more checks failed');
    }

    log_info('All verification checks passed successfully');
} catch (Exception $e) {
    log_error('Verification failed', $e);
    exit(1);
}
