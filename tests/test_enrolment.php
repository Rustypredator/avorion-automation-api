<?php

declare(strict_types=1);

/**
 * Enrolment: the keys the background services call the API with.
 *
 * Needs a Postgres, like the other two PHP tests - tools/dbtest.sh starts a throwaway one
 * and runs all three against it.
 *
 * This is the only table that holds a credential rather than a hash of one, so what is
 * pinned here is mostly about that: that a stored key comes back exactly, that it does
 * not come back under a different secret, that nothing hands it to a client, and that
 * switching every service off deletes it rather than leaving it lying about.
 *
 * The rest is the scoping, which has the same shape as the notification rules': an
 * enrolment belongs to a player, and one player must not see, change or remove another's.
 *
 * Every run uses freshly generated keys and player indices and cleans up after itself.
 */

require __DIR__ . '/../docker/bridge/src/enrolment.php';

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
    fwrite(STDERR, "test_enrolment.php needs a database: set HISTORY_DB_HOST and friends, "
                 . "or run tools/dbtest.sh which starts one.\n");
    exit(2);
}

try {
    Db::connect();
} catch (Throwable $e) {
    fwrite(STDERR, 'test_enrolment.php cannot reach the database: ' . $e->getMessage() . "\n");
    exit(2);
}

// The stack normally generates this into a volume. Here it is just an environment
// variable, which is the other supported source and the easier one to vary mid-test.
putenv('ENROL_SECRET=test-secret-' . bin2hex(random_bytes(8)));
Enrolment::reset();

$madeKeys = [];
$madePlayers = [];

function freshKey(): string
{
    global $madeKeys;

    $key = 'avo_' . bin2hex(random_bytes(32));
    $madeKeys[] = $key;

    return $key;
}

function freshPlayer(): int
{
    global $madePlayers;

    $index = random_int(100000, 2000000000);
    $madePlayers[] = $index;

    return $index;
}

register_shutdown_function(static function () use (&$madeKeys): void {
    try {
        $db = Db::connect();
        $statement = $db->prepare('DELETE FROM service_keys WHERE key_hash = :h');
        foreach ($madeKeys as $key) {
            $statement->execute([':h' => hash('sha256', $key)]);
        }
    } catch (Throwable $e) {
        fwrite(STDERR, 'cleanup failed: ' . $e->getMessage() . "\n");
    }
});

echo "\nthe secret\n";

check(Enrolment::available(), 'enrolment is available with a secret set');

$plain = freshKey();
$sealed = Enrolment::seal($plain);

check($sealed !== $plain && !str_contains($sealed, $plain),
      'a sealed key does not contain the key');
check(Enrolment::open($sealed) === $plain, 'and opens back to exactly it');
check(Enrolment::seal($plain) !== $sealed,
      'sealing twice gives different ciphertext, so the nonce is not reused');

// Tampering. GCM is authenticated, so a flipped byte has to fail rather than decrypt to
// something else - a service quietly presenting a different key is not a failure worth
// having.
$bent = substr($sealed, 0, -4) . (str_ends_with($sealed, 'AAAA') ? 'BBBB' : 'AAAA');
check(Enrolment::open($bent) === null, 'a tampered row does not open');
check(Enrolment::open('not-even-versioned') === null, 'nor does something unversioned');

putenv('ENROL_SECRET=a-completely-different-secret');
Enrolment::reset();
check(Enrolment::open($sealed) === null, 'nor does it open under a different secret');

putenv('ENROL_SECRET=test-secret-back-again');
Enrolment::reset();

echo "\nenrolling\n";

$alice = freshPlayer();
$aliceKey = freshKey();

$result = Enrolment::enrol($aliceKey, $alice, ['poll' => true, 'notify' => false], 'my fleet');
check(!isset($result['error']), 'a key is enrolled');
check(($result['entry']['poll'] ?? null) === true, 'for the service asked for');
check(($result['entry']['notify'] ?? null) === false, 'and not for the other one');
check(($result['entry']['label'] ?? '') === 'my fleet', 'under the name given');

$mine = Enrolment::mine($alice);
check(count($mine) === 1, 'and reads back as one enrolment');

$json = json_encode($mine);
check(is_string($json) && !str_contains($json, $aliceKey),
      'which never carries the key itself');
check(($mine[0]['id'] ?? '') === hash('sha256', $aliceKey),
      'the id being the same hash api_keys stores, which is not the key');

echo "\nwhat the services read\n";

$forPoll = Enrolment::keysFor('poll');
$keys = array_column($forPoll['keys'], 'key');
check(in_array($aliceKey, $keys, true), 'the poller is handed the key back, decrypted');
check($forPoll['sealed'] === 0, 'with nothing it could not decrypt');

$forNotify = Enrolment::keysFor('notify');
check(!in_array($aliceKey, array_column($forNotify['keys'], 'key'), true),
      'and the notifier is not, having not been asked for');

// Enrolling the same key again is an update, not a second copy of the credential.
Enrolment::enrol($aliceKey, $alice, ['poll' => true, 'notify' => true], 'my fleet');
check(count(Enrolment::mine($alice)) === 1, 'enrolling the same key again does not duplicate it');
check(in_array($aliceKey, array_column(Enrolment::keysFor('notify')['keys'], 'key'), true),
      'and does change what it is used for');

echo "\nfailures\n";

$id = hash('sha256', $aliceKey);

Enrolment::failed($id, 'HTTP 504 the mod never picked this request up');
$mine = Enrolment::mine($alice);
check(($mine[0]['failures'] ?? 0) === 1, 'an ordinary failure counts');
check(str_contains($mine[0]['error'] ?? '', '504'), 'and keeps the reason');
check(count(Enrolment::keysFor('poll')['keys']) >= 1,
      'and the key is still read, because a game server is allowed to be down');

Enrolment::succeeded($id);
$mine = Enrolment::mine($alice);
check(($mine[0]['failures'] ?? 1) === 0, 'a pass that works clears the count');
check(($mine[0]['error'] ?? 'x') === '', 'and the reason with it');
check(($mine[0]['usedAt'] ?? null) !== null, 'and records when it last worked');

// 401 from the mod is the key being revoked, which is not worth retrying for a week.
Enrolment::failed($id, 'HTTP 401 unauthorized', true);
check(!in_array($aliceKey, array_column(Enrolment::keysFor('poll')['keys'], 'key'), true),
      'a key the mod rejects is set aside at once');
check(Enrolment::keysFor('poll')['tired'] >= 1, 'and is counted as set aside');
check(count(Enrolment::mine($alice)) === 1,
      'while still being shown to its player, so they can see why');

Enrolment::enrol($aliceKey, $alice, ['poll' => true, 'notify' => true], 'my fleet');
check(in_array($aliceKey, array_column(Enrolment::keysFor('poll')['keys'], 'key'), true),
      'enrolling again is how a player says to try it once more');

echo "\nturning it off\n";

$result = Enrolment::update($alice, $id, ['notify' => false], null);
check(($result['entry']['poll'] ?? null) === true, 'one service can be switched off');
check(($result['entry']['notify'] ?? null) === false, 'leaving the other alone');

$result = Enrolment::update($alice, $id, ['poll' => false], null);
// array_key_exists, not ??: the whole point is that `entry` is present and null.
check(array_key_exists('entry', $result) && $result['entry'] === null,
      'switching the last one off removes the row');
check(Enrolment::mine($alice) === [], 'so the bridge no longer holds the key at all');

$stored = Db::connect()->prepare('SELECT count(*) FROM service_keys WHERE key_hash = :h');
$stored->execute([':h' => $id]);
check((int) $stored->fetchColumn() === 0, 'confirmed against the table itself');

echo "\nwhose it is\n";

$bob = freshPlayer();
$bobKey = freshKey();

Enrolment::enrol($aliceKey, $alice, ['poll' => true, 'notify' => true], 'alice');
Enrolment::enrol($bobKey, $bob, ['poll' => true, 'notify' => true], 'bob');

$aliceSees = array_column(Enrolment::mine($alice), 'label');
check($aliceSees === ['alice'], 'a player sees only their own enrolment');

check(isset(Enrolment::update($bob, $id, ['poll' => false], null)['error']),
      'and cannot change somebody else\'s');
check(in_array($aliceKey, array_column(Enrolment::keysFor('poll')['keys'], 'key'), true),
      'which really did leave it alone');

check(isset(Enrolment::forget($bob, $id)['error']), 'nor remove it');
check(count(Enrolment::mine($alice)) === 1, 'which really did leave it alone too');

check(isset(Enrolment::forget($alice, $id)['removed']), 'its own player can remove it');
check(Enrolment::mine($alice) === [], 'and then it is gone');

echo "\ncarried over from .env\n";

$legacy = freshKey();
$added = Enrolment::importEnv('poll', [$legacy]);
check($added === 1, 'a key still listed in POLL_KEYS is imported');
check(in_array($legacy, array_column(Enrolment::keysFor('poll')['keys'], 'key'), true),
      'and the poller picks it up');

$legacyId = hash('sha256', $legacy);
$row = Db::connect()->prepare('SELECT player FROM service_keys WHERE key_hash = :h');
$row->execute([':h' => $legacyId]);
check($row->fetchColumn() === null,
      'with nobody\'s name on it, because nothing here can ask the mod whose it is');

check(Enrolment::importEnv('poll', [$legacy]) === 0, 'importing again changes nothing');

/*
 * The two services import in parallel and, because NOTIFY_KEYS used to default to
 * POLL_KEYS, usually name the same keys. So the second one has to add its service to the
 * row the first one made rather than finding it present and doing nothing - otherwise an
 * upgrade comes up polling but silently not alerting.
 */
check(Enrolment::importEnv('notify', [$legacy]) === 1,
      'the other service adds itself to a row the first one imported');
check(in_array($legacy, array_column(Enrolment::keysFor('notify')['keys'], 'key'), true),
      'so a deployment that only ever set POLL_KEYS keeps its alerts');
check(in_array($legacy, array_column(Enrolment::keysFor('poll')['keys'], 'key'), true),
      'without disturbing the one that was already there');

// But only while nobody has chosen otherwise. An admin who leaves the variable set must
// not keep switching a service back on that a player deliberately switched off.
$dave = freshPlayer();
Enrolment::enrol($legacy, $dave, ['poll' => true, 'notify' => false], 'mine now');
check(Enrolment::importEnv('notify', [$legacy]) === 0,
      'a key a player has enrolled is not touched by the .env import again');
check(!in_array($legacy, array_column(Enrolment::keysFor('notify')['keys'], 'key'), true),
      'so what the player chose stands');

// The first successful pass is what fills the player in, which is also what makes the
// row appear on that player's console.
$other = freshKey();
$otherId = hash('sha256', $other);
Enrolment::importEnv('poll', [$other]);

$carol = freshPlayer();
Enrolment::attribute($otherId, $carol);
check(count(Enrolment::mine($carol)) === 1, 'the first pass that works attributes it');

Enrolment::attribute($otherId, $bob);
check(count(Enrolment::mine($carol)) === 1, 'and a later pass cannot move it to someone else');

echo "\nno secret\n";

putenv('ENROL_SECRET=');
Enrolment::reset();

check(!Enrolment::available(), 'without a secret, enrolment is off');
check(Enrolment::unavailable() !== '', 'and says why');
check(isset(Enrolment::enrol(freshKey(), $alice, ['poll' => true], '')['error']),
      'enrolling is refused rather than storing a key in the clear');
check(Enrolment::keysFor('poll') === ['keys' => [], 'sealed' => 0, 'tired' => 0],
      'and the services are handed nothing');

echo "\n";
echo $failures === 0 ? "all checks passed\n" : "$failures check(s) failed\n";

exit($failures === 0 ? 0 : 1);
