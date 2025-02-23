<?php

/**
 * Migration Rollback Script
 * 
 * Provides automated rollback functionality for failed migrations.
 * Reverses changes in the correct order to maintain data integrity.
 * 
 * Rollback Process:
 * 1. Users - Removes migrated user accounts
 * 2. Roles - Removes migrated roles and permissions
 * 3. Repositories - Removes created repositories
 * 4. Privileges - Removes created privileges
 * 
 * Features:
 * - Transaction-safe operations
 * - Detailed logging of rollback process
 * - Error handling with context
 * - Maintains deletion order for dependencies
 * 
 * Tables Used:
 * - migration_nexus2_users_backup
 * - migration_nexus2_roles_backup
 * - migration_nexus2_repositories_backup
 * - migration_nexus2_privileges_backup
 * 
 * Requirements:
 * - Active database connection
 * - Valid Nexus3 API access
 * - Backup tables must exist
 * - Sufficient permissions
 */

require_once 'bootstrap.php';

// Initialize logging
init_logging(__DIR__ . '/rollback.log', true);
log_info('Starting rollback procedure');

try {
    $config = require 'config.php';
    
    // Get items to rollback from backup tables
    $dbh = connect_database($config);
    begin_transaction($dbh);

    try {
        // Rollback in reverse order of migration
        log_info('Rolling back users...');
        $stmt = $dbh->query("SELECT userid FROM migration_nexus2_users_backup");
        while ($row = $stmt->fetch(PDO::FETCH_ASSOC)) {
            make_api_request($config, 'DELETE', "v1/security/users/{$row['userid']}");
        }

        log_info('Rolling back roles...');
        $stmt = $dbh->query("SELECT id FROM migration_nexus2_roles_backup");
        while ($row = $stmt->fetch(PDO::FETCH_ASSOC)) {
            make_api_request($config, 'DELETE', "v1/security/roles/{$row['id']}");
        }

        log_info('Rolling back repositories...');
        $stmt = $dbh->query("SELECT name, format FROM migration_nexus2_repositories_backup");
        while ($row = $stmt->fetch(PDO::FETCH_ASSOC)) {
            make_api_request($config, 'DELETE', "v1/repositories/{$row['format']}/{$row['name']}");
        }

        log_info('Rolling back privileges...');
        $stmt = $dbh->query("SELECT name FROM migration_nexus2_privileges_backup");
        while ($row = $stmt->fetch(PDO::FETCH_ASSOC)) {
            make_api_request($config, 'DELETE', "v1/security/privileges/{$row['name']}");
        }

        commit_transaction($dbh);
        log_info('Rollback completed successfully');
    } catch (Exception $e) {
        rollback_transaction($dbh);
        throw $e;
    }
} catch (Exception $e) {
    log_error('Rollback failed', $e);
    exit(1);
}
