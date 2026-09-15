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
 * restart under it, and two clients recording the same batch at once - and since rows
 * belong to factions rather than keys, that alliance history reaches every member and
 * nobody else, and that a database from before that change comes across intact.
 *
 * Every run uses freshly generated keys and faction indices, so it neither sees nor
 * disturbs anything already in the database it is pointed at. The upgrade test builds its
 * old schema in a schema of its own and drops it afterwards.
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

/** Likewise a faction index: players and alliances share one index space in the game. */
function freshFaction(): int
{
    global $madeFactions;

    $index = random_int(100000, 2000000000);
    $madeFactions[] = $index;

    return $index;
}

$madeKeys = [];
$madeFactions = [];

// Whatever happens, this run leaves the database as it found it.
register_shutdown_function(static function () use (&$madeKeys, &$madeFactions): void {
    try {
        $db = Db::connect();
        $factions = '{' . implode(',', $madeFactions) . '}';
        foreach (['visits', 'events', 'station_samples', 'faction_samples', 'event_marks',
                  'manifests', 'station_events'] as $table) {
            $db->prepare("DELETE FROM {$table} WHERE faction = ANY(CAST(:f AS bigint[]))")
               ->execute([':f' => $factions]);
        }
        $db->prepare('DELETE FROM factions WHERE id = ANY(CAST(:f AS bigint[]))')->execute([':f' => $factions]);
        foreach ($madeKeys as $made) {
            // Cascades to anything still recorded against the key itself.
            $db->prepare('DELETE FROM api_keys WHERE key_hash = :h')->execute([':h' => hash('sha256', $made)]);
        }
    } catch (Throwable) {
        // Nothing useful to do in a shutdown handler.
    }
});

/** A /ping answer, as the mod gives it. `$alliance` null is "in no alliance". */
function ping(int $player, ?int $alliance, string $name = 'Pilot', string $allianceName = 'Guild'): stdClass
{
    return (object) ['api' => 1, 'player' => (object) [
        'index' => $player,
        'name' => $name,
        'online' => true,
        'alliance' => $alliance === null ? null : (object) ['index' => $alliance, 'name' => $allianceName],
    ]];
}

/** A History for a new key belonging to `$player`, already vouched for by the mod. */
function member(int $player, ?int $alliance, string $name = 'Pilot'): History
{
    global $madeKeys;

    $key = freshKey();
    $madeKeys[] = $key;

    $history = new History($key);
    $history->recordPing(ping($player, $alliance, $name));

    return $history;
}

/** An owner as the mod describes one. The names match ping()'s, as the game's would. */
function owner(string $kind, int $index, ?string $name = null): stdClass
{
    return (object) ['kind' => $kind, 'index' => $index,
                     'name' => $name ?? ($kind === 'alliance' ? 'Guild' : 'Pilot')];
}

/** @param array<string, array{0: int, 1: int, 2?: stdClass}> $rows name => [x, y, owner] */
function ships(array $rows, stdClass $default): stdClass
{
    $ships = [];
    foreach ($rows as $name => $position) {
        $ships[] = (object) [
            'name' => $name,
            'position' => (object) ['x' => $position[0], 'y' => $position[1]],
            'owner' => $position[2] ?? $default,
        ];
    }

    return (object) ['ships' => $ships, 'count' => count($ships)];
}

function feed(string $ship, stdClass $owner, array $events): stdClass
{
    return (object) [
        'ship' => $ship,
        'owner' => $owner,
        'events' => array_map(static fn (array $e): object => (object) $e, $events),
    ];
}

$player = freshFaction();
$me = owner('player', $player, 'Rusty');

echo "\nkeying\n";

$key = freshKey();
$madeKeys[] = $key;
$history = new History($key);

check(!$history->exists(), 'a key that has never been used is not in the database at all');
check($history->visits([]) === [], 'and an unknown key reads an empty history, not a 500');

$history->recordShips(ships(['Ore Hound' => [5, 5]], $me));
check(!$history->exists(), 'recording a fleet does not claim the key for anyone');

$history->recordPing(ping($player, null, 'Rusty'));
check($history->exists(), 'the mod vouching for it with /ping does');

$stored = $pdo->query('SELECT key_hash FROM api_keys')->fetchAll();
$hashes = array_column($stored, 'key_hash');
check(!in_array($key, $hashes, true), 'the key itself is never stored');
check(in_array(hash('sha256', $key), $hashes, true), 'only a SHA-256 of it');

$scope = $history->scope();
check($scope['player'] === $player && $scope['alliance'] === null, 'and it reads as its player');

echo "\nvisits are written on movement, not on polling\n";

check(count($history->visits([])) === 1, 'the craft recorded before the ping belongs to its owner');
check($history->visits([])[0]['open'] === true, 'flagged as still open');

$history->recordShips(ships(['Ore Hound' => [5, 5]], $me));
$history->recordShips(ships(['Ore Hound' => [5, 5]], $me));
check(count($history->visits([])) === 1,
      'polling a parked craft three times is still one visit, not three');

$history->recordShips(ships(['Ore Hound' => [6, 5]], $me));
$visits = $history->visits([]);
check(count($visits) === 2, 'moving closes the old visit and opens a new one');
check($visits[0]['x'] === 5 && $visits[1]['x'] === 6, 'in the order they happened');
check(!isset($visits[0]['open']) && $visits[1]['open'] === true,
      'and only the latest is still open');

// The partial unique index is what makes this safe under two pollers. Without it a race
// leaves two open rows for one craft and every later poll extends an arbitrary one.
$open = $pdo->prepare('SELECT COUNT(*) AS n FROM visits WHERE faction = :f AND open');
$open->execute([':f' => $player]);
check((int) $open->fetch()['n'] === 1, 'the open visit is an ordinary row, one per craft');

echo "\nheatmap\n";

$history->recordShips(ships(['Ore Hound' => [5, 5]], $me));
$history->recordShips(ships(['Ore Hound' => [6, 5]], $me));

$heat = $history->heatmap([]);
$cells = [];
foreach ($heat['cells'] as $cell) {
    $cells[$cell['x'] . ',' . $cell['y']] = $cell;
}

check(count($heat['cells']) === 2, 'two sectors have been occupied');
check($cells['5,5']['visits'] === 2, 'a sector entered twice counts twice');
check($heat['maxVisits'] === 2, 'and the peak is reported for scaling a colour ramp');
check($heat['ships'] === ['Ore Hound'], 'the craft that contributed are named');

$history->recordShips(ships(['Tug' => [9, 9]], $me));
check(count($history->heatmap(['ship' => 'Tug'])['cells']) === 1,
      'filtering by craft narrows the map to that craft');
check(count($history->heatmap([])['cells']) === 3, 'while the unfiltered map holds both');

echo "\nevents\n";

$history->recordEvents('Ore Hound', feed('Ore Hound', $me, [
    ['seq' => 1, 'kind' => 'status', 'text' => 'Patrolling Sector'],
    ['seq' => 2, 'kind' => 'status', 'text' => 'Idle'],
]));

$events = $history->events(['ship' => 'Ore Hound']);
check(count($events) === 2, 'both events are stored');
check($events[0]['text'] === 'Patrolling Sector', 'with their text intact');
check($events[0]['q'] === 1, 'and the mod\'s own sequence number');

// The console re-sends what it already has whenever it drops its cursor.
$history->recordEvents('Ore Hound', feed('Ore Hound', $me, [
    ['seq' => 1, 'kind' => 'status', 'text' => 'Patrolling Sector'],
    ['seq' => 2, 'kind' => 'status', 'text' => 'Idle'],
    ['seq' => 3, 'kind' => 'status', 'text' => 'Jump not possible.'],
]));
check(count($history->events(['ship' => 'Ore Hound'])) === 3,
      'a replayed batch adds only what is new');

// A restart takes the mod's counter back to zero. Treating that as a replay would swallow
// every event until it climbed past the old mark, which on a busy galaxy is hours - and
// the unique index would otherwise reject seq 1 outright, which is why the epoch is in it.
$history->recordEvents('Ore Hound', feed('Ore Hound', $me, [
    ['seq' => 1, 'kind' => 'status', 'text' => 'after the restart'],
]));
$events = $history->events(['ship' => 'Ore Hound']);
check(count($events) === 4, 'a sequence number going backwards is a restart, not a replay');
check(end($events)['text'] === 'after the restart', 'so the event is kept');

$epochs = $pdo->prepare('SELECT COUNT(DISTINCT epoch) AS n FROM events WHERE faction = :f AND ship = \'Ore Hound\'');
$epochs->execute([':f' => $player]);
check((int) $epochs->fetch()['n'] === 2, 'the two runs are kept apart by epoch, so neither is lost');

$history->recordEvents('Tug', feed('Tug', $me, [['seq' => 7, 'kind' => 'status', 'text' => 'Towing']]));
check(count($history->events(['ship' => 'Tug'])) === 1, 'logs stay per craft');

echo "\nrecording the same batch twice\n";

// Two clients - the poller and an open console - routinely collect the same events. The
// unique index is what makes the second one a no-op rather than a duplicate or an error.
$twice = new History($key);
$twice->recordEvents('Tug', feed('Tug', $me, [['seq' => 7, 'kind' => 'status', 'text' => 'Towing']]));
check(count($history->events(['ship' => 'Tug'])) === 1,
      'a second client recording the same batch changes nothing');

echo "\none player, two keys\n";

// A player routinely has a key for the poller and another for the console. Those used to
// be two disjoint histories; the rows belong to the player, so they are one.
$secondKey = member($player, null, 'Rusty');
check(count($secondKey->events(['ship' => 'Tug'])) === 1, 'a second key of the same player reads the same log');
check(count($secondKey->heatmap([])['cells']) === 3, 'and the same travel');

echo "\nevent timestamps\n";

// A caller that has been away collects a backlog in one call. Stamping all of it with the
// arrival time puts an afternoon of events on one second, which makes the recorded log
// useless as a timeline - so the mod's own uptime stamps are used to space them.
$backlogPlayer = freshFaction();
$backlog = member($backlogPlayer, null);
$backlogOwner = owner('player', $backlogPlayer);
$backlog->recordEvents('Ore Hound', feed('Ore Hound', $backlogOwner, [
    ['seq' => 1, 'at' => 1000.0, 'kind' => 'status', 'text' => 'an hour ago'],
    ['seq' => 2, 'at' => 4000.0, 'kind' => 'status', 'text' => 'ten minutes ago'],
    ['seq' => 3, 'at' => 4600.0, 'kind' => 'status', 'text' => 'just now'],
]));

$stamps = array_column($backlog->events([]), 't');
check(count(array_unique($stamps)) === 3, 'a backlog does not collapse onto one timestamp');
check($stamps[2] - $stamps[1] === 600, 'events are spaced by the mod\'s own clock');
check($stamps[1] - $stamps[0] === 3000, 'across the whole batch');
check(abs($stamps[2] - time()) <= 2, 'and the newest is anchored to now');

// The stamp is best-effort: the mod pcalls for it and records 0 when that fails.
$backlog->recordEvents('Tug', feed('Tug', $backlogOwner, [['seq' => 9, 'kind' => 'status', 'text' => 'no clock']]));
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

$stranger = member(freshFaction(), null);
check($stranger->visits([]) === [], 'another player sees none of these visits');
check($stranger->events([]) === [], 'and none of these events');
check($stranger->summary()['ships'] === [], 'and an empty summary');

$nobody = new History(freshKey());
check($nobody->summary()['ships'] === [] && $nobody->summary()['recording'] === false,
      'a key the mod never vouched for reads nothing at all');

echo "\nalliance history is shared\n";

$guild = freshFaction();
$alice = freshFaction();
$bob = freshFaction();
$carol = freshFaction();

$aliceKey = member($alice, $guild);
$bobKey = member($bob, $guild);
$bobRaw = end($madeKeys);
$carolKey = member($carol, null);

$guildOwner = owner('alliance', $guild);

// Alice's poller records the alliance freighter and her own scout in one answer, which is
// what GET /ships?owner=all looks like.
$aliceKey->recordShips(ships([
    'Freighter' => [10, 10, $guildOwner],
    'Scout' => [1, 1, owner('player', $alice)],
], owner('player', $alice)));
$aliceKey->recordEvents('Freighter', feed('Freighter', $guildOwner, [
    ['seq' => 1, 'at' => 50.0, 'kind' => 'status', 'text' => 'Hauling'],
]));

$seen = array_column($bobKey->visits([]), 's');
check($seen === ['Freighter'], 'a fellow member reads the alliance craft another member recorded');
check(count($bobKey->events(['ship' => 'Freighter'])) === 1, 'and its events');
check($bobKey->events(['ship' => 'Scout']) === [] && !in_array('Scout', $seen, true),
      'but nothing of that member\'s own craft');
check($carolKey->visits([]) === [], 'and a player outside the alliance reads none of it');

// Bob's poller finds the freighter where Alice's did. Shared rows mean the second poll
// extends the visit instead of opening a copy of it.
$bobKey->recordShips(ships(['Freighter' => [10, 10, $guildOwner]], owner('player', $bob)));
$bobKey->recordEvents('Freighter', feed('Freighter', $guildOwner, [
    ['seq' => 1, 'at' => 50.0, 'kind' => 'status', 'text' => 'Hauling'],
    ['seq' => 2, 'at' => 80.0, 'kind' => 'status', 'text' => 'Docked'],
]));
check(count($aliceKey->visits(['ship' => 'Freighter'])) === 1,
      'two members polling one alliance craft still record one visit');
check(count($aliceKey->events(['ship' => 'Freighter'])) === 2,
      'and each event once, whoever collected it first');

$summary = $bobKey->summary();
check($summary['scope']['alliance']['index'] === $guild, 'the summary says whose history is included');
check($summary['scope']['alliance']['name'] === 'Guild', 'by name');

echo "\nmembership has to be current\n";

// Bob leaves the alliance. His key still works - it is his - and the mod says so.
$bobKey->recordPing(ping($bob, null));
check($bobKey->visits([]) === [], 'a player who left the alliance stops reading its history at once');

$bobKey->recordPing(ping($bob, $guild));
check(count($bobKey->visits([])) === 1, 'and reads it again on rejoining');

// A membership nobody has confirmed lately is not acted on. Age Bob's confirmation.
$pdo->prepare("UPDATE api_keys SET verified_at = now() - interval '1 day' WHERE player = :p")
    ->execute([':p' => $bob]);

$bobKeyHash = $pdo->prepare('SELECT key_hash FROM api_keys WHERE player = :p');
$bobKeyHash->execute([':p' => $bob]);
check(count($bobKeyHash->fetchAll()) === 1, '(one key for bob)');

$stale = new History($bobRaw);
check($stale->visits([]) === [], 'with nothing to re-check against, a stale membership reads no alliance rows');

$asked = 0;
$recheck = new History($bobRaw, static function () use (&$asked, $bob, $guild): array {
    $asked++;
    return ['status' => 200, 'body' => ping($bob, $guild)];
});
check(count($recheck->visits([])) === 1, 'a stale membership is re-checked with the mod, then honoured');
$recheck->heatmap([]);
$recheck->events([]);
check($asked === 1, 'and asked once per request, not once per query');

$again = new History($bobRaw, static function () use (&$asked): array {
    $asked++;
    return ['status' => 200, 'body' => new stdClass()];
});
$again->visits([]);
check($asked === 1, 'a fresh confirmation is not asked for again');

$pdo->prepare("UPDATE api_keys SET verified_at = now() - interval '1 day' WHERE player = :p")
    ->execute([':p' => $bob]);

$down = new History($bobRaw, static fn (): array => ['status' => 0, 'body' => null]);
check($down->scope()['alliance'] === null && $down->scope()['player'] === $bob,
      'with the game server down the player still reads their own rows, and not the alliance\'s');

$revoked = new History($bobRaw, static fn (): array => ['status' => 401, 'body' => null]);
check($revoked->scope()['player'] === null && $revoked->visits([]) === [],
      'a key the mod refuses reads nothing, not even what it recorded');

echo "\nsummary\n";

$summary = $history->summary();
$byName = [];
foreach ($summary['ships'] as $ship) {
    $byName[$ship['name']] = $ship;
}

check(isset($byName['Ore Hound'], $byName['Tug']), 'every craft seen is listed');
check($byName['Ore Hound']['sectors'] === 2, 'with how many distinct sectors it has been in');
check($byName['Ore Hound']['events'] === 4, 'and how many events are held for it');
check($byName['Ore Hound']['owner'] === 'player', 'and whose it is');
check($summary['rows'] > 0, 'the number of rows held is reported');
check($summary['recording'] === true, 'and that the store is live');
check($summary['scope']['player']['name'] === 'Rusty', 'the player is named from their ping');

echo "\nmanifests\n";

$aliceKey->recordManifest('Freighter', (object) [
    'name' => 'Freighter',
    'owner' => $guildOwner,
    'cargo' => (object) ['goods' => [(object) ['name' => 'Iron Ore', 'amount' => 400]]],
    'captain' => (object) ['name' => 'Vex'],
    'passengers' => [],
    'turrets' => ['not kept'],
]);

$manifests = $bobKey->manifests([]);
check(count($manifests) === 1 && $manifests[0]['ship'] === 'Freighter',
      'a hold one member read is there for the next');
check($manifests[0]['cargo']['goods'][0]['name'] === 'Iron Ore', 'with its goods');
check($manifests[0]['captain']['name'] === 'Vex', 'and who is aboard');
check(!isset($manifests[0]['turrets']), 'and nothing a search does not need');
check(abs($manifests[0]['at'] - time()) <= 2, 'stamped with when it was read');

$aliceKey->recordManifest('Freighter', (object) [
    'owner' => $guildOwner,
    'cargo' => (object) ['goods' => []],
]);
check(count($bobKey->manifests([])) === 1 && $bobKey->manifests([])[0]['cargo']['goods'] === [],
      'reading it again replaces it rather than adding a row');
check($carolKey->manifests([]) === [], 'and outsiders see none');

echo "\nretention\n";

// Pruning is by window, and must not take the visit a craft is still in the middle of -
// a craft parked somewhere for longer than the window is still there.
//
// Pruning covers the whole store now, so the window here is a year and the aged row two:
// nothing a real deployment still holds is old enough to be caught by it.
$prunePlayer = freshFaction();
$prune = member($prunePlayer, null);
$pruneOwner = owner('player', $prunePlayer);
putenv('HISTORY_DAYS=365');
$prune = new History(end($madeKeys));
$prune->recordShips(ships(['Ore Hound' => [1, 1]], $pruneOwner));
$prune->recordShips(ships(['Ore Hound' => [2, 2]], $pruneOwner));

// Age the closed visit past the window.
$pdo->prepare('UPDATE visits SET entered_at = now() - interval \'730 days\',
                                 left_at = now() - interval \'730 days\'
               WHERE faction = :f AND NOT open')->execute([':f' => $prunePlayer]);

check($prune->prune() >= 1, 'a visit older than the window is dropped');
$left = $prune->visits([]);
check(count($left) === 1 && ($left[0]['open'] ?? false) === true,
      'and the visit still open is kept however old it is');
putenv('HISTORY_DAYS');

echo "\nstation samples\n";

/*
 * The economy views differ from everything above in one way that shapes the whole test:
 * they answer with rates, and a rate needs samples at known, different times. The mod
 * reports running totals, and recordStations stamps a sample with now() and refuses a
 * second one for HISTORY_ECONOMY_INTERVAL - so a series cannot be built by calling it in
 * a loop. The rate-limit is tested through the public method, and the series is then
 * placed directly, which is the only way to control the clock.
 */
$tycoon = freshFaction();
$cartel = freshFaction();
$economy = member($tycoon, $cartel);

function stations(array $rows, stdClass $default): stdClass
{
    $out = [];

    foreach ($rows as $name => $row) {
        $out[] = (object) [
            'name' => $name,
            'owner' => $row['owner'] ?? $default,
            'position' => (object) ['x' => $row['x'] ?? 0, 'y' => $row['y'] ?? 0],
            'cargo' => (object) ['used' => 100.0, 'capacity' => 1000.0],
            'economy' => (object) [
                'kind' => $row['kind'] ?? 'factory',
                'production' => (object) [
                    'factory' => '${good} Refinery ${size}',
                    'title' => 'Oil Refinery',
                    'style' => 'Factory',
                    'slots' => 3,
                    'active' => 1,
                    'results' => [(object) ['name' => 'Oil']],
                ],
                'earnings' => (object) [
                    'fromGoods' => $row['gained'] ?? 0,
                    'spentOnGoods' => $row['spent'] ?? 0,
                    'fromTax' => $row['tax'] ?? 0,
                ],
                'stock' => (object) ($row['stock'] ?? []),
            ],
        ];
    }

    return (object) ['stations' => $out, 'count' => count($out)];
}

$tycoonOwner = owner('player', $tycoon);
$cartelOwner = owner('alliance', $cartel);

$economy->recordStations(stations(['Rusty Refinery' => ['gained' => 1000, 'x' => 12, 'y' => -4]], $tycoonOwner));

$count = static function () use ($pdo, $tycoon): int {
    $row = $pdo->query("SELECT COUNT(*) AS n FROM station_samples WHERE faction = {$tycoon}")->fetch();
    return (int) $row['n'];
};

check($count() === 1, 'a station listing is recorded as one sample');

// The poller calls every 30s and a console faster than that. Without the floor the table
// would grow by a row a pass per station, all of them copies: the mod reads these out of
// the craft's database row, which the game only rewrites when it saves.
$economy->recordStations(stations(['Rusty Refinery' => ['gained' => 1200, 'x' => 12, 'y' => -4]], $tycoonOwner));
check($count() === 1, 'a second listing inside the sample interval adds nothing');

// And the floor is per station, not per key: another member polling it is the same.
member(freshFaction(), $cartel)->recordStations(stations(['Rusty Refinery' => ['gained' => 1200]], $tycoonOwner));
check($count() === 1, 'nor does the same listing relayed through someone else\'s key');

$pdo->exec("DELETE FROM station_samples WHERE faction = {$tycoon}");

/** Places one sample at a known time, which recordStations cannot be made to do. */
function sample(PDO $pdo, int $faction, string $ship, int $ago, array $row): void
{
    $pdo->prepare(
        'INSERT INTO station_samples (faction, ship, owner, x, y, taken_at, gained, spent, tax, stock, data)
         VALUES (:f, :s, :o, 12, -4, now() - make_interval(secs => :ago), :g, :p, :a,
                 CAST(:st AS jsonb), CAST(:d AS jsonb))'
    )->execute([
        ':f' => $faction,
        ':s' => $ship,
        ':o' => $row['owner'] ?? 'player',
        ':ago' => $ago,
        ':g' => $row['gained'] ?? 0,
        ':p' => $row['spent'] ?? 0,
        ':a' => $row['tax'] ?? 0,
        ':st' => json_encode($row['stock'] ?? []),
        ':d' => json_encode(['kind' => 'factory',
                             'production' => ['factory' => '${good} Refinery ${size}',
                                              'title' => 'Oil Refinery',
                                              'results' => ['Oil']]]),
    ]);
}

// Two hours of a refinery, sampled every half hour. The counters only ever rise, which is
// what the game does while a station stands.
sample($pdo, $tycoon, 'Rusty Refinery', 7200, ['gained' => 1000, 'spent' => 400, 'tax' => 10,
                                               'stock' => ['Oil' => 100, 'Raw Oil' => 500]]);
sample($pdo, $tycoon, 'Rusty Refinery', 5400, ['gained' => 3000, 'spent' => 900, 'tax' => 30,
                                               'stock' => ['Oil' => 260, 'Raw Oil' => 380]]);
sample($pdo, $tycoon, 'Rusty Refinery', 3600, ['gained' => 5000, 'spent' => 1400, 'tax' => 50,
                                               'stock' => ['Oil' => 180, 'Raw Oil' => 260]]);
sample($pdo, $cartel, 'Alliance Exchange', 3600, ['gained' => 500, 'spent' => 0, 'tax' => 0,
                                                  'owner' => 'alliance', 'stock' => ['Ore' => 40]]);
sample($pdo, $cartel, 'Alliance Exchange', 1800, ['gained' => 900, 'spent' => 0, 'tax' => 0,
                                                  'owner' => 'alliance', 'stock' => ['Ore' => 90]]);

echo "\neconomy summary\n";

$summary = $economy->economySummary([]);
$byName = [];
foreach ($summary['stations'] as $station) {
    $byName[$station['ship']] = $station;
}

check(count($summary['stations']) === 2, 'both stations are reported, the player\'s and the alliance\'s');

$refinery = $byName['Rusty Refinery'];
check($refinery['earned'] === 4000, 'earnings are differenced, not reported as the running total');
check($refinery['spent'] === 1000, 'and so is what it spent');
check($refinery['tax'] === 40, 'and the tax it took');
check($refinery['net'] === 4000 + 40 - 1000, 'net is earned plus tax less spent');
check($refinery['observed'] === 3600, 'observed time is the span the samples actually cover');
check($refinery['perHour']['earned'] === 4000.0, 'the rate is per observed hour');
check($refinery['kind'] === 'factory', 'the station description travels with the sample');
check($refinery['produces'] === ['Oil'], 'including what it produces');
check($refinery['factoryTitle'] === 'Oil Refinery',
      'and the resolved factory name, which `kind` cannot give');

check($summary['totals']['earned'] === 4400, 'the totals add both stations up');
check($summary['totals']['stations'] === 2, 'and count them');

$mine = $economy->economySummary(['owner' => 'player']);
check(count($mine['stations']) === 1, 'the owner filter narrows it');

$one = $economy->economySummary(['ship' => 'Alliance Exchange']);
check(count($one['stations']) === 1 && $one['stations'][0]['earned'] === 400,
      'and so does naming one station');

$partner = member(freshFaction(), $cartel);
$theirs = $partner->economySummary([]);
check(count($theirs['stations']) === 1 && $theirs['stations'][0]['ship'] === 'Alliance Exchange',
      'another member reads the alliance\'s station and not the player\'s');

/*
 * The window applies to the later sample of each pair, and the scan below it does not
 * stop at the window edge. Asking for the last 45 minutes has to include the 3000 -> 5000
 * step, whose earlier half sits outside: the alternative silently loses whatever happened
 * between the last sample before the window and the first one inside it.
 */
$recent = $economy->economySummary(['from' => time() - 2700]);
check(count($recent['stations']) === 1 && $recent['stations'][0]['ship'] === 'Alliance Exchange',
      'a station whose last sample predates the window drops out of it');
check($recent['stations'][0]['earned'] === 400,
      'and the pair whose earlier half sits outside the window still counts, not zero');

echo "\none name, two owners\n";

// A player and their alliance can each own a "Rusty Refinery". Differenced as one series,
// the alliance's small counters would read as the player's station being reset.
sample($pdo, $cartel, 'Rusty Refinery', 3000, ['gained' => 10, 'owner' => 'alliance']);
sample($pdo, $cartel, 'Rusty Refinery', 2000, ['gained' => 30, 'owner' => 'alliance']);
$named = array_values(array_filter($economy->economySummary([])['stations'],
    static fn (array $s): bool => $s['ship'] === 'Rusty Refinery'));
$earned = array_column($named, 'earned', 'owner');
check(count($named) === 2, 'they are reported as two stations');
check(($earned['player'] ?? null) === 4000 && ($earned['alliance'] ?? null) === 20,
      'each differenced against its own samples');
$pdo->exec("DELETE FROM station_samples WHERE faction = {$cartel} AND ship = 'Rusty Refinery'");

echo "\na counter that went backwards\n";

// A station destroyed and rebuilt under the same name starts its books again at zero.
// Differencing that naively reports a refund of everything it ever made.
sample($pdo, $tycoon, 'Rusty Refinery', 900, ['gained' => 0, 'spent' => 0, 'tax' => 0,
                                              'stock' => ['Oil' => 0]]);
$afterReset = $economy->economySummary([]);
foreach ($afterReset['stations'] as $station) {
    if ($station['ship'] === 'Rusty Refinery') {
        check($station['earned'] === 4000, 'a reset counter contributes nothing, not a negative');
    }
}

echo "\neconomy series\n";

$series = $economy->economySeries(['ship' => 'Alliance Exchange'], 'hour');
check($series['bucket'] === 'hour', 'the bucket is echoed back');
check(count($series['points']) >= 1, 'the window is bucketed');

$earned = 0;
foreach ($series['points'] as $point) {
    $earned += $point['earned'];
}
check($earned === 400, 'and the buckets add up to the same total the summary reports');

$split = $economy->economySeries([], 'hour', true);
$shares = 0;
$totals = 0;
$named = [];
foreach ($split['points'] as $point) {
    $totals += $point['net'];
    foreach ($point['ships'] as $share) {
        $shares += $share['net'];
        $named[$share['ship']] = true;
    }
}
check(isset($named['Rusty Refinery'], $named['Alliance Exchange']),
      'split by ship, every station has its own share of the buckets');
check($shares === $totals, 'and the shares add up to each bucket\'s total');
check(!isset($series['points'][0]['ships']), 'the split is only there when asked for');

check(count($economy->economySeries(['x' => 12, 'y' => -4], 'hour')['points']) >= 1,
      'a sector filter keeps the stations in that sector');
check($economy->economySeries(['x' => 99, 'y' => 99], 'hour')['points'] === [],
      'and leaves out every other sector');

check($economy->economySeries([], 'nonsense')['bucket'] === 'hour',
      'an unknown bucket falls back to the hour rather than reaching the query');

echo "\neconomy goods\n";

$goods = [];
foreach ($economy->economyGoods(['ship' => 'Rusty Refinery'])['goods'] as $row) {
    $goods[$row['good']] = $row;
}

// Oil went 100 -> 260 -> 180 -> 0: 160 units appeared, then 80 and then 180 left.
check($goods['Oil']['in'] === 160, 'units that appeared are counted as in');
check($goods['Oil']['out'] === 260, 'and units that left as out');
check($goods['Oil']['net'] === -100, 'net is the difference');
check($goods['Oil']['stock'] === 0, 'stock is the latest reading');

// Raw Oil only ever drains, which is what an ingredient does.
check($goods['Raw Oil']['in'] === 0 && $goods['Raw Oil']['out'] === 240,
      'an ingredient that is only consumed shows no inflow');

echo "\nfaction ledger\n";

$economy->recordFactions((object) ['factions' => [
    (object) [
        'owner' => $tycoonOwner,
        'money' => 12500000,
        'resources' => [(object) ['material' => 'Iron', 'amount' => 40000]],
        'stations' => (object) ['count' => 2],
    ],
    (object) ['owner' => $cartelOwner, 'money' => 900],
]]);

$ledger = array_column($economy->economySummary([])['factions'], null, 'owner');
check(count($ledger) === 2, 'the faction ledger is sampled for the player and the alliance');
check($ledger['player']['money']['last'] === 12500000, 'with the balance');
check($ledger['player']['money']['change'] === 0, 'and no change from a single sample');
check((float) $ledger['player']['resources']['Iron'] === 40000.0,
      'resources are flattened to material -> amount');
check($ledger['player']['stations'] === 2, 'and the station count travels with it');

$economy->recordFactions((object) ['factions' => [
    (object) ['owner' => $tycoonOwner, 'money' => 99],
]]);
$ledger = array_column($economy->economySummary([])['factions'], null, 'owner');
check($ledger['player']['money']['last'] === 12500000,
      'a second ledger sample inside the interval is refused too');

$partnerLedger = $partner->economySummary([])['factions'];
check(count($partnerLedger) === 1 && $partnerLedger[0]['owner'] === 'alliance',
      'a fellow member sees the alliance\'s ledger and not the player\'s money');

echo "\neconomy in the summary\n";

$shape = $economy->summary();
check($shape['economy']['stations'] === 2, 'the store says how many stations it has samples for');
check($shape['economy']['samples'] > 0, 'and how many samples it holds');
check($shape['economy']['interval'] === 300, 'and the interval it is sampling at');

$economy->clear(null);
$left = $economy->economySummary([])['stations'];
check(count($left) === 1 && $left[0]['ship'] === 'Alliance Exchange',
      'clearing takes the player\'s samples and leaves the alliance\'s');

echo "\nstation activity\n";

/*
 * The mod's station feed, as GET /economy/events answers it: pages of trades, production
 * windows and reload catch-ups, numbered once per server run across every faction. Each
 * event names the faction that owns its station, and that is who the row belongs to.
 */
$tycoon = freshFaction();
$tycoonGuild = freshFaction();
$activity = member($tycoon, $tycoonGuild, 'Rusty');
$partner = member(freshFaction(), $tycoonGuild);
$outsider = member(freshFaction(), null);

$mine = owner('player', $tycoon, 'Rusty');
$ours = owner('alliance', $tycoonGuild);

// The feed's run ids are global, so a run of this test must not share one with another.
$bootA = 'boot-A-' . bin2hex(random_bytes(4));
$bootB = 'boot-B-' . bin2hex(random_bytes(4));

function feedPage(string $boot, float $now, int $cursor, bool $more, array $events): stdClass
{
    return (object) ['boot' => $boot, 'now' => $now, 'cursor' => $cursor, 'more' => $more,
                     'gap' => false, 'events' => $events];
}

function tradeEvent(int $seq, float $at, stdClass $owner, string $station, string $direction,
                    string $good, float $units, float $price, bool $internal = false): stdClass
{
    return (object) [
        'seq' => $seq, 'at' => $at, 'kind' => 'trade', 'station' => $station,
        'owner' => $owner, 'faction' => $owner->index,
        'sector' => (object) ['x' => 12, 'y' => -4],
        'direction' => $direction, 'good' => $good, 'units' => $units, 'price' => $price,
        'unitPrice' => $units > 0 ? $price / $units : 0, 'internal' => $internal,
        'channel' => 'docked',
    ];
}

function recipeOf(): array
{
    return [
        'results' => [(object) ['name' => 'Oil', 'amount' => 5]],
        'ingredients' => [(object) ['name' => 'Raw Oil', 'amount' => 10],
                          (object) ['name' => 'Fuel', 'amount' => 2, 'optional' => true]],
        'garbage' => [],
    ];
}

$window = (object) ([
    'seq' => 3, 'at' => 1000.0, 'kind' => 'production', 'station' => 'Rusty Refinery',
    'owner' => $mine, 'sector' => (object) ['x' => 12, 'y' => -4],
    'seconds' => 60, 'slotSeconds' => 180, 'busySlotSeconds' => 80, 'starvedSeconds' => 40,
    'blockedSeconds' => 20, 'idleSeconds' => 0, 'cycles' => 2, 'boosted' => 1, 'slots' => 3,
    'cycleSeconds' => 30,
] + recipeOf());

check($activity->stationEventCursor() === ['boot' => null, 'cursor' => 0],
      'a key that has never collected starts from zero');

$first = feedPage($bootA, 1000.0, 3, true, [
    tradeEvent(1, 400.0, $mine, 'Rusty Refinery', 'bought', 'Raw Oil', 200, 14000),
    tradeEvent(2, 700.0, $mine, 'Rusty Refinery', 'sold', 'Oil', 50, 17000),
    $window,
]);

$activity->recordStationEvents($first, true, 0);
$log = $activity->stationEvents([]);

check(count($log) === 3, 'a page of the feed is stored event by event');
check(abs($log[0]['t'] - (time() - 600)) <= 2,
      'dated off the server clock the page carries, not the time it arrived');
check($log[0]['direction'] === 'bought' && $log[0]['good'] === 'Raw Oil',
      'with the trade itself kept');
check($activity->stationEventCursor() === ['boot' => $bootA, 'cursor' => 3],
      'and an in-order page moves the collector\'s cursor');

$activity->recordStationEvents($first, true, 0);
check(count($activity->stationEvents([])) === 3, 'collecting the same page twice stores nothing new');

$catchup = (object) ([
    'seq' => 4, 'at' => 1500.0, 'kind' => 'catchup', 'station' => 'Rusty Refinery',
    'owner' => $mine, 'sector' => (object) ['x' => 12, 'y' => -4],
    'seconds' => 3600, 'cycles' => 120,
] + recipeOf());

$activity->recordStationEvents(feedPage($bootA, 1600.0, 5, false, [
    $catchup,
    tradeEvent(5, 1550.0, $mine, 'Rusty Refinery', 'bought', 'Raw Oil', 25, 0, true),
]), true, 3);
check($activity->stationEventCursor()['cursor'] === 5, 'the next page continues it');

// A console opening one station's newest events: stored, but no continuation.
$newest = (object) ['boot' => $bootA, 'now' => 2000.0, 'cursor' => 9, 'more' => false,
                    'station' => 'Rusty Refinery', 'owner' => $mine,
                    'events' => [(object) ['seq' => 9, 'at' => 1990.0, 'kind' => 'trade',
                                           'direction' => 'sold', 'good' => 'Oil', 'units' => 40,
                                           'price' => 13600, 'internal' => false]]];
$activity->recordStationEvents($newest);
check($activity->stationEventCursor()['cursor'] === 5,
      'a page that is not an in-order continuation leaves the cursor alone');
check(count($activity->stationEvents(['ship' => 'Rusty Refinery'])) === 6,
      'while the events on it are still kept, station and owner taken off the page');

// The server restarts: the new run numbers from zero again.
$restarted = feedPage($bootB, 50.0, 2, false, [
    tradeEvent(1, 40.0, $ours, 'Alliance Exchange', 'sold', 'Ore', 100, 3000),
]);
$restarted->events[0]->sector = (object) ['x' => 30, 'y' => 30];

$activity->recordStationEvents($restarted, true, 5);
check($activity->stationEventCursor() === ['boot' => $bootA, 'cursor' => 5],
      'a page from another server run does not move a cursor it was not asked from');

$activity->recordStationEvents($restarted, true, 0);
check($activity->stationEventCursor() === ['boot' => $bootB, 'cursor' => 2],
      'starting that run over from zero does');
check(count($activity->stationEvents(['ship' => 'Alliance Exchange'])) === 1,
      'and the same seq under a new run is a new event, stored once');

echo "\nstation activity belongs to the station's owner\n";

check(array_column($partner->stationEvents([]), 'station') === ['Alliance Exchange'],
      'another member reads the alliance\'s station activity, and none of the player\'s');
check($outsider->stationEvents([]) === [] && $outsider->economyObserved([])['stations'] === [],
      'someone outside the alliance reads none of it');

$partner->recordStationEvents($restarted, true, 0);
check(count($partner->stationEvents([])) === 1,
      'a second member collecting the same page stores nothing new');
check($partner->stationEventCursor() === ['boot' => $bootB, 'cursor' => 2]
      && $activity->stationEventCursor() === ['boot' => $bootB, 'cursor' => 2],
      'while each key keeps its own cursor');

$nameless = feedPage($bootB, 60.0, 3, false, [
    (object) ['seq' => 3, 'at' => 55.0, 'kind' => 'trade', 'station' => 'Somewhere',
              'owner' => (object) ['kind' => 'alliance'], 'direction' => 'sold', 'good' => 'Ore',
              'units' => 1, 'price' => 30, 'internal' => false],
]);
$activity->recordStationEvents($nameless);
check($activity->stationEvents(['ship' => 'Somewhere']) === [],
      'an alliance event that does not say which alliance is not guessed at');

echo "\nobserved economy\n";

$observed = $activity->economyObserved(['ship' => 'Rusty Refinery']);
check(count($observed['stations']) === 1, 'one row per station');

$refinery = $observed['stations'][0];
$production = $refinery['production'];

check($production['cycles'] == 2 && $production['catchupCycles'] == 120,
      'live and catch-up cycles are counted apart');
check(abs($production['utilization'] - 80 / 180) < 0.001, 'utilisation is busy slot time over slot time');
check($production['starvedSeconds'] == 40 && $production['blockedSeconds'] == 20,
      'with the reasons for idle slots summed');
check(abs($production['cyclesPerHour'] - 122 * 3600 / 3660) < 0.01,
      'and a rate over running and catch-up time together');
check($production['slots'] === 3 && $production['cycleSeconds'] == 30,
      'and the line described as its latest window reports it');
check($refinery['span'] == 3660, 'span is that same running time');

$byGood = [];
foreach ($refinery['goods'] as $row) {
    $byGood[$row['good']] = $row;
}

check($byGood['Oil']['made'] == 610, 'units made are cycles times the recipe each window carried');
check($byGood['Raw Oil']['used'] == 1220, 'and so are units used');
check($byGood['Fuel']['used'] == 2, 'an optional ingredient only on boosted cycles, and never on catch-up');
check($byGood['Raw Oil']['bought']['units'] == 200 && $byGood['Raw Oil']['bought']['unitPrice'] == 70,
      'trades are summed per good with the price they happened at');
check($byGood['Raw Oil']['internalIn'] == 25, 'an internal delivery is movement and not a price');
check($byGood['Oil']['sold']['units'] == 90 && $byGood['Oil']['sold']['unitPrice'] == 340,
      'every recorded sale counts, however it was collected');
check(abs($byGood['Oil']['madePerHour'] - 610 * 3600 / 3660) < 0.01, 'and made per hour of span');

check($refinery['traded']['net'] == 30600 - 14000, 'traded net is sales less purchases');

check(count($activity->economyObserved(['x' => 30, 'y' => 30])['stations']) === 1,
      'a sector filter reads one sector');
check($activity->economyObserved(['owner' => 'alliance'])['stations'][0]['ship'] === 'Alliance Exchange',
      'and an owner filter one owner');
check($activity->economyObserved(['ship' => 'Rusty Refinery', 'from' => time() + 60])['stations'] === [],
      'a window after everything reads empty');

check(count($activity->stationEvents(['kind' => 'production'])) === 1, 'the log can be narrowed to one kind');

// A player and their alliance can each own a station of the same name.
$activity->recordStationEvents(feedPage($bootB, 100.0, 5, false, [
    tradeEvent(4, 90.0, $mine, 'Twin Yard', 'sold', 'Steel', 10, 1000),
    tradeEvent(5, 95.0, $ours, 'Twin Yard', 'sold', 'Steel', 20, 3000),
]));
$twins = $activity->economyObserved(['ship' => 'Twin Yard'])['stations'];
check(count($twins) === 2 && array_sum(array_map(static fn ($t) => $t['traded']['sold'], $twins)) == 4000,
      'and they are kept apart rather than summed as one');

$shape = $activity->summary();
check($shape['economy']['events'] === 9 && $shape['economy']['recordedStations'] === 4,
      'the summary says how much activity is stored');

$activity->clear('Rusty Refinery');
check($activity->economyObserved(['ship' => 'Rusty Refinery'])['stations'] === [],
      'clearing a station takes its activity with it');

$activity->clear(null);
check(array_column($activity->stationEvents([]), 'station') === ['Alliance Exchange', 'Twin Yard'],
      'and clearing everything takes the player\'s activity and leaves the alliance\'s');
check($activity->stationEventCursor()['cursor'] === 2,
      'without rewinding the collector into re-recording what was just thrown away');

echo "\nclearing\n";

$history->clear('Tug');
check(count($history->events(['ship' => 'Tug'])) === 0, 'one craft can be dropped');
check(count($history->events(['ship' => 'Ore Hound'])) === 4, 'without touching the others');

$history->clear(null);
check($history->visits([]) === [] && $history->events([]) === [],
      'and the whole store can be dropped');
check($history->summary()['ships'] === [], 'leaving nothing behind');
check($secondKey->visits([]) === [], 'for every key of that player, since it was one history');

$aliceKey->clear(null);
check(count($bobKey->visits([])) === 1 && $aliceKey->visits([]) !== [],
      'a member clearing their history leaves the alliance\'s alone');

echo "\nupgrading a version 2 database\n";

/*
 * Built for real rather than simulated: the old schema is created from Db's own version 2
 * statements in a schema of its own, filled the way the old code filled it, and then
 * migrated by the same call the bridge makes on its first connection.
 */
$upgradeSchema = 'upgrade_' . bin2hex(random_bytes(4));

$old = new PDO(Db::dsn(), (string) (getenv('HISTORY_DB_USER') ?: 'avorion'),
               (string) (getenv('HISTORY_DB_PASSWORD') ?: ''), [
    PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
    PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
    PDO::ATTR_EMULATE_PREPARES => false,
]);
$old->exec("CREATE SCHEMA {$upgradeSchema}");
$old->exec("SET search_path TO {$upgradeSchema}");

$swap = static function (?PDO $to): void {
    Db::reset();
    if ($to !== null) {
        (new ReflectionProperty(Db::class, 'pdo'))->setValue(null, $to);
    }
};

try {
    $base = new ReflectionMethod(Db::class, 'base');
    foreach ($base->invoke(null) as $sql) {
        $old->exec($sql);
    }
    $old->exec('INSERT INTO api_schema (version) VALUES (2)');

    $keyOne = freshKey();
    $keyTwo = freshKey();
    $keyThree = freshKey();

    $insertKey = $old->prepare('INSERT INTO api_keys (key_hash) VALUES (:h) RETURNING id');
    $ids = [];
    foreach ([$keyOne, $keyTwo, $keyThree] as $made) {
        $insertKey->execute([':h' => hash('sha256', $made)]);
        $ids[$made] = (int) $insertKey->fetch()['id'];
    }
    [$k1, $k2, $k3] = array_values($ids);

    $visit = $old->prepare(
        "INSERT INTO visits (key_id, ship, owner, x, y, entered_at, left_at, open)
         VALUES (:k, :s, :o, :x, :y, now() - make_interval(secs => :from),
                 now() - make_interval(secs => :to), :open)"
    );
    $event = $old->prepare(
        "INSERT INTO events (key_id, ship, owner, epoch, seq, happened_at, data)
         VALUES (:k, :s, :o, :e, :q, now() - make_interval(secs => :ago), CAST(:d AS jsonb))"
    );
    $state = $old->prepare('INSERT INTO ship_state (key_id, ship, epoch, max_seq) VALUES (:k, :s, :e, :m)');

    // Key one: a player craft of its own, and the alliance freighter.
    $visit->execute([':k' => $k1, ':s' => 'Scout', ':o' => 'player', ':x' => 1, ':y' => 1,
                     ':from' => 3600, ':to' => 1800, ':open' => 'false']);
    $visit->execute([':k' => $k1, ':s' => 'Scout', ':o' => 'player', ':x' => 2, ':y' => 1,
                     ':from' => 1800, ':to' => 0, ':open' => 'true']);
    $visit->execute([':k' => $k1, ':s' => 'Freighter', ':o' => 'alliance', ':x' => 7, ':y' => 7,
                     ':from' => 3000, ':to' => 60, ':open' => 'true']);
    $event->execute([':k' => $k1, ':s' => 'Freighter', ':o' => 'alliance', ':e' => 0, ':q' => 1,
                     ':ago' => 2000, ':d' => '{"at": 100, "text": "Hauling"}']);
    $event->execute([':k' => $k1, ':s' => 'Freighter', ':o' => 'alliance', ':e' => 0, ':q' => 2,
                     ':ago' => 1000, ':d' => '{"at": 1100, "text": "Docked"}']);
    $event->execute([':k' => $k1, ':s' => 'Scout', ':o' => 'player', ':e' => 0, ':q' => 1,
                     ':ago' => 500, ':d' => '{"at": 1600, "text": "Scouting"}']);
    $state->execute([':k' => $k1, ':s' => 'Freighter', ':e' => 0, ':m' => 2]);
    $old->prepare(
        "INSERT INTO station_samples (key_id, ship, owner, taken_at, gained)
         VALUES (:k, 'Depot', 'alliance', now() - interval '1 hour', 100),
                (:k2, 'Depot', 'alliance', now() - interval '10 minutes', 400)"
    )->execute([':k' => $k1, ':k2' => $k1]);
    $old->prepare(
        "INSERT INTO faction_samples (key_id, owner, taken_at, money) VALUES (:k, 'player', now(), 5000)"
    )->execute([':k' => $k1]);

    // Key two: another member, who watched the same freighter over an overlapping stretch
    // and collected one of the same events - with a different restart count, as a key
    // that started polling at a different time would have.
    $visit->execute([':k' => $k2, ':s' => 'Freighter', ':o' => 'alliance', ':x' => 7, ':y' => 7,
                     ':from' => 3500, ':to' => 0, ':open' => 'true']);
    $event->execute([':k' => $k2, ':s' => 'Freighter', ':o' => 'alliance', ':e' => 3, ':q' => 2,
                     ':ago' => 990, ':d' => '{"at": 1100, "text": "Docked"}']);
    $event->execute([':k' => $k2, ':s' => 'Freighter', ':o' => 'alliance', ':e' => 3, ':q' => 3,
                     ':ago' => 100, ':d' => '{"at": 2000, "text": "Undocked"}']);
    $state->execute([':k' => $k2, ':s' => 'Freighter', ':e' => 3, ':m' => 3]);

    // Key three: someone who has since left the alliance, holding a copy of its craft.
    $visit->execute([':k' => $k3, ':s' => 'Freighter', ':o' => 'alliance', ':x' => 7, ':y' => 7,
                     ':from' => 5000, ':to' => 4000, ':open' => 'false']);
    $visit->execute([':k' => $k3, ':s' => 'Canoe', ':o' => 'player', ':x' => 0, ':y' => 0,
                     ':from' => 100, ':to' => 0, ':open' => 'true']);

    $swap($old);
    Db::migrate($old);

    $version = (int) $old->query('SELECT version FROM api_schema')->fetch()['version'];
    check($version === 4, 'the migration brings it up to date');
    check((int) $old->query('SELECT COUNT(*) AS n FROM api_keys WHERE legacy')->fetch()['n'] === 3,
          'every existing key is flagged for adoption');
    check((int) $old->query('SELECT COUNT(*) AS n FROM visits WHERE faction IS NULL')->fetch()['n'] === 6,
          'and no row has been given an owner it cannot know yet');

    $one = new History($keyOne);
    $two = new History($keyTwo);
    check(count($one->visits([])) === 3 && count($one->events([])) === 3,
          'before its next ping, a key still reads exactly what it recorded');
    check(count($two->visits([])) === 1, 'and only that');

    $upgradeGuild = freshFaction();
    $pOne = freshFaction();
    $pTwo = freshFaction();
    $pThree = freshFaction();

    $one->recordPing(ping($pOne, $upgradeGuild));

    check((int) $old->query("SELECT COUNT(*) AS n FROM visits WHERE key_id = {$k1}")->fetch()['n'] === 0,
          'its first ping moves every one of its rows onto an owner');
    check(count($one->visits([])) === 3 && count($one->events([])) === 3,
          'and it reads the same history as before');
    check($one->economySummary([])['stations'][0]['earned'] === 300,
          'including the station series, still differenced correctly');

    $bystander = new History(freshKey());
    $bystander->recordPing(ping($pTwo, $upgradeGuild));
    check(array_column($bystander->visits([]), 's') === ['Freighter'],
          'another member reads the adopted alliance craft at once');
    check($bystander->events(['ship' => 'Scout']) === [], 'and none of the player\'s');

    $two->recordPing(ping($pTwo, $upgradeGuild));

    $freighter = $two->visits(['ship' => 'Freighter']);
    check(count($freighter) === 1, 'a second member\'s copy of the same stay merges into one visit');
    check(($freighter[0]['open'] ?? false) === true, 'still open');
    check($freighter[0]['e'] - $freighter[0]['t'] >= 3490,
          'widened to cover what either of them saw');

    $texts = array_column($two->events(['ship' => 'Freighter']), 'text');
    sort($texts);
    check($texts === ['Docked', 'Hauling', 'Undocked'],
          'an event both collected is kept once, and each one only one of them saw is kept');

    $marks = $old->query("SELECT epoch, max_seq FROM event_marks WHERE faction = {$upgradeGuild} AND ship = 'Freighter'")->fetch();
    check((int) $marks['max_seq'] === 3, 'the restart marks merge to the furthest either had seen');

    // The mod's ring buffer still holds these after the upgrade, and a poll will offer them.
    $two->recordEvents('Freighter', feed('Freighter', owner('alliance', $upgradeGuild), [
        ['seq' => 1, 'at' => 100, 'text' => 'Hauling'],
        ['seq' => 2, 'at' => 1100, 'text' => 'Docked'],
        ['seq' => 3, 'at' => 2000, 'text' => 'Undocked'],
    ]));
    check(count($two->events(['ship' => 'Freighter'])) === 3,
          'events the old rows already hold are not recorded again after adoption');

    $three = new History($keyThree);
    $three->recordPing(ping($pThree, null));
    check(array_column($three->visits(['owner' => 'player']), 's') === ['Canoe'],
          'a player now in no alliance keeps their own craft');
    check(count($three->visits(['ship' => 'Freighter'])) === 1,
          'and their old copy of the alliance\'s craft, readable by that key alone');
    check(count($two->visits(['ship' => 'Freighter'])) === 1,
          'which is not merged into an alliance they are no longer in');

    $three->recordPing(ping($pThree, freshFaction()));
    check(count($three->visits(['ship' => 'Freighter'])) === 1
          && (int) $old->query("SELECT COUNT(*) AS n FROM visits WHERE key_id = {$k3} AND faction IS NULL")->fetch()['n'] === 1,
          'nor carried into the next alliance they join');

    check((int) $old->query('SELECT COUNT(*) AS n FROM api_keys WHERE legacy')->fetch()['n'] === 0,
          'and no key is left waiting for adoption');
    check((int) $old->query("SELECT COUNT(*) AS n FROM ship_state")->fetch()['n'] === 0,
          'the old per-key restart marks are gone');
} finally {
    $swap(null);
    $old->exec('SET search_path TO public');
    $old->exec("DROP SCHEMA {$upgradeSchema} CASCADE");
}

echo "\nupgrading a database from the first station activity branch\n";

/*
 * That branch numbered its schema 3 too: version 2 plus key-owned station tables, and none
 * of the ownership step. Taken on its word it would never get that step at all.
 */
$branchSchema = 'upgrade_' . bin2hex(random_bytes(4));
$old->exec("CREATE SCHEMA {$branchSchema}");
$old->exec("SET search_path TO {$branchSchema}");

try {
    foreach ((new ReflectionMethod(Db::class, 'base'))->invoke(null) as $sql) {
        $old->exec($sql);
    }
    $old->exec('CREATE TABLE station_events (id BIGSERIAL PRIMARY KEY,
                    key_id BIGINT NOT NULL REFERENCES api_keys(id) ON DELETE CASCADE,
                    station TEXT NOT NULL, boot TEXT NOT NULL, seq BIGINT NOT NULL)');
    $old->exec('CREATE TABLE station_feed_state (key_id BIGINT PRIMARY KEY, boot TEXT NOT NULL,
                    cursor BIGINT NOT NULL DEFAULT 0)');
    $old->exec('INSERT INTO api_schema (version) VALUES (3)');

    $swap($old);
    Db::migrate($old);

    $column = static fn (string $table, string $name): bool => $old->query(
        "SELECT 1 FROM information_schema.columns WHERE table_schema = '{$branchSchema}'
           AND table_name = '{$table}' AND column_name = '{$name}'"
    )->fetch() !== false;

    check((int) $old->query('SELECT version FROM api_schema')->fetch()['version'] === 4,
          'it is brought up to date');
    check($column('api_keys', 'legacy') && $column('visits', 'faction'),
          'including the ownership step it claimed to have');
    check($column('station_events', 'faction') && !$column('station_events', 'key_id'),
          'and its key-owned station table is replaced by the owned one');
} finally {
    $swap(null);
    $old->exec('SET search_path TO public');
    $old->exec("DROP SCHEMA {$branchSchema} CASCADE");
}

echo "\n";
if ($failures === 0) {
    echo "all checks passed\n";
    exit(0);
}

echo "$failures check(s) failed\n";
exit(1);
