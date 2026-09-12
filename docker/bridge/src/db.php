<?php

declare(strict_types=1);

/**
 * The history store's connection to Postgres, and the schema it expects to find there.
 *
 * Kept apart from history.php because two very different things need it: the request path,
 * where a connection is opened thousands of times and must be cheap, and the poller, which
 * holds one open for the life of the process.
 *
 * ### On connecting from the request path
 *
 * Connections are persistent (PDO::ATTR_PERSISTENT). FrankenPHP in classic mode runs a
 * fresh PHP context per request, so without pooling every relayed call would pay a TCP
 * handshake plus Postgres startup - tens of milliseconds onto calls that currently take
 * one. With pooling the socket outlives the request and the cost is a round trip.
 *
 * A failed connection is an exception and the caller is expected to swallow it: history is
 * a copy of data the API already returned, so a database that is down or still starting
 * must cost the caller nothing but a missing overlay. index.php wraps every write in a
 * try/catch for exactly this reason.
 */
final class Db
{
    /** Bumped when the schema below changes in a way that needs applying. */
    private const SCHEMA = 1;

    /** Postgres advisory lock id, so two workers cannot migrate at the same moment. */
    private const MIGRATE_LOCK = 0x41564F31; // "AVO1"

    private static ?PDO $pdo = null;
    private static bool $migrated = false;

    /**
     * The configured DSN, or "" when no history is to be kept.
     *
     * HISTORY_DSN wins if set to anything. Otherwise one is assembled from the pieces
     * compose passes, which is the normal path - it means the deployment sets a password
     * and nothing else.
     *
     * An empty HISTORY_DB_HOST is what turns the store off, rather than an empty
     * HISTORY_DSN as one might expect. Compose expands a variable the .env does not
     * mention to an empty string, so "unset" and "deliberately blanked" reach this process
     * looking exactly alike - which makes an empty HISTORY_DSN useless as a switch and, if
     * it were treated as one, would silently disable the history for every deployment that
     * simply never mentioned it. The host has a real default to fall back to, so blank
     * there is unambiguous.
     */
    public static function dsn(): string
    {
        $explicit = getenv('HISTORY_DSN');
        if (is_string($explicit) && $explicit !== '') {
            return $explicit;
        }

        $host = getenv('HISTORY_DB_HOST');
        if ($host === false) {
            $host = 'db';
        }
        if ($host === '') {
            return '';
        }

        $port = (string) (getenv('HISTORY_DB_PORT') ?: '5432');
        $name = (string) (getenv('HISTORY_DB_NAME') ?: 'avorion');

        return sprintf('pgsql:host=%s;port=%s;dbname=%s', $host, $port, $name);
    }

    public static function enabled(): bool
    {
        return self::dsn() !== '';
    }

    public static function connect(): PDO
    {
        if (self::$pdo instanceof PDO) {
            return self::$pdo;
        }

        $dsn = self::dsn();
        if ($dsn === '') {
            throw new RuntimeException('history is disabled: HISTORY_DSN is empty');
        }

        self::$pdo = new PDO(
            $dsn,
            (string) (getenv('HISTORY_DB_USER') ?: 'avorion'),
            (string) (getenv('HISTORY_DB_PASSWORD') ?: ''),
            [
                PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
                PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
                PDO::ATTR_EMULATE_PREPARES => false,
                PDO::ATTR_PERSISTENT => true,
                PDO::ATTR_TIMEOUT => (int) (getenv('HISTORY_DB_TIMEOUT') ?: 5),
            ]
        );

        self::migrate(self::$pdo);

        return self::$pdo;
    }

    /** Drops the memoised handle, so the next connect() starts over. Tests use this. */
    public static function reset(): void
    {
        self::$pdo = null;
        self::$migrated = false;
    }

    /**
     * Brings the schema up to date, at most once per process.
     *
     * Guarded by a session-level advisory lock rather than a transaction: CREATE TABLE IF
     * NOT EXISTS is transactional in Postgres but still deadlocks when two sessions run the
     * same set in the same order, which is precisely what a compose stack starting the API
     * and the poller together would do.
     */
    public static function migrate(PDO $pdo): void
    {
        if (self::$migrated) {
            return;
        }

        // The common case by far: already current, one cheap query, no lock taken.
        if (self::schemaVersion($pdo) >= self::SCHEMA) {
            self::$migrated = true;
            return;
        }

        $pdo->prepare('SELECT pg_advisory_lock(:id)')->execute([':id' => self::MIGRATE_LOCK]);

        try {
            // Re-read under the lock: whoever held it before us may have just done the work.
            if (self::schemaVersion($pdo) < self::SCHEMA) {
                foreach (self::statements() as $sql) {
                    $pdo->exec($sql);
                }
            }
            self::$migrated = true;
        } finally {
            $pdo->prepare('SELECT pg_advisory_unlock(:id)')->execute([':id' => self::MIGRATE_LOCK]);
        }
    }

    private static function schemaVersion(PDO $pdo): int
    {
        try {
            $row = $pdo->query('SELECT version FROM api_schema LIMIT 1')->fetch();
        } catch (PDOException) {
            // No table yet, which is version zero rather than an error.
            return 0;
        }

        return is_array($row) ? (int) ($row['version'] ?? 0) : 0;
    }

    /**
     * @return list<string>
     */
    private static function statements(): array
    {
        return [
            'CREATE TABLE IF NOT EXISTS api_schema (version INTEGER NOT NULL)',

            /*
             * One row per API key that has ever had anything recorded, holding a SHA-256 of
             * the key and never the key itself. This process deliberately owns no
             * credential; storing one would change that, and a 256-bit key means the hash
             * cannot be walked back or guessed.
             *
             * It is also what lets reads skip validation. An unknown key simply matches no
             * row and reads an empty history rather than someone else's.
             */
            'CREATE TABLE IF NOT EXISTS api_keys (
                 id         BIGSERIAL PRIMARY KEY,
                 key_hash   TEXT        NOT NULL UNIQUE,
                 created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
                 seen_at    TIMESTAMPTZ NOT NULL DEFAULT now()
             )',

            /*
             * One row per sector a craft was seen to occupy.
             *
             * The row for the sector a craft is in right now is a real row with open =
             * true, extended in place by each poll that finds it still there. So the table
             * grows with travel rather than with polling - a fleet parked for a week is one
             * UPDATE per craft per poll and no new rows - and "where is it now" is the same
             * query as "where has it been", which under the JSONL store it was not.
             */
            'CREATE TABLE IF NOT EXISTS visits (
                 id         BIGSERIAL PRIMARY KEY,
                 key_id     BIGINT      NOT NULL REFERENCES api_keys(id) ON DELETE CASCADE,
                 ship       TEXT        NOT NULL,
                 owner      TEXT        NOT NULL DEFAULT \'\',
                 x          INTEGER     NOT NULL,
                 y          INTEGER     NOT NULL,
                 entered_at TIMESTAMPTZ NOT NULL,
                 left_at    TIMESTAMPTZ NOT NULL,
                 open       BOOLEAN     NOT NULL DEFAULT FALSE
             )',

            // Finding the visit a craft currently has open, which every poll does once per
            // craft. Partial, so it indexes the handful of open rows and not the history.
            'CREATE UNIQUE INDEX IF NOT EXISTS visits_open_idx
                 ON visits (key_id, ship) WHERE open',

            // The window filter behind every overlay read.
            'CREATE INDEX IF NOT EXISTS visits_window_idx ON visits (key_id, left_at DESC)',

            // The heatmap groups on this pair.
            'CREATE INDEX IF NOT EXISTS visits_cell_idx ON visits (key_id, x, y)',

            /*
             * The mod's own order and status events, kept past its 200-entry in-memory ring
             * buffer and past a server restart.
             *
             * Fields the mod sends that are not columns here live in `data`. The event
             * shape is the mod's to change and this table should not need a migration every
             * time it gains a field.
             */
            'CREATE TABLE IF NOT EXISTS events (
                 id          BIGSERIAL PRIMARY KEY,
                 key_id      BIGINT      NOT NULL REFERENCES api_keys(id) ON DELETE CASCADE,
                 ship        TEXT        NOT NULL,
                 owner       TEXT        NOT NULL DEFAULT \'\',
                 epoch       INTEGER     NOT NULL DEFAULT 0,
                 seq         BIGINT      NOT NULL,
                 happened_at TIMESTAMPTZ NOT NULL,
                 data        JSONB       NOT NULL DEFAULT \'{}\'::jsonb
             )',

            /*
             * What makes recording an event idempotent: two pollers, or one poller and an
             * open console, can collect the same batch and the second INSERT is a no-op.
             *
             * `epoch` is in the key because the mod restarts its sequence counter at zero
             * whenever the server restarts, so (ship, seq) alone is not unique over time -
             * seq 4 after a restart is a different event from seq 4 before it. See
             * History::recordEvents for how a restart is spotted.
             */
            'CREATE UNIQUE INDEX IF NOT EXISTS events_dedupe_idx
                 ON events (key_id, ship, epoch, seq)',

            'CREATE INDEX IF NOT EXISTS events_window_idx ON events (key_id, happened_at DESC)',

            /*
             * Per craft, the highest sequence number seen and which restart it belonged to.
             * Small, one row per craft, and the only thing recordEvents has to lock.
             */
            'CREATE TABLE IF NOT EXISTS ship_state (
                 key_id  BIGINT  NOT NULL REFERENCES api_keys(id) ON DELETE CASCADE,
                 ship    TEXT    NOT NULL,
                 epoch   INTEGER NOT NULL DEFAULT 0,
                 max_seq BIGINT  NOT NULL DEFAULT -1,
                 PRIMARY KEY (key_id, ship)
             )',

            'DELETE FROM api_schema',
            'INSERT INTO api_schema (version) VALUES (' . self::SCHEMA . ')',
        ];
    }
}
