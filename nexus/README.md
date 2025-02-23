# Nexus2 to Nexus3 Migration Tool

⚠️ **WARNING: USE AT YOUR OWN RISK**
This code is provided as-is without any warranties. Always backup your data before migration.
The authors and contributors are not responsible for any data loss or system damage.

## Overview

Automated migration tool to transfer configuration and metadata from Nexus2 to Nexus3.

### What it Migrates
- Privileges and permissions (including custom privileges)
- Repository configurations:
  - Hosted repositories with write policies
  - Proxy repositories with cache settings
  - Group repositories with member relationships
  - Format-specific configurations
  - SSL/TLS settings per repository
- User accounts:
  - Basic information (username, email, etc.)
  - Role assignments
  - Account status
  - User-specific settings
- Roles and permissions:
  - Role hierarchies
  - Privilege assignments
  - Role properties
  - Custom roles

### What it Doesn't Migrate
- Repository contents/artifacts (must be migrated separately)
- Scheduled tasks and their configurations
- Custom SSL certificates and keystores
- LDAP/Active Directory configurations
- Email server settings
- Webhook configurations
- Custom routing rules
- Anonymous access settings
- Custom realms
- Metrics collection settings

### Assumptions
1. Source Database:
   - PostgreSQL database containing Nexus2 data
   - All required tables present and populated
   - Read access available
   - Data integrity maintained

2. Target System:
   - Clean Nexus3 installation
   - Admin access available
   - API accessible
   - Sufficient storage space
   - Required blob stores exist

3. Network:
   - Stable connection to both systems
   - Required ports accessible
   - Sufficient bandwidth

4. Environment:
   - PHP 8.0+ installed
   - Required extensions available
   - Sufficient memory allocated
   - Write permissions for logs

### Prerequisites

#### System Requirements
1. Hardware:
   - CPU: 2+ cores recommended
   - RAM: 4GB minimum, 8GB recommended
   - Storage: 1GB free space for logs
   - Network: Stable connection to both systems

2. Software:
   - PHP 8.0 or higher
   - PostgreSQL client libraries
   - Nexus3 3.0.0 or higher
   - Git (for installation)

3. PHP Extensions:
   - pdo: Database abstraction
   - pdo_pgsql: PostgreSQL driver
   - curl: API communication
   - json: Data processing
   - mbstring: String handling
   - openssl: Secure communication

#### Database Access
1. Required Permissions:
   - SELECT on all migration tables
   - CONNECT to database
   - USAGE on schema

2. Required Tables:
   ```sql
   migration_nexus2_privileges
   migration_nexus2_repositories
   migration_nexus2_roles
   migration_nexus2_users
   ```

3. Table Relationships:
   - Privilege mappings
   - Role hierarchies
   - User-role assignments
   - Repository group memberships

#### Nexus3 Access
1. API Requirements:
   - Admin user credentials
   - API enabled and accessible
   - Script host has network access
   - Required ports open (default: 8081)

2. System Requirements:
   - Running and responsive
   - Sufficient storage space
   - Default blob store configured
   - No conflicting configurations

### Installation

1. Clone Repository:
   ```bash
   git clone https://your-repo/nexus-migration.git
   cd nexus-migration
   ```

2. Configure Environment:
   ```bash
   cp .env.example .env
   chmod 600 .env  # Secure credentials
   ```

3. Edit Configuration:
   ```bash
   # Database settings
   DB_HOST=your-db-host
   DB_PORT=5432
   DB_NAME=nexus2
   DB_USER=your-user
   DB_PASS=your-password

   # Nexus3 settings
   NEXUS3_URL=http://your-nexus3:8081
   NEXUS3_USER=admin
   NEXUS3_PASS=your-admin-password
   ```

4. Create Log Directory:
   ```bash
   mkdir -p logs
   chmod 755 logs
   ```

5. Verify Permissions:
   ```bash
   chmod +x migrate.php
   ```

### Pre-Migration Checklist

1. System Verification:
   - [ ] PHP version checked
   - [ ] Extensions installed
   - [ ] Memory limits configured
   - [ ] Disk space verified

2. Database Preparation:
   - [ ] Full backup created
   - [ ] Tables verified
   - [ ] Permissions granted
   - [ ] Data integrity checked

3. Nexus3 Preparation:
   - [ ] System backed up
   - [ ] API accessible
   - [ ] Blob stores created
   - [ ] Space available

4. Network Verification:
   - [ ] Database accessible
   - [ ] Nexus3 reachable
   - [ ] Ports open
   - [ ] Bandwidth available

5. Configuration Review:
   - [ ] Environment variables set
   - [ ] Paths configured
   - [ ] Credentials verified
   - [ ] Options reviewed

### Verification

Before running the migration, verify your environment:

### Running the Migration

1. Dry Run (Optional):
   ```bash
   php migrate.php --dry-run
   ```

2. Full Migration:
   ```bash
   php migrate.php
   ```

3. Debug Mode:
   ```bash
   php migrate.php --debug
   ```

### Post-Migration Tasks

1. Verification:
   - [ ] Check migration logs
   - [ ] Verify privilege mappings
   - [ ] Test repository access
   - [ ] Validate user logins

2. Security:
   - [ ] Update user passwords
   - [ ] Review permissions
   - [ ] Verify SSL settings
   - [ ] Check anonymous access

3. Cleanup:
   - [ ] Archive logs
   - [ ] Secure credentials
   - [ ] Remove temporary files
   - [ ] Update documentation

### Troubleshooting

1. Database Issues:
   - Connection failures
   - Permission errors
   - Schema mismatches
   - Data integrity issues

2. API Problems:
   - Authentication failures
   - Connection timeouts
   - Invalid responses
   - Version mismatches

3. Common Errors:
   ```
   Error: Database connection failed
   Solution: Check credentials and network

   Error: API request failed
   Solution: Verify Nexus3 is running and accessible

   Error: Invalid schema
   Solution: Verify table structure matches requirements
   ```

### Support and Contributing

1. Getting Help:
   - GitHub Issues
   - Documentation
   - Community forums

2. Contributing:
   - Fork repository
   - Create feature branch
   - Submit pull request
   - Follow coding standards

### License

MIT License
See LICENSE file for details.

### Disclaimer

THIS SOFTWARE IS PROVIDED "AS IS" WITHOUT WARRANTY OF ANY KIND.
USE AT YOUR OWN RISK.
ALWAYS BACKUP YOUR DATA BEFORE MIGRATION.
