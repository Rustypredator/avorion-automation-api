<?php

declare(strict_types=1);

require_once __DIR__ . '/db.php';

/**
 * Durable history for one API key.
 *
 * The mod's own event log is a ring buffer in server memory: 200 entries per ship, gone
 * at the next restart, and only written while some player agent is online to see the
 * callbacks fire. That is the right shape for "what is this ship doing now" and the wrong
 * one for "where has this fleet been all month", which is what a map overlay needs.
 *
 * So the bridge keeps a copy in Postgres. Every answer it relays past on its way back to
 * the caller is also recorded here, which costs one statement on calls that were happening
 * anyway and needs nothing at all from the Lua side - where a growing file written on the
 * server tick would be a genuinely bad idea.
 *
 * Two tables carry it, both defined in db.php:
 *
 *   visits - one row per sector a craft was seen to occupy. Positions come from
 *            GET /ships, which reads the ship database, so this keeps recording with
 *            every player logged out. It is what the heatmap and the travel track are
 *            built from.
 *   events - the mod's own order and status events, kept past the ring buffer's 200 and
 *            past a server restart.
 *
 * ### On keying by the API key
 *
 * A key is identified by a SHA-256 of itself and the key is never stored: this process
 * deliberately owns no credential, and keeping one would change that. A key is 256 bits of
 * randomness, so the hash cannot be guessed, and a key nobody has ever used simply matches
 * no row.
 *
 * That is what lets reads skip validation - an unknown key reads an empty history rather
 * than someone else's. Writes are a different matter and are only ever made after the mod
 * has answered a call successfully, which is the actual authentication. A caller who
 * cannot get a 200 out of the mod cannot make a row here exist.
 *
 * ### What it does not know
 *
 * Nothing in the mod pushes. History accumulates while *something* is calling the API -
 * the poller service, the console with a tab open, your own script - and a gap in the
 * tables is a gap in who was looking, not a gap in what happened. Dwell times are
 * therefore reported as observed seconds: time nobody was watching is counted as zero
 * rather than guessed at. docker-compose.yml runs a poller on a timer so that, in a normal
 * deployment, something is always looking.
 */
final class History
{
    private string $hash;
    private int $retentionDays;
    private int $maxRows;
    private ?PDO $pdo = null;

    /** Memoised api_keys.id: false means "looked and there was none". */
    private int|false|null $keyId = null;

    public function __construct(string $key)
    {
        $this->hash = hash('sha256', $key);
        $this->retentionDays = max(1, (int) (getenv('HISTORY_DAYS') ?: 30));
        $this->maxRows = max(1000, (int) (getenv('HISTORY_MAX_ROWS') ?: 500000));
    }

    public function exists(): bool
    {
        return $this->keyId(false) !== null;
    }

    /* ------------------------------- recording ------------------------------ */

    /**
     * Fold one GET /ships answer into the visit log.
     *
     * A craft that has not moved produces no new row - it extends the one already open for
     * it, which the partial unique index guarantees there is at most one of. So the table
     * grows with travel rather than with polling, and a fleet parked for a week costs one
     * UPDATE per craft per poll and nothing on disk.
     */
    public function recordShips(object $body): void
    {
        $ships = $body->ships ?? null;
        if (!is_array($ships) || $ships === []) {
            return;
        }

        $seen = [];

        foreach ($ships as $ship) {
            $name = is_object($ship) ? ($ship->name ?? null) : null;
            $position = is_object($ship) ? ($ship->position ?? null) : null;

            if (!is_string($name) || $name === '' || !is_object($position)) {
                continue;
            }
            if (!isset($position->x, $position->y)) {
                continue;
            }

            $seen[$name] = [
                'x' => (int) $position->x,
                'y' => (int) $position->y,
                'o' => is_object($ship->owner ?? null) ? (string) ($ship->owner->kind ?? '') : '',
            ];
        }

        if ($seen === []) {
            return;
        }

        $pdo = $this->db();
        $keyId = $this->keyId(true);
        if ($keyId === null) {
            return;
        }

        $pdo->beginTransaction();

        try {
            /*
             * FOR UPDATE rather than a lock file. Two pollers, or a poller and an open
             * console, routinely fold the same answer at the same moment; without this both
             * see no open visit and both insert one, and the partial unique index turns
             * that into an error instead of a duplicate. Taking the rows first serialises
             * them into "second one sees the first one's work".
             */
            $open = [];
            $rows = $this->all(
                $pdo,
                'SELECT ship, x, y FROM visits WHERE key_id = :k AND open FOR UPDATE',
                [':k' => $keyId]
            );
            foreach ($rows as $row) {
                $open[(string) $row['ship']] = ['x' => (int) $row['x'], 'y' => (int) $row['y']];
            }

            $extend = $pdo->prepare(
                'UPDATE visits SET left_at = now() WHERE key_id = :k AND ship = :s AND open'
            );
            $close = $pdo->prepare(
                'UPDATE visits SET open = FALSE WHERE key_id = :k AND ship = :s AND open'
            );
            /*
             * ON CONFLICT because FOR UPDATE above cannot lock a row that does not exist
             * yet. Two writers recording a craft's very first visit at the same moment both
             * see no open row and both insert, and the partial unique index is what stops
             * that becoming two open visits for one craft. Without this the loser's whole
             * transaction aborts; with it, it correctly does nothing, because the winner has
             * already recorded exactly the visit it was going to record.
             */
            $insert = $pdo->prepare(
                'INSERT INTO visits (key_id, ship, owner, x, y, entered_at, left_at, open)
                 VALUES (:k, :s, :o, :x, :y, now(), now(), TRUE)
                 ON CONFLICT (key_id, ship) WHERE open DO NOTHING'
            );

            foreach ($seen as $name => $at) {
                $was = $open[$name] ?? null;

                if ($was !== null && $was['x'] === $at['x'] && $was['y'] === $at['y']) {
                    // Same sector: the visit simply got longer.
                    $extend->execute([':k' => $keyId, ':s' => $name]);
                    continue;
                }

                if ($was !== null) {
                    $close->execute([':k' => $keyId, ':s' => $name]);
                }

                $insert->execute([
                    ':k' => $keyId, ':s' => $name, ':o' => $at['o'],
                    ':x' => $at['x'], ':y' => $at['y'],
                ]);
            }

            $pdo->commit();
        } catch (Throwable $e) {
            $pdo->rollBack();
            throw $e;
        }

        $this->maybePrune();
    }

    /**
     * Fold one GET /ships/{name}/events answer into the event log.
     *
     * Sequence numbers are the mod's and reset to zero on a server restart, so (ship, seq)
     * is not unique over time - seq 4 after a restart is a different event from seq 4
     * before it. A batch whose highest sequence sits below what is already stored is
     * therefore a restart rather than a replay, and is answered by starting a new epoch
     * instead of swallowing every event until the counter catches up again - which, on a
     * busy galaxy, is hours.
     *
     * With the epoch in the unique index, recording is idempotent: the poller and an open
     * console can collect the same batch and the second insert does nothing.
     */
    public function recordEvents(string $ship, object $body): void
    {
        $events = $body->events ?? null;
        if (!is_array($events) || $events === []) {
            return;
        }

        $owner = is_object($body->owner ?? null) ? (string) ($body->owner->kind ?? '') : '';

        $highest = 0;
        foreach ($events as $event) {
            $highest = max($highest, (int) (is_object($event) ? ($event->seq ?? 0) : 0));
        }

        /*
         * When an event actually happened, as opposed to when this process heard about it.
         *
         * They are not the same and the difference is not small: a caller that has been
         * away comes back and collects a whole backlog in one call, and stamping all of it
         * with now() lands an afternoon's worth of events on a single second.
         *
         * The mod stamps each event with Server().unpausedRuntime, which is seconds of
         * server uptime - no use as a date on its own, but exact as a spacing. The newest
         * event in a batch is the one closest to now, so anchoring that to the clock and
         * walking the rest back by their own offsets dates the whole batch. It is wrong by
         * however long the newest event sat in the buffer before anyone asked, which is one
         * poll interval for anything watched live, and it degrades gracefully: an event
         * without a usable stamp simply gets the arrival time it would have had anyway.
         */
        $now = time();
        $newest = 0.0;
        foreach ($events as $event) {
            if (is_object($event) && is_numeric($event->at ?? null)) {
                $newest = max($newest, (float) $event->at);
            }
        }

        $happenedAt = static function (object $event) use ($now, $newest): int {
            if ($newest <= 0 || !is_numeric($event->at ?? null)) {
                return $now;
            }

            $offset = (int) round($newest - (float) $event->at);

            // A negative offset means an event newer than the newest, which cannot
            // happen, and an absurd one means the runtime clock restarted mid-batch.
            if ($offset < 0 || $offset > 30 * 86400) {
                return $now;
            }

            return $now - $offset;
        };

        $pdo = $this->db();
        $keyId = $this->keyId(true);
        if ($keyId === null) {
            return;
        }

        $pdo->beginTransaction();

        try {
            $pdo->prepare(
                'INSERT INTO ship_state (key_id, ship) VALUES (:k, :s)
                 ON CONFLICT (key_id, ship) DO NOTHING'
            )->execute([':k' => $keyId, ':s' => $ship]);

            $state = $this->one(
                $pdo,
                'SELECT epoch, max_seq FROM ship_state WHERE key_id = :k AND ship = :s FOR UPDATE',
                [':k' => $keyId, ':s' => $ship]
            );

            $epoch = (int) ($state['epoch'] ?? 0);
            $mark = (int) ($state['max_seq'] ?? -1);

            if ($highest < $mark) {
                $epoch++;
                $mark = -1;
            }

            $insert = $pdo->prepare(
                'INSERT INTO events (key_id, ship, owner, epoch, seq, happened_at, data)
                 VALUES (:k, :s, :o, :e, :q, to_timestamp(:t), CAST(:d AS jsonb))
                 ON CONFLICT (key_id, ship, epoch, seq) DO NOTHING'
            );

            foreach ($events as $event) {
                if (!is_object($event)) {
                    continue;
                }

                $seq = (int) ($event->seq ?? 0);
                if ($seq <= $mark) {
                    continue;
                }

                // Everything the mod sent except the two fields that became columns. The
                // event shape belongs to the mod and should not need a migration to change.
                $data = get_object_vars($event);
                unset($data['seq']);

                $insert->execute([
                    ':k' => $keyId,
                    ':s' => $ship,
                    ':o' => $owner,
                    ':e' => $epoch,
                    ':q' => $seq,
                    ':t' => $happenedAt($event),
                    ':d' => json_encode($data, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE) ?: '{}',
                ]);
            }

            $pdo->prepare(
                'UPDATE ship_state SET epoch = :e, max_seq = GREATEST(max_seq, :q)
                 WHERE key_id = :k AND ship = :s'
            )->execute([':k' => $keyId, ':s' => $ship, ':e' => $epoch, ':q' => max($mark, $highest)]);

            $pdo->commit();
        } catch (Throwable $e) {
            $pdo->rollBack();
            throw $e;
        }

        $this->maybePrune();
    }

    /* -------------------------------- reading ------------------------------- */

    /**
     * Every visit in the window, oldest first. The one a craft currently has open is an
     * ordinary row carrying `open: true`, so "where is it right now" is part of the same
     * answer rather than a separate call.
     */
    public function visits(array $filter): array
    {
        $keyId = $this->keyId(false);
        if ($keyId === null) {
            return [];
        }

        [$where, $args] = $this->where($keyId, $filter, 'entered_at', 'left_at');

        $sql = 'SELECT ship, owner, x, y, open,
                       EXTRACT(EPOCH FROM entered_at)::bigint AS t,
                       EXTRACT(EPOCH FROM left_at)::bigint    AS e
                FROM visits WHERE ' . $where . ' ORDER BY entered_at, id';

        // Keep the newest: a caller drawing a track wants where the ship has been lately,
        // and can page back with `from` for the rest. Done as a descending LIMIT and
        // flipped, so the database never materialises the rows being thrown away.
        $limit = (int) ($filter['limit'] ?? 0);
        if ($limit > 0) {
            // `id` is carried through the subquery so the outer sort can break ties the
            // same way the inner one did. Several visits routinely share a second - a fleet
            // jumping together is recorded in one pass - and ordering by t alone would let
            // the planner hand them back in a different order each call.
            $sql = 'SELECT * FROM (SELECT id, ship, owner, x, y, open,
                           EXTRACT(EPOCH FROM entered_at)::bigint AS t,
                           EXTRACT(EPOCH FROM left_at)::bigint    AS e
                    FROM visits WHERE ' . $where . ' ORDER BY entered_at DESC, id DESC LIMIT '
                    . $limit . ') q ORDER BY t, id';
        }

        $out = [];
        foreach ($this->all($this->db(), $sql, $args) as $row) {
            $visit = [
                't' => (int) $row['t'],
                'e' => (int) $row['e'],
                's' => (string) $row['ship'],
                'x' => (int) $row['x'],
                'y' => (int) $row['y'],
                'o' => (string) $row['owner'],
            ];
            if ($this->truthy($row['open'])) {
                $visit['open'] = true;
            }
            $out[] = $visit;
        }

        return $out;
    }

    /**
     * Visits collapsed onto the grid: how often each sector was entered, and for how long.
     *
     * This is the query the JSONL store could not do - it had to read every line and fold
     * it in PHP. Here the grouping is the database's problem and the index on (key_id, x, y)
     * is the whole of the work.
     */
    public function heatmap(array $filter): array
    {
        $keyId = $this->keyId(false);
        if ($keyId === null) {
            return ['cells' => [], 'maxVisits' => 0, 'maxSeconds' => 0,
                    'ships' => [], 'from' => null, 'to' => null];
        }

        [$where, $args] = $this->where($keyId, $filter, 'entered_at', 'left_at');

        // Observed seconds only. A visit that opened and closed between two polls is a
        // real visit of zero measured duration, not a missing one - hence GREATEST(...,0)
        // rather than any attempt to guess at the gap.
        $cells = $this->all(
            $this->db(),
            'SELECT x, y, COUNT(*)::bigint AS visits,
                    SUM(GREATEST(0, EXTRACT(EPOCH FROM (left_at - entered_at))))::bigint AS seconds
             FROM visits WHERE ' . $where . ' GROUP BY x, y ORDER BY y, x',
            $args
        );

        $span = $this->one(
            $this->db(),
            'SELECT EXTRACT(EPOCH FROM MIN(entered_at))::bigint AS f,
                    EXTRACT(EPOCH FROM MAX(left_at))::bigint    AS t,
                    COUNT(DISTINCT ship)::bigint                AS n
             FROM visits WHERE ' . $where,
            $args
        );

        $ships = $this->all(
            $this->db(),
            'SELECT DISTINCT ship FROM visits WHERE ' . $where . ' ORDER BY ship',
            $args
        );

        $out = [];
        $maxVisits = 0;
        $maxSeconds = 0;

        foreach ($cells as $cell) {
            $visits = (int) $cell['visits'];
            $seconds = (int) $cell['seconds'];
            $out[] = ['x' => (int) $cell['x'], 'y' => (int) $cell['y'],
                      'visits' => $visits, 'seconds' => $seconds];
            $maxVisits = max($maxVisits, $visits);
            $maxSeconds = max($maxSeconds, $seconds);
        }

        return [
            'cells' => $out,
            'maxVisits' => $maxVisits,
            'maxSeconds' => $maxSeconds,
            'ships' => array_map(static fn (array $r): string => (string) $r['ship'], $ships),
            'from' => isset($span['f']) ? (int) $span['f'] : null,
            'to' => isset($span['t']) ? (int) $span['t'] : null,
        ];
    }

    public function events(array $filter): array
    {
        $keyId = $this->keyId(false);
        if ($keyId === null) {
            return [];
        }

        [$where, $args] = $this->where($keyId, $filter, 'happened_at', 'happened_at');

        $limit = (int) ($filter['limit'] ?? 0);
        /*
         * `id` is not decoration. A batch collected in one call is stored in one second, so
         * happened_at alone leaves the order inside that second up to the planner - and a
         * caller asking for the newest N would get an arbitrary N of them. The serial is
         * insertion order, which for a batch is the mod's own sequence order.
         */
        $sql = 'SELECT ship, owner, seq, data, EXTRACT(EPOCH FROM happened_at)::bigint AS t
                FROM events WHERE ' . $where
                . ' ORDER BY happened_at ' . ($limit > 0 ? 'DESC, id DESC LIMIT ' . $limit : 'ASC, id ASC');

        $out = [];
        foreach ($this->all($this->db(), $sql, $args) as $row) {
            $event = [
                't' => (int) $row['t'],
                's' => (string) $row['ship'],
                'q' => (int) $row['seq'],
                'o' => (string) $row['owner'],
            ];

            $data = json_decode((string) $row['data'], true);
            if (is_array($data)) {
                foreach ($data as $field => $value) {
                    $event[$field] = $value;
                }
            }

            $out[] = $event;
        }

        // The descending LIMIT above kept the newest; the caller wants them oldest first.
        return $limit > 0 ? array_reverse($out) : $out;
    }

    /** What is stored, per craft, so a client can show the shape of it before asking for any. */
    public function summary(): array
    {
        $keyId = $this->keyId(false);
        if ($keyId === null) {
            return ['ships' => [], 'rows' => 0, 'retentionDays' => $this->retentionDays,
                    'recording' => false];
        }

        $ships = [];

        $note = static function (string $name, string $field, int $count, ?int $first, ?int $last)
            use (&$ships): void {
            if (!isset($ships[$name])) {
                $ships[$name] = ['name' => $name, 'visits' => 0, 'events' => 0,
                                 'sectors' => 0, 'first' => null, 'last' => null];
            }
            $ships[$name][$field] = $count;
            foreach ([['first', $first, 'min'], ['last', $last, 'max']] as [$slot, $value, $pick]) {
                if ($value === null) {
                    continue;
                }
                $ships[$name][$slot] = $ships[$name][$slot] === null
                    ? $value
                    : $pick($ships[$name][$slot], $value);
            }
        };

        $rows = $this->all(
            $this->db(),
            'SELECT ship, COUNT(*)::bigint AS n, COUNT(DISTINCT (x, y))::bigint AS sectors,
                    EXTRACT(EPOCH FROM MIN(entered_at))::bigint AS f,
                    EXTRACT(EPOCH FROM MAX(left_at))::bigint    AS l
             FROM visits WHERE key_id = :k GROUP BY ship',
            [':k' => $keyId]
        );
        foreach ($rows as $row) {
            $note((string) $row['ship'], 'visits', (int) $row['n'], (int) $row['f'], (int) $row['l']);
            $ships[(string) $row['ship']]['sectors'] = (int) $row['sectors'];
        }

        $rows = $this->all(
            $this->db(),
            'SELECT ship, COUNT(*)::bigint AS n,
                    EXTRACT(EPOCH FROM MIN(happened_at))::bigint AS f,
                    EXTRACT(EPOCH FROM MAX(happened_at))::bigint AS l
             FROM events WHERE key_id = :k GROUP BY ship',
            [':k' => $keyId]
        );
        foreach ($rows as $row) {
            $note((string) $row['ship'], 'events', (int) $row['n'], (int) $row['f'], (int) $row['l']);
        }

        ksort($ships);

        $total = 0;
        foreach ($ships as $ship) {
            $total += $ship['visits'] + $ship['events'];
        }

        return [
            'ships' => array_values($ships),
            'rows' => $total,
            'retentionDays' => $this->retentionDays,
            'recording' => true,
        ];
    }

    /** Removes everything stored for this key, or just one craft's share of it. */
    public function clear(?string $ship): array
    {
        $keyId = $this->keyId(false);
        if ($keyId === null) {
            return ['cleared' => true, 'ship' => $ship, 'removed' => 0];
        }

        $pdo = $this->db();
        $removed = 0;

        if ($ship === null) {
            // ON DELETE CASCADE takes visits, events and ship_state with it, and forgetting
            // the key row means the next write starts over as if nothing had been recorded.
            $removed = (int) $this->one($pdo, 'SELECT COUNT(*)::bigint AS n FROM visits WHERE key_id = :k',
                [':k' => $keyId])['n'];
            $removed += (int) $this->one($pdo, 'SELECT COUNT(*)::bigint AS n FROM events WHERE key_id = :k',
                [':k' => $keyId])['n'];

            $pdo->prepare('DELETE FROM api_keys WHERE id = :k')->execute([':k' => $keyId]);
            $this->keyId = false;

            return ['cleared' => true, 'ship' => null, 'removed' => $removed];
        }

        foreach (['visits', 'events', 'ship_state'] as $table) {
            $statement = $pdo->prepare("DELETE FROM {$table} WHERE key_id = :k AND ship = :s");
            $statement->execute([':k' => $keyId, ':s' => $ship]);
            if ($table !== 'ship_state') {
                $removed += $statement->rowCount();
            }
        }

        return ['cleared' => true, 'ship' => $ship, 'removed' => $removed];
    }

    /**
     * Drops rows past the retention window, and past a hard row cap if the window alone is
     * not enough. Public because the poller calls it on its own timer, which is where this
     * work belongs - see maybePrune for why it also runs, rarely, from the request path.
     */
    public function prune(): int
    {
        $keyId = $this->keyId(false);
        if ($keyId === null) {
            return 0;
        }

        $pdo = $this->db();
        $cutoff = time() - $this->retentionDays * 86400;
        $removed = 0;

        foreach ([['visits', 'left_at'], ['events', 'happened_at']] as [$table, $column]) {
            $statement = $pdo->prepare(
                "DELETE FROM {$table} WHERE key_id = :k AND {$column} < to_timestamp(:c) AND NOT "
                . ($table === 'visits' ? 'open' : 'FALSE')
            );
            $statement->execute([':k' => $keyId, ':c' => $cutoff]);
            $removed += $statement->rowCount();

            // Still over the cap for the window alone - a single very busy month. Trim the
            // oldest rather than letting one key fill the volume.
            $count = (int) $this->one($pdo, "SELECT COUNT(*)::bigint AS n FROM {$table} WHERE key_id = :k",
                [':k' => $keyId])['n'];

            if ($count > $this->maxRows) {
                $statement = $pdo->prepare(
                    "DELETE FROM {$table} WHERE id IN (
                         SELECT id FROM {$table} WHERE key_id = :k ORDER BY {$column}, id LIMIT :n)"
                );
                $statement->bindValue(':k', $keyId, PDO::PARAM_INT);
                $statement->bindValue(':n', $count - $this->maxRows, PDO::PARAM_INT);
                $statement->execute();
                $removed += $statement->rowCount();
            }
        }

        return $removed;
    }

    /* -------------------------------- internals ----------------------------- */

    private function db(): PDO
    {
        return $this->pdo ??= Db::connect();
    }

    /**
     * This key's row id, creating it only when something is about to be written.
     *
     * Reads must not create: a read is unauthenticated by design, so letting one insert a
     * row would let anybody fill the table with hashes of keys that do not exist.
     */
    private function keyId(bool $create): ?int
    {
        if (is_int($this->keyId)) {
            return $this->keyId;
        }
        if ($this->keyId === false && !$create) {
            return null;
        }

        $pdo = $this->db();

        if ($create) {
            // ON CONFLICT ... DO UPDATE rather than DO NOTHING, because DO NOTHING returns
            // no row and would need a second SELECT on every single write.
            $row = $this->one(
                $pdo,
                'INSERT INTO api_keys (key_hash) VALUES (:h)
                 ON CONFLICT (key_hash) DO UPDATE SET seen_at = now()
                 RETURNING id',
                [':h' => $this->hash]
            );
        } else {
            $row = $this->one($pdo, 'SELECT id FROM api_keys WHERE key_hash = :h', [':h' => $this->hash]);
        }

        if (!isset($row['id'])) {
            $this->keyId = false;
            return null;
        }

        return $this->keyId = (int) $row['id'];
    }

    /**
     * Builds the WHERE shared by every read.
     *
     * A window overlaps a row when the row ends after `from` and starts before `to`, which
     * is not the same as either endpoint being inside it: a craft parked in one sector for
     * a week belongs in every window that week touches.
     *
     * @return array{0: string, 1: array<string, mixed>}
     */
    private function where(int $keyId, array $filter, string $start, string $end): array
    {
        $sql = 'key_id = :k';
        $args = [':k' => $keyId];

        if (isset($filter['ship']) && $filter['ship'] !== '') {
            $sql .= ' AND ship = :s';
            $args[':s'] = (string) $filter['ship'];
        }
        if (isset($filter['owner']) && $filter['owner'] !== '') {
            $sql .= ' AND owner = :o';
            $args[':o'] = (string) $filter['owner'];
        }
        if (!empty($filter['from'])) {
            $sql .= " AND {$end} >= to_timestamp(:f)";
            $args[':f'] = (int) $filter['from'];
        }
        if (!empty($filter['to'])) {
            $sql .= " AND {$start} <= to_timestamp(:t)";
            $args[':t'] = (int) $filter['to'];
        }

        return [$sql, $args];
    }

    private function all(PDO $pdo, string $sql, array $args): array
    {
        $statement = $pdo->prepare($sql);
        $statement->execute($args);

        return $statement->fetchAll();
    }

    private function one(PDO $pdo, string $sql, array $args): array
    {
        $statement = $pdo->prepare($sql);
        $statement->execute($args);
        $row = $statement->fetch();

        return is_array($row) ? $row : [];
    }

    /** Postgres hands booleans back as "t"/"f" over this driver, not as PHP bools. */
    private function truthy(mixed $value): bool
    {
        return $value === true || $value === 't' || $value === 1 || $value === '1';
    }

    /**
     * Pruning from the request path, throttled hard.
     *
     * The poller is what normally prunes, on its own timer and away from anyone waiting.
     * This is the fallback for a deployment that runs no poller, so it is deliberately
     * rare: a DELETE on the hot path of a relayed call is worth it once an hour and not
     * once a call.
     */
    private function maybePrune(): void
    {
        if (random_int(1, 2000) !== 1) {
            return;
        }

        try {
            $this->prune();
        } catch (Throwable) {
            // A failed prune is a table that stays large, which is not worth failing a
            // write over - the poller will get it on its next pass.
        }
    }
}
