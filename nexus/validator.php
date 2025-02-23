<?php

/**
 * Data validation functions
 */

function validate_config(array $config): void {
    $required = ['db', 'nexus3', 'settings'];
    foreach ($required as $section) {
        if (!isset($config[$section])) {
            throw new ConfigurationException("Missing required config section: $section");
        }
    }
    
    validate_db_config($config['db']);
    validate_nexus_config($config['nexus3']);
    validate_settings($config['settings']);
}

function validate_db_config(array $db): void {
    $required = ['host', 'dbname', 'user', 'password'];
    foreach ($required as $field) {
        if (!isset($db[$field])) {
            throw new ConfigurationException("Missing required database config: $field");
        }
    }
}

function validate_nexus_config(array $nexus): void {
    $required = ['baseUrl', 'username', 'password'];
    foreach ($required as $field) {
        if (!isset($nexus[$field])) {
            throw new ConfigurationException("Missing required Nexus config: $field");
        }
    }
    
    if (!filter_var($nexus['baseUrl'], FILTER_VALIDATE_URL)) {
        throw new ConfigurationException("Invalid Nexus baseUrl");
    }
}

function validate_repository(array $data, string $type, string $format): void {
    if (!in_array($type, [REPO_TYPE_HOSTED, REPO_TYPE_PROXY, REPO_TYPE_GROUP])) {
        throw new ValidationException("Invalid repository type: $type");
    }
    
    if (!in_array($format, SUPPORTED_FORMATS)) {
        throw new ValidationException("Unsupported repository format: $format");
    }
    
    $required = ['name', 'online', 'storage'];
    foreach ($required as $field) {
        if (!isset($data[$field])) {
            throw new ValidationException("Missing required repository field: $field");
        }
    }
}
