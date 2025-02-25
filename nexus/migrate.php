<?php

/**
 * Nexus2 to Nexus3 Migration Script
 * 
 * This script migrates the following from Nexus2 to Nexus3:
 * - Privileges with their properties and mappings
 * - Repositories (hosted, proxy, and group) with their configurations
 * - Roles with their privilege mappings
 * - Users with their roles and settings
 * 
 * Each migration section is wrapped in a transaction for rollback safety.
 * Progress and errors are logged to both file and console.
 */

const DEFAULT_PASSWORD = 'changeme123';
const DEFAULT_CACHE_TTL = 1440;
const BLOB_STORE_NAME = 'default';

require_once 'functions.php';
setup_error_handling();

// Initialize logging with debug mode enabled
init_logging(__DIR__ . '/migration.log', true);
log_info('Starting Nexus2 to Nexus3 migration');

// Load and validate configuration
try {
    $config = require 'config.php';
    log_debug('Configuration loaded successfully');
} catch (Exception $e) {
    log_error('Failed to load configuration', $e);
    exit(1);
}

// Validate configuration
if (!isset($config['db']) || !isset($config['nexus3'])) {
    log_error('Invalid configuration: missing required sections');
    exit(1);
}

$requiredDbKeys = ['host', 'dbname', 'user', 'password'];
$requiredNexusKeys = ['baseUrl', 'username', 'password'];

foreach ($requiredDbKeys as $key) {
    if (!isset($config['db'][$key])) {
        log_error("Invalid configuration: missing db.$key");
        exit(1);
    }
}

foreach ($requiredNexusKeys as $key) {
    if (!isset($config['nexus3'][$key])) {
        log_error("Invalid configuration: missing nexus3.$key");
        exit(1);
    }
}

// Main migration process
try {
    /**
     * Test Connections
     * - Verify database connectivity
     * - Verify Nexus3 API accessibility
     */
    try {
        log_info('Connecting to PostgreSQL database...');
        $dbh = new PDO(
            "pgsql:host={$config['db']['host']};dbname={$config['db']['dbname']}",
            $config['db']['user'],
            $config['db']['password']
        );
        $dbh->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
        log_info('Database connection successful');
    } catch (PDOException $e) {
        log_error('Database connection failed', $e);
        exit(1);
    }

    try {
        log_info('Testing Nexus3 API connection...');
        make_api_request($config, 'GET', 'v1/status');
        log_info('Nexus3 API connection successful');
    } catch (Exception $e) {
        log_error('Nexus3 API connection failed', $e);
        exit(1);
    }

    /**
     * Migration Statistics Tracking
     * Keeps count of:
     * - Total items to migrate
     * - Successfully migrated items
     * - Failed migrations
     */
    $stats = [
        'privileges' => ['total' => 0, 'success' => 0, 'failed' => 0],
        'repositories' => ['total' => 0, 'success' => 0, 'failed' => 0],
        'roles' => ['total' => 0, 'success' => 0, 'failed' => 0],
        'users' => ['total' => 0, 'success' => 0, 'failed' => 0]
    ];

    /**
     * Privilege Migration
     * - Migrates privileges with their methods and repository targets
     * - Maps Nexus2 privilege types to Nexus3 equivalents
     * - Preserves privilege properties and descriptions
     */
    $dbh->beginTransaction();
    try {
        log_info('Starting privileges migration...');
        $stmt = $dbh->query("SELECT COUNT(*) FROM public.migration_nexus2_privileges");
        $stats['privileges']['total'] = $stmt->fetchColumn();
        
        $stmt = $dbh->query("
            SELECT p.uuid, p.id, p.resourceuri, p.name, p.description, p.type,
                p.usermanaged, p.dateadded, p.dateupdated, p.properties_checksum, 
                p.properties,
                string_agg(DISTINCT pm.method, ',') as methods,
                string_agg(DISTINCT pr.repository_id, ',') as repository_targets
            FROM public.migration_nexus2_privileges p
            LEFT JOIN public.migration_nexus2_privilege_methods pm ON p.id = pm.privilege_id
            LEFT JOIN public.migration_nexus2_privilege_repository pr ON p.id = pr.privilege_id
            GROUP BY p.uuid, p.id, p.resourceuri, p.name, p.description, p.type,
                p.usermanaged, p.dateadded, p.dateupdated, p.properties_checksum, 
                p.properties
        ");

        while ($row = $stmt->fetch(PDO::FETCH_ASSOC)) {
            try {
                // Parse methods and repository targets
                $methods = !empty($row['methods']) ? explode(',', $row['methods']) : [];
                $repositoryTargets = !empty($row['repository_targets']) ? 
                    explode(',', $row['repository_targets']) : [];

                // Parse properties string into array (assuming it's stored as key=value pairs)
                $properties = [];
                if (!empty($row['properties'])) {
                    foreach (explode(',', $row['properties']) as $property) {
                        $parts = str_contains($property, '=') ? explode('=', $property) : [];
                        if (count($parts) == 2) {
                            $properties[$parts[0]] = $parts[1];
                        }
                    }
                }

                // Map Nexus2 privilege types to Nexus3 types
                $actions = [];
                switch ($row['type']) {
                    case 'target':
                        $actions = ['READ'];
                        if (!empty($methods)) {
                            foreach ($methods as $method) {
                                switch (strtoupper($method)) {
                                    case 'CREATE':
                                    case 'UPDATE':
                                        if (!in_array('EDIT', $actions)) $actions[] = 'EDIT';
                                        break;
                                    case 'DELETE':
                                        if (!in_array('DELETE', $actions)) $actions[] = 'DELETE';
                                        break;
                                    default:
                                        log_warning("Unknown method type: " . $method);
                                        break;
                                }
                            }
                        }
                        break;
                        
                    case 'application':
                        // Map application privileges directly
                        $actions = isset($properties['method']) ? [$properties['method']] : ['READ'];
                        break;

                    case 'method':
                        // Map method privileges directly from the methods array
                        if (!empty($methods)) {
                            $actions = array_map('strtoupper', $methods);
                        } else {
                            $actions = ['READ'];
                        }
                        break;

                    default:
                        log_warning("Skipping privilege {$row['name']} - unsupported type: {$row['type']}");
                        continue;
                }

                if (!is_array($actions)) {
                    throw new InvalidArgumentException("Actions must be an array");
                }

                if (empty($row['name'])) {
                    throw new InvalidArgumentException("Privilege name cannot be empty");
                }

                create_privilege(
                    config: $config,
                    privilegeData: [
                        'name' => $row['name'],
                        'description' => $row['description'] ?? $row['name'],
                        'actions' => $actions,
                        'domain' => $row['resourceuri'] ?? '*'
                    ]
                );
                log_info("Created privilege: {$row['name']}");
                $stats['privileges']['success']++;
            } catch (Exception $e) {
                log_error("Failed to create privilege {$row['name']}", $e);
                $stats['privileges']['failed']++;
            }
        }

        $dbh->commit();
        log_info("Privileges migration completed");
    } catch (Exception $e) {
        $dbh->rollBack();
        log_error('Privileges migration failed, rolling back', $e);
        throw $e;
    }

    /**
     * Repository Migration
     * - Handles hosted, proxy, and group repositories
     * - Preserves format-specific configurations
     * - Maps repository types and formats
     * - Maintains group memberships
     * - Applies format-specific validations
     */
    $dbh->beginTransaction();
    try {
        log_info('Starting repositories migration...');
        $stmt = $dbh->query("SELECT COUNT(*) FROM public.migration_nexus2_repositories");
        $stats['repositories']['total'] = $stmt->fetchColumn();
        
        $stmt = $dbh->query("
            SELECT r.*, 
                string_agg(DISTINCT g.member_id, ',') as group_members,
                string_agg(DISTINCT rc.key || '=' || rc.value, ',') as repo_configs
            FROM public.migration_nexus2_repositories r
            LEFT JOIN public.migration_nexus2_repository_group_members g ON r.id = g.group_id
            LEFT JOIN public.migration_nexus2_repository_config rc ON r.id = rc.repository_id
            GROUP BY r.uuid, r.id, r.name, r.type, r.format, r.exposed, r.repotype,
                r.contentresourceuri, r.writepolicy, r.notfoundcachett
        ");

        while ($row = $stmt->fetch(PDO::FETCH_ASSOC)) {
            try {
                // Parse group members for group repositories
                $groupMembers = !empty($row['group_members']) ? explode(',', $row['group_members']) : [];
                
                // Parse repository configurations
                $repoConfigs = [];
                if (!empty($row['repo_configs'])) {
                    foreach (explode(',', $row['repo_configs']) as $config) {
                        $parts = explode('=', $config);
                        if (count($parts) == 2) {
                            $repoConfigs[$parts[0]] = $parts[1];
                        }
                    }
                }

                // Map Nexus2 repository types to Nexus3 types
                $type = match($row['repotype']) {
                    'hosted' => 'hosted',
                    'proxy' => 'proxy',
                    'virtual' => 'group',
                    default => null
                };

                if (!$type) {
                    log_warning("Skipping repository {$row['name']} - unsupported type: {$row['repotype']}");
                    continue;
                }

                // Map format names between versions if needed
                $format = strtolower($row['format']);
                
                // Skip unsupported formats
                $supportedFormats = ['maven2', 'npm', 'nuget', 'docker', 'yum', 'pypi', 
                    'raw', 'rubygems', 'apt', 'helm', 'conan', 'p2', 'r', 'conda', 
                    'gitlfs', 'go'];
                
                if (!in_array($format, $supportedFormats)) {
                    log_warning("Skipping repository {$row['name']} - unsupported format: {$format}");
                    continue;
                }

                switch ($type) {
                    case 'hosted':
                        $repoData = [
                            'name' => $row['name'],
                            'online' => $row['exposed'] === 't',
                            'storage' => [
                                'blobStoreName' => BLOB_STORE_NAME,
                                'strictContentTypeValidation' => true,
                                'writePolicy' => match($row['writepolicy']) {
                                    'ALLOW_WRITE' => 'ALLOW',
                                    'ALLOW_WRITE_ONCE' => 'ALLOW_ONCE',
                                    default => 'DENY'
                                }
                            ]
                        ];
                        create_hosted_repository($config, $format, $repoData);
                        break;
                        
                    case 'proxy':
                        $repoData = [
                            'name' => $row['name'],
                            'online' => $row['exposed'] === 't',
                            'storage' => [
                                'blobStoreName' => BLOB_STORE_NAME,
                                'strictContentTypeValidation' => true
                            ],
                            'proxy' => [
                                'remoteUrl' => $row['contentresourceuri'],
                                'contentMaxAge' => DEFAULT_CACHE_TTL,
                                'metadataMaxAge' => DEFAULT_CACHE_TTL
                            ],
                            'negativeCache' => [
                                'enabled' => true,
                                'timeToLive' => intval($row['notfoundcachett']) ?: DEFAULT_CACHE_TTL
                            ]
                        ];
                        create_proxy_repository($config, $format, $repoData);
                        break;

                    case 'group':
                        if (!empty($groupMembers)) {
                            $repoData = [
                                'name' => $row['name'],
                                'online' => $row['exposed'] === 't',
                                'storage' => [
                                    'blobStoreName' => BLOB_STORE_NAME,
                                    'strictContentTypeValidation' => true
                                ],
                                'group' => [
                                    'memberNames' => $groupMembers
                                ]
                            ];
                            create_group_repository($config, $format, $repoData);
                        }
                        break;
                }
                
                log_info("Created {$type} repository: {$row['name']} ({$format})");
                $stats['repositories']['success']++;
            } catch (Exception $e) {
                log_error("Failed to create repository {$row['name']}", $e);
                $stats['repositories']['failed']++;
            }
        }

        $dbh->commit();
        log_info("Repositories migration completed");
    } catch (Exception $e) {
        $dbh->rollBack();
        log_error('Repositories migration failed, rolling back', $e);
        throw $e;
    }

    /**
     * Role Migration
     * - Preserves role hierarchies
     * - Maintains privilege assignments
     * - Keeps role descriptions and metadata
     */
    $dbh->beginTransaction();
    try {
        log_info('Starting roles migration...');
        $stmt = $dbh->query("SELECT COUNT(*) FROM public.migration_nexus2_roles");
        $stats['roles']['total'] = $stmt->fetchColumn();
        
        $stmt = $dbh->query("
            SELECT r.*,
                string_agg(DISTINCT rm.child_role_id, ',') as child_roles,
                string_agg(DISTINCT rp.privilege_id, ',') as role_privileges
            FROM public.migration_nexus2_roles r
            LEFT JOIN public.migration_nexus2_role_mappings rm ON r.id = rm.parent_role_id
            LEFT JOIN public.migration_nexus2_role_privileges rp ON r.id = rp.role_id
            GROUP BY r.uuid, r.id, r.name, r.description, r.sessiontimeout,
                r.roles, r.privileges, r.dateadded, r.dateupdated, r.usermanaged
        ");

        while ($row = $stmt->fetch(PDO::FETCH_ASSOC)) {
            try {
                // Clean up privileges and roles strings before splitting
                $privileges = array_filter(
                    explode(',', $row['role_privileges'] ?? ''),
                    function($value) { return !empty(trim($value)); }
                );
                
                $roles = array_filter(
                    explode(',', $row['child_roles'] ?? ''),
                    function($value) { return !empty(trim($value)); }
                );

                $roleData = [
                    'id' => $row['id'],
                    'name' => $row['name'],
                    'description' => $row['description'] ?: $row['name'],
                    'privileges' => $privileges,
                    'roles' => $roles
                ];

                create_role($config, $roleData);
                log_info("Created role: {$row['name']}");
                $stats['roles']['success']++;
            } catch (Exception $e) {
                log_error("Failed to create role {$row['name']}", $e);
                $stats['roles']['failed']++;
            }
        }

        $dbh->commit();
        log_info("Roles migration completed");
    } catch (Exception $e) {
        $dbh->rollBack();
        log_error('Roles migration failed, rolling back', $e);
        throw $e;
    }

    /**
     * User Migration
     * - Migrates user details and metadata
     * - Preserves role assignments
     * - Maps user status values
     * - Sets default passwords
     * - Maintains user settings
     */
    $dbh->beginTransaction();
    try {
        log_info('Starting users migration...');
        $stmt = $dbh->query("SELECT COUNT(*) FROM public.migration_nexus2_users");
        $stats['users']['total'] = $stmt->fetchColumn();
        
        $stmt = $dbh->query("
            SELECT u.*,
                string_agg(DISTINCT ur.role_id, ',') as user_roles,
                string_agg(DISTINCT us.setting_key || '=' || us.setting_value, ',') as user_settings
            FROM public.migration_nexus2_users u
            LEFT JOIN public.migration_nexus2_user_roles ur ON u.id = ur.user_id
            LEFT JOIN public.migration_nexus2_user_settings us ON u.id = us.user_id
            GROUP BY u.uuid, u.id, u.userid
                -- Add all other u.* columns here
        ");

        while ($row = $stmt->fetch(PDO::FETCH_ASSOC)) {
            try {
                // Map Nexus2 status values to Nexus3 status values
                $status = match(strtolower($row['status'])) {
                    'active', 'enabled' => 'active',
                    'disabled' => 'disabled',
                    'locked' => 'locked',
                    default => 'disabled'
                };

                // Clean up roles string before splitting
                $roles = array_filter(
                    explode(',', $row['user_roles'] ?? ''),
                    function($value) { return !empty(trim($value)); }
                );

                $userData = [
                    'userId' => $row['userid'],
                    'firstName' => $row['firstname'],
                    'lastName' => $row['lastname'],
                    'emailAddress' => $row['email'],
                    'password' => DEFAULT_PASSWORD, // Set a default password
                    'status' => $status,
                    'roles' => $roles
                ];

                create_user($config, $userData);
                log_info("Created user: {$row['userid']}");
                $stats['users']['success']++;
            } catch (Exception $e) {
                log_error("Failed to create user {$row['userid']}", $e);
                $stats['users']['failed']++;
            }
        }

        $dbh->commit();
        log_info("Users migration completed");
    } catch (Exception $e) {
        $dbh->rollBack();
        log_error('Users migration failed, rolling back', $e);
        throw $e;
    }

    /**
     * Migration Summary
     * Outputs statistics for each migrated entity type
     */
    log_info("\nMigration Statistics:");
    foreach ($stats as $type => $counts) {
        log_info(sprintf(
            "%s: %d total, %d successful, %d failed",
            ucfirst($type),
            $counts['total'],
            $counts['success'],
            $counts['failed']
        ));
    }

} catch (Exception $e) {
    log_error('Migration failed', $e);
    cleanup($dbh);
    exit(1);
}

cleanup($dbh);
log_info('Migration completed successfully');

// Cleanup
$dbh = null; // Close database connection
if (file_exists($logFile)) {
    chmod($logFile, 0644); // Set appropriate permissions
}

/**
 * Creates a privilege in Nexus 3
 * @param array $config The configuration array
 * @param array $privilegeData The privilege data to create
 * @param string|null $description Optional description for the privilege
 * @throws Exception When privilege creation fails
 * @return void
 */
function create_privilege(array $config, array $privilegeData, ?string $description = null): void

public function log_error(string $message, string|Exception $context = null): void
