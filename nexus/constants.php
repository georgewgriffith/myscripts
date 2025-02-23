<?php

/**
 * Global Constants for Nexus Migration
 * 
 * This file defines all global constants used throughout the migration process.
 * Constants are organized by category for easy maintenance and clarity.
 * 
 * Categories:
 * - Default Values: System-wide default settings
 * - Repository Types: Valid repository classification types
 * - User Status Codes: Valid user account states
 * - Repository Formats: Supported repository format types
 * - HTTP Methods: Standard HTTP method constants
 * 
 * Usage:
 * These constants are used across the application to:
 * - Ensure consistent values
 * - Validate input data
 * - Configure repositories
 * - Set up user accounts
 * - Define API endpoints
 */

/**
 * Default Values
 * Used for initial setup and fallback configurations
 */
const DEFAULT_PASSWORD = 'changeme123';    // Default password for migrated users
const DEFAULT_CACHE_TTL = 1440;           // Default cache time-to-live (in minutes)
const BLOB_STORE_NAME = 'default';        // Default blob store for repositories
const BATCH_SIZE = 50;                    // Number of items to process in each batch

/**
 * Repository Types
 * Valid types for repository classification
 */
const REPO_TYPE_HOSTED = 'hosted';        // Local storage repositories
const REPO_TYPE_PROXY = 'proxy';          // Remote proxy repositories
const REPO_TYPE_GROUP = 'group';          // Repository groups

/**
 * User Status Codes
 * Valid states for user accounts
 */
const USER_STATUS_ACTIVE = 'active';      // User can log in and access resources
const USER_STATUS_DISABLED = 'disabled';   // User account is disabled
const USER_STATUS_LOCKED = 'locked';      // User account is temporarily locked

/**
 * Repository Formats
 * Supported repository format types for migration
 */
const SUPPORTED_FORMATS = [
    'maven2',    // Maven repositories
    'npm',       // Node Package Manager
    'nuget',     // .NET package manager
    'docker',    // Container images
    'yum',       // RPM packages
    'pypi',      // Python packages
    'raw',       // Raw/generic content
    'rubygems',  // Ruby packages
    'apt',       // Debian packages
    'helm',      // Kubernetes packages
    'conan',     // C/C++ package manager
    'p2',        // Eclipse plugins
    'r',         // R language packages
    'conda',     // Conda packages
    'gitlfs',    // Git Large File Storage
    'go'         // Go packages
];

/**
 * HTTP Methods
 * Standard HTTP method constants for API requests
 */
const HTTP_GET = 'GET';          // Retrieve resources
const HTTP_POST = 'POST';        // Create new resources
const HTTP_PUT = 'PUT';          // Update existing resources
const HTTP_DELETE = 'DELETE';    // Remove resources
