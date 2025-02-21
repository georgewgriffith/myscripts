<?php
declare(strict_types=1);

namespace Nexus3\Traits;

trait RepositoryManagement {
    /**
     * Get repository details
     */
    public function getRepository(string $name): array {
        return $this->request('GET', "/v1/repositories/$name");
    }

    /**
     * List all repositories
     */
    public function getRepositories(): array {
        return $this->request('GET', '/v1/repositories');
    }

    /**
     * Rebuild repository index
     */
    public function rebuildIndex(string $repositoryName): array {
        return $this->request('POST', "/v1/repositories/$repositoryName/rebuild-index");
    }

    /**
     * Invalidate repository cache
     */
    public function invalidateCache(string $repositoryName): array {
        return $this->request('POST', "/v1/repositories/$repositoryName/invalidate-cache");
    }

    /**
     * Get repository health check status
     */
    public function getHealthCheck(string $repositoryName): array {
        return $this->request('GET', "/v1/repositories/$repositoryName/health-check");
    }
}
