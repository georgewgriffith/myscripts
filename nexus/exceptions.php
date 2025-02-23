<?php

/**
 * Custom Exception Classes for Nexus Migration
 * 
 * Provides specialized exception handling for the migration process.
 * Each exception type carries additional context data to help with debugging.
 * 
 * Exception Classes:
 * - MigrationException: Base exception class with context support
 *   Used for: Generic migration errors with additional context data
 * 
 * - ValidationException: For data validation failures
 *   Used for: Schema validation, data format validation, required field checks
 * 
 * - ApiException: For Nexus3 API communication issues
 *   Used for: Connection failures, authentication errors, invalid responses
 * 
 * - DatabaseException: For database operation failures
 *   Used for: Connection issues, query failures, transaction errors
 * 
 * - ConfigurationException: For configuration/environment issues
 *   Used for: Missing config values, invalid settings, environment problems
 * 
 * Usage Examples:
 * throw new ValidationException('Invalid repository format', ['format' => $format]);
 * throw new ApiException('API request failed', ['endpoint' => $url, 'status' => $code]);
 * throw new DatabaseException('Query failed', ['query' => $sql, 'params' => $params]);
 */

/**
 * Base exception class for migration operations
 * Adds context support to standard PHP exceptions
 */
class MigrationException extends Exception {
    /**
     * @var array Additional context data for the exception
     */
    protected $context;
    
    /**
     * @param string $message Error message
     * @param array $context Additional error context data
     * @param int $code Error code
     * @param Exception|null $previous Previous exception if any
     */
    public function __construct($message, $context = [], $code = 0, Exception $previous = null) {
        $this->context = $context;
        parent::__construct($message, $code, $previous);
    }
    
    /**
     * @return array Context data associated with the exception
     */
    public function getContext() {
        return $this->context;
    }
}

/**
 * For data validation failures during migration
 */
class ValidationException extends MigrationException {}

/**
 * For API communication errors with Nexus3
 */
class ApiException extends MigrationException {}

/**
 * For database operation failures
 */
class DatabaseException extends MigrationException {}

/**
 * For configuration and environment issues
 */
class ConfigurationException extends MigrationException {}
