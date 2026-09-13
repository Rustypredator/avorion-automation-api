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
    private const SCHEMA = 3;

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
            $current = self::schemaVersion($pdo);
            if ($current < self::SCHEMA) {
                // One transaction for the lot, so a migration that fails part-way leaves
                // the previous schema standing rather than half of the next one.
                $pdo->beginTransaction();
                try {
                    foreach (self::migrations() as $version => $statements) {
                        if ($version <= $current) {
                            continue;
                        }
                        foreach ($statements as $sql) {
                            $pdo->exec($sql);
                        }
                    }
                    $pdo->exec('DELETE FROM api_schema');
                    $pdo->exec('INSERT INTO api_schema (version) VALUES (' . self::SCHEMA . ')');
                    $pdo->commit();
                } catch (Throwable $e) {
                    $pdo->rollBack();
                    throw $e;
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
     * Schema steps by the version they bring the database up to. A database at version N
     * runs every step above N, in order.
     *
     * Version 2 is the whole schema as it stood before steps were numbered, and every
     * statement in it is idempotent - a database at version 0 or 1 simply runs it all.
     *
     * @return array<int, list<string>>
     */
    private static function migrations(): array
    {
        return [2 => self::base(), 3 => self::shared()];
    }

    /**
     * @return list<string>
     */
    private static function base(): array
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

            /*
             * A station's books, sampled.
             *
             * The mod reports earnings as running totals since the station was founded,
             * because that is what the game itself keeps - a TradingManager holds three
             * counters and no history. A total is not an answer to "what did this place
             * make last week", so the answer is built here, out of two samples and the
             * time between them.
             *
             * `stock` is good name -> units held, which is the other half: the counters
             * are one number for the whole station and cannot say which line earned it,
             * while differencing the stock good by good says what was produced and what
             * left. See History::economyGoods.
             *
             * Sampling is rate-limited per station rather than written every pass - see
             * History::recordStations. Secured values are only refreshed when the game
             * saves, so a faster sample is a copy of the previous one.
             */
            'CREATE TABLE IF NOT EXISTS station_samples (
                 id       BIGSERIAL PRIMARY KEY,
                 key_id   BIGINT      NOT NULL REFERENCES api_keys(id) ON DELETE CASCADE,
                 ship     TEXT        NOT NULL,
                 owner    TEXT        NOT NULL DEFAULT \'\',
                 x        INTEGER     NOT NULL DEFAULT 0,
                 y        INTEGER     NOT NULL DEFAULT 0,
                 taken_at TIMESTAMPTZ NOT NULL,
                 gained   BIGINT      NOT NULL DEFAULT 0,
                 spent    BIGINT      NOT NULL DEFAULT 0,
                 tax      BIGINT      NOT NULL DEFAULT 0,
                 stock    JSONB       NOT NULL DEFAULT \'{}\'::jsonb,
                 data     JSONB       NOT NULL DEFAULT \'{}\'::jsonb
             )',

            // Every economy read walks one key's samples in time order, and the window
            // filter and the LAG() that turns totals into deltas both want this order.
            'CREATE INDEX IF NOT EXISTS station_samples_window_idx
                 ON station_samples (key_id, ship, taken_at)',

            // Finding the newest sample per station, which every write does once to
            // decide whether enough time has passed to take another.
            'CREATE INDEX IF NOT EXISTS station_samples_latest_idx
                 ON station_samples (key_id, taken_at DESC)',

            /*
             * The faction ledger over time: money and resources for the player and for
             * their alliance. Rate-limited the same way, and kept apart from the station
             * samples because it answers a different question - station earnings are
             * gross, while this is what actually survived crew wages, ship losses and
             * whatever the owner spent it on.
             */
            'CREATE TABLE IF NOT EXISTS faction_samples (
                 id        BIGSERIAL PRIMARY KEY,
                 key_id    BIGINT      NOT NULL REFERENCES api_keys(id) ON DELETE CASCADE,
                 owner     TEXT        NOT NULL DEFAULT \'\',
                 taken_at  TIMESTAMPTZ NOT NULL,
                 money     BIGINT      NOT NULL DEFAULT 0,
                 resources JSONB       NOT NULL DEFAULT \'{}\'::jsonb,
                 stations  INTEGER     NOT NULL DEFAULT 0
             )',

            'CREATE INDEX IF NOT EXISTS faction_samples_window_idx
                 ON faction_samples (key_id, owner, taken_at)',
        ];
    }

    /**
     * Version 3: rows belong to the faction that owns the craft, not to the key that saw it.
     *
     * Up to version 2 everything hung off api_keys, so two members of one alliance each
     * held a private copy of the same alliance fleet and neither could see the other's -
     * and one player with two keys held two disjoint histories. From here a row carries
     * `faction`, the game's own index of the owning player or alliance, and a key reads
     * whatever its player may: that player's rows, and its alliance's rows while the mod
     * confirms the membership. See History::scope.
     *
     * The existing rows cannot be moved here. SQL alone does not know which player a key
     * hash belongs to, let alone their alliance, so they keep their key_id with faction
     * NULL and every key is flagged `legacy`. The next time the mod vouches for a key - the
     * first /ping it relays, or the check a /history read makes - History::adopt moves that
     * key's rows over, merging what two members recorded of the same alliance craft. Until
     * then the key still reads them exactly as before.
     *
     * @return list<string>
     */
    private static function shared(): array
    {
        return [
            /*
             * Who a key belongs to, as far as the mod last said. `alliance` is NULL for a
             * player in none; `verified_at` is when the mod last said so, and alliance rows
             * are only readable while it is recent. A key whose mod answer is older than
             * that is re-checked through the transport rather than trusted.
             */
            'ALTER TABLE api_keys ADD COLUMN IF NOT EXISTS player BIGINT',
            'ALTER TABLE api_keys ADD COLUMN IF NOT EXISTS alliance BIGINT',
            'ALTER TABLE api_keys ADD COLUMN IF NOT EXISTS verified_at TIMESTAMPTZ',
            'ALTER TABLE api_keys ADD COLUMN IF NOT EXISTS legacy BOOLEAN NOT NULL DEFAULT FALSE',

            // Every key that exists at this point predates faction ownership. A fresh
            // database has none, so this only ever marks rows an upgrade inherited.
            'UPDATE api_keys SET legacy = TRUE',

            'CREATE INDEX IF NOT EXISTS api_keys_player_idx ON api_keys (player)',

            /*
             * Names for the faction indices, so a reader can say "Rusty Industries" rather
             * than "faction 77". Refreshed from every answer that names one; never used to
             * decide access, which goes by index alone.
             */
            'CREATE TABLE IF NOT EXISTS factions (
                 id   BIGINT PRIMARY KEY,
                 kind TEXT   NOT NULL DEFAULT \'\',
                 name TEXT   NOT NULL DEFAULT \'\'
             )',

            // The owning faction on every data table. key_id stays for the rows that have
            // not been adopted yet, and is NULL on everything written from now on.
            'ALTER TABLE visits ADD COLUMN IF NOT EXISTS faction BIGINT',
            'ALTER TABLE visits ALTER COLUMN key_id DROP NOT NULL',
            'ALTER TABLE events ADD COLUMN IF NOT EXISTS faction BIGINT',
            'ALTER TABLE events ALTER COLUMN key_id DROP NOT NULL',
            'ALTER TABLE station_samples ADD COLUMN IF NOT EXISTS faction BIGINT',
            'ALTER TABLE station_samples ALTER COLUMN key_id DROP NOT NULL',
            'ALTER TABLE faction_samples ADD COLUMN IF NOT EXISTS faction BIGINT',
            'ALTER TABLE faction_samples ALTER COLUMN key_id DROP NOT NULL',

            // The same partial unique index as visits_open_idx, one level up: at most one
            // open visit per craft however many keys are polling it.
            'CREATE UNIQUE INDEX IF NOT EXISTS visits_faction_open_idx
                 ON visits (faction, ship) WHERE open',
            'CREATE INDEX IF NOT EXISTS visits_faction_window_idx ON visits (faction, left_at DESC)',
            'CREATE INDEX IF NOT EXISTS visits_faction_cell_idx ON visits (faction, x, y)',

            /*
             * Partial on epoch >= 0. Adopted rows are moved to negative epochs - see
             * History::adopt - because two members numbered their restarts independently,
             * and "epoch 1, seq 4" from one of them is not the same event as from the other.
             */
            'CREATE UNIQUE INDEX IF NOT EXISTS events_faction_dedupe_idx
                 ON events (faction, ship, epoch, seq) WHERE epoch >= 0',
            'CREATE INDEX IF NOT EXISTS events_faction_window_idx
                 ON events (faction, happened_at DESC)',

            'CREATE INDEX IF NOT EXISTS station_samples_faction_window_idx
                 ON station_samples (faction, ship, taken_at)',
            'CREATE INDEX IF NOT EXISTS station_samples_faction_latest_idx
                 ON station_samples (faction, taken_at DESC)',

            'CREATE INDEX IF NOT EXISTS faction_samples_faction_window_idx
                 ON faction_samples (faction, taken_at)',

            // ship_state, per faction. Shared, so two members polling one alliance craft
            // agree on which restart they are in and never record an event twice.
            'CREATE TABLE IF NOT EXISTS event_marks (
                 faction BIGINT  NOT NULL,
                 ship    TEXT    NOT NULL,
                 epoch   INTEGER NOT NULL DEFAULT 0,
                 max_seq BIGINT  NOT NULL DEFAULT -1,
                 PRIMARY KEY (faction, ship)
             )',

            /*
             * The last manifest seen for each craft: its hold and who is aboard.
             *
             * Not a series - one row per craft, replaced on every GET /ships/{name} - because
             * nobody asks what was in a hold last Tuesday, and a goods search asks what is
             * in every hold right now. The listing carries no cargo, so without this a
             * console searching for a good has to read every craft's detail through the
             * transport, one call each, every session and for every member separately.
             */
            'CREATE TABLE IF NOT EXISTS manifests (
                 faction  BIGINT      NOT NULL,
                 ship     TEXT        NOT NULL,
                 owner    TEXT        NOT NULL DEFAULT \'\',
                 taken_at TIMESTAMPTZ NOT NULL,
                 data     JSONB       NOT NULL DEFAULT \'{}\'::jsonb,
                 PRIMARY KEY (faction, ship)
             )',
        ];
    }
}
