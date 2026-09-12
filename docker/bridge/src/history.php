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
    private int $economyInterval;
    private ?PDO $pdo = null;

    /** Memoised api_keys.id: false means "looked and there was none". */
    private int|false|null $keyId = null;

    public function __construct(string $key)
    {
        $this->hash = hash('sha256', $key);
        $this->retentionDays = max(1, (int) (getenv('HISTORY_DAYS') ?: 30));
        $this->maxRows = max(1000, (int) (getenv('HISTORY_MAX_ROWS') ?: 500000));
        // The floor between two stored economy samples of the same station. See
        // recordStations for why this is not simply the poll interval.
        $this->economyInterval = max(30, (int) (getenv('HISTORY_ECONOMY_INTERVAL') ?: 300));
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

    /**
     * Fold one GET /stations answer into the station sample log.
     *
     * The mod reports each station's earnings as running totals since it was founded,
     * because that is all the game keeps: a TradingManager holds three counters -
     * moneyGainedFromGoods, moneySpentOnGoods, moneyGainedFromTax - and no history at
     * all. Nothing in that says what a place made yesterday. Two samples and the gap
     * between them do, which is the whole reason this table exists.
     *
     * ### Why it is rate-limited
     *
     * Unlike a visit, a sample cannot be extended in place - a time series is exactly the
     * repetition - so writing one per station per pass is 2,880 rows a day per station on
     * a 30s poller. It would also be 2,880 copies of the same numbers: the mod reads these
     * out of the craft's database row, and the game only rewrites that row when it saves
     * or unloads the sector. Sampling faster than the game writes buys nothing but rows.
     *
     * HISTORY_ECONOMY_INTERVAL (default 300s) is the floor. It is deliberately not the
     * poll interval: the poller keeps calling at its own rate, so a console that is open
     * still sees live numbers, and only the durable copy is thinned.
     */
    public function recordStations(object $body): void
    {
        $stations = $body->stations ?? null;
        if (!is_array($stations) || $stations === []) {
            return;
        }

        $pdo = $this->db();
        $keyId = $this->keyId(true);
        if ($keyId === null) {
            return;
        }

        // One query for every station's last sample rather than one per station: a fleet
        // of forty stations would otherwise be forty round trips before a single write.
        $last = [];
        $rows = $this->all(
            $pdo,
            'SELECT DISTINCT ON (ship) ship, EXTRACT(EPOCH FROM taken_at)::bigint AS t
             FROM station_samples WHERE key_id = :k ORDER BY ship, taken_at DESC',
            [':k' => $keyId]
        );
        foreach ($rows as $row) {
            $last[(string) $row['ship']] = (int) $row['t'];
        }

        $now = time();

        $insert = $pdo->prepare(
            'INSERT INTO station_samples
                 (key_id, ship, owner, x, y, taken_at, gained, spent, tax, stock, data)
             VALUES (:k, :s, :o, :x, :y, to_timestamp(:t), :g, :p, :a,
                     CAST(:st AS jsonb), CAST(:d AS jsonb))'
        );

        foreach ($stations as $station) {
            if (!is_object($station)) {
                continue;
            }

            $name = $station->name ?? null;
            $economy = $station->economy ?? null;

            if (!is_string($name) || $name === '' || !is_object($economy)) {
                continue;
            }

            if (isset($last[$name]) && $now - $last[$name] < $this->economyInterval) {
                continue;
            }

            $earnings = is_object($economy->earnings ?? null) ? $economy->earnings : new stdClass();
            $position = is_object($station->position ?? null) ? $station->position : null;

            $insert->execute([
                ':k' => $keyId,
                ':s' => $name,
                ':o' => is_object($station->owner ?? null) ? (string) ($station->owner->kind ?? '') : '',
                ':x' => $position !== null ? (int) ($position->x ?? 0) : 0,
                ':y' => $position !== null ? (int) ($position->y ?? 0) : 0,
                ':t' => $now,
                ':g' => (int) round((float) ($earnings->fromGoods ?? 0)),
                ':p' => (int) round((float) ($earnings->spentOnGoods ?? 0)),
                ':a' => (int) round((float) ($earnings->fromTax ?? 0)),
                ':st' => $this->encode($economy->stock ?? new stdClass()),
                ':d' => $this->encode($this->stationFacts($station, $economy)),
            ]);
        }

        $this->maybePrune();
    }

    /**
     * Fold one GET /economy answer into the faction sample log.
     *
     * Money is a level rather than a counter, so unlike the station totals this is not
     * differenced into a rate - a balance that fell is as meaningful as one that rose.
     * What the reads do with it is report where it started and where it ended.
     */
    public function recordFactions(object $body): void
    {
        $factions = $body->factions ?? null;
        if (!is_array($factions) || $factions === []) {
            return;
        }

        $pdo = $this->db();
        $keyId = $this->keyId(true);
        if ($keyId === null) {
            return;
        }

        $last = [];
        $rows = $this->all(
            $pdo,
            'SELECT DISTINCT ON (owner) owner, EXTRACT(EPOCH FROM taken_at)::bigint AS t
             FROM faction_samples WHERE key_id = :k ORDER BY owner, taken_at DESC',
            [':k' => $keyId]
        );
        foreach ($rows as $row) {
            $last[(string) $row['owner']] = (int) $row['t'];
        }

        $now = time();

        $insert = $pdo->prepare(
            'INSERT INTO faction_samples (key_id, owner, taken_at, money, resources, stations)
             VALUES (:k, :o, to_timestamp(:t), :m, CAST(:r AS jsonb), :n)'
        );

        foreach ($factions as $faction) {
            if (!is_object($faction)) {
                continue;
            }

            $owner = is_object($faction->owner ?? null) ? (string) ($faction->owner->kind ?? '') : '';
            if ($owner === '') {
                continue;
            }

            if (isset($last[$owner]) && $now - $last[$owner] < $this->economyInterval) {
                continue;
            }

            // Flattened to material -> amount here rather than stored as the array the
            // mod sends, so a read can pick one material out without unnesting a list.
            $resources = [];
            foreach ((array) ($faction->resources ?? []) as $entry) {
                if (is_object($entry) && is_string($entry->material ?? null)) {
                    $resources[$entry->material] = (float) ($entry->amount ?? 0);
                }
            }

            $insert->execute([
                ':k' => $keyId,
                ':o' => $owner,
                ':t' => $now,
                ':m' => (int) round((float) ($faction->money ?? 0)),
                ':r' => $this->encode($resources),
                ':n' => is_object($faction->stations ?? null) ? (int) ($faction->stations->count ?? 0) : 0,
            ]);
        }

        $this->maybePrune();
    }

    /**
     * The slow-moving description of a station, kept alongside each sample.
     *
     * Denormalised on purpose. A station can be rebuilt into a different factory, and a
     * sample that only held numbers would then be attributed to whatever it produces
     * today; holding the line with the reading keeps last month's rows honest about what
     * they were measuring.
     */
    private function stationFacts(object $station, object $economy): array
    {
        $production = is_object($economy->production ?? null) ? $economy->production : null;

        $facts = [
            'kind' => (string) ($economy->kind ?? ''),
            'title' => is_object($station->title ?? null) ? (string) ($station->title->text ?? '') : '',
        ];

        if (is_object($station->cargo ?? null)) {
            $facts['cargo'] = [
                'used' => (float) ($station->cargo->used ?? 0),
                'capacity' => (float) ($station->cargo->capacity ?? 0),
            ];
        }

        if ($production !== null) {
            $facts['production'] = [
                'factory' => (string) ($production->factory ?? ''),
                // The template above resolved against the good the line makes. `kind` is
                // "factory" for a Solar Power Plant and a Book Factory alike, so this is
                // the only field in a sample that names which one the row was measuring.
                'title' => (string) ($production->title ?? ''),
                'style' => (string) ($production->style ?? ''),
                'slots' => (int) ($production->slots ?? 0),
                'active' => (int) ($production->active ?? 0),
                'results' => array_values(array_map(
                    static fn ($r) => (string) ($r->name ?? ''),
                    array_filter((array) ($production->results ?? []), 'is_object')
                )),
            ];
        }

        return $facts;
    }

    private function encode(mixed $value): string
    {
        return json_encode($value, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE) ?: '{}';
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

    /*
     * ---------------------------- economy reads ----------------------------
     *
     * All three read the same table the same way, so the shape is worth stating once.
     *
     * A sample holds running totals, and what anyone wants is a rate, so every query
     * differences consecutive samples with LAG() and sums the differences. Two details
     * follow from that and are easy to get wrong:
     *
     *   The window is applied to the *later* sample of each pair, and the scan itself is
     *   not bounded below. A station sampled at 09:55 and 10:05 earned something between
     *   those two readings; asking about "since 10:00" and starting the scan there would
     *   silently drop it, because the first in-window sample would have nothing to be
     *   differenced against. Starting from the beginning of what is stored costs a wider
     *   index scan and is the only way the first minutes of a window are not a hole.
     *
     *   A drop in a counter is read as zero, not as negative earnings. The counters only
     *   ever rise while a station stands; one that falls means the row was reset - the
     *   station was destroyed and rebuilt, or founded again under the same name - and the
     *   honest reading of that is "this pair measures nothing" rather than a refund.
     */

    /** key_id, the optional craft and owner filters, and the window's upper bound. */
    private function economyScope(int $keyId, array $filter): array
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

        $sql .= ' AND taken_at <= to_timestamp(:t)';
        $args[':t'] = $this->windowEnd($filter);

        return [$sql, $args];
    }

    private function windowEnd(array $filter): int
    {
        $to = (int) ($filter['to'] ?? 0);

        return $to > 0 ? $to : time();
    }

    private function windowStart(array $filter): int
    {
        return (int) ($filter['from'] ?? 0);
    }

    /**
     * What each station earned over the window, and what the faction is holding.
     *
     * `observed` is the time actually covered by pairs of samples, and the rates are per
     * observed hour rather than per wall-clock hour. It is the same honesty the travel
     * heatmap applies to dwell: nothing here pushes, so a stretch with no samples is a
     * stretch when nobody was asking, and guessing across it would quietly invent income.
     * A single gap is capped, so one weekend with the stack down does not swallow the
     * denominator and report a thriving station as earning nothing an hour.
     */
    public function economySummary(array $filter): array
    {
        $from = $this->windowStart($filter);
        $to = $this->windowEnd($filter);

        $empty = ['window' => ['from' => $from ?: null, 'to' => $to, 'seconds' => $from ? $to - $from : null],
                  'stations' => [], 'totals' => $this->zeroTotals(), 'factions' => []];

        $keyId = $this->keyId(false);
        if ($keyId === null) {
            return $empty;
        }

        [$scope, $args] = $this->economyScope($keyId, $filter);
        $args[':f'] = $from;
        $args[':cap'] = $this->gapCap();

        $rows = $this->all(
            $this->db(),
            "WITH samples AS (
                 SELECT ship, owner, x, y, taken_at, gained, spent, tax, data
                 FROM station_samples WHERE {$scope}
             ),
             diffs AS (
                 SELECT ship, owner, x, y, taken_at, data,
                        GREATEST(gained - LAG(gained) OVER w, 0) AS d_gained,
                        GREATEST(spent  - LAG(spent)  OVER w, 0) AS d_spent,
                        GREATEST(tax    - LAG(tax)    OVER w, 0) AS d_tax,
                        EXTRACT(EPOCH FROM taken_at - LAG(taken_at) OVER w) AS gap
                 FROM samples
                 WINDOW w AS (PARTITION BY ship ORDER BY taken_at)
             )
             SELECT ship,
                    MAX(owner) AS owner,
                    MAX(x)::int AS x,
                    MAX(y)::int AS y,
                    COUNT(*)::bigint AS samples,
                    COALESCE(SUM(d_gained), 0)::bigint AS gained,
                    COALESCE(SUM(d_spent), 0)::bigint  AS spent,
                    COALESCE(SUM(d_tax), 0)::bigint    AS tax,
                    COALESCE(SUM(LEAST(gap, :cap)), 0)::bigint AS observed,
                    EXTRACT(EPOCH FROM MIN(taken_at))::bigint AS first_at,
                    EXTRACT(EPOCH FROM MAX(taken_at))::bigint AS last_at,
                    (array_agg(data ORDER BY taken_at DESC))[1] AS data
             FROM diffs
             WHERE taken_at >= to_timestamp(:f)
             GROUP BY ship
             ORDER BY gained DESC, ship",
            $args
        );

        $stations = [];
        $totals = $this->zeroTotals();

        foreach ($rows as $row) {
            $station = $this->stationRow($row);
            $stations[] = $station;

            foreach (['earned', 'spent', 'tax', 'net'] as $field) {
                $totals[$field] += $station[$field];
            }
            $totals['observed'] = max($totals['observed'], $station['observed']);
        }

        $totals['stations'] = count($stations);
        $totals['perHour'] = $this->perHour($totals, $totals['observed']);

        return [
            'window' => ['from' => $from ?: null, 'to' => $to,
                         'seconds' => $from ? $to - $from : null],
            'stations' => $stations,
            'totals' => $totals,
            'factions' => $this->factionRows($keyId, $filter),
        ];
    }

    /**
     * The same numbers bucketed by hour or by day, which is what a chart wants.
     *
     * Buckets are attributed to the later sample of each pair. An interval that straddles
     * a boundary therefore lands wholly in the bucket it ended in - a rounding error of at
     * most one sample interval, and the alternative is apportioning income across buckets
     * on an assumption of evenness that the data does not support.
     */
    public function economySeries(array $filter, string $bucket): array
    {
        $bucket = $bucket === 'day' ? 'day' : 'hour';
        $from = $this->windowStart($filter);
        $to = $this->windowEnd($filter);

        $keyId = $this->keyId(false);
        if ($keyId === null) {
            return ['bucket' => $bucket, 'points' => []];
        }

        [$scope, $args] = $this->economyScope($keyId, $filter);
        $args[':f'] = $from;

        $rows = $this->all(
            $this->db(),
            "WITH samples AS (
                 SELECT ship, taken_at, gained, spent, tax
                 FROM station_samples WHERE {$scope}
             ),
             diffs AS (
                 SELECT taken_at,
                        GREATEST(gained - LAG(gained) OVER w, 0) AS d_gained,
                        GREATEST(spent  - LAG(spent)  OVER w, 0) AS d_spent,
                        GREATEST(tax    - LAG(tax)    OVER w, 0) AS d_tax
                 FROM samples
                 WINDOW w AS (PARTITION BY ship ORDER BY taken_at)
             )
             SELECT EXTRACT(EPOCH FROM date_trunc('{$bucket}', taken_at))::bigint AS at,
                    COALESCE(SUM(d_gained), 0)::bigint AS gained,
                    COALESCE(SUM(d_spent), 0)::bigint  AS spent,
                    COALESCE(SUM(d_tax), 0)::bigint    AS tax
             FROM diffs
             WHERE taken_at >= to_timestamp(:f)
             GROUP BY 1 ORDER BY 1",
            $args
        );

        $points = [];
        foreach ($rows as $row) {
            $gained = (int) $row['gained'];
            $spent = (int) $row['spent'];
            $tax = (int) $row['tax'];

            $points[] = ['at' => (int) $row['at'], 'earned' => $gained, 'spent' => $spent,
                         'tax' => $tax, 'net' => $gained + $tax - $spent];
        }

        return ['bucket' => $bucket, 'window' => ['from' => $from ?: null, 'to' => $to],
                'ship' => (string) ($filter['ship'] ?? ''), 'points' => $points];
    }

    /**
     * Units in and out per good, which is the closest thing to "what did it sell".
     *
     * The station's own books cannot answer that question: a TradingManager keeps one
     * money counter for the whole station and never attributes it to a good. What it does
     * keep, good by good, is how many units are in the bay, and differencing that says
     * which way each good moved.
     *
     * So `in` is units that appeared - produced by the line, bought from a passing trader,
     * or delivered by a supply ship - and `out` is units that left, whether sold, consumed
     * as an ingredient, or shuttled to another of your stations. The split between those
     * causes is not recoverable from here and is not guessed at: the fields are named for
     * what they actually measure.
     */
    public function economyGoods(array $filter): array
    {
        $from = $this->windowStart($filter);
        $to = $this->windowEnd($filter);

        $keyId = $this->keyId(false);
        if ($keyId === null) {
            return ['goods' => [], 'window' => ['from' => $from ?: null, 'to' => $to]];
        }

        [$scope, $args] = $this->economyScope($keyId, $filter);
        $args[':f'] = $from;

        $rows = $this->all(
            $this->db(),
            "WITH points AS (
                 SELECT s.ship, g.key AS good, s.taken_at, (g.value)::numeric AS units
                 FROM station_samples s, LATERAL jsonb_each_text(s.stock) g
                 WHERE {$scope}
             ),
             diffs AS (
                 SELECT ship, good, taken_at, units,
                        units - LAG(units) OVER (PARTITION BY ship, good ORDER BY taken_at) AS d
                 FROM points
             )
             SELECT ship, good,
                    COALESCE(SUM(GREATEST(d, 0)), 0)::bigint  AS units_in,
                    COALESCE(SUM(GREATEST(-d, 0)), 0)::bigint AS units_out,
                    (array_agg(units ORDER BY taken_at DESC))[1]::bigint AS stock
             FROM diffs
             WHERE taken_at >= to_timestamp(:f)
             GROUP BY ship, good
             ORDER BY units_out DESC, ship, good",
            $args
        );

        $goods = [];
        foreach ($rows as $row) {
            $in = (int) $row['units_in'];
            $out = (int) $row['units_out'];

            $goods[] = [
                'ship' => (string) $row['ship'],
                'good' => (string) $row['good'],
                'in' => $in,
                'out' => $out,
                'net' => $in - $out,
                'stock' => (int) $row['stock'],
            ];
        }

        return ['goods' => $goods, 'window' => ['from' => $from ?: null, 'to' => $to]];
    }

    /** One row of economySummary's station list. */
    private function stationRow(array $row): array
    {
        $gained = (int) $row['gained'];
        $spent = (int) $row['spent'];
        $tax = (int) $row['tax'];
        $observed = (int) $row['observed'];

        $facts = json_decode((string) ($row['data'] ?? '{}'), true);
        if (!is_array($facts)) {
            $facts = [];
        }

        $station = [
            'ship' => (string) $row['ship'],
            'owner' => (string) $row['owner'],
            'x' => (int) $row['x'],
            'y' => (int) $row['y'],
            'kind' => (string) ($facts['kind'] ?? ''),
            'produces' => $facts['production']['results'] ?? [],
            'factory' => $facts['production']['factory'] ?? '',
            'factoryTitle' => $facts['production']['title'] ?? '',
            'samples' => (int) $row['samples'],
            'first' => (int) $row['first_at'],
            'last' => (int) $row['last_at'],
            'observed' => $observed,
            'earned' => $gained,
            'spent' => $spent,
            'tax' => $tax,
            'net' => $gained + $tax - $spent,
        ];

        $station['perHour'] = $this->perHour($station, $observed);

        return $station;
    }

    /**
     * The faction ledger over the window: where money started, where it ended, and what
     * it is holding now. Not differenced - see recordFactions.
     */
    private function factionRows(int $keyId, array $filter): array
    {
        $args = [':k' => $keyId, ':t' => $this->windowEnd($filter), ':f' => $this->windowStart($filter)];

        $rows = $this->all(
            $this->db(),
            'SELECT owner,
                    COUNT(*)::bigint AS samples,
                    (array_agg(money ORDER BY taken_at))[1]::bigint      AS first_money,
                    (array_agg(money ORDER BY taken_at DESC))[1]::bigint AS last_money,
                    (array_agg(resources ORDER BY taken_at DESC))[1]     AS resources,
                    (array_agg(stations ORDER BY taken_at DESC))[1]::int AS stations,
                    EXTRACT(EPOCH FROM MIN(taken_at))::bigint AS first_at,
                    EXTRACT(EPOCH FROM MAX(taken_at))::bigint AS last_at
             FROM faction_samples
             WHERE key_id = :k AND taken_at <= to_timestamp(:t) AND taken_at >= to_timestamp(:f)
             GROUP BY owner ORDER BY owner',
            $args
        );

        $factions = [];

        foreach ($rows as $row) {
            $resources = json_decode((string) ($row['resources'] ?? '{}'), true);

            $factions[] = [
                'owner' => (string) $row['owner'],
                'samples' => (int) $row['samples'],
                'first' => (int) $row['first_at'],
                'last' => (int) $row['last_at'],
                'money' => [
                    'first' => (int) $row['first_money'],
                    'last' => (int) $row['last_money'],
                    'change' => (int) $row['last_money'] - (int) $row['first_money'],
                ],
                'resources' => is_array($resources) ? $resources : [],
                'stations' => (int) $row['stations'],
            ];
        }

        return $factions;
    }

    private function zeroTotals(): array
    {
        return ['earned' => 0, 'spent' => 0, 'tax' => 0, 'net' => 0,
                'observed' => 0, 'stations' => 0];
    }

    /**
     * @param array{earned: int, spent: int, tax: int, net: int} $amounts
     */
    private function perHour(array $amounts, int $observed): array
    {
        if ($observed <= 0) {
            return ['earned' => 0.0, 'spent' => 0.0, 'net' => 0.0];
        }

        $rate = static fn (int $value): float => round($value * 3600 / $observed, 2);

        return ['earned' => $rate($amounts['earned']), 'spent' => $rate($amounts['spent']),
                'net' => $rate($amounts['net'])];
    }

    /**
     * The longest gap between two samples that still counts as observed time.
     *
     * Without it, one sample before a week of downtime and one after would report a week
     * of observation and an income of nearly zero per hour. Four sampling intervals is
     * generous enough to ride out a restart and short enough that a real outage is
     * excluded rather than averaged into the answer.
     */
    private function gapCap(): int
    {
        return $this->economyInterval * 4;
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
                                 'samples' => 0, 'sectors' => 0,
                                 'first' => null, 'last' => null];
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

        $rows = $this->all(
            $this->db(),
            'SELECT ship, COUNT(*)::bigint AS n,
                    EXTRACT(EPOCH FROM MIN(taken_at))::bigint AS f,
                    EXTRACT(EPOCH FROM MAX(taken_at))::bigint AS l
             FROM station_samples WHERE key_id = :k GROUP BY ship',
            [':k' => $keyId]
        );
        foreach ($rows as $row) {
            $note((string) $row['ship'], 'samples', (int) $row['n'], (int) $row['f'], (int) $row['l']);
        }

        ksort($ships);

        $total = 0;
        foreach ($ships as $ship) {
            $total += $ship['visits'] + $ship['events'] + $ship['samples'];
        }

        // Whether there is an economy series at all, which is what tells a client to
        // offer the view rather than draw an empty chart. A deployment that upgraded
        // mid-month has travel history and no station samples, and should say so.
        $economy = $this->one(
            $this->db(),
            'SELECT COUNT(*)::bigint AS n, COUNT(DISTINCT ship)::bigint AS stations,
                    EXTRACT(EPOCH FROM MIN(taken_at))::bigint AS f
             FROM station_samples WHERE key_id = :k',
            [':k' => $keyId]
        );

        return [
            'ships' => array_values($ships),
            'rows' => $total,
            'retentionDays' => $this->retentionDays,
            'recording' => true,
            'economy' => [
                'samples' => (int) ($economy['n'] ?? 0),
                'stations' => (int) ($economy['stations'] ?? 0),
                'since' => isset($economy['f']) ? (int) $economy['f'] : null,
                'interval' => $this->economyInterval,
            ],
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
            $removed = 0;
            foreach (['visits', 'events', 'station_samples', 'faction_samples'] as $table) {
                $removed += (int) $this->one(
                    $pdo,
                    "SELECT COUNT(*)::bigint AS n FROM {$table} WHERE key_id = :k",
                    [':k' => $keyId]
                )['n'];
            }

            $pdo->prepare('DELETE FROM api_keys WHERE id = :k')->execute([':k' => $keyId]);
            $this->keyId = false;

            return ['cleared' => true, 'ship' => null, 'removed' => $removed];
        }

        foreach (['visits', 'events', 'station_samples', 'ship_state'] as $table) {
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

        foreach ([['visits', 'left_at'], ['events', 'happened_at'],
                  ['station_samples', 'taken_at'], ['faction_samples', 'taken_at']] as [$table, $column]) {
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
