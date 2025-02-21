<?php

// Load environment variables
$nexus_api_url = getenv('NEXUS3_API_URL');
$nexus_auth = getenv('NEXUS_AUTH'); // Base64 encoded "user:password"
$pg_host = getenv('PGHOST');
$pg_user = getenv('PGUSER');
$pg_port = getenv('PGPORT');
$pg_db = getenv('PGDATABASE');
$pg_password = getenv('PGPASSWORD');

// Establish PostgreSQL connection
$dsn = "pgsql:host=$pg_host;port=$pg_port;dbname=$pg_db;";
try {
    $pdo = new PDO($dsn, $pg_user, $pg_password, [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
} catch (PDOException $e) {
    die("Database connection failed: " . $e->getMessage());
}

// Function to make API requests
function nexus_api_request(string $method, string $endpoint, array $data = null)
{
    global $nexus_api_url, $nexus_auth;

    $ch = curl_init();
    $url = rtrim($nexus_api_url, '/') . $endpoint;

    $headers = [
        "Authorization: Basic $nexus_auth",
        "Content-Type: application/json",
        "Accept: application/json"
    ];

    $options = [
        CURLOPT_URL => $url,
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_HTTPHEADER => $headers,
        CURLOPT_CUSTOMREQUEST => strtoupper($method),
        CURLOPT_TIMEOUT => 5,
        CURLOPT_FOLLOWLOCATION => true,
    ];

    if (!empty($data)) {
        $options[CURLOPT_POSTFIELDS] = json_encode($data);
    }

    curl_setopt_array($ch, $options);

    $response = curl_exec($ch);
    $http_code = curl_getinfo($ch, CURLINFO_HTTP_CODE);
    curl_close($ch);

    return [$http_code, json_decode($response, true)];
}

// Function to migrate users
function migrate_users(PDO $pdo)
{
    $stmt = $pdo->query("SELECT username, first_name, last_name, email, password, roles FROM users");
    while ($row = $stmt->fetch(PDO::FETCH_ASSOC)) {
        $user_data = [
            "status" => "disabled",
            "userId" => $row["username"],
            "firstName" => $row["first_name"],
            "lastName" => $row["last_name"],
            "emailAddress" => $row["email"],
            "password" => $row["password"], // Ensure secure handling
            "roles" => explode(',', $row["roles"]),
        ];

        list($http_code, $response) = nexus_api_request("POST", "/v1/security/users", $user_data);
        echo "User {$row['username']} -> HTTP $http_code\n";
    }
}

// DRY Repository Creation Function (Supports Hosted, Proxy, and Group)
function create_repository(string $name, string $format, string $type, array $extra_data = [])
{
    $valid_formats = ['maven2', 'npm', 'nuget', 'raw', 'docker', 'pypi', 'rubygems', 'helm', 'apt', 'cocoapods', 'gitlfs', 'go', 'bower', 'conan', 'yum', 'r'];
    $valid_types = ['hosted', 'proxy', 'group'];

    if (!in_array(strtolower($format), $valid_formats) || !in_array(strtolower($type), $valid_types)) {
        echo "Unsupported repository format/type: $format ($type)\n";
        return;
    }

    $endpoint = "/v1/repositories/$format/$type";
    
    // Common repository structure
    $data = array_merge([
        "name" => $name,
        "online" => true,
        "storage" => [
            "blobStoreName" => "default",
            "strictContentTypeValidation" => true
        ]
    ], $extra_data);

    list($http_code, $response) = nexus_api_request("POST", $endpoint, $data);
    echo ucfirst($format) . " $type Repository $name -> HTTP $http_code\n";
}

// Function to migrate repositories
function migrate_repositories(PDO $pdo)
{
    $stmt = $pdo->query("SELECT name, format, type, group_members, remote_url FROM repositories");
    while ($row = $stmt->fetch(PDO::FETCH_ASSOC)) {
        $extra_data = [];

        if ($row["type"] === "proxy" && !empty($row["remote_url"])) {
            $extra_data["proxy"] = [
                "remoteUrl" => $row["remote_url"],
                "contentMaxAge" => 1440,
                "metadataMaxAge" => 1440
            ];
        }

        if ($row["type"] === "group" && !empty($row["group_members"])) {
            $extra_data["group"] = [
                "memberNames" => explode(',', $row["group_members"])
            ];
        }

        create_repository($row["name"], $row["format"], $row["type"], $extra_data);
    }
}

// Run migration tasks
migrate_users($pdo);
migrate_repositories($pdo);

echo "Migration completed!\n";
?>
