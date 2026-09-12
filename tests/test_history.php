<?php

declare(strict_types=1);

/**
 * The bridge's durable history store.
 *
 * Runs outside Docker against a throwaway directory:
 *
 *   docker run --rm -v "$PWD:/w" -w /w dunglas/frankenphp:1-php8.3-alpine \
 *       php tests/test_history.php
 *
 * What it pins is the awkward half: the store is fed by whatever calls happen to be made,
 * so it has to survive a caller that polls irregularly, a server whose sequence numbers
 * restart under it, and two threads writing at once.
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

$root = sys_get_temp_dir() . '/avo-history-' . bin2hex(random_bytes(6));
register_shutdown_function(static function () use ($root): void {
    if (!is_dir($root)) {
        return;
    }
    foreach (glob($root . '/*/*') ?: [] as $file) {
        @unlink($file);
    }
    foreach (glob($root . '/*') ?: [] as $dir) {
        @rmdir($dir);
    }
    @rmdir($root);
});

$key = 'avo_' . str_repeat('a', 64);
$history = new History($root, $key);

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

check(!$history->exists(), 'a key that has never been used has no directory at all');
check(!str_contains($history->directory(), $key), 'and the key itself is never a path');

$other = new History($root, 'avo_' . str_repeat('b', 64));
check($other->directory() !== $history->directory(), 'two keys land in two directories');
check($other->visits([]) === [], 'and an unknown key reads an empty history, not a 500');

echo "\nvisits are written on movement, not on polling\n";

$history->recordShips(ships(['Ore Hound' => [5, 5]]));
check($history->exists(), 'the first recorded answer creates the store');
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

// A restart takes the mod's global counter back to zero. Treating that as a replay would
// swallow every event until it climbed past the old mark, which on a busy galaxy is hours.
$history->recordEvents('Ore Hound', feed([
    ['seq' => 1, 'kind' => 'status', 'text' => 'after the restart'],
]));
$events = $history->events(['ship' => 'Ore Hound']);
check(count($events) === 4, 'a sequence number going backwards is a restart, not a replay');
check(end($events)['text'] === 'after the restart', 'so the event is kept');

$history->recordEvents('Tug', (object) [
    'ship' => 'Tug',
    'owner' => (object) ['kind' => 'alliance'],
    'events' => [(object) ['seq' => 7, 'kind' => 'status', 'text' => 'Alliance business']],
]);
check(count($history->events(['ship' => 'Tug'])) === 1, 'logs stay per craft');
check(count($history->events(['owner' => 'alliance'])) === 1,
      'and can be filtered to alliance craft');

echo "\nevent timestamps\n";

// A caller that has been away collects a backlog in one call. Stamping all of it with the
// arrival time puts an afternoon of events on one second, which makes the recorded log
// useless as a timeline - so the mod's own uptime stamps are used to space them.
$backlog = new History($root, 'avo_' . str_repeat('c', 64));
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

$backlog->clear(null);

echo "\ntime filtering\n";

check(count($history->events(['from' => time() + 60])) === 0, 'a window in the future is empty');
check(count($history->events(['to' => time() - 60])) === 0, 'so is one in the past');
check(count($history->events(['from' => time() - 60, 'to' => time() + 60])) === 5,
      'and a window around now holds everything');
check(count($history->events(['limit' => 2])) === 2, 'a limit is honoured');

echo "\nsummary\n";

$summary = $history->summary();
$byName = [];
foreach ($summary['ships'] as $ship) {
    $byName[$ship['name']] = $ship;
}

check(isset($byName['Ore Hound'], $byName['Tug']), 'every craft seen is listed');
check($byName['Ore Hound']['sectors'] === 2, 'with how many distinct sectors it has been in');
check($byName['Ore Hound']['events'] === 4, 'and how many events are held for it');
check($summary['bytes'] > 0, 'the size on disk is reported');
check($summary['recording'] === true, 'and that the store is live');

echo "\nclearing\n";

$history->clear('Tug');
check(count($history->events(['ship' => 'Tug'])) === 0, 'one craft can be dropped');
check(count($history->events(['ship' => 'Ore Hound'])) === 4, 'without touching the others');

$history->clear(null);
check($history->visits([]) === [] && $history->events([]) === [],
      'and the whole store can be dropped');
check($history->summary()['ships'] === [], 'leaving nothing behind');

echo "\ntorn lines\n";

$history->recordShips(ships(['Ore Hound' => [1, 1]]));
$history->recordShips(ships(['Ore Hound' => [2, 2]]));
file_put_contents($history->directory() . '/visits.jsonl', '{"t":1,"s":"Half' . "\n",
                  FILE_APPEND);
check(count($history->visits([])) === 2,
      'an unparseable line is skipped rather than failing the read');

echo "\n";
if ($failures === 0) {
    echo "all checks passed\n";
    exit(0);
}

echo "$failures check(s) failed\n";
exit(1);
