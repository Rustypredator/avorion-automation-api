<?php

declare(strict_types=1);

/**
 * Push notifications: the rules, and what comes out of them.
 *
 * Needs a Postgres, like tests/test_history.php - tools/dbtest.sh starts a throwaway one
 * and runs both against it.
 *
 * What it pins is the part that is easy to get subtly wrong and impossible to notice:
 * an alert that fires once when a line is crossed rather than once a pass for as long as
 * it stays crossed, a first evaluation that does not replay a month of history onto
 * somebody's phone, and the scoping - notifications belong to a player, and one member
 * of an alliance must not configure or receive another's.
 *
 * Delivery is tested against a real HTTP server: PHP's own, started here on localhost,
 * which records what it was sent. That is the only way to check the shape of an ntfy or
 * Gotify payload, and it is cheap. Where it cannot be started the delivery checks say so
 * and are skipped rather than failing.
 *
 * Every run uses freshly generated keys and faction indices and cleans up after itself.
 */

require __DIR__ . '/../docker/bridge/src/notifications.php';

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

function skip(string $message): void
{
    echo "  skip $message\n";
}

if (!Db::enabled()) {
    fwrite(STDERR, "test_notifications.php needs a database: set HISTORY_DB_HOST and "
                 . "friends, or run tools/dbtest.sh which starts one.\n");
    exit(2);
}

try {
    Db::connect();
} catch (Throwable $e) {
    fwrite(STDERR, 'test_notifications.php cannot reach the database: ' . $e->getMessage() . "\n");
    exit(2);
}

$madeKeys = [];
$madePlayers = [];

function freshKey(): string
{
    global $madeKeys;

    $key = 'avo_' . bin2hex(random_bytes(32));
    $madeKeys[] = $key;

    return $key;
}

function freshFaction(): int
{
    global $madePlayers;

    $index = random_int(100000, 2000000000);
    $madePlayers[] = $index;

    return $index;
}

register_shutdown_function(static function () use (&$madeKeys, &$madePlayers): void {
    try {
        $db = Db::connect();
        $factions = '{' . implode(',', $madePlayers) . '}';

        // Rules cascade to marks, and notifications to nothing - so both are named.
        foreach (['notifications', 'notification_rules', 'notification_channels',
                  'notification_watch'] as $table) {
            $db->prepare("DELETE FROM {$table} WHERE player = ANY(CAST(:f AS bigint[]))")
               ->execute([':f' => $factions]);
        }
        foreach (['events', 'event_marks'] as $table) {
            $db->prepare("DELETE FROM {$table} WHERE faction = ANY(CAST(:f AS bigint[]))")
               ->execute([':f' => $factions]);
        }
        $db->prepare('DELETE FROM factions WHERE id = ANY(CAST(:f AS bigint[]))')
           ->execute([':f' => $factions]);
        foreach ($madeKeys as $made) {
            $db->prepare('DELETE FROM api_keys WHERE key_hash = :h')
               ->execute([':h' => hash('sha256', $made)]);
        }
    } catch (Throwable) {
        // Nothing useful to do in a shutdown handler.
    }
});

/** A /ping answer, as the mod gives it. */
function ping(int $player, ?int $alliance): stdClass
{
    return (object) ['api' => 1, 'player' => (object) [
        'index' => $player,
        'name' => 'Pilot',
        'online' => true,
        'alliance' => $alliance === null ? null : (object) ['index' => $alliance, 'name' => 'Guild'],
    ]];
}

/** A vouched-for key belonging to `$player`, and the store that goes with it. */
function member(int $player, ?int $alliance = null): Notifications
{
    $history = new History(freshKey());
    $history->recordPing(ping($player, $alliance));

    return new Notifications($history);
}

function owner(string $kind, int $index): stdClass
{
    return (object) ['kind' => $kind, 'index' => $index, 'name' => $kind === 'alliance' ? 'Guild' : 'Pilot'];
}

/**
 * One craft as GET /ships describes it.
 *
 * @param array{hull?: float, shield?: float} $condition
 */
function craft(string $name, stdClass $owner, array $condition = []): stdClass
{
    return (object) [
        'name' => $name,
        'owner' => $owner,
        'position' => (object) ['x' => 0, 'y' => 0],
        'condition' => $condition === [] ? null : (object) $condition,
    ];
}

/** Puts craft events in the table the way the poller's relayed reads do. */
$eventSeq = 0;

function record(History $history, string $ship, stdClass $owner, array $events): void
{
    global $eventSeq;

    $made = [];
    foreach ($events as $event) {
        $eventSeq++;
        $made[] = (object) ($event + ['seq' => $eventSeq, 'at' => 1000 + $eventSeq]);
    }

    $history->recordEvents($ship, (object) ['ship' => $ship, 'owner' => $owner, 'events' => $made]);
}

/** The undelivered outbox of one player, newest last. */
function outbox(int $player): array
{
    $rows = Db::connect()->prepare(
        'SELECT kind, ship, title, body, priority, rule FROM notifications
         WHERE player = :p ORDER BY id'
    );
    $rows->execute([':p' => $player]);

    return $rows->fetchAll();
}

function clearOutbox(int $player): void
{
    Db::connect()->prepare('DELETE FROM notifications WHERE player = :p')->execute([':p' => $player]);
}

/* ------------------------------- channels -------------------------------- */

echo "\nchannels\n";

$stranger = new Notifications(new History(freshKey()));
check($stranger->player() === null, 'a key the mod has never vouched for is nobody');
check($stranger->channels() === [], 'and reads no channels');
check(($stranger->saveChannel(['name' => 'x'])['error']['status'] ?? 0) === 401,
      'and cannot make one');

$player = freshFaction();
$me = member($player);

$result = $me->saveChannel(['name' => 'Phone', 'kind' => 'ntfy',
                            'url' => 'https://ntfy.sh', 'config' => []]);
check(($result['error']['code'] ?? '') === 'bad_channel', 'ntfy without a topic is refused');

$result = $me->saveChannel(['name' => 'Phone', 'kind' => 'ntfy',
                            'url' => 'ntfy.sh', 'config' => ['topic' => 'avorion']]);
check(($result['error']['code'] ?? '') === 'bad_channel', 'so is a url with no scheme');

$result = $me->saveChannel(['name' => 'Phone', 'kind' => 'gotify',
                            'url' => 'https://gotify.example.com']);
check(($result['error']['code'] ?? '') === 'bad_channel', 'and gotify without a token');

$result = $me->saveChannel(['name' => 'Phone', 'kind' => 'ntfy', 'url' => 'https://ntfy.sh',
                            'token' => 'tk_secret', 'config' => ['topic' => 'avorion-rusty']]);
check(($result['channel']['name'] ?? '') === 'Phone', 'a complete ntfy channel is saved');
check(($result['channel']['hasToken'] ?? false) === true, 'and says it has a token');
check(!array_key_exists('token', $result['channel'] ?? []),
      'without ever handing the token back');

// Saving again without a token keeps the stored one: a console that was never shown the
// secret must still be able to change the topic.
$me->saveChannel(['name' => 'Phone', 'kind' => 'ntfy', 'url' => 'https://ntfy.sh',
                  'config' => ['topic' => 'avorion-moved']]);
$stored = Db::connect()->prepare('SELECT token, config FROM notification_channels
                                  WHERE player = :p AND name = :n');
$stored->execute([':p' => $player, ':n' => 'Phone']);
$row = $stored->fetch();
check(($row['token'] ?? '') === 'tk_secret', 'an update that omits the token keeps it');
check(str_contains((string) ($row['config'] ?? ''), 'avorion-moved'), 'and takes the new topic');

$me->saveChannel(['name' => 'Phone', 'token' => '']);
$stored->execute([':p' => $player, ':n' => 'Phone']);
check((string) ($stored->fetch()['token'] ?? 'x') === '', 'an empty token clears it');

check(count($me->channels()) === 1, 'the same name updates rather than adding');

/* --------------------------------- rules --------------------------------- */

echo "\nrules\n";

check(($me->saveRule(['name' => 'r', 'kind' => 'nonsense'])['error']['code'] ?? '') === 'bad_kind',
      'a rule has to watch something the store knows about');
check(($me->saveRule(['name' => 'r', 'kind' => 'idle',
                      'config' => ['below' => 0.5]])['error']['code'] ?? '') === 'bad_config',
      'and may not carry an option that kind does not take');
check(($me->saveRule(['name' => 'r', 'kind' => 'status'])['error']['code'] ?? '') === 'bad_config',
      'a status rule without text to look for is refused');
check(($me->saveRule(['name' => 'r', 'kind' => 'idle',
                      'channels' => ['Pager']])['error']['status'] ?? 0) === 404,
      'so is one naming a channel that does not exist');
check(($me->saveRule(['name' => 'r', 'kind' => 'idle',
                      'alliance' => true])['error']['code'] ?? '') === 'no_alliance',
      'and one watching an alliance for a player who is in none');

$result = $me->saveRule(['name' => 'Hurt', 'kind' => 'hull', 'config' => ['below' => 40],
                         'quiet' => 0]);
check(($result['rule']['config']['below'] ?? null) === 40, 'a threshold is stored as given');

$result = $me->saveRule(['name' => 'Hurt', 'kind' => 'hull', 'config' => ['below' => 0.4],
                         'quiet' => 0]);
check(($result['rule']['channels'] ?? null) === [],
      'an empty channel list means every channel the player has');

/* ------------------------------ evaluating -------------------------------- */

echo "\nthe first pass raises nothing\n";

$player = freshFaction();
$me = member($player);
$history = new History(freshKey());
$history->recordPing(ping($player, null));
$mine = owner('player', $player);

$me->saveChannel(['name' => 'Phone', 'kind' => 'ntfy', 'url' => 'https://ntfy.invalid',
                  'config' => ['topic' => 't']]);
$me->saveRule(['name' => 'Fights', 'kind' => 'combat', 'quiet' => 0]);

record($history, 'Scout', $mine, [
    ['kind' => 'order', 'automation' => ['enemies' => true, 'sector' => ['x' => 4, 'y' => 2]]],
]);

$me->evaluate([craft('Scout', $mine)]);
check(outbox($player) === [],
      'a player evaluated for the first time is not sent a backlog of old events');

echo "\nunder attack\n";

record($history, 'Scout', $mine, [
    ['kind' => 'order', 'automation' => ['enemies' => true, 'sector' => ['x' => 4, 'y' => 2],
                                         'vitals' => ['hull' => 0.8, 'shield' => 0.1]]],
]);

$me->evaluate([craft('Scout', $mine)]);
$out = outbox($player);
check(count($out) === 1 && $out[0]['kind'] === 'combat' && $out[0]['ship'] === 'Scout',
      'enemies turning up raises one notification');
check(str_contains($out[0]['body'], '(4:2)'), 'which says where');
check(str_contains($out[0]['body'], '80%'), 'and in what condition the craft is');

record($history, 'Scout', $mine, [
    ['kind' => 'order', 'automation' => ['enemies' => true, 'sector' => ['x' => 4, 'y' => 2]]],
    ['kind' => 'order', 'automation' => ['enemies' => true, 'sector' => ['x' => 4, 'y' => 2]]],
]);
$me->evaluate([craft('Scout', $mine)]);
check(count(outbox($player)) === 1, 'a fight that is still going raises no more');

record($history, 'Scout', $mine, [
    ['kind' => 'order', 'automation' => ['enemies' => false, 'sector' => ['x' => 4, 'y' => 2]]],
]);
$me->evaluate([craft('Scout', $mine)]);
check(count(outbox($player)) === 1, 'and the fight ending raises none by default');

$me->saveRule(['name' => 'Fights', 'kind' => 'combat', 'quiet' => 0, 'config' => ['ends' => true]]);
record($history, 'Scout', $mine, [
    ['kind' => 'order', 'automation' => ['enemies' => true, 'sector' => ['x' => 4, 'y' => 2]]],
    ['kind' => 'order', 'automation' => ['enemies' => false, 'sector' => ['x' => 4, 'y' => 2]]],
]);
$me->evaluate([craft('Scout', $mine)]);
$out = outbox($player);
check(count($out) === 3 && str_contains($out[2]['title'], 'clear'),
      'with "ends" on, both edges of a fight are reported');

echo "\nhull\n";

$player = freshFaction();
$me = member($player);
$history = new History(freshKey());
$history->recordPing(ping($player, null));
$mine = owner('player', $player);

$me->saveRule(['name' => 'Hurt', 'kind' => 'hull', 'config' => ['below' => 0.5], 'quiet' => 0]);
$me->evaluate([craft('Scout', $mine, ['hull' => 1.0])]);
clearOutbox($player);

$me->evaluate([craft('Scout', $mine, ['hull' => 0.9])]);
check(outbox($player) === [], 'a healthy craft raises nothing');

$me->evaluate([craft('Scout', $mine, ['hull' => 0.45])]);
$out = outbox($player);
check(count($out) === 1 && str_contains($out[0]['title'], '45%'),
      'crossing the threshold raises one notification with the value on it');

$me->evaluate([craft('Scout', $mine, ['hull' => 0.30])]);
$me->evaluate([craft('Scout', $mine, ['hull' => 0.49])]);
check(count(outbox($player)) === 1,
      'and staying under it raises no more, however far it falls');

$me->evaluate([craft('Scout', $mine, ['hull' => 0.52])]);
check(count(outbox($player)) === 1,
      'recovering to just above the line does not rearm it either');

$me->evaluate([craft('Scout', $mine, ['hull' => 0.80])]);
$me->evaluate([craft('Scout', $mine, ['hull' => 0.40])]);
check(count(outbox($player)) === 2, 'a real recovery rearms it, and it fires again');

// The live value off the craft's own feed beats the listing, which is as old as the last
// time the game saved that row.
clearOutbox($player);
$me->evaluate([craft('Scout', $mine, ['hull' => 0.90])]);
record($history, 'Scout', $mine, [
    ['kind' => 'order', 'automation' => ['vitals' => ['hull' => 0.2], 'sector' => ['x' => 1, 'y' => 1]]],
]);
$me->evaluate([craft('Scout', $mine, ['hull' => 0.90])]);
$out = outbox($player);
check(count($out) === 1 && str_contains($out[0]['title'], '20%'),
      'the live hull off the event feed wins over the database row');

echo "\nthe quiet period\n";

$player = freshFaction();
$me = member($player);
$history = new History(freshKey());
$history->recordPing(ping($player, null));
$mine = owner('player', $player);

$me->saveRule(['name' => 'Hurt', 'kind' => 'hull', 'config' => ['below' => 0.5], 'quiet' => 600]);
$me->evaluate([craft('Scout', $mine, ['hull' => 1.0])]);

$me->evaluate([craft('Scout', $mine, ['hull' => 0.4])]);
$me->evaluate([craft('Scout', $mine, ['hull' => 0.9])]);
$me->evaluate([craft('Scout', $mine, ['hull' => 0.4])]);
check(count(outbox($player)) === 1, 'a rule with a quiet period fires once inside it');

echo "\nfleeing\n";

$player = freshFaction();
$me = member($player);
$history = new History(freshKey());
$history->recordPing(ping($player, null));
$mine = owner('player', $player);

$me->saveRule(['name' => 'Runners', 'kind' => 'flee', 'quiet' => 0]);
$me->evaluate([craft('Scout', $mine)]);

record($history, 'Scout', $mine, [
    ['kind' => 'order', 'automation' => ['sector' => ['x' => 4, 'y' => 2],
                                         'vitals' => ['hull' => 0.3],
                                         'flee' => ['reason' => 'hull', 'phase' => 'jumping']]],
]);
$me->evaluate([craft('Scout', $mine)]);
$out = outbox($player);
check(count($out) === 1 && str_contains($out[0]['title'], 'running'),
      'a craft breaking off is reported when it goes');

record($history, 'Scout', $mine, [
    ['kind' => 'order', 'automation' => ['sector' => ['x' => 9, 'y' => 9],
                                         'lastFlee' => ['outcome' => 'arrived',
                                                        'sector' => ['x' => 9, 'y' => 9]]]],
]);
$me->evaluate([craft('Scout', $mine)]);
$out = outbox($player);
check(count($out) === 2 && str_contains($out[1]['body'], '(9:9)'),
      'and again when it gets there, with where it got to');

record($history, 'Scout', $mine, [
    ['kind' => 'order', 'automation' => ['sector' => ['x' => 9, 'y' => 9],
                                         'flee' => ['reason' => 'shield', 'phase' => 'stuck']]],
    ['kind' => 'order', 'automation' => ['sector' => ['x' => 9, 'y' => 9],
                                         'lastFlee' => ['outcome' => 'failed',
                                                        'detail' => 'no_route',
                                                        'sector' => ['x' => 9, 'y' => 9]]]],
]);
$me->evaluate([craft('Scout', $mine)]);
$out = outbox($player);
check(count($out) === 4 && $out[3]['priority'] > $out[1]['priority'],
      'a craft that could not get away is more urgent than one that did');

echo "\nscope\n";

$player = freshFaction();
$alliance = freshFaction();
$me = member($player, $alliance);
$history = new History(freshKey());
$history->recordPing(ping($player, $alliance));
$mine = owner('player', $player);
$ours = owner('alliance', $alliance);

$me->saveRule(['name' => 'Mine', 'kind' => 'combat', 'quiet' => 0]);
$me->evaluate([craft('Scout', $mine), craft('Hauler', $ours)]);

record($history, 'Scout', $mine, [['kind' => 'order', 'automation' => ['enemies' => true]]]);
record($history, 'Hauler', $ours, [['kind' => 'order', 'automation' => ['enemies' => true]]]);

$me->evaluate([craft('Scout', $mine), craft('Hauler', $ours)]);
$out = outbox($player);
check(count($out) === 1 && $out[0]['ship'] === 'Scout',
      'a rule leaves the alliance fleet alone unless it was asked to watch it');

clearOutbox($player);
$me->saveRule(['name' => 'Ours', 'kind' => 'combat', 'quiet' => 0, 'alliance' => true]);
record($history, 'Hauler', $ours, [
    ['kind' => 'order', 'automation' => ['enemies' => false]],
    ['kind' => 'order', 'automation' => ['enemies' => true]],
]);
$me->evaluate([craft('Scout', $mine), craft('Hauler', $ours)]);
$out = outbox($player);
check(count($out) === 1 && $out[0]['ship'] === 'Hauler' && $out[0]['rule'] === 'Ours',
      'and watches it once it has been');

clearOutbox($player);
$me->saveRule(['name' => 'One craft', 'kind' => 'combat', 'quiet' => 0, 'ship' => 'Nobody']);
record($history, 'Scout', $mine, [
    ['kind' => 'order', 'automation' => ['enemies' => false]],
    ['kind' => 'order', 'automation' => ['enemies' => true]],
]);
$me->evaluate([craft('Scout', $mine), craft('Hauler', $ours)]);
$named = array_filter(outbox($player), static fn (array $n): bool => $n['rule'] === 'One craft');
check(outbox($player) !== [] && $named === [],
      'a rule naming one craft ignores every other');

echo "\ncraft that go missing\n";

$player = freshFaction();
$me = member($player);
$mine = owner('player', $player);

$me->saveRule(['name' => 'Losses', 'kind' => 'gone', 'quiet' => 0]);
$me->evaluate([craft('Scout', $mine), craft('Hauler', $mine)]);
check(outbox($player) === [], 'a first look at a fleet reports nothing');

$me->evaluate([craft('Scout', $mine)]);
$out = outbox($player);
check(count($out) === 1 && $out[0]['ship'] === 'Hauler', 'a craft that vanishes is reported');

$me->evaluate([craft('Scout', $mine)]);
check(count(outbox($player)) === 1, 'once');

$me->evaluate([]);
check(count(outbox($player)) === 1,
      'and an empty listing reports nothing at all - that is the mod reloading, not a wipe');

/* ------------------------------- delivery --------------------------------- */

echo "\ndelivery\n";

/**
 * PHP's own web server, as a place for notifications to land. Returns the port, or 0
 * when it could not be started.
 */
function sink(string $log): array
{
    $router = sys_get_temp_dir() . '/avo-sink-' . getmypid() . '.php';
    file_put_contents($router, '<?php file_put_contents(' . var_export($log, true)
        . ', json_encode(["path" => $_SERVER["REQUEST_URI"], "body" => file_get_contents("php://input"),'
        . ' "auth" => $_SERVER["HTTP_AUTHORIZATION"] ?? "", "gotify" => $_SERVER["HTTP_X_GOTIFY_KEY"] ?? ""])'
        . ' . "\n", FILE_APPEND); http_response_code(200); echo "{}";');

    $port = random_int(20000, 60000);
    $handle = @proc_open(
        sprintf('exec php -S 127.0.0.1:%d %s', $port, escapeshellarg($router)),
        [1 => ['file', '/dev/null', 'w'], 2 => ['file', '/dev/null', 'w']], $pipes
    );

    if (!is_resource($handle)) {
        return [0, null, $router];
    }

    for ($try = 0; $try < 50; $try++) {
        $socket = @fsockopen('127.0.0.1', $port, $errno, $errstr, 0.2);
        if (is_resource($socket)) {
            fclose($socket);

            return [$port, $handle, $router];
        }
        usleep(100000);
    }

    proc_terminate($handle);

    return [0, $handle, $router];
}

$log = sys_get_temp_dir() . '/avo-sink-' . getmypid() . '.log';
@unlink($log);
[$port, $handle, $router] = sink($log);

$player = freshFaction();
$me = member($player);

if ($port === 0) {
    skip('no local web server could be started, so delivery is not checked here');
} else {
    $base = 'http://127.0.0.1:' . $port;

    $me->saveChannel(['name' => 'Hook', 'kind' => 'webhook', 'url' => $base . '/hook',
                      'token' => 'shh', 'config' => ['headers' => ['X-Thing' => 'yes']]]);
    $me->saveChannel(['name' => 'Ntfy', 'kind' => 'ntfy', 'url' => $base,
                      'config' => ['topic' => 'avorion']]);
    $me->saveChannel(['name' => 'Goti', 'kind' => 'gotify', 'url' => $base,
                      'token' => 'AppToken']);

    $result = $me->test('Hook');
    check(($result['results'][0]['ok'] ?? false) === true, 'a test notification is delivered');

    $me->test('Ntfy');
    $me->test('Goti');

    $sent = array_map(
        static fn (string $line): array => json_decode($line, true),
        array_values(array_filter(explode("\n", (string) @file_get_contents($log))))
    );

    check(count($sent) === 3, 'each of the three drivers sent one request');

    $hook = $sent[0] ?? [];
    check(($hook['path'] ?? '') === '/hook', 'a webhook posts to the url it was given');
    check(($hook['auth'] ?? '') === 'Bearer shh', 'with its token as a bearer');
    check(str_contains((string) ($hook['body'] ?? ''), '"kind":"test"'),
          'and the notification as JSON');

    $ntfy = $sent[1] ?? [];
    $ntfyBody = json_decode((string) ($ntfy['body'] ?? ''), true) ?: [];
    check(($ntfy['path'] ?? '') === '/', 'ntfy is published as JSON to the server root');
    check(($ntfyBody['topic'] ?? '') === 'avorion' && isset($ntfyBody['title']),
          'with the topic in the body, so a non-ASCII title survives');

    $gotify = $sent[2] ?? [];
    $gotifyBody = json_decode((string) ($gotify['body'] ?? ''), true) ?: [];
    check(($gotify['path'] ?? '') === '/message', 'gotify posts to /message');
    check(($gotify['gotify'] ?? '') === 'AppToken',
          'with the application token in a header, not the query string');
    check(($gotifyBody['priority'] ?? 0) === 5, 'and our 1..5 stretched onto its 0..10');

    // What the notifier actually does: raise now, send on the next pass.
    @unlink($log);
    $me->raise($player, ['rule' => 'r', 'kind' => 'idle', 'ship' => 'Scout',
                         'title' => 'Scout is idle', 'body' => '', 'priority' => 2,
                         'data' => ['channels' => ['Hook']]]);
    $delivered = $me->deliver();
    check($delivered['sent'] === 1, 'a queued notification is delivered on the next pass');

    $lines = array_values(array_filter(explode("\n", (string) @file_get_contents($log))));
    check(count($lines) === 1, 'to the one channel the rule named, not to all three');
    check(!str_contains((string) ($lines[0] ?? ''), 'channels'),
          'and the payload does not tell it which channels were tried');

    check($me->deliver()['sent'] === 0, 'and is not delivered twice');
}

$me->saveChannel(['name' => 'Dead', 'kind' => 'webhook', 'url' => 'http://127.0.0.1:1/nope']);
$me->raise($player, ['rule' => 'r', 'kind' => 'idle', 'ship' => 'Scout', 'title' => 'x',
                     'body' => '', 'priority' => 3, 'data' => ['channels' => ['Dead']]]);

$failed = $me->deliver();
check($failed['failed'] === 1, 'a channel that cannot be reached is a failed delivery');

$row = Db::connect()->prepare(
    "SELECT attempts, error, next_try > now() AS waiting FROM notifications
     WHERE player = :p ORDER BY id DESC LIMIT 1"
);
$row->execute([':p' => $player]);
$state = $row->fetch();
check((int) ($state['attempts'] ?? 0) === 1 && ($state['waiting'] === true || $state['waiting'] === 't'),
      'and is backed off rather than retried in a tight loop');
check(!str_contains((string) ($state['error'] ?? ''), 'shh'),
      'the recorded error says nothing a channel was configured with');

check($me->deliver()['sent'] === 0 && $me->deliver()['failed'] === 0,
      'nothing is attempted again until the backoff is over');

if (is_resource($handle ?? null)) {
    proc_terminate($handle);
}
@unlink($router ?? '');
@unlink($log);

echo "\n";
if ($failures > 0) {
    echo $failures . " check(s) failed\n";
    exit(1);
}
echo "all checks passed\n";
