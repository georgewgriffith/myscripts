<?php
return [
    'nexus' => [
        'base_url' => getenv('NEXUS_API_URL') ?: 'http://localhost:8081',
        'username' => getenv('NEXUS_USERNAME') ?: 'admin',
        'password' => getenv('NEXUS_PASSWORD') ?: 'admin123',
    ],
    'logging' => [
        'enabled' => true,
        'file' => __DIR__ . '/logs/nexus-api.log',
    ],
    'timeout' => 30,
    'verify_ssl' => true,
];
