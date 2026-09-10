<?php

declare(strict_types=1);

/**
 * HTTP bridge for the Avorion Automation API.
 *
 * The mod cannot open a socket, so it speaks JSON over files in the galaxy's moddata
 * folder. This turns HTTP into those files and back. It holds no logic of its own:
 * routing, auth, validation and serialization all happen inside the mod.
 *
 * See docs/protocol.md for the transport and docs/external.md for the rules below.
 */

// The mod polls 5x/second, so this is well inside its own latency floor.
const POLL_US = 50000;

// The mod answers 504 itself at 20s; stay above that so its answer wins the race.
const TIMEOUT = 30.0;

// Waiting on a file is not CPU time, but do not let the runtime cut a call short.
set_time_limit(120);

$galaxy = rtrim(getenv('GALAXY_DIR') ?: '/galaxy', '/');
$root = $galaxy . '/moddata/AutomationAPI';
$requestDir = $root . '/requests';
$responseDir = $root . '/responses';

/**
 * Cross-origin access, so a browser page - the bundled console, or anything else - can
 * call the API directly.
 *
 * This is safe to leave open because the credential is a header, never a cookie: a
 * browser sends no key of its own, so a hostile page reaches exactly what an ordinary
 * HTTP client already reaches. Credentialed requests are refused outright, which is what
 * keeps that true. Set CORS_ORIGIN to a specific origin, or to an empty string to turn
 * the headers off entirely.
 */
function cors(): void
{
    $origin = getenv('CORS_ORIGIN');
    if ($origin === false) {
        $origin = '*';
    }
    if ($origin === '') {
        return;
    }

    header('Access-Control-Allow-Origin: ' . $origin);
    header('Access-Control-Allow-Methods: GET, POST, OPTIONS');
    header('Access-Control-Allow-Headers: Content-Type, X-API-Key, Authorization');
    header('Access-Control-Max-Age: 86400');

    // A named origin means the answer varies by it, so caches have to be told.
    if ($origin !== '*') {
        header('Vary: Origin');
    }
}

function reply(int $status, mixed $body): never
{
    http_response_code($status);
    cors();
    header('Content-Type: application/json');
    echo json_encode($body, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
    exit;
}

function fail(int $status, string $code, string $message): never
{
    reply($status, ['error' => ['code' => $code, 'message' => $message]]);
}

$method = $_SERVER['REQUEST_METHOD'] ?? 'GET';

// The console sends X-API-Key, which is not a CORS-safelisted header, so every call is
// preflighted. Answer it before the key check - a preflight carries no key by design.
if ($method === 'OPTIONS') {
    http_response_code(204);
    cors();
    exit;
}

if ($method !== 'GET' && $method !== 'POST') {
    fail(405, 'method_not_allowed', 'The API speaks GET and POST only.');
}

if (!is_dir($requestDir)) {
    fail(503, 'bridge_unavailable', 'No request directory in the galaxy folder - is the mod loaded?');
}

// Take the key from a header rather than the URL so it stays out of access logs, and
// never hold one here: a key is a player, and the mod acts as whoever it belongs to.
$key = $_SERVER['HTTP_X_API_KEY'] ?? '';
if ($key === '') {
    $authorization = $_SERVER['HTTP_AUTHORIZATION'] ?? '';
    if (str_starts_with($authorization, 'Bearer ')) {
        $key = substr($authorization, 7);
    }
}
if ($key === '') {
    fail(401, 'unauthorized', 'Missing X-API-Key header.');
}

$uri = $_SERVER['REQUEST_URI'] ?? '/';

// Stays percent-encoded, which is what the mod expects - it decodes each segment
// itself, so ship names with spaces survive. Do not decode and re-encode it here.
$path = parse_url($uri, PHP_URL_PATH) ?: '/';

$query = [];
$rawQuery = parse_url($uri, PHP_URL_QUERY);
if (is_string($rawQuery) && $rawQuery !== '') {
    parse_str($rawQuery, $query);
    // Values stay strings: the mod compares them against "true", "all" and friends and
    // parses numbers with tonumber, which accepts strings. Arrays would never match.
    $query = array_filter($query, 'is_string');
}

// Caddy caps the body as well, but that cap simply makes the read come up short, so
// the size has to be caught here to produce an honest error. The whole envelope has to
// stay under the mod's 256 KB file limit, so leave room for the key, path and query.
const MAX_BODY = 240 * 1024;

if ((int) ($_SERVER['CONTENT_LENGTH'] ?? 0) > MAX_BODY) {
    fail(413, 'request_too_large', 'Body must be under 240 KB.');
}

$body = new stdClass();
$rawBody = file_get_contents('php://input');
if (is_string($rawBody) && strlen($rawBody) > MAX_BODY) {
    fail(413, 'request_too_large', 'Body must be under 240 KB.');
}
if (is_string($rawBody) && $rawBody !== '') {
    $decoded = json_decode($rawBody);
    if (json_last_error() !== JSON_ERROR_NONE) {
        fail(400, 'malformed_json', 'Body is not valid JSON.');
    }
    if (!$decoded instanceof stdClass) {
        fail(400, 'malformed_request', 'Body must be an object.');
    }
    $body = $decoded;
}

$requestId = bin2hex(random_bytes(16)); // matches [A-Za-z0-9_-]+
$envelope = [
    'id' => $requestId,
    'key' => $key,
    'method' => $method,
    'path' => $path,
    // Objects, not arrays: an empty PHP array encodes as [], which the mod ignores
    // silently, and the parameters would vanish.
    'query' => (object) $query,
    'body' => $body,
];

// Write under a name the mod's ^[A-Za-z0-9_-]+\.json$ filter rejects, then rename it
// in. Our rename is atomic, so the mod never picks up a half-written request.
$staged = $requestDir . '/' . $requestId . '.part.json';
$final = $requestDir . '/' . $requestId . '.json';
$json = json_encode($envelope, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);

if (@file_put_contents($staged, $json) === false || !@rename($staged, $final)) {
    @unlink($staged);
    fail(500, 'bridge_write_failed', 'Could not write the request file. Check the galaxy mount and its permissions.');
}

$responseFile = $responseDir . '/' . $requestId . '.json';
$deadline = microtime(true) + TIMEOUT;

while (microtime(true) < $deadline) {
    clearstatcache(true, $responseFile);
    $raw = @file_get_contents($responseFile);

    if ($raw === false) {
        usleep(POLL_US);
        continue;
    }

    $payload = json_decode($raw);
    if (!$payload instanceof stdClass) {
        // The mod cannot write responses atomically - os.rename() inside the sandbox
        // reports success and then loses the file - so a failed parse means we caught
        // it mid-write. Retry rather than fail.
        usleep(POLL_US);
        continue;
    }

    // Delete it, or the mod deletes it 60 seconds later and we raced it for nothing.
    @unlink($responseFile);

    $status = isset($payload->status) && is_int($payload->status) ? $payload->status : 500;
    reply($status, $payload->body ?? new stdClass());
}

fail(504, 'bridge_timeout', sprintf('No response within %ds.', (int) TIMEOUT));
