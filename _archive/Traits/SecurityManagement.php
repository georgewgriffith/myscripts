<?php
declare(strict_types=1);

namespace Nexus3\Traits;

trait SecurityManagement {
    /**
     * Gets a list of privileges
     * 
     * @return array Response from API
     */
    public function getPrivileges(): array {
        return $this->request('GET', '/v1/security/privileges');
    }

    /**
     * Creates a new privilege
     * 
     * @param string $type Privilege type (application, wildcard, etc.)
     * @param array $privilegeData Privilege configuration
     * @return array Response from API
     */
    public function createPrivilege(string $type, array $privilegeData): array {
        $validTypes = ['application', 'wildcard', 'repository-admin', 'repository-view', 'script'];
        
        if (!in_array($type, $validTypes)) {
            throw new \InvalidArgumentException("Invalid privilege type: $type");
        }

        return $this->request('POST', "/v1/security/privileges/$type", $privilegeData);
    }

    /**
     * Updates realm settings
     * 
     * @param array $realms List of realm IDs in desired order
     * @return array Response from API
     */
    public function updateRealms(array $realms): array {
        return $this->request('PUT', '/v1/security/realms/active', $realms);
    }

    // ... Additional security-related methods
}
