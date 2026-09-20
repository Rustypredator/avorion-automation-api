<?php

declare(strict_types=1);

require_once __DIR__ . '/db.php';

/**
 * Which API keys the background services may call the API with, and where they come from.
 *
 * The poller and the notifier are ordinary clients: they hold a player's API key and make
 * the same HTTP calls a console would. Something therefore has to tell them whose keys to
 * use. That used to be POLL_KEYS and NOTIFY_KEYS in the stack's .env, which works for one
 * player and does not scale at all - on a shared server every player who wants their
 * fleet watched needs an admin to edit a file and restart two containers, and the admin
 * ends up holding everybody's credentials in a text file. So instead a player enrols
 * their own key from the console, this table holds it, and the services read it.
 *
 * ### Holding a credential, on purpose
 *
 * This is the only place the bridge stores a key rather than a hash of one, and it is
 * worth being plain about why the rule is broken here. Everywhere else - api_keys - the
 * bridge only ever has to *recognise* a key it was handed, which a SHA-256 does. A
 * background service has to *present* one, and no amount of hashing produces something the
 * mod will accept. There is no version of "call the API as this player while they are
 * asleep" that does not involve keeping the player's key.
 *
 * So the row is encrypted rather than plain. That is a smaller win than it looks and worth
 * describing honestly: the secret and the database live in the same compose stack, so
 * anyone who is already inside the stack can read both and the encryption buys nothing
 * against them. What it does buy is the case that actually happens - a database dump, a
 * backup on somebody's NAS, a volume copied off a decommissioned box - where the rows
 * travel and the secret does not.
 *
 * The blast radius is bounded by the mod, not by this: a key is one player, it can be
 * revoked from the game with /apikey revoke, and a player who never enrols has nothing
 * here to leak.
 *
 *   ENROL_SECRET       the key the rows are encrypted with. Normally unset.
 *   ENROL_SECRET_FILE  a file holding it instead (default /run/enrol/secret). This is the
 *                      usual path: docker-compose.yml has the init service generate one
 *                      into a volume, so the secret exists without anybody choosing it
 *                      and never goes near .env.
 *
 * Lose the secret and the enrolled keys cannot be read back. Nothing is corrupted - the
 * services skip what they cannot open and say so, and the player re-enrols from the
 * console - but the volume holding it is worth the same backup as the database.
 */
final class Enrolment
{
    /**
     * The services a key can be enrolled for, and what each one means to a player.
     *
     * Served to the console at GET /services so the checkboxes and their explanations
     * come from here rather than from a copy that drifts. The keys are the column names
     * in service_keys, which is what keeps `$service` below safe to interpolate.
     */
    public const SERVICES = [
        'poll' => [
            'title' => 'Record my fleet',
            'about' => 'Keeps something calling the API on a timer, so where your craft '
                     . 'went and what they did is kept past the mod\'s own short memory. '
                     . 'Without it the history only covers the moments this page was open.',
        ],
        'notify' => [
            'title' => 'Send me alerts',
            'about' => 'Runs your alert rules while you are away and pushes what fires to '
                     . 'your channels. Needs the recording above to be on for somebody in '
                     . 'the fleet, since that is where the events come from.',
        ],
    ];

    /** How many consecutive failures before a row is set aside. See failed(). */
    public const MAX_FAILURES = 20;

    /** Memoised, because every service pass asks and the answer cannot change. */
    private static ?string $secret = null;
    private static bool $looked = false;

    /* -------------------------------- the secret -------------------------------- */

    /**
     * The configured secret, or null when there is none and enrolment cannot work.
     *
     * A file wins over nothing and the environment wins over the file, so a deployment can
     * override the generated one without deleting it.
     */
    public static function secret(): ?string
    {
        if (self::$looked) {
            return self::$secret;
        }

        self::$looked = true;

        $explicit = getenv('ENROL_SECRET');
        if (is_string($explicit) && trim($explicit) !== '') {
            return self::$secret = trim($explicit);
        }

        $path = (string) (getenv('ENROL_SECRET_FILE') ?: '/run/enrol/secret');
        if ($path !== '' && is_readable($path)) {
            $contents = trim((string) @file_get_contents($path));
            if ($contents !== '') {
                return self::$secret = $contents;
            }
        }

        return self::$secret = null;
    }

    /** Drops the memoised secret, so the next read starts over. Tests use this. */
    public static function reset(): void
    {
        self::$secret = null;
        self::$looked = false;
    }

    public static function available(): bool
    {
        return Db::enabled() && self::secret() !== null && function_exists('openssl_encrypt');
    }

    /** Why enrolment is off, in a sentence a player can hand to whoever runs the server. */
    public static function unavailable(): string
    {
        if (!Db::enabled()) {
            return 'This bridge keeps no database, so there is nowhere to record an '
                 . 'enrolment. Unset HISTORY_DB_HOST in the stack\'s .env.';
        }
        if (!function_exists('openssl_encrypt')) {
            return 'This bridge was built without OpenSSL, so it cannot store a key safely '
                 . 'and will not store one any other way.';
        }

        return 'This bridge has no enrolment secret, so it cannot store a key. The stack '
             . 'generates one into a volume on startup; if that volume is missing, set '
             . 'ENROL_SECRET in the stack\'s .env to any long random string instead.';
    }

    /**
     * AES-256-GCM, with the nonce and the tag carried alongside the ciphertext.
     *
     * Authenticated on purpose rather than a bare cipher: an attacker who can write to the
     * database but not read the secret could otherwise flip bits in a stored key, and
     * while that only produces a key the mod rejects, "the service quietly starts
     * presenting something else" is not a failure mode worth having. A tampered row fails
     * to open and is reported as such.
     */
    public static function seal(string $key): string
    {
        $secret = self::secret();
        if ($secret === null) {
            throw new RuntimeException('no enrolment secret is configured');
        }

        $nonce = random_bytes(12);
        $tag = '';
        $sealed = openssl_encrypt($key, 'aes-256-gcm', self::cipherKey($secret),
                                  OPENSSL_RAW_DATA, $nonce, $tag);

        if (!is_string($sealed)) {
            throw new RuntimeException('could not encrypt the key');
        }

        return 'v1:' . base64_encode($nonce . $tag . $sealed);
    }

    /** The key back, or null if the secret is wrong, missing, or the row was tampered with. */
    public static function open(string $stored): ?string
    {
        $secret = self::secret();
        if ($secret === null || !str_starts_with($stored, 'v1:')) {
            return null;
        }

        $raw = base64_decode(substr($stored, 3), true);
        if (!is_string($raw) || strlen($raw) <= 28) {
            return null;
        }

        $plain = openssl_decrypt(substr($raw, 28), 'aes-256-gcm', self::cipherKey($secret),
                                 OPENSSL_RAW_DATA, substr($raw, 0, 12), substr($raw, 12, 16));

        return is_string($plain) && $plain !== '' ? $plain : null;
    }

    /** A 32-byte cipher key from a secret of any length or shape. */
    private static function cipherKey(string $secret): string
    {
        return hash('sha256', 'automationapi-enrolment-v1:' . $secret, true);
    }

    public static function hash(string $key): string
    {
        return hash('sha256', $key);
    }

    /* ------------------------------ the request path ------------------------------ */

    /**
     * Enrol one key, or change what an already-enrolled one is used for.
     *
     * The caller has already established two things this cannot check for itself: that the
     * key works, and that it belongs to `$player`. Both need the mod, and this module has
     * no transport - see the /services block in public/index.php, which relays a /ping for
     * exactly this.
     *
     * Enrolling the same key again overwrites rather than appends, and clears the failure
     * count: "enrol this" from a player who has just fixed something is a reasonable way
     * to ask for it to be tried again.
     *
     * @param array<string, bool> $wants  service name -> on
     * @return array{entry: array<string, mixed>}|array{error: array{status: int, code: string, message: string}}
     */
    public static function enrol(string $key, int $player, array $wants, string $label): array
    {
        if (!self::available()) {
            return self::refuse(503, 'enrolment_disabled', self::unavailable());
        }

        $label = self::clean($label, 60);
        $on = [];
        foreach (array_keys(self::SERVICES) as $service) {
            $on[$service] = ($wants[$service] ?? false) === true;
        }

        $hash = self::hash($key);

        /*
         * Nothing on means "stop using my key", which is the same thing forget() does and
         * is much the likelier reading of a player clearing both boxes than "keep the
         * credential but do not use it". A key we are not going to present is a key we
         * have no business storing.
         */
        if (!in_array(true, $on, true)) {
            self::drop($hash);
            return ['entry' => null];
        }

        /*
         * The booleans are bound rather than passed in the execute() array. With emulated
         * prepares off - which db.php sets, so the server parses the SQL - PDO sends a PHP
         * false as an empty string, and Postgres refuses that for a boolean column.
         */
        $statement = Db::connect()->prepare(
            'INSERT INTO service_keys (key_hash, secret, player, label, poll, notify)
             VALUES (:h, :s, :p, :l, :poll, :notify)
             ON CONFLICT (key_hash) DO UPDATE
                 SET secret = EXCLUDED.secret, player = EXCLUDED.player,
                     label = EXCLUDED.label, poll = EXCLUDED.poll,
                     notify = EXCLUDED.notify, failures = 0, error = \'\',
                     from_env = FALSE'
        );
        $statement->bindValue(':h', $hash);
        $statement->bindValue(':s', self::seal($key));
        $statement->bindValue(':p', $player, PDO::PARAM_INT);
        $statement->bindValue(':l', $label);
        $statement->bindValue(':poll', $on['poll'], PDO::PARAM_BOOL);
        $statement->bindValue(':notify', $on['notify'], PDO::PARAM_BOOL);
        $statement->execute();

        return ['entry' => self::find($player, $hash)];
    }

    /**
     * Change the services on an enrolment already held, without the key being sent again.
     *
     * This is what the toggles on the console's Keys tab use. It cannot create a row -
     * there is no key to store - and it is scoped to the player, so an id is only useful
     * to whoever it belongs to.
     *
     * @return array{entry: array<string, mixed>|null}|array{error: array{status: int, code: string, message: string}}
     */
    public static function update(int $player, string $id, array $wants, ?string $label): array
    {
        $row = self::row($player, $id);
        if ($row === null) {
            return self::refuse(404, 'not_enrolled',
                'No enrolled key of yours has that id. It may have been removed already.');
        }

        $on = [];
        foreach (array_keys(self::SERVICES) as $service) {
            $on[$service] = array_key_exists($service, $wants)
                ? $wants[$service] === true
                : (bool) $row[$service];
        }

        // As in enrol(): switching everything off is the player saying the bridge should
        // stop holding their key, so it stops holding it.
        if (!in_array(true, $on, true)) {
            self::drop((string) $row['key_hash']);
            return ['entry' => null];
        }

        // Bound rather than passed, as in enrol(): a PHP false becomes '' otherwise.
        $statement = Db::connect()->prepare(
            'UPDATE service_keys SET poll = :poll, notify = :notify, label = :l,
                                     failures = 0, error = \'\'
             WHERE key_hash = :h'
        );
        $statement->bindValue(':poll', $on['poll'], PDO::PARAM_BOOL);
        $statement->bindValue(':notify', $on['notify'], PDO::PARAM_BOOL);
        $statement->bindValue(':l', $label !== null ? self::clean($label, 60) : (string) $row['label']);
        $statement->bindValue(':h', $row['key_hash']);
        $statement->execute();

        return ['entry' => self::find($player, (string) $row['key_hash'])];
    }

    /**
     * @return array{removed: bool}|array{error: array{status: int, code: string, message: string}}
     */
    public static function forget(int $player, string $id): array
    {
        $row = self::row($player, $id);
        if ($row === null) {
            return self::refuse(404, 'not_enrolled',
                'No enrolled key of yours has that id. It may have been removed already.');
        }

        self::drop((string) $row['key_hash']);

        return ['removed' => true];
    }

    /**
     * One player's enrolments, without the credential.
     *
     * `id` is the key's SHA-256, which is what api_keys has stored all along and is not
     * the key: a 256-bit key cannot be walked back from its hash. It is handed out so the
     * console has something to name a row by that is not a label the player can repeat.
     *
     * @return list<array<string, mixed>>
     */
    public static function mine(int $player): array
    {
        if (!Db::enabled()) {
            return [];
        }

        // Epoch seconds, as everything else the bridge hands a client is: a client that
        // has to parse a Postgres timestamp string gets the timezone wrong sooner or later.
        $rows = Db::connect()->prepare(
            'SELECT key_hash, secret, label, poll, notify, failures, error,
                    EXTRACT(EPOCH FROM enrolled_at)::bigint AS enrolled,
                    EXTRACT(EPOCH FROM used_at)::bigint AS used
             FROM service_keys WHERE player = :p ORDER BY enrolled_at'
        );
        $rows->execute([':p' => $player]);

        return array_map(static fn (array $row): array => [
            'id' => (string) $row['key_hash'],
            // Derived rather than stored, so it costs no column and no migration, and so
            // a row nobody can decrypt any more simply has none. It is the same handle
            // the mod prints for that key, which is the only thing tying a row here to a
            // key in the game: the id is a hash the mod never shows.
            'fingerprint' => self::fingerprint(self::open((string) $row['secret'])),
            'label' => (string) $row['label'],
            'poll' => self::truthy($row['poll']),
            'notify' => self::truthy($row['notify']),
            'enrolledAt' => (int) $row['enrolled'],
            'usedAt' => $row['used'] !== null ? (int) $row['used'] : null,
            'failures' => (int) $row['failures'],
            'error' => (string) $row['error'],
        ], $rows->fetchAll());
    }

    /**
     * The mod's own short handle for a key: the first 8 characters after the `avo_`
     * prefix. Safe to show - 8 of 64 hex characters reconstruct nothing - and it is what
     * /apikey list and the console's Keys tab print, so a player can match an enrolment
     * to the key it is.
     */
    public static function fingerprint(?string $key): string
    {
        if ($key === null) {
            return '';
        }

        $body = str_contains($key, '_') ? substr($key, strpos($key, '_') + 1) : $key;

        return substr($body, 0, 8);
    }

    /** @return array<string, mixed>|null */
    private static function find(int $player, string $hash): ?array
    {
        foreach (self::mine($player) as $entry) {
            if ($entry['id'] === $hash) {
                return $entry;
            }
        }

        return null;
    }

    /* -------------------------------- the services -------------------------------- */

    /**
     * Every key enrolled for one service, decrypted, ready to call the API with.
     *
     * Read at the top of every pass rather than once at startup, so enrolling from the
     * console takes effect within one interval and nothing has to be restarted. It is one
     * indexed query over a table with a row per opted-in player, which is nothing next to
     * the HTTP the pass is about to do.
     *
     * A row set aside after repeated failures is left out, and so is one that cannot be
     * decrypted - the caller is told how many of each so it can say so once rather than
     * failing silently.
     *
     * @return array{keys: list<array{id: string, key: string, label: string}>, sealed: int, tired: int}
     */
    public static function keysFor(string $service): array
    {
        if (!isset(self::SERVICES[$service])) {
            throw new InvalidArgumentException('unknown service ' . $service);
        }
        if (!self::available()) {
            return ['keys' => [], 'sealed' => 0, 'tired' => 0];
        }

        // Interpolated, and safe: $service is one of the SERVICES keys, checked above,
        // and each is a column name. A bound parameter cannot name a column.
        $rows = Db::connect()->query(
            "SELECT key_hash, secret, label FROM service_keys
             WHERE {$service} AND failures < " . self::MAX_FAILURES . '
             ORDER BY enrolled_at'
        )->fetchAll();

        $keys = [];
        $sealed = 0;

        foreach ($rows as $row) {
            $key = self::open((string) $row['secret']);
            if ($key === null) {
                $sealed++;
                continue;
            }

            $keys[] = ['id' => (string) $row['key_hash'], 'key' => $key,
                       'label' => (string) $row['label']];
        }

        $tired = (int) (Db::connect()->query(
            "SELECT count(*) FROM service_keys
             WHERE {$service} AND failures >= " . self::MAX_FAILURES
        )->fetchColumn() ?: 0);

        return ['keys' => $keys, 'sealed' => $sealed, 'tired' => $tired];
    }

    /** A pass that worked: clears whatever the last one complained about. */
    public static function succeeded(string $id): void
    {
        if (!Db::enabled()) {
            return;
        }

        Db::connect()->prepare(
            'UPDATE service_keys SET used_at = now(), failures = 0, error = \'\'
             WHERE key_hash = :h'
        )->execute([':h' => $id]);
    }

    /**
     * A pass that did not.
     *
     * `$fatal` is for the mod saying the key is not a key - revoked, or the galaxy was
     * replaced. There is no point retrying that for a week, so it goes straight to the
     * failure ceiling and the row stops being read; the player still sees it on the
     * console, with the reason, and re-enrolling clears it.
     *
     * Everything else - the game server down, the stack still coming up - just counts, and
     * MAX_FAILURES passes of it is long enough that no ordinary outage reaches the ceiling.
     */
    public static function failed(string $id, string $error, bool $fatal = false): void
    {
        if (!Db::enabled()) {
            return;
        }

        Db::connect()->prepare(sprintf(
            'UPDATE service_keys SET failures = %s, error = :e WHERE key_hash = :h',
            $fatal ? (string) self::MAX_FAILURES : 'failures + 1'
        ))->execute([':e' => self::clean($error, 200), ':h' => $id]);
    }

    /**
     * Moves keys still listed in POLL_KEYS or NOTIFY_KEYS into the table, once.
     *
     * A migration shim, and the reason removing the .env lists does not break a stack that
     * is already running one. The player index is left null because nothing here can ask
     * the mod who a key is; the service's next successful pass fills it in, and until then
     * the row simply does not appear on that player's console.
     *
     * The two services import in parallel and may name the same key - NOTIFY_KEYS used to
     * default to POLL_KEYS, so on most deployments they name exactly the same keys. So
     * whichever gets there second has to add its own service to the row the first one
     * made, rather than finding it already present and doing nothing. `from_env` is what
     * makes that safe: it is only ever true on a row nobody has enrolled from the console,
     * so an admin who has left the variable set cannot switch a service back on that a
     * player deliberately switched off.
     *
     * @param list<string> $keys
     */
    public static function importEnv(string $service, array $keys): int
    {
        if (!isset(self::SERVICES[$service])) {
            throw new InvalidArgumentException('unknown service ' . $service);
        }
        if (!self::available() || $keys === []) {
            return 0;
        }

        $insert = Db::connect()->prepare(
            "INSERT INTO service_keys (key_hash, secret, label, {$service}, from_env)
             VALUES (:h, :s, :l, TRUE, TRUE)
             ON CONFLICT (key_hash) DO UPDATE SET {$service} = TRUE
             WHERE service_keys.from_env AND NOT service_keys.{$service}"
        );

        $added = 0;
        foreach ($keys as $key) {
            $insert->execute([':h' => self::hash($key), ':s' => self::seal($key),
                              ':l' => 'carried over from .env']);
            $added += $insert->rowCount();
        }

        return $added;
    }

    /**
     * Fills in the player behind a row once the mod has said who it is.
     *
     * Only ever widens: a row that already names a player is left alone, so this cannot
     * move somebody's enrolment onto another player if a key is somehow reissued.
     */
    public static function attribute(string $id, int $player): void
    {
        if (!Db::enabled()) {
            return;
        }

        Db::connect()->prepare(
            'UPDATE service_keys SET player = :p WHERE key_hash = :h AND player IS NULL'
        )->execute([':p' => $player, ':h' => $id]);
    }

    /* ---------------------------------- plumbing ---------------------------------- */

    /** One row of this player's, by the id the console was given. */
    private static function row(int $player, string $id): ?array
    {
        if (!Db::enabled() || $id === '') {
            return null;
        }

        $rows = Db::connect()->prepare(
            'SELECT key_hash, label, poll, notify FROM service_keys
             WHERE player = :p AND key_hash = :h'
        );
        $rows->execute([':p' => $player, ':h' => $id]);
        $row = $rows->fetch();

        return is_array($row) ? $row : null;
    }

    private static function drop(string $hash): void
    {
        Db::connect()->prepare('DELETE FROM service_keys WHERE key_hash = :h')
            ->execute([':h' => $hash]);
    }

    /** @return array{error: array{status: int, code: string, message: string}} */
    private static function refuse(int $status, string $code, string $message): array
    {
        return ['error' => ['status' => $status, 'code' => $code, 'message' => $message]];
    }

    private static function clean(string $text, int $max): string
    {
        // Control characters out: these are shown on a console and written to a log, and
        // a label is free text a player typed.
        $text = trim((string) preg_replace('/[\x00-\x1f\x7f]+/u', ' ', $text));

        return mb_substr($text, 0, $max);
    }

    private static function truthy(mixed $value): bool
    {
        return $value === true || $value === 't' || $value === 1 || $value === '1';
    }
}
