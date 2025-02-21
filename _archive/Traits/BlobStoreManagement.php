<?php
declare(strict_types=1);

namespace Nexus3\Traits;

trait BlobStoreManagement {
    /**
     * List blob stores
     */
    public function listBlobStores(): array {
        return $this->request('GET', '/v1/blobstores');
    }

    /**
     * Create file blob store
     */
    public function createFileBlobStore(string $name, string $path): array {
        $data = [
            'name' => $name,
            'path' => $path,
            'type' => 'File'
        ];
        return $this->request('POST', '/v1/blobstores/file', $data);
    }

    /**
     * Create S3 blob store
     */
    public function createS3BlobStore(string $name, array $config): array {
        $config['name'] = $name;
        return $this->request('POST', '/v1/blobstores/s3', $config);
    }

    /**
     * Delete blob store
     */
    public function deleteBlobStore(string $name): array {
        return $this->request('DELETE', "/v1/blobstores/$name");
    }

    /**
     * Get quota status
     */
    public function getBlobStoreQuotaStatus(string $name): array {
        return $this->request('GET', "/v1/blobstores/$name/quota-status");
    }
}
