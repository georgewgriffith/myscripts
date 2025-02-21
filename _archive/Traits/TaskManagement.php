<?php
declare(strict_types=1);

namespace Nexus3\Traits;

trait TaskManagement {
    /**
     * List tasks
     */
    public function getTasks(): array {
        return $this->request('GET', '/v1/tasks');
    }

    /**
     * Get task by ID
     */
    public function getTask(string $id): array {
        return $this->request('GET', "/v1/tasks/$id");
    }

    /**
     * Run task
     */
    public function runTask(string $id): array {
        return $this->request('POST', "/v1/tasks/$id/run");
    }

    /**
     * Stop task
     */
    public function stopTask(string $id): array {
        return $this->request('POST', "/v1/tasks/$id/stop");
    }
}
