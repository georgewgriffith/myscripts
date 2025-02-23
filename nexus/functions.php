<?php

/**
 * Nexus Migration Utility Functions
 * 
 * Functions:
 * 
 * Logging Functions:
 * - init_logging(): Initializes logging system with file and debug settings
 * - write_log(): Writes timestamped messages to log file and console
 * - log_debug(): Logs debug messages when debug mode is enabled
 * - log_info(): Logs informational messages
 * - log_error(): Logs error messages with optional exception details
 * - log_warning(): Logs warning messages
 * 
 * API Functions:
 * - validate_api_response(): Validates API responses for errors
 * - make_api_request(): Makes HTTP requests to Nexus3 API
 * 
 * Entity Creation:
 * - create_privilege(): Creates privileges in Nexus3
 * - create_repository(): Creates repositories of any type
 * - create_role(): Creates roles with privilege mappings
 * - create_user(): Creates users with role assignments
 * 
 * Repository Management:
 * - get_repository_config(): Generates format-specific repository configs
 * - create_hosted_repository(): Creates hosted repositories
 * - create_proxy_repository(): Creates proxy repositories
 * - create_group_repository(): Creates group repositories
 * 
 * Validation:
 * - validate_required_fields(): Checks for required data fields
 * - validate_repository_config(): Validates repository configuration
 * - validate_api_version(): Checks Nexus3 version compatibility
 * - validate_repository_format(): Validates repository format support
 * 
 * Data Preparation:
 * - clean_string(): Sanitizes string inputs
 * - parse_csv_string(): Parses comma-separated values
 * - sanitize_data(): Cleanses input data arrays
 * - prepare_repository_data(): Prepares repository creation data
 * - prepare_user_data(): Prepares user creation data
 * 
 * Migration:
 * - migrate_item(): Handles migration of individual items
 * - cleanup(): Performs cleanup operations
 * - setup_error_handling(): Configures error handlers
 */

/**
 * Utility Functions
 * 
 * Core functionality for the Nexus2 to Nexus3 migration process.
 * Provides functions for:
 * - Logging and error handling
 * - API communication
 * - Data validation and sanitization
 * - Repository management
 * - User and role management
 * - Migration helpers
 * 
 * Functions are grouped by purpose:
 * - Logging functions (log_*, write_log)
 * - API functions (make_api_request, validate_api_response)
 * - Creation functions (create_*)
 * - Validation functions (validate_*)
 * - Helper functions (clean_*, parse_*, prepare_*)
 * - Migration functions (migrate_*)
 */

// Global logging configuration
$GLOBALS['debug_mode'] = false;
$GLOBALS['log_file'] = null;

/**
 * Logging System Functions
 * Handles all logging operations with different severity levels
 */

function init_logging($log_file, $debug_mode = false) {
    $GLOBALS['debug_mode'] = $debug_mode;
    $GLOBALS['log_file'] = $log_file;
    
    $timestamp = date('Y-m-d H:i:s');
    write_log("=== Migration Started at $timestamp ===\n");
}

/**
 * Write a message to the log file and console
 * @param string $message Message to log
 * @throws Exception if logging is not initialized
 */
function write_log($message) {
    if (!$GLOBALS['log_file']) {
        throw new Exception('Logging not initialized');
    }
    
    $timestamp = date('Y-m-d H:i:s');
    $formattedMessage = "[$timestamp] $message\n";
    
    file_put_contents($GLOBALS['log_file'], $formattedMessage, FILE_APPEND);
    echo $formattedMessage;
}

/**
 * Log a debug message (only if debug mode is enabled)
 * @param string $message Debug message to log
 */
function log_debug($message) {
    if ($GLOBALS['debug_mode']) {
        write_log("[DEBUG] $message");
    }
}

/**
 * Log an informational message
 * @param string $message Info message to log
 */
function log_info($message) {
    write_log("[INFO] $message");
}

/**
 * Log an error message with optional context
 * @param string $message Error message to log
 * @param string|Exception|null $context Additional context or exception
 * @return void
 */
function log_error(string $message, string|Exception|null $context = null): void {
    $logMessage = "[ERROR] $message";
    
    if ($context instanceof Exception) {
        $logMessage .= "\nException: " . $context->getMessage();
        $logMessage .= "\nStack trace: " . $context->getTraceAsString();
    } elseif (is_string($context) && !empty($context)) {
        $logMessage .= "\nContext: " . $context;
    }
    
    write_log($logMessage);
}

/**
 * Log a warning message
 * @param string $message Warning message to log
 */
function log_warning($message) {
    write_log("[WARNING] $message");
}

/**
 * API Communication Functions
 * Handles all interactions with Nexus3 API
 */

function validate_api_response($response, $context) {
    if (empty($response)) {
        log_error("Empty response received for $context");
        throw new Exception("Empty response received for $context");
    }
    
    if (isset($response['errors'])) {
        $errors = is_array($response['errors']) ? 
            implode(', ', $response['errors']) : 
            $response['errors'];
        log_error("API error for $context: $errors");
        throw new Exception("API error: $errors");
    }
    
    return $response;
}

/**
 * Make an HTTP request to the Nexus3 API
 * @param array $config Configuration array containing API credentials
 * @param string $method HTTP method (GET, POST, PUT, DELETE)
 * @param string $endpoint API endpoint path
 * @param array|null $data Optional data to send with request
 * @return array Decoded JSON response
 * @throws Exception on network errors or invalid responses
 */
function make_api_request($config, $method, $endpoint, $data = null) {
    $baseUrl = rtrim($config['nexus3']['baseUrl'], '/');
    $url = $baseUrl . '/service/rest/' . ltrim($endpoint, '/');
    
    $ch = curl_init();
    curl_setopt($ch, CURLOPT_URL, $url);
    curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
    curl_setopt($ch, CURLOPT_USERPWD, $config['nexus3']['username'] . ":" . $config['nexus3']['password']);
    curl_setopt($ch, CURLOPT_HTTPHEADER, ['Content-Type: application/json']);

    if ($method === 'POST' || $method === 'PUT') {
        curl_setopt($ch, CURLOPT_CUSTOMREQUEST, $method);
        if ($data) {
            curl_setopt($ch, CURLOPT_POSTFIELDS, json_encode($data));
        }
    }

    $response = curl_exec($ch);
    $httpCode = curl_getinfo($ch, CURLINFO_HTTP_CODE);
    
    if (curl_errno($ch)) {
        $error = curl_error($ch);
        curl_close($ch);
        log_error("Curl error: $error");
        throw new Exception("Curl error: $error");
    }
    
    curl_close($ch);
    
    log_debug("Response code: $httpCode");
    log_debug("Response body: $response");

    if ($httpCode >= 400) {
        log_error("API request failed with code $httpCode: $response");
        throw new Exception("API request failed: $response");
    }

    $decoded = json_decode($response, true);
    if (json_last_error() !== JSON_ERROR_NONE) {
        log_error("JSON decode error: " . json_last_error_msg());
        throw new Exception("JSON decode error: " . json_last_error_msg());
    }

    return validate_api_response($decoded, $endpoint);
}

/**
 * Creation Functions
 * Functions for creating entities in Nexus3
 */

/**
 * Creates a privilege in Nexus 3
 * @param array $config Configuration array
 * @param array $privilegeData The privilege data to create
 * @param string|null $description Optional description
 * @return array API response
 * @throws Exception When privilege creation fails
 */
function create_privilege(array $config, array $privilegeData): void {
    if (empty($privilegeData['name'])) {
        throw new ValidationException('Privilege name is required');
    }

    if (empty($privilegeData['actions']) || !is_array($privilegeData['actions'])) {
        throw new ValidationException('Privilege actions must be a non-empty array');
    }

    $payload = [
        'name' => $privilegeData['name'],
        'description' => $privilegeData['description'] ?? $privilegeData['name'],
        'actions' => $privilegeData['actions'],
        'domain' => $privilegeData['domain'] ?? '*',
        'type' => 'application'
    ];

    try {
        make_api_request(
            $config,
            'POST',
            'v1/security/privileges',
            json_encode($payload)
        );
    } catch (Exception $e) {
        if (strpos($e->getMessage(), '422') !== false) {
            log_warning("Privilege {$privilegeData['name']} already exists, skipping");
            return;
        }
        throw new MigrationException(
            "Failed to create privilege {$privilegeData['name']}: " . $e->getMessage(),
            0,
            $e
        );
    }
}

/**
 * Create a repository in Nexus3
 * @param array $config Configuration array
 * @param string $type Repository type (hosted, proxy, group)
 * @param string $format Repository format (maven2, npm, etc.)
 * @param array $data Repository configuration data
 * @return array API response
 */
function create_repository(array $config, string $type, string $format, array $data): array {
    validate_repository_config($data, $type, $format);
    return make_api_request($config, 'POST', "v1/repositories/$format/$type", $data);
}

/**
 * Create a role in Nexus3
 * @param array $config Configuration array
 * @param array $data Role data
 * @return array API response
 */
function create_role($config, $data) {
    return make_api_request($config, 'POST', 'v1/security/roles', $data);
}

/**
 * Create a user in Nexus3
 * @param array $config Configuration array
 * @param array $data User data
 * @return array API response
 */
function create_user($config, $data) {
    return make_api_request($config, 'POST', 'v1/security/users', $data);
}

/**
 * Repository Configuration Functions
 * Handles repository-specific configurations and validations
 */

function get_repository_config($format, $type, $baseConfig) {
    $config = $baseConfig;
    
    switch ($format) {
        case 'maven2':
            $config['maven'] = [
                'versionPolicy' => 'RELEASE',
                'layoutPolicy' => 'STRICT'
            ];
            break;
            
        case 'npm':
            $config['npm'] = [
                'removeQuarantined' => true
            ];
            break;
            
        case 'docker':
            $config['docker'] = [
                'v1Enabled' => false,
                'forceBasicAuth' => true
            ];
            if ($type === 'proxy') {
                $config['dockerProxy'] = [
                    'indexType' => 'REGISTRY'
                ];
            }
            break;
            
        case 'nuget':
            if ($type === 'proxy') {
                $config['nugetProxy'] = [
                    'queryCacheItemMaxAge' => 3600
                ];
            }
            break;
            
        case 'pypi':
            if ($type === 'proxy') {
                $config['pypiProxy'] = [
                    'removeQuarantined' => true
                ];
            }
            break;
            
        case 'yum':
            if ($type === 'hosted') {
                $config['yum'] = [
                    'repodataDepth' => 0
                ];
            }
            break;
            
        case 'apt':
            if ($type === 'hosted') {
                $config['apt'] = [
                    'distribution' => 'bionic'
                ];
                $config['aptSigning'] = [
                    'keypair' => '',  // Add your keypair
                    'passphrase' => '' // Add your passphrase
                ];
            }
            break;
            
        case 'helm':
        case 'raw':
        case 'rubygems':
        case 'conan':
        case 'p2':
        case 'r':
        case 'conda':
        case 'gitlfs':
        case 'go':
            // These formats don't require special configuration
            break;
    }
    
    return $config;
}

/**
 * Create a hosted repository with format-specific configuration
 * @param array $config Configuration array
 * @param string $format Repository format
 * @param array $data Repository data
 * @return array API response
 */
function create_hosted_repository($config, $format, $data) {
    $repoConfig = get_repository_config($format, 'hosted', $data);
    return create_repository($config, 'hosted', $format, $repoConfig);
}

/**
 * Create a proxy repository with format-specific configuration
 * @param array $config Configuration array
 * @param string $format Repository format
 * @param array $data Repository data
 * @return array API response
 */
function create_proxy_repository($config, $format, $data) {
    $repoConfig = get_repository_config($format, 'proxy', $data);
    return create_repository($config, 'proxy', $format, $repoConfig);
}

/**
 * Create a group repository with format-specific configuration
 * @param array $config Configuration array
 * @param string $format Repository format
 * @param array $data Repository data
 * @return array API response
 */
function create_group_repository($config, $format, $data) {
    $repoConfig = get_repository_config($format, 'group', $data);
    return create_repository($config, 'group', $format, $repoConfig);
}

/**
 * Validation Functions
 * Input validation and data integrity checks
 */

function validate_required_fields(array $data, array $required): void {
    $missing = [];
    foreach ($required as $field) {
        if (!isset($data[$field]) || empty($data[$field])) {
            $missing[] = $field;
        }
    }
    if (!empty($missing)) {
        throw new InvalidArgumentException(
            'Missing required fields: ' . implode(', ', $missing)
        );
    }
}

/**
 * Validate repository configuration
 * @param array $data Repository configuration
 * @param string $type Repository type
 * @param string $format Repository format
 * @throws InvalidArgumentException if validation fails
 */
function validate_repository_config(array $data, string $type, string $format): void {
    $required = ['name', 'online', 'storage'];
    validate_required_fields($data, $required);

    if (!in_array($type, ['hosted', 'proxy', 'group'])) {
        throw new InvalidArgumentException("Invalid repository type: $type");
    }

    $supportedFormats = ['maven2', 'npm', 'nuget', 'docker', 'yum', 'pypi', 
        'raw', 'rubygems', 'apt', 'helm', 'conan', 'p2', 'r', 'conda', 
        'gitlfs', 'go'];

    if (!in_array($format, $supportedFormats)) {
        throw new InvalidArgumentException("Unsupported format: $format");
    }
}

/**
 * Validate API connectivity and version compatibility
 * @throws RuntimeException if API is incompatible
 */
function validate_api_version(array $config): void {
    $response = make_api_request($config, 'GET', 'v1/status');
    if (!isset($response['version'])) {
        throw new RuntimeException('Could not determine Nexus version');
    }
    
    if (version_compare($response['version'], '3.0.0', '<')) {
        throw new RuntimeException('Requires Nexus 3.0.0 or higher');
    }
}

/**
 * Validate repository format
 * @param string $format Repository format
 * @return bool True if format is supported, false otherwise
 */
function validate_repository_format(string $format): bool {
    $supportedFormats = [
        'maven2', 'npm', 'nuget', 'docker', 'yum', 'pypi',
        'raw', 'rubygems', 'apt', 'helm', 'conan', 'p2',
        'r', 'conda', 'gitlfs', 'go'
    ];
    return in_array(strtolower($format), $supportedFormats);
}

/**
 * Data Preparation Functions
 * Clean and format data for API requests
 */

function clean_string(string $value): string {
    return trim(strip_tags($value));
}

/**
 * Safely parse comma-separated string into array
 * @param string|null $value Value to parse
 * @return array Parsed values
 */
function parse_csv_string(?string $value): array {
    if (empty($value)) {
        return [];
    }
    return array_filter(
        array_map('trim', explode(',', $value)),
        function($v) { return !empty($v); }
    );
}

/**
 * Clean and sanitize data for API requests
 */
function sanitize_data(array $data): array {
    array_walk_recursive($data, function(&$value) {
        if (is_string($value)) {
            $value = trim(strip_tags($value));
        }
    });
    return $data;
}

/**
 * Prepare repository data for creation
 */
function prepare_repository_data(array $data): array {
    return [
        'name' => $data['name'],
        'online' => $data['exposed'] === 't',
        'storage' => [
            'blobStoreName' => BLOB_STORE_NAME,
            'strictContentTypeValidation' => true,
            'writePolicy' => match($data['writepolicy']) {
                'ALLOW_WRITE' => 'ALLOW',
                'ALLOW_WRITE_ONCE' => 'ALLOW_ONCE',
                default => 'DENY'
            }
        ]
    ];
}

/**
 * Prepare user data for creation
 */
function prepare_user_data(array $data): array {
    return [
        'userId' => $data['userid'],
        'firstName' => $data['firstname'],
        'lastName' => $data['lastname'],
        'emailAddress' => $data['email'],
        'password' => DEFAULT_PASSWORD,
        'status' => match(strtolower($data['status'])) {
            'active', 'enabled' => USER_STATUS_ACTIVE,
            'disabled' => USER_STATUS_DISABLED,
            'locked' => USER_STATUS_LOCKED,
            default => USER_STATUS_DISABLED
        },
        'roles' => parse_csv_string($data['roles'])
    ];
}

/**
 * Migration Helper Functions
 * Support functions for the migration process
 */

/**
 * Migrate a single item based on type
 * @param array $config Configuration array
 * @param string $type Item type (privileges, repositories, roles, users)
 * @param array $item Item data to migrate
 * @return array API response
 * @throws InvalidArgumentException for unknown types
 */
function migrate_item(array $config, string $type, array $item): array {
    $item = sanitize_data($item);
    
    return match($type) {
        'privileges' => create_privilege($config, $item),
        'repositories' => create_repository(
            $config,
            $item['repotype'],
            strtolower($item['format']),
            prepare_repository_data($item)
        ),
        'roles' => create_role($config, $item),
        'users' => create_user($config, prepare_user_data($item)),
        default => throw new InvalidArgumentException("Unknown migration type: $type")
    };
}

/**
 * Clean up resources and perform final tasks
 * @param PDO|null $dbh Database handle to close
 * @return void
 */
function cleanup(?PDO $dbh = null): void {
    if ($dbh) {
        $dbh = null;
    }
    if ($GLOBALS['log_file'] && file_exists($GLOBALS['log_file'])) {
        chmod($GLOBALS['log_file'], 0644);
    }
}

/**
 * Set up error handlers and logging
 * @return void
 */
function setup_error_handling(): void {
    set_error_handler(function($errno, $errstr, $errfile, $errline) {
        if (!(error_reporting() & $errno)) {
            return false;
        }
        log_error("PHP Error ($errno): $errstr in $errfile on line $errline");
        return true;
    });

    set_exception_handler(function($e) {
        log_error('Uncaught Exception: ' . $e->getMessage(), $e);
        cleanup();
        exit(1);
    });
}

/**
 * Repository Type Configuration Functions
 * Handle specific repository type configurations
 */

/**
 * Get repository type configuration
 * @param string $type Repository type
 * @param array $data Repository data
 * @return array Repository type configuration
 * @throws InvalidArgumentException if repository type is invalid
 */
function get_repository_type_config(string $type, array $data): array {
    return match($type) {
        'hosted' => [
            'storage' => [
                'blobStoreName' => BLOB_STORE_NAME,
                'strictContentTypeValidation' => true,
                'writePolicy' => $data['writePolicy'] ?? 'DENY'
            ]
        ],
        'proxy' => [
            'storage' => [
                'blobStoreName' => BLOB_STORE_NAME,
                'strictContentTypeValidation' => true
            ],
            'proxy' => [
                'remoteUrl' => $data['remoteUrl'],
                'contentMaxAge' => $data['contentMaxAge'] ?? DEFAULT_CACHE_TTL,
                'metadataMaxAge' => $data['metadataMaxAge'] ?? DEFAULT_CACHE_TTL
            ],
            'negativeCache' => [
                'enabled' => true,
                'timeToLive' => $data['negativeCacheTTL'] ?? DEFAULT_CACHE_TTL
            ]
        ],
        'group' => [
            'storage' => [
                'blobStoreName' => BLOB_STORE_NAME,
                'strictContentTypeValidation' => true
            ],
            'group' => [
                'memberNames' => $data['memberNames'] ?? []
            ]
        ],
        default => throw new InvalidArgumentException("Invalid repository type: $type")
    };
}

/**
 * Database Schema Validation Functions
 * Ensure database structure meets requirements
 */

/**
 * Validate database schema before migration
 * @throws RuntimeException if schema is invalid
 */
function validate_database_schema(PDO $dbh): void {
    $requiredTables = [
        'migration_nexus2_privileges',
        'migration_nexus2_repositories',
        'migration_nexus2_roles',
        'migration_nexus2_users'
    ];

    $foundTables = $dbh->query("
        SELECT tablename 
        FROM pg_catalog.pg_tables 
        WHERE schemaname='public'
    ")->fetchAll(PDO::FETCH_COLUMN);

    $missingTables = array_diff($requiredTables, $foundTables);
    if (!empty($missingTables)) {
        throw new RuntimeException(
            'Missing required tables: ' . implode(', ', $missingTables)
        );
    }
}
