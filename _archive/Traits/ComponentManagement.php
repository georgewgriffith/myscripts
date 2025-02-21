<?php
declare(strict_types=1);

namespace Nexus3\Traits;

trait ComponentManagement {
    /**
     * Search components
     */
    public function searchComponents(array $params = []): array {
        return $this->request('GET', '/v1/search', null, $params);
    }

    /**
     * Get component by ID
     */
    public function getComponent(string $id): array {
        return $this->request('GET', "/v1/components/$id");
    }

    /**
     * Delete component
     */
    public function deleteComponent(string $id): array {
        return $this->request('DELETE', "/v1/components/$id");
    }

    /**
     * Upload component
     */
    public function uploadComponent(string $repository, array $files, array $coordinates): array {
        $ch = curl_init();
        
        $url = $this->baseUrl . "/v1/components?repository=" . urlencode($repository);
        
        $postFields = [];
        foreach ($files as $type => $path) {
            $postFields[$type] = new \CURLFile($path);
        }
        
        foreach ($coordinates as $key => $value) {
            $postFields[$key] = $value;
        }

        curl_setopt_array($ch, [
            CURLOPT_URL => $url,
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_HTTPHEADER => [
                "Authorization: Basic {$this->authToken}",
                "Accept: application/json"
            ],
            CURLOPT_POST => true,
            CURLOPT_POSTFIELDS => $postFields
        ]);

        $response = curl_exec($ch);
        $httpCode = curl_getinfo($ch, CURLINFO_HTTP_CODE);
        
        if ($response === false) {
            $error = curl_error($ch);
            curl_close($ch);
            throw new \RuntimeException("Component upload failed: $error");
        }
        
        curl_close($ch);
        
        return [
            $httpCode,
            !empty($response) ? json_decode($response, true) : null
        ];
    }
}
