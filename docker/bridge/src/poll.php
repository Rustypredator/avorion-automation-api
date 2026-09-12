<?php

declare(strict_types=1);

/**
 * Keeps something looking, so the history has no holes in it.
 *
 * The mod never pushes. History accumulates only while something is calling the API, so
 * without this the record is a record of when a browser tab happened to be open - and the
 * mod's own event log is a 200-entry ring buffer that quietly drops the oldest entry the
 * moment nobody has collected it. This process is the "something": one small loop that
 * calls the same public endpoints a console would, on a timer.
 *
 * It deliberately goes over HTTP to the api service rather than writing to Postgres itself.
 * That keeps one recording code path instead of two that must be kept in step, and it means
 * the poller authenticates the way every other client does - through the mod, which is the
 * only thing that can actually say whether a key is real. A poller with a bad key records
 * nothing, rather than filling a table with it.
 *
 *   POLL_KEYS       comma-separated API keys to poll for. No default: with none set this
 *                   process logs why and exits, rather than looping doing nothing.
 *   POLL_INTERVAL   seconds between passes (default 30)
 *   POLL_EVENTS     "0" to record movement only and skip the per-ship event calls
 *   POLL_ECONOMY    "0" to skip the station and faction calls the economy series is
 *                   built from
 *   POLL_URL        base URL of the bridge (default http://api:80)
 *   POLL_TIMEOUT    seconds to allow one call (default 30)
 *
 * ### On the interval
 *
 * Two things set the floor. Travel resolution: a craft that crosses a sector between two
 * passes is recorded as having gone straight there, so the interval is the accuracy of a
 * track. And the ring buffer: a ship generating events faster than 200 per interval loses
 * the overflow before this gets to it. 30s is comfortable for both on a normal fleet.
 *
 * The ceiling is the game server. Every pass is one file round-trip through the mod
 * transport per key, plus one per craft when events are on, and that work happens on the
 * server's own tick. A large fleet on a short interval is not free.
 */

require_once __DIR__ . '/db.php';
require_once __DIR__ . '/history.php';

const RETRY_AFTER_FAILURE = 5;

$keys = array_values(array_filter(array_map(
    'trim',
    explode(',', (string) (getenv('POLL_KEYS') ?: ''))
), static fn (string $k): bool => $k !== ''));

$interval = max(5, (int) (getenv('POLL_INTERVAL') ?: 30));
$base = rtrim((string) (getenv('POLL_URL') ?: 'http://api:80'), '/');
$timeout = max(5, (int) (getenv('POLL_TIMEOUT') ?: 30));
$wantEvents = (string) (getenv('POLL_EVENTS') ?: '1') !== '0';
$wantEconomy = (string) (getenv('POLL_ECONOMY') ?: '1') !== '0';

/** Everything this process says goes to stderr, where compose collects it. */
function say(string $message): void
{
    fwrite(STDERR, sprintf("[%s] poller: %s\n", date('Y-m-d H:i:s'), $message));
}

if ($keys === []) {
    say('POLL_KEYS is empty, so there is nothing to poll for. Set it in .env to the API '
        . 'keys whose fleets should be recorded, then restart this service.');
    exit(0);
}

if (!Db::enabled()) {
    say('HISTORY_DSN is empty, so nothing would be recorded. Not polling.');
    exit(0);
}

/**
 * One GET against the bridge.
 *
 * Returns the decoded body, or null on anything that is not a 2xx. A failure here is
 * ordinary - the game server restarts, the mod is mid-reload, the stack is still coming up -
 * so it is logged at most once per pass and the loop simply tries again.
 *
 * @return array{status: int, body: mixed}
 */
function fetch(string $url, string $key, int $timeout): array
{
    $curl = curl_init($url);
    curl_setopt_array($curl, [
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_TIMEOUT => $timeout,
        CURLOPT_CONNECTTIMEOUT => 5,
        CURLOPT_HTTPHEADER => ['X-API-Key: ' . $key, 'Accept: application/json'],
    ]);

    $raw = curl_exec($curl);
    $status = (int) curl_getinfo($curl, CURLINFO_HTTP_CODE);
    $error = curl_error($curl);
    curl_close($curl);

    if (!is_string($raw)) {
        return ['status' => 0, 'body' => $error];
    }

    return ['status' => $status, 'body' => json_decode($raw)];
}

/**
 * One pass over one key: the fleet, each craft's events, then the station and faction
 * ledgers the economy series is built from.
 *
 * Nothing is recorded here. The bridge records what it relays, so calling it is the whole
 * of the job - which is also why a key this process cannot use records nothing at all.
 */
function pass(string $base, string $key, int $timeout, bool $wantEvents, bool $wantEconomy): array
{
    $answer = fetch($base . '/ships', $key, $timeout);

    if ($answer['status'] !== 200) {
        return ['ok' => false, 'status' => $answer['status'], 'ships' => 0,
                'detail' => detail($answer)];
    }

    $ships = is_object($answer['body']) ? ($answer['body']->ships ?? []) : [];
    if (!is_array($ships)) {
        $ships = [];
    }

    $polled = 0;

    if ($wantEvents) {
        foreach ($ships as $ship) {
            $name = is_object($ship) ? ($ship->name ?? null) : null;
            if (!is_string($name) || $name === '') {
                continue;
            }

            // Percent-encoded: craft names are player-chosen and routinely hold spaces.
            $events = fetch($base . '/ships/' . rawurlencode($name) . '/events', $key, $timeout);
            if ($events['status'] === 200) {
                $polled++;
            }
        }
    }

    $stations = 0;

    /*
     * Two flat calls, whatever the fleet looks like: both endpoints roll every station up
     * themselves, so this does not grow with the number of stations the way the per-ship
     * event calls above do.
     *
     * owner=all on purpose. An alliance station's earnings land in the alliance's account
     * and the rest of this loop would never see them - the default scope is the calling
     * player, and a series missing half of a co-owned industry is worse than none.
     *
     * The bridge thins these on the way past (HISTORY_ECONOMY_INTERVAL), so polling them
     * every pass costs the game server two round trips and the database nothing.
     */
    if ($wantEconomy) {
        $answer = fetch($base . '/stations?owner=all', $key, $timeout);
        if ($answer['status'] === 200 && is_object($answer['body'])) {
            $stations = is_array($answer['body']->stations ?? null)
                ? count($answer['body']->stations)
                : 0;
        }

        fetch($base . '/economy?owner=all', $key, $timeout);
    }

    return ['ok' => true, 'status' => 200, 'ships' => count($ships), 'events' => $polled,
            'stations' => $stations];
}

function detail(array $answer): string
{
    $body = $answer['body'];

    if (is_string($body) && $body !== '') {
        return $body;
    }
    if (is_object($body) && is_object($body->error ?? null)) {
        return (string) ($body->error->message ?? '');
    }

    return '';
}

say(sprintf(
    'polling %d key%s every %ds at %s, events %s, economy %s',
    count($keys), count($keys) === 1 ? '' : 's', $interval, $base,
    $wantEvents ? 'on' : 'off', $wantEconomy ? 'on' : 'off'
));

/*
 * Pruning belongs here rather than on the request path: it is a DELETE over a window and
 * there is no caller waiting on it. history.php still does it occasionally on its own, for
 * deployments that run no poller at all.
 */
$pruneEvery = 3600;
$lastPrune = time();

/*
 * Failures are logged the first time and then stay quiet until the picture changes. A game
 * server that is down for an hour should be one line in the log, not one every 30 seconds.
 */
$complained = [];

// No signal handling: pcntl is not built into this image. Nothing here holds state across
// an iteration - every write has committed by the time a pass ends - so being killed
// mid-sleep costs at most one pass, and compose's SIGKILL after the grace period is a
// perfectly good way for this to stop.
while (true) {
    $started = time();
    $failed = false;

    foreach ($keys as $index => $key) {
        $label = 'key #' . ($index + 1);

        try {
            $result = pass($base, $key, $timeout, $wantEvents, $wantEconomy);
        } catch (Throwable $e) {
            $result = ['ok' => false, 'status' => 0, 'detail' => $e->getMessage()];
        }

        if ($result['ok']) {
            if (($complained[$label] ?? null) !== null) {
                say(sprintf('%s is answering again (%d craft)', $label, $result['ships']));
                unset($complained[$label]);
            }
            continue;
        }

        $failed = true;
        $note = sprintf('%s: HTTP %d %s', $label, $result['status'], $result['detail'] ?? '');

        if (($complained[$label] ?? null) !== $note) {
            say(rtrim($note));
            $complained[$label] = $note;
        }
    }

    if (time() - $lastPrune >= $pruneEvery) {
        $lastPrune = time();
        foreach ($keys as $key) {
            try {
                $removed = (new History($key))->prune();
                if ($removed > 0) {
                    say(sprintf('pruned %d row%s past the retention window',
                        $removed, $removed === 1 ? '' : 's'));
                }
            } catch (Throwable $e) {
                say('prune failed: ' . $e->getMessage());
            }
        }
    }

    // Measured from the start of the pass, so a slow pass does not push the schedule out;
    // a pass slower than the interval simply runs back to back.
    $spent = time() - $started;
    $wait = $failed ? min($interval, RETRY_AFTER_FAILURE) : max(1, $interval - $spent);

    sleep($wait);
}
