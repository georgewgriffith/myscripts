<?php

// Global configuration for logging
$GLOBALS['debug_mode'] = false;  // Controls verbose debug output
$GLOBALS['log_file'] = null;     // Path to log file

/**
 * Initialize the logging system
 * @param string $log_file Path to the log file
 * @param bool $debug_mode Enable verbose debug logging
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
 * Log an error message with optional exception details
 * @param string $message Error message to log
 * @param Exception|null $exception Optional exception to include in log
 */
function log_error($message, $exception = null) {
    $logMessage = "[ERROR] $message";
    if ($exception) {
        $logMessage .= "\nException: " . $exception->getMessage();
        $logMessage .= "\nStack trace: " . $exception->getTraceAsString();
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
 * Validate API response for errors
 * @param mixed $response The API response to validate
 * @param string $context Description of the API call for error messages
 * @return mixed Validated response
 * @throws Exception if response is empty or contains errors
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
    
    log_debug("Making $method request to: $url");
    if ($data) {
        log_debug("Request data: " . json_encode($data, JSON_PRETTY_PRINT));
    }
    
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
 * Create a privilege in Nexus3
 * @param array $config Configuration array
 * @param array $data Privilege data
 * @return array API response
 */
function create_privilege($config, $data) {
    return make_api_request($config, 'POST', 'v1/security/privileges/application', $data);
}

/**
 * Create a repository in Nexus3
 * @param array $config Configuration array
 * @param string $type Repository type (hosted, proxy, group)
 * @param string $format Repository format (maven2, npm, etc.)
 * @param array $data Repository configuration data
 * @return array API response
 */
function create_repository($config, $type, $format, $data) {
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
 * Get repository configuration based on format and type
 * Applies format-specific settings and validations
 * @param string $format Repository format
 * @param string $type Repository type
 * @param array $baseConfig Base configuration to extend
 * @return array Complete repository configuration
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
 * Validate array data against required fields
 * @param array $data Data to validate
 * @param array $required Required field names
 * @throws InvalidArgumentException if validation fails
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
 * Clean and normalize string values
 * @param string $value Value to clean
 * @return string Cleaned value
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
