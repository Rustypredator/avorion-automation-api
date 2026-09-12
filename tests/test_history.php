<?php

declare(strict_types=1);

/**
 * The bridge's durable history store.
 *
 * Needs a Postgres to talk to. tools/dbtest.sh starts a throwaway one, runs this against
 * it and takes it down again, which is the intended way in:
 *
 *   tools/dbtest.sh
 *
 * To point it at a database you already have, set the same variables the bridge reads -
 * HISTORY_DB_HOST, HISTORY_DB_NAME, HISTORY_DB_USER, HISTORY_DB_PASSWORD - and run it with
 * any PHP that has pdo_pgsql.
 *
 * What it pins is the awkward half: the store is fed by whatever calls happen to be made,
 * so it has to survive a caller that polls irregularly, a server whose sequence numbers
 * restart under it, and two clients recording the same batch at once.
 *
 * Every run uses freshly generated keys, so it neither sees nor disturbs anything already
 * in the database it is pointed at.
 */

require __DIR__ . '/../docker/bridge/src/history.php';

$failures = 0;

function check(bool $cond, string $message): void
{
    global $failures;

    if ($cond) {
        echo "  ok   $message\n";
    } else {
        $failures++;
        echo "  FAIL $message\n";
    }
}

if (!Db::enabled()) {
    fwrite(STDERR, "test_history.php needs a database: set HISTORY_DB_HOST and friends, "
                 . "or run tools/dbtest.sh which starts one.\n");
    exit(2);
}

try {
    $pdo = Db::connect();
} catch (Throwable $e) {
    fwrite(STDERR, 'test_history.php cannot reach the database: ' . $e->getMessage() . "\n");
    exit(2);
}

/** A key no previous run can have used, so every run starts empty. */
function freshKey(): string
{
    return 'avo_' . bin2hex(random_bytes(32));
}

$key = freshKey();
$history = new History($key);

// Whatever happens, this run leaves the database as it found it.
register_shutdown_function(static function () use (&$madeKeys): void {
    foreach ($madeKeys ?? [] as $made) {
        try {
            (new History($made))->clear(null);
        } catch (Throwable) {
            // Nothing useful to do in a shutdown handler.
        }
    }
});

$madeKeys = [$key];

function ships(array $rows): stdClass
{
    $ships = [];
    foreach ($rows as $name => $position) {
        $ships[] = (object) [
            'name' => $name,
            'position' => (object) ['x' => $position[0], 'y' => $position[1]],
            'owner' => (object) ['kind' => $position[2] ?? 'player'],
        ];
    }

    return (object) ['ships' => $ships, 'count' => count($ships)];
}

echo "\nkeying\n";

check(!$history->exists(), 'a key that has never been used is not in the database at all');

$other = new History(freshKey());
$madeKeys[] = 'unused';
check($other->visits([]) === [], 'and an unknown key reads an empty history, not a 500');

$history->recordShips(ships(['Ore Hound' => [5, 5]]));

$stored = $pdo->query('SELECT key_hash FROM api_keys')->fetchAll();
$hashes = array_column($stored, 'key_hash');
check(!in_array($key, $hashes, true), 'the key itself is never stored');
check(in_array(hash('sha256', $key), $hashes, true), 'only a SHA-256 of it');

echo "\nvisits are written on movement, not on polling\n";

check($history->exists(), 'the first recorded answer creates the key');
check(count($history->visits([])) === 1, 'the craft has one visit open');
check($history->visits([])[0]['open'] === true, 'flagged as still open');

$history->recordShips(ships(['Ore Hound' => [5, 5]]));
$history->recordShips(ships(['Ore Hound' => [5, 5]]));
check(count($history->visits([])) === 1,
      'polling a parked craft three times is still one visit, not three');

$history->recordShips(ships(['Ore Hound' => [6, 5]]));
$visits = $history->visits([]);
check(count($visits) === 2, 'moving closes the old visit and opens a new one');
check($visits[0]['x'] === 5 && $visits[1]['x'] === 6, 'in the order they happened');
check(!isset($visits[0]['open']) && $visits[1]['open'] === true,
      'and only the latest is still open');

// The partial unique index is what makes this safe under two pollers. Without it a race
// leaves two open rows for one craft and every later poll extends an arbitrary one.
$open = $pdo->query('SELECT COUNT(*) AS n FROM visits WHERE open')->fetch();
check((int) $open['n'] >= 1, 'the open visit is an ordinary row, not a separate file');

echo "\nheatmap\n";

$history->recordShips(ships(['Ore Hound' => [5, 5]]));
$history->recordShips(ships(['Ore Hound' => [6, 5]]));

$heat = $history->heatmap([]);
$cells = [];
foreach ($heat['cells'] as $cell) {
    $cells[$cell['x'] . ',' . $cell['y']] = $cell;
}

check(count($heat['cells']) === 2, 'two sectors have been occupied');
check($cells['5,5']['visits'] === 2, 'a sector entered twice counts twice');
check($heat['maxVisits'] === 2, 'and the peak is reported for scaling a colour ramp');
check($heat['ships'] === ['Ore Hound'], 'the craft that contributed are named');

$history->recordShips(ships(['Tug' => [9, 9]]));
check(count($history->heatmap(['ship' => 'Tug'])['cells']) === 1,
      'filtering by craft narrows the map to that craft');
check(count($history->heatmap([])['cells']) === 3, 'while the unfiltered map holds both');

echo "\nevents\n";

function feed(array $events, string $owner = 'player'): stdClass
{
    return (object) [
        'ship' => 'Ore Hound',
        'owner' => (object) ['kind' => $owner],
        'events' => array_map(static fn (array $e): object => (object) $e, $events),
    ];
}

$history->recordEvents('Ore Hound', feed([
    ['seq' => 1, 'kind' => 'status', 'text' => 'Patrolling Sector'],
    ['seq' => 2, 'kind' => 'status', 'text' => 'Idle'],
]));

$events = $history->events(['ship' => 'Ore Hound']);
check(count($events) === 2, 'both events are stored');
check($events[0]['text'] === 'Patrolling Sector', 'with their text intact');
check($events[0]['q'] === 1, 'and the mod\'s own sequence number');

// The console re-sends what it already has whenever it drops its cursor.
$history->recordEvents('Ore Hound', feed([
    ['seq' => 1, 'kind' => 'status', 'text' => 'Patrolling Sector'],
    ['seq' => 2, 'kind' => 'status', 'text' => 'Idle'],
    ['seq' => 3, 'kind' => 'status', 'text' => 'Jump not possible.'],
]));
check(count($history->events(['ship' => 'Ore Hound'])) === 3,
      'a replayed batch adds only what is new');

// A restart takes the mod's counter back to zero. Treating that as a replay would swallow
// every event until it climbed past the old mark, which on a busy galaxy is hours - and
// the unique index would otherwise reject seq 1 outright, which is why the epoch is in it.
$history->recordEvents('Ore Hound', feed([
    ['seq' => 1, 'kind' => 'status', 'text' => 'after the restart'],
]));
$events = $history->events(['ship' => 'Ore Hound']);
check(count($events) === 4, 'a sequence number going backwards is a restart, not a replay');
check(end($events)['text'] === 'after the restart', 'so the event is kept');

$epochs = $pdo->query('SELECT COUNT(DISTINCT epoch) AS n FROM events
                       WHERE ship = \'Ore Hound\'')->fetch();
check((int) $epochs['n'] === 2, 'the two runs are kept apart by epoch, so neither is lost');

$history->recordEvents('Tug', (object) [
    'ship' => 'Tug',
    'owner' => (object) ['kind' => 'alliance'],
    'events' => [(object) ['seq' => 7, 'kind' => 'status', 'text' => 'Alliance business']],
]);
check(count($history->events(['ship' => 'Tug'])) === 1, 'logs stay per craft');
check(count($history->events(['owner' => 'alliance'])) === 1,
      'and can be filtered to alliance craft');

echo "\nrecording the same batch twice\n";

// Two clients - the poller and an open console - routinely collect the same events. The
// unique index is what makes the second one a no-op rather than a duplicate or an error.
$twice = new History($key);
$twice->recordEvents('Tug', (object) [
    'ship' => 'Tug',
    'owner' => (object) ['kind' => 'alliance'],
    'events' => [(object) ['seq' => 7, 'kind' => 'status', 'text' => 'Alliance business']],
]);
check(count($history->events(['ship' => 'Tug'])) === 1,
      'a second client recording the same batch changes nothing');

echo "\nevent timestamps\n";

// A caller that has been away collects a backlog in one call. Stamping all of it with the
// arrival time puts an afternoon of events on one second, which makes the recorded log
// useless as a timeline - so the mod's own uptime stamps are used to space them.
$backlogKey = freshKey();
$madeKeys[] = $backlogKey;
$backlog = new History($backlogKey);
$backlog->recordEvents('Ore Hound', (object) [
    'ship' => 'Ore Hound',
    'owner' => (object) ['kind' => 'player'],
    'events' => [
        (object) ['seq' => 1, 'at' => 1000.0, 'kind' => 'status', 'text' => 'an hour ago'],
        (object) ['seq' => 2, 'at' => 4000.0, 'kind' => 'status', 'text' => 'ten minutes ago'],
        (object) ['seq' => 3, 'at' => 4600.0, 'kind' => 'status', 'text' => 'just now'],
    ],
]);

$stamps = array_column($backlog->events([]), 't');
check(count(array_unique($stamps)) === 3, 'a backlog does not collapse onto one timestamp');
check($stamps[2] - $stamps[1] === 600, 'events are spaced by the mod\'s own clock');
check($stamps[1] - $stamps[0] === 3000, 'across the whole batch');
check(abs($stamps[2] - time()) <= 2, 'and the newest is anchored to now');

// The stamp is best-effort: the mod pcalls for it and records 0 when that fails.
$backlog->recordEvents('Tug', (object) [
    'ship' => 'Tug',
    'owner' => (object) ['kind' => 'player'],
    'events' => [(object) ['seq' => 9, 'kind' => 'status', 'text' => 'no clock']],
]);
$row = $backlog->events(['ship' => 'Tug'])[0];
check(abs($row['t'] - time()) <= 2, 'an event with no clock stamp falls back to arrival time');

echo "\ntime filtering\n";

check(count($history->events(['from' => time() + 60])) === 0, 'a window in the future is empty');
check(count($history->events(['to' => time() - 60])) === 0, 'so is one in the past');
check(count($history->events(['from' => time() - 60, 'to' => time() + 60])) === 5,
      'and a window around now holds everything');
check(count($history->events(['limit' => 2])) === 2, 'a limit is honoured');

$newest = $history->events([]);
check($history->events(['limit' => 2])[1] === end($newest),
      'and keeps the newest, which is what a track wants');

echo "\nisolation\n";

// The whole point of keying by hash: a read needs no validation because an unknown key
// cannot address anyone else's rows.
$stranger = new History(freshKey());
check($stranger->visits([]) === [], 'another key sees none of these visits');
check($stranger->events([]) === [], 'and none of these events');
check($stranger->summary()['ships'] === [], 'and an empty summary');

echo "\nsummary\n";

$summary = $history->summary();
$byName = [];
foreach ($summary['ships'] as $ship) {
    $byName[$ship['name']] = $ship;
}

check(isset($byName['Ore Hound'], $byName['Tug']), 'every craft seen is listed');
check($byName['Ore Hound']['sectors'] === 2, 'with how many distinct sectors it has been in');
check($byName['Ore Hound']['events'] === 4, 'and how many events are held for it');
check($summary['rows'] > 0, 'the number of rows held is reported');
check($summary['recording'] === true, 'and that the store is live');

echo "\nretention\n";

// Pruning is by window, and must not take the visit a craft is still in the middle of -
// a craft parked somewhere for longer than the window is still there.
$pruneKey = freshKey();
$madeKeys[] = $pruneKey;
putenv('HISTORY_DAYS=1');
$prune = new History($pruneKey);
$prune->recordShips(ships(['Ore Hound' => [1, 1]]));
$prune->recordShips(ships(['Ore Hound' => [2, 2]]));

$keyRow = $pdo->prepare('SELECT id FROM api_keys WHERE key_hash = :h');
$keyRow->execute([':h' => hash('sha256', $pruneKey)]);
$pruneId = (int) $keyRow->fetch()['id'];

// Age the closed visit past the window.
$pdo->prepare('UPDATE visits SET entered_at = now() - interval \'5 days\',
                                 left_at = now() - interval \'5 days\'
               WHERE key_id = :k AND NOT open')->execute([':k' => $pruneId]);

check($prune->prune() === 1, 'a visit older than the window is dropped');
$left = $prune->visits([]);
check(count($left) === 1 && ($left[0]['open'] ?? false) === true,
      'and the visit still open is kept however old it is');
putenv('HISTORY_DAYS');

echo "\nclearing\n";

$history->clear('Tug');
check(count($history->events(['ship' => 'Tug'])) === 0, 'one craft can be dropped');
check(count($history->events(['ship' => 'Ore Hound'])) === 4, 'without touching the others');

$history->clear(null);
check($history->visits([]) === [] && $history->events([]) === [],
      'and the whole store can be dropped');
check($history->summary()['ships'] === [], 'leaving nothing behind');

$gone = $pdo->prepare('SELECT COUNT(*) AS n FROM api_keys WHERE key_hash = :h');
$gone->execute([':h' => hash('sha256', $key)]);
check((int) $gone->fetch()['n'] === 0, 'including the key row itself');

echo "\n";
if ($failures === 0) {
    echo "all checks passed\n";
    exit(0);
}

echo "$failures check(s) failed\n";
exit(1);
