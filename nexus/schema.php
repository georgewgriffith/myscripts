<?php

/**
 * Nexus2 Migration Schema Definition
 * 
 * This file defines the required database schema for migration tables.
 * Each array represents a table structure with its required columns.
 * Used for validation before migration begins.
 * 
 * Tables:
 * 
 * 1. migration_nexus2_privileges
 *    - uuid: Unique identifier (primary key)
 *    - id: Legacy Nexus2 ID
 *    - resourceuri: Resource path or pattern
 *    - name: Privilege name
 *    - description: Privilege description
 *    - type: Privilege type (target, application)
 *    - usermanaged: User management flag
 *    - dateadded, dateupdated: Timestamps
 *    - properties_checksum: Configuration checksum
 *    - properties: Additional settings
 * 
 * 2. migration_nexus2_repositories
 *    - uuid: Unique identifier (primary key)
 *    - id: Legacy Nexus2 ID
 *    - name: Repository name
 *    - type: Repository type
 *    - format: Repository format (maven2, npm, etc)
 *    - exposed: Public visibility flag
 *    - repotype: Repository classification (hosted, proxy, group)
 *    - contentresourceuri: Remote URL for proxies
 *    - writepolicy: Write access policy
 *    - notfoundcachett: Cache TTL for 404s
 * 
 * 3. migration_nexus2_roles
 *    - uuid: Unique identifier (primary key)
 *    - id: Legacy Nexus2 ID
 *    - name: Role name
 *    - description: Role description
 *    - sessiontimeout: Session timeout value
 *    - roles: Nested role assignments
 *    - privileges: Assigned privileges
 *    - dateadded, dateupdated: Timestamps
 *    - usermanaged: User management flag
 * 
 * 4. migration_nexus2_users
 *    - uuid: Unique identifier (primary key)
 *    - id: Legacy Nexus2 ID
 *    - userid: Username
 *    - firstname, lastname: User's name
 *    - email: Email address
 *    - status: Account status
 *    - roles: Assigned roles
 * 
 * Usage:
 * This schema is used to validate the source database structure
 * before migration begins. It ensures all required columns are
 * present and properly named.
 */

return [
    'migration_nexus2_privileges' => [
        'uuid', 'id', 'resourceuri', 'name', 'description', 'type',
        'usermanaged', 'dateadded', 'dateupdated', 'properties_checksum',
        'properties'
    ],
    'migration_nexus2_repositories' => [
        'uuid', 'id', 'name', 'type', 'format', 'exposed', 'repotype',
        'contentresourceuri', 'writepolicy', 'notfoundcachett'
    ],
    'migration_nexus2_roles' => [
        'uuid', 'id', 'name', 'description', 'sessiontimeout',
        'roles', 'privileges', 'dateadded', 'dateupdated', 'usermanaged'
    ],
    'migration_nexus2_users' => [
        'uuid', 'id', 'userid', 'firstname', 'lastname', 'email',
        'status', 'roles'
    ]
];
