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
 * ### Whose fleets
 *
 * The keys come out of the database - the `service_keys` table, filled in by players
 * opting in from the console's Keys tab. See src/enrolment.php. They are re-read at the
 * top of every pass, so enrolling takes effect within one interval and this service never
 * needs restarting; and with nobody enrolled it idles quietly rather than exiting, since
 * somebody may enrol a minute from now.
 *
 *   POLL_INTERVAL   seconds between passes (default 30)
 *   POLL_EVENTS     "0" to record movement only and skip the per-ship event calls
 *   POLL_ECONOMY    "0" to skip the station and faction calls the economy series is
 *                   built from, and the stations' trade and production feed
 *   POLL_URL        base URL of the bridge (default http://api:80)
 *   POLL_TIMEOUT    seconds to allow one call (default 30)
 *   POLL_KEYS       deprecated. Keys still listed here are moved into the table once, on
 *                   startup, so upgrading a running stack does not stop recording. Take
 *                   it out of .env afterwards; it is ignored once the rows exist.
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
require_once __DIR__ . '/enrolment.php';

const RETRY_AFTER_FAILURE = 5;

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

if (!Db::enabled()) {
    say('HISTORY_DSN is empty, so nothing would be recorded. Not polling.');
    exit(0);
}

if (!Enrolment::available()) {
    say('No enrolment secret, so the enrolled keys cannot be read: ' . Enrolment::unavailable());
    exit(1);
}

/*
 * Keys an older deployment still lists in .env, moved into the table once. Nothing here
 * can ask the mod who they belong to, so they arrive with no player on them and the first
 * successful pass below fills that in.
 */
$carriedOver = Enrolment::importEnv('poll', array_values(array_filter(array_map(
    'trim',
    explode(',', (string) (getenv('POLL_KEYS') ?: ''))
), static fn (string $k): bool => $k !== '')));

if ($carriedOver > 0) {
    say(sprintf('moved %d key%s out of POLL_KEYS and into the database. Players enrol '
        . 'themselves from the console now, so that setting can come out of .env.',
        $carriedOver, $carriedOver === 1 ? '' : 's'));
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
 * One pass over one key: who it belongs to, the fleet, each craft's events, then the
 * station and faction ledgers the economy series is built from.
 *
 * Two members' keys polling the same alliance fleet is fine and costs the database nothing
 * extra - the rows are the alliance's, and the second pass extends or skips what the first
 * one wrote. It does cost the game server the round trips, so one key per alliance is
 * enough to keep an alliance fleet recorded, and the console says so where players enrol.
 *
 * Nothing is recorded here. The bridge records what it relays, so calling it is the whole
 * of the job - which is also why a key this process cannot use records nothing at all.
 */
function pass(string $base, string $key, int $timeout, bool $wantEvents, bool $wantEconomy): array
{
    /*
     * First, so the bridge's idea of who this key belongs to is never older than one pass.
     * That is what lets every member of an alliance read the alliance's history without
     * each read having to relay a /ping of its own, and it is what moves rows recorded
     * before rows had owners onto the player and alliance they belong to. One round trip,
     * and a cheap one: /ping touches no ship data.
     */
    $ping = fetch($base . '/ping', $key, $timeout);
    if ($ping['status'] !== 200) {
        return ['ok' => false, 'status' => $ping['status'], 'ships' => 0,
                'detail' => detail($ping)];
    }

    // Which player this key is, so an enrolment carried over from POLL_KEYS - which
    // arrived with nobody's name on it - shows up on that player's console.
    $whose = is_object($ping['body'] ?? null) ? ($ping['body']->player->index ?? null) : null;

    /*
     * owner=all and type=all, which is the whole fleet rather than the calling player's
     * own ships.
     *
     * Without them this polls `owner=player, type=ship`, and every alliance craft and
     * every station is invisible to it - no movement recorded, and, because the per-craft
     * event calls below are driven off this list, no events either. An alliance fleet
     * appeared in the history only where a member happened to have a console open, and an
     * alert rule scoped to the alliance had nothing behind it at all.
     *
     * Two members' keys polling the same alliance fleet costs the database nothing: the
     * rows are the alliance's, and the second pass extends or skips what the first wrote.
     */
    $answer = fetch($base . '/ships?owner=all&type=all', $key, $timeout);

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

            /*
             * Stations skipped. The order chain is what produces these events and it does
             * not run on a station, so the call is a guaranteed empty answer - and it is
             * one file round-trip through the game server's tick per station per pass,
             * which on an industrial alliance is the most expensive nothing here could
             * do. What a station does is collected by the feed below instead.
             */
            if (($ship->type ?? '') === 'Station') {
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

        $activity = collectStationEvents($base, $key, $timeout);
    }

    return ['ok' => true, 'status' => 200, 'ships' => count($ships), 'events' => $polled,
            'stations' => $stations, 'activity' => $activity ?? null,
            'player' => is_numeric($whose) ? (int) $whose : null];
}

/** Largest page the mod hands out; see Config.maxStationEventsPerRead. */
const STATION_EVENT_PAGE = 1000;

/**
 * Drains the mod's station feed - every trade and production window since the last pass -
 * into the history store.
 *
 * This is the one collection that cannot be a snapshot. The mod keeps the feed in a ring
 * buffer, so whatever is not collected before the buffer comes round is gone, and a pass
 * pages forward from where the last one stopped until the mod says there is no more. The
 * bridge records each page on the way past and moves the stored cursor; this only has to
 * keep asking.
 *
 * A server restart numbers the feed from zero again under a new `boot`. The stored cursor
 * then points past everything the new run has produced, so the pass starts over from zero
 * for the new run instead of waiting for the counter to climb back.
 *
 * @return array{events: int, gap: bool}
 */
function collectStationEvents(string $base, string $key, int $timeout): array
{
    $state = (new History($key))->stationEventCursor();
    $since = $state['cursor'];
    $boot = $state['boot'];

    $events = 0;
    $gap = false;

    // Bounded, so a feed that somehow never reports the end cannot hold the loop forever.
    for ($page = 0; $page < 50; $page++) {
        $answer = fetch(sprintf('%s/economy/events?owner=all&limit=%d&since=%d',
            $base, STATION_EVENT_PAGE, $since), $key, $timeout);

        if ($answer['status'] !== 200 || !is_object($answer['body'])) {
            break;
        }

        $body = $answer['body'];
        $answerBoot = (string) ($body->boot ?? '');

        if ($boot !== null && $answerBoot !== $boot && $since > 0) {
            $boot = $answerBoot;
            $since = 0;
            continue;
        }

        $boot = $answerBoot;
        $events += is_array($body->events ?? null) ? count($body->events) : 0;
        $gap = $gap || ($body->gap ?? false) === true;

        if (($body->more ?? false) !== true || !is_numeric($body->cursor ?? null)) {
            break;
        }

        $since = (int) $body->cursor;
    }

    return ['events' => $events, 'gap' => $gap];
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

say(sprintf('polling every %ds at %s, events %s, economy %s; keys come from the database, '
    . 'so players enrol themselves from the console',
    $interval, $base, $wantEvents ? 'on' : 'off', $wantEconomy ? 'on' : 'off'));

/**
 * Says how many keys are enrolled, but only when that has changed.
 *
 * This runs every pass and most passes find exactly what the last one did, so the
 * interesting line is the transition - somebody enrolled, somebody's key stopped working,
 * the table went empty. Printing it unconditionally would bury everything else.
 */
function announce(array $enrolled, ?string &$last): void
{
    $note = sprintf('%d key%s enrolled', count($enrolled['keys']),
                    count($enrolled['keys']) === 1 ? '' : 's');

    if ($enrolled['sealed'] > 0) {
        $note .= sprintf('; %d cannot be decrypted, so the enrolment secret is not the one '
            . 'they were stored with - those players have to enrol again', $enrolled['sealed']);
    }
    if ($enrolled['tired'] > 0) {
        $note .= sprintf('; %d set aside after repeated failures', $enrolled['tired']);
    }
    if (count($enrolled['keys']) === 0 && $enrolled['sealed'] === 0) {
        $note .= '. Nothing is being recorded. A player enrols their key on the console\'s '
               . 'Keys tab, under Background services.';
    }

    if ($note !== $last) {
        say($note);
        $last = $note;
    }
}

$announced = null;

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

    /*
     * Re-read every pass rather than held from startup. Enrolment happens while this is
     * running - that is the whole point of taking it out of .env - and one indexed query
     * over a table with a row per opted-in player is nothing beside the HTTP below.
     */
    try {
        $enrolled = Enrolment::keysFor('poll');
    } catch (Throwable $e) {
        say('could not read the enrolled keys: ' . $e->getMessage());
        sleep(RETRY_AFTER_FAILURE);
        continue;
    }

    announce($enrolled, $announced);

    foreach ($enrolled['keys'] as $entry) {
        $label = $entry['label'] !== '' ? $entry['label'] : 'key ' . substr($entry['id'], 0, 8);

        try {
            $result = pass($base, $entry['key'], $timeout, $wantEvents, $wantEconomy);
        } catch (Throwable $e) {
            $result = ['ok' => false, 'status' => 0, 'detail' => $e->getMessage()];
        }

        if ($result['ok']) {
            Enrolment::succeeded($entry['id']);

            if (is_int($result['player'] ?? null)) {
                Enrolment::attribute($entry['id'], $result['player']);
            }

            // Events that fell out of the mod's buffer before anyone collected them. Worth one
            // line each time, since it means the interval is too long for the industry.
            if (($result['activity']['gap'] ?? false) === true) {
                say(sprintf('%s: the mod dropped station events before they were collected; '
                    . 'shorten POLL_INTERVAL or raise Config.stationEventsPerFaction', $label));
            }

            if (($complained[$label] ?? null) !== null) {
                say(sprintf('%s is answering again (%d craft)', $label, $result['ships']));
                unset($complained[$label]);
            }
            continue;
        }

        $failed = true;
        $note = sprintf('%s: HTTP %d %s', $label, $result['status'], $result['detail'] ?? '');

        /*
         * 401 and 403 are the mod saying this is not a key - revoked, or a galaxy that was
         * replaced under it. Retrying that every 30 seconds for a week helps nobody, so it
         * is recorded as final; the player still sees the row and the reason on the
         * console, and enrolling again clears it. Everything else just counts.
         */
        Enrolment::failed($entry['id'], rtrim($note),
                          $result['status'] === 401 || $result['status'] === 403);

        if (($complained[$label] ?? null) !== $note) {
            say(rtrim($note));
            $complained[$label] = $note;
        }
    }

    // Once for the whole store, not once per key: rows belong to factions now, and the
    // retention window is one setting for all of them. The key the History is built with
    // is unused here - prune() is the one call on it that reads no scope - so it runs
    // whether or not anybody is enrolled.
    if (time() - $lastPrune >= $pruneEvery) {
        $lastPrune = time();
        try {
            $removed = (new History(''))->prune();
            if ($removed > 0) {
                say(sprintf('pruned %d row%s past the retention window',
                    $removed, $removed === 1 ? '' : 's'));
            }
        } catch (Throwable $e) {
            say('prune failed: ' . $e->getMessage());
        }
    }

    // Measured from the start of the pass, so a slow pass does not push the schedule out;
    // a pass slower than the interval simply runs back to back.
    $spent = time() - $started;
    $wait = $failed ? min($interval, RETRY_AFTER_FAILURE) : max(1, $interval - $spent);

    sleep($wait);
}
