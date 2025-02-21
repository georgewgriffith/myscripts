<?php
declare(strict_types=1);

namespace Nexus3;

use Nexus3\Traits\SecurityManagement;
use Nexus3\Traits\RepositoryManagement;
use Nexus3\Traits\ComponentManagement;
use Nexus3\Traits\BlobStoreManagement;
use Nexus3\Traits\TaskManagement;

class Nexus3Api {
    use SecurityManagement;
    use RepositoryManagement;
    use ComponentManagement;
    use BlobStoreManagement;
    use TaskManagement;

    private string $baseUrl;
    private string $authToken;
    private array $defaultHeaders;
    
    public function __construct(string $baseUrl, string $username, string $password) {
        $this->baseUrl = rtrim($baseUrl, '/');
        $this->authToken = base64_encode("$username:$password");
        $this->defaultHeaders = [
            "Authorization: Basic {$this->authToken}",
            "Content-Type: application/json",
            "Accept: application/json"
        ];
    }

    /**
     * Makes an HTTP request to the Nexus API
     * 
     * @param string $method HTTP method (GET, POST, PUT, DELETE)
     * @param string $endpoint API endpoint
     * @param array|null $data Request payload
     * @param array $queryParams Optional query parameters
     * @return array [int $statusCode, array|null $response]
     * @throws \RuntimeException If the request fails
     */
    protected function request(
        string $method,
        string $endpoint,
        ?array $data = null,
        array $queryParams = []
    ): array {
        $ch = curl_init();
        $url = $this->baseUrl . $endpoint;
        
        if (!empty($queryParams)) {
            $url .= '?' . http_build_query($queryParams);
        }

        $options = [
            CURLOPT_URL => $url,
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_HTTPHEADER => $this->defaultHeaders,
            CURLOPT_CUSTOMREQUEST => strtoupper($method),
            CURLOPT_TIMEOUT => 30,
            CURLOPT_FOLLOWLOCATION => true,
        ];

        if ($data !== null) {
            $options[CURLOPT_POSTFIELDS] = json_encode($data);
        }

        curl_setopt_array($ch, $options);

        $response = curl_exec($ch);
        $httpCode = curl_getinfo($ch, CURLINFO_HTTP_CODE);
        
        if ($response === false) {
            $error = curl_error($ch);
            curl_close($ch);
            throw new \RuntimeException("API request failed: $error");
        }
        
        curl_close($ch);
        
        return [
            $httpCode,
            !empty($response) ? json_decode($response, true) : null
        ];
    }

    /**
     * System Management Methods
     */

    public function getSystemStatus(): array {
        return $this->request('GET', '/v1/status');
    }

    public function isWritable(): array {
        return $this->request('GET', '/v1/status/writable');
    }

    public function getSystemInformation(): array {
        return $this->request('GET', '/beta/system/information');
    }

    /**
     * Support Methods
     */

    public function generateSupportZip(array $options = []): array {
        return $this->request('POST', '/v1/support/supportzip', $options);
    }

    /**
     * Email Configuration Methods
     */

    public function getEmailConfig(): array {
        return $this->request('GET', '/v1/email');
    }

    public function updateEmailConfig(array $config): array {
        return $this->request('PUT', '/v1/email', $config);
    }

    public function verifyEmailConfig(string $email): array {
        return $this->request('POST', '/v1/email/verify', ['email' => $email]);
    }

    /**
     * License Management Methods
     */

    public function getLicenseStatus(): array {
        return $this->request('GET', '/v1/system/license');
    }

    public function installLicense(string $licenseContent): array {
        return $this->request('POST', '/v1/system/license', ['license' => $licenseContent]);
    }

    public function removeLicense(): array {
        return $this->request('DELETE', '/v1/system/license');
    }
}
