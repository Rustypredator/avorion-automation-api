<?php

declare(strict_types=1);

/**
 * The notifier: turns what the poller collected into messages on somebody's phone.
 *
 * Avorion is a game you leave running. The console can raise a browser notification, but
 * only while the tab is open and the machine is awake, which is exactly not the case when
 * a fleet is grinding overnight. This process is the other half: it looks at what has
 * happened, decides what crossed a line somebody cared about, and pushes it out through
 * ntfy, Gotify or a webhook.
 *
 * ### What it reads, and why it is nearly free
 *
 * Almost everything comes out of Postgres, not out of the game. The poller is already
 * collecting each craft's event feed into the `events` table for the history store, and
 * those events carry the ship's own automation state - enemies in the sector, hull and
 * shield, a flee in progress, a plan that ended. Reading rows costs the game server
 * nothing at all.
 *
 * The one live call per key per pass is GET /ships, for craft in unloaded sectors and for
 * a fleet nobody is flying: the listing reads the ship database, so it keeps answering
 * with every player logged out, and it carries each craft's hull and shield.
 *
 * ### What it therefore cannot do
 *
 * It cannot be quicker than the poller. An alert about a fight is raised when the events
 * describing that fight reach the database, so POLL_INTERVAL is the floor on how late a
 * notification is, and a craft whose owner is offline records nothing to raise one from -
 * player scripts do not run for a logged-out player. Shortening NOTIFY_INTERVAL below
 * POLL_INTERVAL buys nothing but queries.
 *
 *   NOTIFY_KEYS      comma-separated API keys whose players' rules should be run.
 *                    Defaults to POLL_KEYS, which is normally the same list.
 *   NOTIFY_INTERVAL  seconds between passes (default 15)
 *   NOTIFY_URL       base URL of the bridge (default http://api:80)
 *   NOTIFY_TIMEOUT   seconds to allow one call (default 30)
 */

require_once __DIR__ . '/db.php';
require_once __DIR__ . '/history.php';
require_once __DIR__ . '/notifications.php';

$keys = array_values(array_filter(array_map('trim', explode(',',
    (string) (getenv('NOTIFY_KEYS') ?: getenv('POLL_KEYS') ?: ''))),
    static fn (string $k): bool => $k !== ''));

$interval = max(5, (int) (getenv('NOTIFY_INTERVAL') ?: 15));
$base = rtrim((string) (getenv('NOTIFY_URL') ?: 'http://api:80'), '/');
$timeout = max(5, (int) (getenv('NOTIFY_TIMEOUT') ?: 30));

function say(string $message): void
{
    fwrite(STDERR, sprintf("[%s] notifier: %s\n", date('Y-m-d H:i:s'), $message));
}

if ($keys === []) {
    say('NOTIFY_KEYS and POLL_KEYS are both empty, so there is nobody to notify. Set '
        . 'NOTIFY_KEYS in .env to the API keys of the players who want alerts, then '
        . 'restart this service.');
    exit(0);
}

if (!Db::enabled()) {
    say('HISTORY_DSN is empty, so there is no database to keep rules in. Not notifying.');
    exit(0);
}

/**
 * One GET against the bridge.
 *
 * @return array{status: int, body: mixed}
 */
function get(string $url, string $key, int $timeout): array
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
    curl_close($curl);

    return ['status' => $status, 'body' => is_string($raw) ? json_decode($raw) : null];
}

/**
 * One pass over one key.
 *
 * /ping first, for the same reason the poller calls it first: it is the only thing that
 * says which player a key belongs to and which alliance they are in right now, and the
 * rules are the player's. Without a current answer, an alliance-scoped rule reads nothing
 * and the whole pass does nothing - which is correct, but silent, so it is worth a line.
 *
 * @return array{ok: bool, status: int, raised: int, events: int, detail: string}
 */
function pass(string $base, string $key, int $timeout): array
{
    $ping = get($base . '/ping', $key, $timeout);
    if ($ping['status'] !== 200) {
        return ['ok' => false, 'status' => $ping['status'], 'raised' => 0, 'events' => 0,
                'detail' => 'the mod would not answer /ping for this key'];
    }

    $notifications = new Notifications(new History($key));
    if ($notifications->player() === null) {
        return ['ok' => false, 'status' => 200, 'raised' => 0, 'events' => 0,
                'detail' => 'the bridge does not know which player this key is'];
    }

    /*
     * type=all so stations are watched too. A station cannot flee and will not go idle,
     * but it can be attacked and it can be destroyed, which are the two alerts somebody
     * away from the keyboard most wants.
     */
    $fleet = get($base . '/ships?owner=all&type=all', $key, $timeout);
    if ($fleet['status'] !== 200 || !is_object($fleet['body'])) {
        return ['ok' => false, 'status' => $fleet['status'], 'raised' => 0, 'events' => 0,
                'detail' => 'the fleet listing failed'];
    }

    $ships = $fleet['body']->ships ?? [];
    $result = $notifications->evaluate(is_array($ships) ? $ships : []);

    return ['ok' => true, 'status' => 200, 'raised' => $result['raised'],
            'events' => $result['events'], 'detail' => ''];
}

say(sprintf('watching %d key%s every %ds at %s', count($keys),
    count($keys) === 1 ? '' : 's', $interval, $base));

// As in the poller: a failure is logged the first time and then stays quiet until the
// picture changes, so a game server down for an hour is one line rather than 240.
$complained = [];

// Deliveries are attempted by whichever pass comes next, and one instance of this drains
// the whole outbox - it is not scoped to a key. See Notifications::deliver.
$notifier = new Notifications(new History($keys[0]));

while (true) {
    $started = time();
    $raised = 0;

    foreach ($keys as $index => $key) {
        $label = 'key #' . ($index + 1);

        try {
            $result = pass($base, $key, $timeout);
        } catch (Throwable $e) {
            $result = ['ok' => false, 'status' => 0, 'raised' => 0, 'events' => 0,
                       'detail' => $e->getMessage()];
        }

        if ($result['ok']) {
            $raised += $result['raised'];

            if (($complained[$label] ?? null) !== null) {
                say($label . ' is answering again');
                unset($complained[$label]);
            }
            continue;
        }

        $note = sprintf('%s: HTTP %d %s', $label, $result['status'], $result['detail']);
        if (($complained[$label] ?? null) !== $note) {
            say($note);
            $complained[$label] = $note;
        }
    }

    /*
     * Sending is a separate pass over the outbox rather than something each rule does as
     * it fires. A push server that is slow or down then costs one backoff on a row, not a
     * stalled evaluation - and a notification survives this process being restarted
     * between being raised and being sent.
     */
    try {
        $delivery = $notifier->deliver();

        if ($delivery['sent'] > 0 || $delivery['failed'] > 0) {
            say(sprintf('%d raised, %d sent, %d could not be delivered',
                $raised, $delivery['sent'], $delivery['failed']));
        }
    } catch (Throwable $e) {
        say('delivery failed: ' . $e->getMessage());
    }

    $spent = time() - $started;
    sleep(max(1, $interval - $spent));
}
