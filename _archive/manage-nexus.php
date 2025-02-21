<?php
require_once __DIR__ . '/Nexus3Api.php';

try {
    $config = require __DIR__ . '/config.php';
    
    $nexus = new Nexus3\Nexus3Api(
        $config['nexus']['base_url'],
        $config['nexus']['username'],
        $config['nexus']['password']
    );

    // Example: Create a new user
    $userData = [
        'userId' => 'john.doe',
        'firstName' => 'John',
        'lastName' => 'Doe',
        'emailAddress' => 'john.doe@example.com',
        'password' => 'secure123',
        'roles' => ['nx-admin']
    ];

    [$status, $response] = $nexus->createUser($userData);
    echo "Create user response: " . json_encode($response, JSON_PRETTY_PRINT) . "\n";

    // Example: Create a Maven proxy repository
    $repoData = [
        'name' => 'maven-central-proxy',
        'online' => true,
        'storage' => [
            'blobStoreName' => 'default',
            'strictContentTypeValidation' => true
        ],
        'proxy' => [
            'remoteUrl' => 'https://repo1.maven.org/maven2/',
            'contentMaxAge' => 1440,
            'metadataMaxAge' => 1440
        ]
    ];

    [$status, $response] = $nexus->createRepository('maven2', 'proxy', $repoData);
    echo "Create repository response: " . json_encode($response, JSON_PRETTY_PRINT) . "\n";

} catch (\Exception $e) {
    echo "Error: " . $e->getMessage() . "\n";
    exit(1);
}
