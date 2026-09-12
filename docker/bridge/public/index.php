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

require __DIR__ . '/../src/history.php';

$galaxy = rtrim(getenv('GALAXY_DIR') ?: '/galaxy', '/');
$root = $galaxy . '/moddata/AutomationAPI';
$requestDir = $root . '/requests';
$responseDir = $root . '/responses';

/*
 * Whether the bridge keeps its own durable copy of what it has relayed - see src/history.php
 * for why it exists and what it can and cannot know, and src/db.php for where it goes.
 *
 * Deliberately NOT a file under the galaxy mount: that tree belongs to the mod, which
 * re-creates its own directories and would be within its rights to clean up anything else
 * it finds there. It is a Postgres database on its own volume instead.
 *
 * Set HISTORY_DSN to an empty string to keep no history at all; nothing else changes, and
 * the bridge still relays every call exactly as before.
 */
$keepHistory = Db::enabled();

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

    // Chrome blocks a page on a public - or file:// - origin from reaching a private
    // address unless the preflight asks for it and gets this back, which is exactly the
    // shape of someone opening the console off their disk against a bridge on their LAN
    // or on localhost. It only ever grants what the origin check above already granted.
    if (($_SERVER['HTTP_ACCESS_CONTROL_REQUEST_PRIVATE_NETWORK'] ?? '') === 'true') {
        header('Access-Control-Allow-Private-Network: true');
    }

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

/**
 * Folds one relayed answer into the history store, if it is one the store is built from:
 * the fleet listing, which carries every craft's position and keeps working with everyone
 * logged out; a ship's event feed; the station listing, which carries each station's
 * running earnings totals and stock; and the faction ledger.
 *
 * Wrapped whole in a try/catch. A history that cannot be written is a lost overlay; a
 * history that takes the API call down with it is an outage. The caller's answer has
 * already been decided by the time this runs and must reach them either way.
 */
function record(History $history, string $path, stdClass $answer): void
{
    try {
        if ($path === '/ships') {
            $history->recordShips($answer);
            return;
        }

        // /ships/<name>/events, with the name still percent-encoded.
        if (preg_match('#^/ships/([^/]+)/events$#', $path, $found) === 1) {
            $ship = $answer->ship ?? rawurldecode($found[1]);
            if (is_string($ship) && $ship !== '') {
                $history->recordEvents($ship, $answer);
            }
            return;
        }

        // The two the economy series is built from. Both are rate-limited on the way in,
        // so a console refreshing every few seconds costs the same rows as the poller.
        if ($path === '/stations') {
            $history->recordStations($answer);
            return;
        }

        if ($path === '/economy') {
            $history->recordFactions($answer);
        }
    } catch (Throwable $e) {
        error_log('AutomationAPI bridge: history write failed: ' . $e->getMessage());
    }
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

/*
 * A bridge that cannot reach the transport directory fails every call, and it is nearly
 * always one of two deployment mistakes that need opposite fixes. Separate them here,
 * before anything else, rather than letting both surface as one write error later.
 *
 * Both come from the same Docker habit: it creates a missing bind-mount source itself -
 * as root, parent levels included - so a GALAXY_DIR pointing at the wrong directory does
 * not fail. It quietly manufactures an empty transport directory the game server has
 * never heard of, owned by an account this process may not be running as.
 *
 * This runs before the key check on purpose. An operator debugging a fresh deployment
 * should not have to hold a valid key to be told the mount is wrong, and the paths and
 * uids below are the bridge's own container, not the caller's business.
 */
clearstatcache();

if (!is_dir($requestDir) || !is_dir($responseDir)) {
    fail(503, 'bridge_unavailable', sprintf(
        'No transport directory at %s. The mod creates it on startup, so either the game '
        . 'server is not running with this mod loaded, or GALAXY_DIR points somewhere the '
        . 'mod is not writing. The mod prints the directory it settled on to the server '
        . 'console as "AutomationAPI: ... transport directory: <path>"; GALAXY_DIR is the '
        . 'host path of that directory with /moddata/AutomationAPI taken off the end.',
        $root));
}

if (!is_writable($requestDir) || !is_writable($responseDir)) {
    fail(503, 'transport_not_writable', sprintf(
        '%s exists but this process (uid %d) cannot write to it - it belongs to uid %d. '
        . 'Let the mod own these directories rather than Docker: start the game server '
        . 'first so it creates them, and set BRIDGE_USER to the uid:gid that server runs '
        . 'as. A directory Docker created to satisfy a missing mount belongs to root, and '
        . 'nothing else can write to it.',
        $requestDir, posix_geteuid(), (int) @fileowner($requestDir)));
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

/*
 * /history is the bridge's own, and is answered here rather than forwarded.
 *
 * Everything else in this file is deliberately dumb - the mod owns routing, auth and
 * serialization, and this process only moves bytes. The history is the one exception, and
 * it is one because it cannot live on the other side: the mod's log is a ring buffer in
 * server memory, and growing a file on the game's own tick to fix that would be paying for
 * a month of travel data with server frame time. So the copy lives here, built out of
 * answers the bridge was relaying anyway.
 *
 * No key check happens first, and none is needed. The store is addressed by a hash of the
 * key, so an unknown key reads an empty history rather than anyone else's, and nothing is
 * ever written except off the back of a call the mod itself answered.
 */
if (str_starts_with($path, '/history')) {
    if (!$keepHistory) {
        fail(404, 'history_disabled',
            'This bridge keeps no history: HISTORY_DSN is set empty. Unset it to turn the '
            . 'store back on, or read the mod\'s own in-memory log at '
            . '/ships/{name}/events instead.');
    }

    $history = new History($key);
    $what = rawurldecode(substr($path, strlen('/history')));

    $filter = [
        // `station` is an alias for `ship`: the economy views are about stations and
        // reading `?ship=` on them is a small but constant papercut.
        'ship' => (string) ($query['ship'] ?? $query['station'] ?? ''),
        'owner' => (string) ($query['owner'] ?? ''),
        'from' => (int) ($query['from'] ?? 0),
        'to' => (int) ($query['to'] ?? 0),
        'limit' => max(0, min(20000, (int) ($query['limit'] ?? 2000))),
    ];

    if ($method === 'GET' && ($what === '' || $what === '/' || $what === '/summary')) {
        reply(200, $history->summary());
    }

    if ($method === 'GET' && $what === '/visits') {
        reply(200, ['visits' => $history->visits($filter)]);
    }

    if ($method === 'GET' && $what === '/heatmap') {
        reply(200, $history->heatmap($filter));
    }

    if ($method === 'GET' && $what === '/events') {
        reply(200, ['events' => $history->events($filter)]);
    }

    /*
     * The economy views. All three read the station samples the bridge has been keeping
     * off GET /stations, and differ only in how they group them - by station, by time
     * bucket, or by good. See History::economySummary for what a sample is and why the
     * rates are per observed hour.
     */
    if ($method === 'GET' && ($what === '/economy' || $what === '/economy/summary')) {
        reply(200, $history->economySummary($filter));
    }

    if ($method === 'GET' && $what === '/economy/series') {
        reply(200, $history->economySeries($filter, (string) ($query['bucket'] ?? 'hour')));
    }

    if ($method === 'GET' && $what === '/economy/goods') {
        reply(200, $history->economyGoods($filter));
    }

    if ($method === 'POST' && $what === '/clear') {
        reply(200, $history->clear($filter['ship'] !== '' ? $filter['ship'] : null));
    }

    fail(404, 'no_such_route', sprintf(
        'The bridge serves GET /history/summary, /history/visits, /history/heatmap, '
        . '/history/events, /history/economy/summary, /history/economy/series and '
        . '/history/economy/goods, and POST /history/clear. It does not serve %s %s.',
        $method, $what === '' ? '/history' : '/history' . $what));
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
    $answer = $payload->body ?? new stdClass();

    // Keep a durable copy of the two answers worth keeping, on the way past. A successful
    // reply is also proof the mod recognised this key, which is the only authentication
    // the store gets - and the reason nothing is written before this line.
    if ($keepHistory && $method === 'GET' && $status >= 200 && $status < 300
        && $answer instanceof stdClass) {
        record(new History($key), $path, $answer);
    }

    reply($status, $answer);
}

/**
 * Nothing came back, and which half of the round trip is broken is the only useful thing
 * to say here. The request file answers it: the mod deletes it the instant it picks it up,
 * so one still sitting there means nothing is reading that directory at all.
 *
 * That case is otherwise completely silent. The directory check above passes whether or
 * not the mod ever created it, because Docker makes an empty directory on the host for any
 * bind mount whose source is missing - so a GALAXY_DIR pointing at the wrong galaxy looks
 * like a healthy bridge right up to this line.
 */
clearstatcache(true, $final);

if (file_exists($final)) {
    // Take it back out. Nothing is reading the directory now, but a mod that is merely
    // down would answer every abandoned request at once on its way back up, long after
    // the callers stopped listening.
    @unlink($final);

    fail(504, 'mod_not_responding',
        'The mod never picked this request up. Check that the game server is running with '
        . 'the mod loaded, and that GALAXY_DIR points at the galaxy that server is actually '
        . 'running.');
}

fail(504, 'bridge_timeout', sprintf(
    'The mod took the request but wrote no response within %ds. Check the game server log '
    . 'for AutomationAPI errors - a response the mod cannot write fails exactly like this, '
    . 'so make sure the responses directory is writable by the account the server runs as.',
    (int) TIMEOUT));
