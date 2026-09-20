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
 * ### Whose rules
 *
 * The keys come out of the `service_keys` table, where a player put their own by opting
 * in on the console's Alerts tab - see src/enrolment.php. Re-read at the top of every
 * pass, so switching alerts on takes effect within one interval and nothing needs
 * restarting, and with nobody enrolled this idles rather than exiting.
 *
 *   NOTIFY_INTERVAL  seconds between passes (default 15)
 *   NOTIFY_URL       base URL of the bridge (default http://api:80)
 *   NOTIFY_TIMEOUT   seconds to allow one call (default 30)
 *   NOTIFY_KEYS      deprecated, as POLL_KEYS is: keys still listed here are moved into
 *                    the table once on startup and the setting is then ignored.
 */

require_once __DIR__ . '/db.php';
require_once __DIR__ . '/history.php';
require_once __DIR__ . '/notifications.php';
require_once __DIR__ . '/enrolment.php';

$interval = max(5, (int) (getenv('NOTIFY_INTERVAL') ?: 15));
$base = rtrim((string) (getenv('NOTIFY_URL') ?: 'http://api:80'), '/');
$timeout = max(5, (int) (getenv('NOTIFY_TIMEOUT') ?: 30));

function say(string $message): void
{
    fwrite(STDERR, sprintf("[%s] notifier: %s\n", date('Y-m-d H:i:s'), $message));
}

if (!Db::enabled()) {
    say('HISTORY_DSN is empty, so there is no database to keep rules in. Not notifying.');
    exit(0);
}

if (!Enrolment::available()) {
    say('No enrolment secret, so the enrolled keys cannot be read: ' . Enrolment::unavailable());
    exit(1);
}

// As in the poller: keys an older deployment still names in .env are moved into the table
// once, so upgrading a running stack does not silently stop alerting. NOTIFY_KEYS used to
// fall back to POLL_KEYS, and the poller's own import covers that half.
$carriedOver = Enrolment::importEnv('notify', array_values(array_filter(array_map('trim',
    explode(',', (string) (getenv('NOTIFY_KEYS') ?: ''))),
    static fn (string $k): bool => $k !== '')));

if ($carriedOver > 0) {
    say(sprintf('moved %d key%s out of NOTIFY_KEYS and into the database; that setting can '
        . 'come out of .env', $carriedOver, $carriedOver === 1 ? '' : 's'));
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
 * @return array{ok: bool, status: int, raised: int, events: int, detail: string, player?: ?int}
 */
function pass(string $base, string $key, int $timeout): array
{
    $ping = get($base . '/ping', $key, $timeout);
    if ($ping['status'] !== 200) {
        return ['ok' => false, 'status' => $ping['status'], 'raised' => 0, 'events' => 0,
                'detail' => 'the mod would not answer /ping for this key'];
    }

    $whose = is_object($ping['body'] ?? null) ? ($ping['body']->player->index ?? null) : null;

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
            'events' => $result['events'], 'detail' => '',
            'player' => is_numeric($whose) ? (int) $whose : null];
}

say(sprintf('watching every %ds at %s; keys come from the database, so players enrol '
    . 'themselves from the console', $interval, $base));

/** Says how many keys are enrolled, but only when that has changed. As in the poller. */
function announce(array $enrolled, ?string &$last): void
{
    $note = sprintf('%d key%s enrolled for alerts', count($enrolled['keys']),
                    count($enrolled['keys']) === 1 ? '' : 's');

    if ($enrolled['sealed'] > 0) {
        $note .= sprintf('; %d cannot be decrypted and have to be enrolled again',
                         $enrolled['sealed']);
    }
    if ($enrolled['tired'] > 0) {
        $note .= sprintf('; %d set aside after repeated failures', $enrolled['tired']);
    }
    if (count($enrolled['keys']) === 0 && $enrolled['sealed'] === 0) {
        $note .= '. Nobody will be sent anything until a player enrols on the console\'s '
               . 'Alerts tab, under Background services.';
    }

    if ($note !== $last) {
        say($note);
        $last = $note;
    }
}

$announced = null;

// As in the poller: a failure is logged the first time and then stays quiet until the
// picture changes, so a game server down for an hour is one line rather than 240.
$complained = [];

/*
 * Deliveries are attempted by whichever pass comes next, and one instance of this drains
 * the whole outbox - it is not scoped to a key, so the empty one it is built with is never
 * used to read anything. See Notifications::deliver.
 */
$notifier = new Notifications(new History(''));

while (true) {
    $started = time();
    $raised = 0;

    try {
        $enrolled = Enrolment::keysFor('notify');
    } catch (Throwable $e) {
        say('could not read the enrolled keys: ' . $e->getMessage());
        sleep($interval);
        continue;
    }

    announce($enrolled, $announced);

    foreach ($enrolled['keys'] as $entry) {
        $label = $entry['label'] !== '' ? $entry['label'] : 'key ' . substr($entry['id'], 0, 8);

        try {
            $result = pass($base, $entry['key'], $timeout);
        } catch (Throwable $e) {
            $result = ['ok' => false, 'status' => 0, 'raised' => 0, 'events' => 0,
                       'detail' => $e->getMessage()];
        }

        if ($result['ok']) {
            $raised += $result['raised'];
            Enrolment::succeeded($entry['id']);

            if (is_int($result['player'] ?? null)) {
                Enrolment::attribute($entry['id'], $result['player']);
            }

            if (($complained[$label] ?? null) !== null) {
                say($label . ' is answering again');
                unset($complained[$label]);
            }
            continue;
        }

        // A key the mod will not vouch for is final, as in the poller; anything else is
        // an outage and merely counts towards the ceiling.
        Enrolment::failed($entry['id'], sprintf('HTTP %d %s', $result['status'], $result['detail']),
                          $result['status'] === 401 || $result['status'] === 403);

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
