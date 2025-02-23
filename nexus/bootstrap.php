<?php

/**
 * Application Bootstrap Module
 * 
 * This file initializes the entire migration environment and ensures
 * all requirements are met before the migration begins.
 * 
 * Initialization Steps:
 * 1. Error Reporting Setup
 *    - Enables all error reporting
 *    - Configures error display
 *    - Sets timezone to UTC
 * 
 * 2. Component Loading
 *    - Validates presence of required files
 *    - Loads core components (constants, exceptions, functions)
 *    - Loads utility components (validator, performance)
 *    - Loads process components (batch, verify, retry)
 * 
 * 3. Environment Configuration
 *    - Loads .env file if present
 *    - Sets environment variables
 *    - Validates PHP version (8.0+)
 * 
 * 4. Extension Validation
 *    - PDO/pdo_pgsql: Database connectivity
 *    - curl: API communication
 *    - json: Data processing
 * 
 * 5. System Initialization
 *    - Sets up error handlers
 *    - Initializes logging
 *    - Starts performance monitoring
 * 
 * Required Files:
 * - constants.php: Global constant definitions
 * - exceptions.php: Custom exception classes
 * - functions.php: Utility functions
 * - database.php: Database operations
 * - validator.php: Data validation
 * - performance.php: Performance tracking
 * - batch.php: Batch processing
 * - verify.php: Data verification
 * - retry.php: Retry mechanisms
 * - rollback.php: Rollback handling
 */

// Initialize error reporting
error_reporting(E_ALL);
ini_set('display_errors', '1');
date_default_timezone_set('UTC');

/**
 * Required Component Files
 * Each file is checked for existence before loading
 */
$required_files = [
    'constants.php',
    'exceptions.php',
    'functions.php',
    'database.php',
    'validator.php',
    'performance.php',
    'batch.php',
    'verify.php',
    'retry.php',
    'rollback.php'
];

foreach ($required_files as $file) {
    if (!file_exists(__DIR__ . '/' . $file)) {
        throw new RuntimeException("Required file missing: $file");
    }
}

// Load core components
require_once __DIR__ . '/constants.php';
require_once __DIR__ . '/exceptions.php';
require_once __DIR__ . '/functions.php';
require_once __DIR__ . '/database.php';
require_once __DIR__ . '/validator.php';

// Load additional components
require_once __DIR__ . '/performance.php';
require_once __DIR__ . '/batch.php';
require_once __DIR__ . '/verify.php';
require_once __DIR__ . '/retry.php';
require_once __DIR__ . '/rollback.php';

// Initialize environment
if (file_exists(__DIR__ . '/.env')) {
    $env = parse_ini_file(__DIR__ . '/.env');
    foreach ($env as $key => $value) {
        putenv("$key=$value");
    }
}

// Validate PHP version and extensions
if (version_compare(PHP_VERSION, '8.0.0', '<')) {
    throw new RuntimeException('PHP 8.0.0 or higher is required');
}

$required_extensions = ['pdo', 'pdo_pgsql', 'curl', 'json'];
foreach ($required_extensions as $ext) {
    if (!extension_loaded($ext)) {
        throw new RuntimeException("Required PHP extension missing: $ext");
    }
}

// Set up error handlers and logging
setup_error_handling();