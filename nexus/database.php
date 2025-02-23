<?php

/**
 * Database Operations Module
 * 
 * Functions:
 * 
 * Connection Management:
 * - connect_database(): Establishes secure database connections
 * - validate_table_schema(): Validates required table structure
 * 
 * Transaction Handling:
 * - begin_transaction(): Starts database transactions
 * - commit_transaction(): Commits active transactions
 * - rollback_transaction(): Rolls back failed transactions
 * 
 * Data Retrieval:
 * - get_nexus2_privileges(): Fetches privileges with mappings
 * - get_nexus2_repositories(): Fetches repositories with configs
 * - get_nexus2_roles(): Fetches roles with privilege mappings
 * - get_nexus2_users(): Fetches users with role assignments
 * - get_migration_counts(): Gets migration statistics
 */

/**
 * Establishes a connection to the PostgreSQL database using PDO
 * 
 * @param array $config Configuration array containing database credentials
 * @return PDO Database connection handle
 * @throws DatabaseException If connection fails
 */
function connect_database(array $config): PDO {
    try {
        $dsn = sprintf(
            "pgsql:host=%s;port=%d;dbname=%s;",
            $config['db']['host'],
            $config['db']['port'],
            $config['db']['dbname']
        );
        
        $dbh = new PDO($dsn, $config['db']['user'], $config['db']['password']);
        $dbh->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
        
        return $dbh;
    } catch (PDOException $e) {
        throw new DatabaseException('Database connection failed: ' . $e->getMessage(), [], 0, $e);
    }
}

/**
 * Validates that a table contains all required columns
 * 
 * @param PDO $dbh Database connection handle
 * @param string $table Name of table to validate
 * @param array $required_columns Array of required column names
 * @throws DatabaseException If required columns are missing
 */
function validate_table_schema(PDO $dbh, string $table, array $required_columns): void {
    $columns = $dbh->query("
        SELECT column_name 
        FROM information_schema.columns 
        WHERE table_schema = 'public' 
        AND table_name = '$table'
    ")->fetchAll(PDO::FETCH_COLUMN);

    $missing = array_diff($required_columns, $columns);
    if (!empty($missing)) {
        throw new DatabaseException(
            "Missing required columns in $table: " . implode(', ', $missing)
        );
    }
}

function begin_transaction(PDO $dbh): void {
    if (!$dbh->inTransaction()) {
        $dbh->beginTransaction();
    }
}

function commit_transaction(PDO $dbh): void {
    if ($dbh->inTransaction()) {
        $dbh->commit();
    }
}

function rollback_transaction(PDO $dbh): void {
    if ($dbh->inTransaction()) {
        $dbh->rollBack();
    }
}

/**
 * Retrieves all privileges from Nexus2 database with their methods and repository targets
 * Joins with related tables to get complete privilege information including:
 * - Basic privilege details
 * - Associated HTTP methods
 * - Repository target mappings
 * 
 * @param PDO $dbh Database connection handle
 * @return array Array of privileges with their complete mappings
 */
function get_nexus2_privileges(PDO $dbh): array {
    return $dbh->query("
        SELECT p.*, 
            string_agg(DISTINCT pm.method, ',') as methods,
            string_agg(DISTINCT pr.repository_id, ',') as repository_targets
        FROM migration_nexus2_privileges p
        LEFT JOIN migration_nexus2_privilege_methods pm ON p.id = pm.privilege_id
        LEFT JOIN migration_nexus2_privilege_repository pr ON p.id = pr.privilege_id
        GROUP BY p.id, p.uuid, p.resourceuri, p.name, p.description, p.type,
            p.usermanaged, p.dateadded, p.dateupdated, p.properties_checksum, 
            p.properties
        ORDER BY p.id"
    )->fetchAll(PDO::FETCH_ASSOC);
}

/**
 * Get repositories from Nexus2 database
 */
function get_nexus2_repositories(PDO $dbh): array {
    return $dbh->query("
        SELECT r.*,
            string_agg(DISTINCT gm.member_repo_id, ',') as member_repositories,
            string_agg(DISTINCT rc.key || '=' || rc.value, ',') as configurations
        FROM migration_nexus2_repositories r
        LEFT JOIN migration_nexus2_repository_group_members gm ON r.id = gm.group_repo_id
        LEFT JOIN migration_nexus2_repository_config rc ON r.id = rc.repository_id
        GROUP BY r.id, r.uuid, r.name, r.type, r.format, r.exposed, 
            r.repotype, r.contentresourceuri, r.writepolicy
        ORDER BY r.id"
    )->fetchAll(PDO::FETCH_ASSOC);
}

/**
 * Get roles from Nexus2 database
 */
function get_nexus2_roles(PDO $dbh): array {
    return $dbh->query("
        SELECT r.*,
            string_agg(DISTINCT rp.privilege_id, ',') as privilege_ids,
            string_agg(DISTINCT rm.child_role_id, ',') as child_role_ids
        FROM migration_nexus2_roles r
        LEFT JOIN migration_nexus2_role_privileges rp ON r.id = rp.role_id
        LEFT JOIN migration_nexus2_role_mappings rm ON r.id = rm.parent_role_id
        GROUP BY r.id, r.uuid, r.name, r.description, r.sessiontimeout,
            r.roles, r.privileges, r.dateadded, r.dateupdated, r.usermanaged
        ORDER BY r.id"
    )->fetchAll(PDO::FETCH_ASSOC);
}

/**
 * Get users from Nexus2 database
 */
function get_nexus2_users(PDO $dbh): array {
    return $dbh->query("
        SELECT u.*,
            string_agg(DISTINCT ur.role_id, ',') as role_ids,
            string_agg(DISTINCT us.setting_key || '=' || us.setting_value, ',') as user_settings
        FROM migration_nexus2_users u
        LEFT JOIN migration_nexus2_user_roles ur ON u.id = ur.user_id
        LEFT JOIN migration_nexus2_user_settings us ON u.id = us.user_id
        GROUP BY u.id, u.uuid, u.userid, u.firstname, u.lastname,
            u.email, u.status, u.roles
        ORDER BY u.id"
    )->fetchAll(PDO::FETCH_ASSOC);
}

/**
 * Count total records to migrate
 */
function get_migration_counts(PDO $dbh): array {
    return [
        'privileges' => $dbh->query("SELECT COUNT(*) FROM migration_nexus2_privileges")->fetchColumn(),
        'repositories' => $dbh->query("SELECT COUNT(*) FROM migration_nexus2_repositories")->fetchColumn(),
        'roles' => $dbh->query("SELECT COUNT(*) FROM migration_nexus2_roles")->fetchColumn(),
        'users' => $dbh->query("SELECT COUNT(*) FROM migration_nexus2_users")->fetchColumn()
    ];
}
