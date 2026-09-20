<?php

declare(strict_types=1);

require_once __DIR__ . '/db.php';

/**
 * Durable history, as seen through one API key.
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
 * The tables are defined in db.php:
 *
 *   visits    - one row per sector a craft was seen to occupy. Positions come from
 *               GET /ships, which reads the ship database, so this keeps recording with
 *               every player logged out. It is what the heatmap and the travel track are
 *               built from.
 *   events    - the mod's own order and status events, kept past the ring buffer's 200 and
 *               past a server restart.
 *   station_samples, faction_samples - the economy series; see recordStations.
 *   manifests - the last hold and crew list seen per craft; see recordManifest.
 *
 * ### Who a row belongs to
 *
 * A row belongs to the faction that owns the craft - the player, or their alliance - as the
 * mod itself reported it in the answer being recorded. Not to the key that happened to
 * relay it. So an alliance fleet has one history however many members are polling it, and
 * a player with two keys has one history rather than two.
 *
 * Reading is the other half, and is where privacy is decided. A key reads:
 *
 *   - its player's rows, always;
 *   - its alliance's rows, only while the mod has confirmed the membership within
 *     HISTORY_VERIFY_TTL seconds. A stale confirmation is refreshed by relaying a /ping
 *     through the transport, and one that cannot be refreshed - the game server is down -
 *     reads no alliance rows at all. Someone who left the alliance keeps their key, so
 *     "they were a member last week" is not good enough;
 *   - rows recorded before rows had owners, which still belong to the key that recorded
 *     them until History::adopt hands them over. See db.php, version 3.
 *
 * A key the mod refuses reads nothing.
 *
 * ### On the key itself
 *
 * A key is identified by a SHA-256 of itself and the key is never stored: this process
 * deliberately owns no credential, and keeping one would change that. A key is 256 bits of
 * randomness, so the hash cannot be guessed.
 *
 * Writes are only ever made after the mod has answered a call successfully, which is the
 * actual authentication, and a row's owner comes out of that answer rather than out of
 * anything the caller said.
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
    private int $verifyTtl;
    private ?PDO $pdo = null;

    /**
     * Relays a /ping for this key through the transport, for when the mod's last word on
     * who the key belongs to is too old to act on. Null where there is no transport to ask,
     * which is the poller and the tests.
     *
     * @var (Closure(): array{status: int, body: mixed})|null
     */
    private ?Closure $verify;

    /** Memoised api_keys row: false means "looked and there was none". */
    private array|false|null $keyRow = null;

    /** Memoised scope(); cleared whenever the key row changes. */
    private ?array $scope = null;

    public function __construct(string $key, ?callable $verify = null)
    {
        $this->hash = hash('sha256', $key);
        $this->retentionDays = max(1, (int) (getenv('HISTORY_DAYS') ?: 30));
        $this->maxRows = max(1000, (int) (getenv('HISTORY_MAX_ROWS') ?: 500000));
        // The floor between two stored economy samples of the same station. See
        // recordStations for why this is not simply the poll interval.
        $this->economyInterval = max(30, (int) (getenv('HISTORY_ECONOMY_INTERVAL') ?: 300));
        $this->verifyTtl = max(30, (int) (getenv('HISTORY_VERIFY_TTL') ?: 300));
        $this->verify = $verify !== null ? Closure::fromCallable($verify) : null;
    }

    public function exists(): bool
    {
        return $this->keyRow() !== null;
    }

    /* ------------------------------- identity ------------------------------- */

    /**
     * Fold one GET /ping answer: who this key belongs to, and which alliance that player is
     * in right now.
     *
     * The only place membership is learned. Rows can name an alliance too, but a row says
     * who owns a craft, not whether the caller is still allowed to look at it; /ping is the
     * mod answering that question about this key, now.
     */
    public function recordPing(object $body): void
    {
        $player = $body->player ?? null;
        if (!is_object($player) || !is_numeric($player->index ?? null)) {
            return;
        }

        $index = (int) $player->index;

        // A mod older than the field says nothing either way, which is not the same as
        // "in no alliance": the identity is still worth keeping, but nothing that depends
        // on membership - reading alliance rows, adopting old ones - may act on it.
        $knowsAlliance = property_exists($player, 'alliance');
        $alliance = null;
        if (is_object($player->alliance ?? null) && is_numeric($player->alliance->index ?? null)) {
            $alliance = (int) $player->alliance->index;
        }

        $pdo = $this->db();

        $row = $this->one(
            $pdo,
            'INSERT INTO api_keys (key_hash, player, alliance, verified_at)
             VALUES (:h, :p, :a, now())
             ON CONFLICT (key_hash) DO UPDATE
                 SET player = EXCLUDED.player, alliance = EXCLUDED.alliance,
                     verified_at = EXCLUDED.verified_at, seen_at = now()
             RETURNING id, legacy',
            [':h' => $this->hash, ':p' => $index, ':a' => $knowsAlliance ? $alliance : null]
        );

        $names = [$index => ['player', (string) ($player->name ?? '')]];
        if ($alliance !== null) {
            $names[$alliance] = ['alliance', (string) ($player->alliance->name ?? '')];
        }
        $this->noteFactions($names);

        $this->keyRow = null;
        $this->scope = null;

        if ($knowsAlliance && $this->truthy($row['legacy'] ?? false)) {
            $this->adopt((int) $row['id'], $index, $alliance);
        }
    }

    /**
     * What this key may read: its player, its alliance if the membership is current, and
     * its own not-yet-adopted rows.
     *
     * @return array{key: ?int, player: ?int, alliance: ?int, verified: bool}
     */
    public function scope(): array
    {
        if ($this->scope !== null) {
            return $this->scope;
        }

        $none = ['key' => null, 'player' => null, 'alliance' => null, 'verified' => false];

        $row = $this->keyRow();
        $fresh = $row !== null && $row['player'] !== null && $row['verified'] !== null
            && time() - $row['verified'] < $this->verifyTtl;

        if (!$fresh && $this->verify !== null) {
            $answer = ($this->verify)();
            $status = (int) ($answer['status'] ?? 0);

            if ($status >= 200 && $status < 300 && is_object($answer['body'] ?? null)) {
                $this->recordPing($answer['body']);
                $row = $this->keyRow();
                $fresh = $row !== null && $row['player'] !== null;
            } elseif ($status === 401 || $status === 403) {
                // Revoked, or never a key at all. Whatever it recorded while it worked
                // stays with its player and is read through that player's other keys.
                return $this->scope = $none;
            }
            // Anything else is a mod that could not be asked. The player's own rows are
            // still theirs; only the alliance's, which depend on a membership nobody can
            // confirm right now, are withheld.
        }

        if ($row === null) {
            return $this->scope = $none;
        }

        return $this->scope = [
            'key' => $row['id'],
            'player' => $row['player'],
            'alliance' => $fresh ? $row['alliance'] : null,
            'verified' => $fresh,
        ];
    }

    /**
     * Moves one key's pre-version-3 rows onto the factions that own them.
     *
     * Player rows go to the player. Alliance rows go to the alliance the player is in now,
     * which is the best anyone can do - the old rows never said which alliance - and is
     * right for everyone who did not change alliances between recording and upgrading. A
     * player in no alliance keeps their old alliance rows private to the key, rather than
     * carrying them into whichever alliance they join next.
     *
     * Two members recorded the same alliance craft independently, so the second adoption
     * merges rather than appends: a visit overlapping one already adopted widens it, an
     * event already adopted is dropped, and restart epochs are moved out of the range the
     * live writer uses so two members' numbering cannot collide.
     */
    private function adopt(int $keyId, int $player, ?int $alliance): void
    {
        $pdo = $this->db();
        $pdo->beginTransaction();

        try {
            $row = $this->one($pdo, 'SELECT legacy FROM api_keys WHERE id = :k FOR UPDATE', [':k' => $keyId]);
            if (!$this->truthy($row['legacy'] ?? false)) {
                // Another request adopted these while this one waited for the row.
                $pdo->commit();
                return;
            }

            // Serialises adoptions into one faction, so two members upgrading at the same
            // moment merge into each other instead of both finding nothing to merge with.
            $targets = array_filter([$player, $alliance], 'is_int');
            sort($targets);
            foreach ($targets as $faction) {
                $pdo->prepare('SELECT pg_advisory_xact_lock(:f)')->execute([':f' => $faction]);
            }

            $this->adoptInto($pdo, $keyId, $player, "<> 'alliance'");
            if ($alliance !== null) {
                $this->adoptInto($pdo, $keyId, $alliance, "= 'alliance'");
            }

            $pdo->prepare('DELETE FROM ship_state WHERE key_id = :k')->execute([':k' => $keyId]);
            $pdo->prepare('UPDATE api_keys SET legacy = FALSE WHERE id = :k')->execute([':k' => $keyId]);

            $pdo->commit();
        } catch (Throwable $e) {
            $pdo->rollBack();
            // Left flagged, so the next /ping tries again. Until then the rows are still
            // readable through the key that recorded them.
            error_log('AutomationAPI bridge: adopting history failed: ' . $e->getMessage());
        }
    }

    /** One owner kind of one key's rows, onto one faction. `$kind` is SQL, never input. */
    private function adoptInto(PDO $pdo, int $keyId, int $faction, string $kind): void
    {
        $args = [':k' => $keyId, ':f' => $faction];

        // The restart marks first: what they protect is the events below, found by the
        // same "not adopted yet" test that the events update is about to make false. Two
        // members' marks merge to the furthest either had seen, which is right while both
        // were polling the same run of the server - the usual case - and at worst records
        // a few events twice after a restart one of them missed.
        $pdo->prepare(
            "INSERT INTO event_marks (faction, ship, epoch, max_seq)
             SELECT :f, s.ship, s.epoch, s.max_seq FROM ship_state s
             WHERE s.key_id = :k AND EXISTS (
                 SELECT 1 FROM events e
                 WHERE e.key_id = s.key_id AND e.faction IS NULL AND e.ship = s.ship
                   AND e.owner {$kind})
             ON CONFLICT (faction, ship)
                 DO UPDATE SET max_seq = GREATEST(event_marks.max_seq, EXCLUDED.max_seq)"
        )->execute($args);

        // Already recorded by someone else - another member, or this player's other key.
        // Sequence numbers repeat across restarts, so the event itself has to match too,
        // and within an hour: each recorder dated the batch by its own arrival time.
        $pdo->prepare(
            "DELETE FROM events l USING events o
             WHERE l.key_id = :k AND l.faction IS NULL AND l.owner {$kind}
               AND o.faction = :f AND o.ship = l.ship AND o.seq = l.seq AND o.data = l.data
               AND o.happened_at BETWEEN l.happened_at - interval '1 hour'
                                     AND l.happened_at + interval '1 hour'"
        )->execute($args);

        $pdo->prepare(
            "UPDATE events SET faction = :f, key_id = NULL, epoch = -1 - epoch
             WHERE key_id = :k AND faction IS NULL AND owner {$kind}"
        )->execute($args);

        // The same stay seen by two recorders is one stay: widen the adopted visit to
        // cover both and drop the copy.
        $pdo->prepare(
            "WITH pairs AS (
                 SELECT l.id AS lid, o.id AS oid, l.entered_at, l.left_at
                 FROM visits l
                 JOIN visits o ON o.faction = :f AND o.ship = l.ship AND o.x = l.x AND o.y = l.y
                              AND o.entered_at <= l.left_at AND o.left_at >= l.entered_at
                 WHERE l.key_id = :k AND l.faction IS NULL AND l.owner {$kind}
             ),
             widened AS (
                 UPDATE visits o
                 SET entered_at = LEAST(o.entered_at, g.e), left_at = GREATEST(o.left_at, g.l)
                 FROM (SELECT oid, MIN(entered_at) AS e, MAX(left_at) AS l FROM pairs GROUP BY oid) g
                 WHERE o.id = g.oid
             )
             DELETE FROM visits WHERE id IN (SELECT lid FROM pairs)"
        )->execute($args);

        // At most one open visit per craft per faction, and the live writer may already
        // have opened one since the upgrade. Its row is the current one.
        $pdo->prepare(
            "UPDATE visits l SET open = FALSE
             WHERE l.key_id = :k AND l.faction IS NULL AND l.open AND l.owner {$kind}
               AND EXISTS (SELECT 1 FROM visits o WHERE o.faction = :f AND o.ship = l.ship AND o.open)"
        )->execute($args);

        foreach (['visits', 'station_samples', 'faction_samples'] as $table) {
            $pdo->prepare(
                "UPDATE {$table} SET faction = :f, key_id = NULL
                 WHERE key_id = :k AND faction IS NULL AND owner {$kind}"
            )->execute($args);
        }
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
        $names = [];

        foreach ($ships as $ship) {
            $name = is_object($ship) ? ($ship->name ?? null) : null;
            $position = is_object($ship) ? ($ship->position ?? null) : null;

            if (!is_string($name) || $name === '' || !is_object($position)) {
                continue;
            }
            if (!isset($position->x, $position->y)) {
                continue;
            }

            $faction = $this->factionOf($ship->owner ?? null, $names);
            if ($faction === null) {
                continue;
            }

            $seen[$faction . "\0" . $name] = [
                'f' => $faction,
                's' => $name,
                'x' => (int) $position->x,
                'y' => (int) $position->y,
                'o' => $this->kindOf($ship->owner ?? null),
            ];
        }

        if ($seen === []) {
            return;
        }

        $pdo = $this->db();
        $this->noteFactions($names);

        $pdo->beginTransaction();

        try {
            /*
             * FOR UPDATE rather than a lock file. Two pollers, or a poller and an open
             * console, routinely fold the same answer at the same moment - and with alliance
             * craft shared, two members' pollers do too. Without this both see no open visit
             * and both insert one, and the partial unique index turns that into an error
             * instead of a duplicate. Taking the rows first serialises them into "second one
             * sees the first one's work"; ordered, so two writers whose answers overlap
             * lock the shared rows in the same order and cannot deadlock.
             */
            $open = [];
            $rows = $this->all(
                $pdo,
                'SELECT faction, ship, x, y FROM visits
                 WHERE faction = ANY(CAST(:fs AS bigint[])) AND open
                 ORDER BY faction, ship FOR UPDATE',
                [':fs' => $this->pgArray(array_column($seen, 'f'))]
            );
            foreach ($rows as $row) {
                $open[$row['faction'] . "\0" . $row['ship']] = ['x' => (int) $row['x'], 'y' => (int) $row['y']];
            }

            $extend = $pdo->prepare(
                'UPDATE visits SET left_at = now() WHERE faction = :f AND ship = :s AND open'
            );
            $close = $pdo->prepare(
                'UPDATE visits SET open = FALSE WHERE faction = :f AND ship = :s AND open'
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
                'INSERT INTO visits (faction, ship, owner, x, y, entered_at, left_at, open)
                 VALUES (:f, :s, :o, :x, :y, now(), now(), TRUE)
                 ON CONFLICT (faction, ship) WHERE open DO NOTHING'
            );

            ksort($seen);
            foreach ($seen as $id => $at) {
                $was = $open[$id] ?? null;
                $craft = [':f' => $at['f'], ':s' => $at['s']];

                if ($was !== null && $was['x'] === $at['x'] && $was['y'] === $at['y']) {
                    // Same sector: the visit simply got longer.
                    $extend->execute($craft);
                    continue;
                }

                if ($was !== null) {
                    $close->execute($craft);
                }

                $insert->execute($craft + [':o' => $at['o'], ':x' => $at['x'], ':y' => $at['y']]);
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
     * With the epoch in the unique index, recording is idempotent: the poller, an open
     * console and every other member of the alliance can collect the same batch and only
     * the first insert does anything.
     */
    public function recordEvents(string $ship, object $body): void
    {
        $events = $body->events ?? null;
        if (!is_array($events) || $events === []) {
            return;
        }

        $names = [];
        $faction = $this->factionOf($body->owner ?? null, $names);
        if ($faction === null) {
            return;
        }
        $owner = $this->kindOf($body->owner ?? null);

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
        $this->noteFactions($names);

        $pdo->beginTransaction();

        try {
            $craft = [':f' => $faction, ':s' => $ship];

            $pdo->prepare(
                'INSERT INTO event_marks (faction, ship) VALUES (:f, :s)
                 ON CONFLICT (faction, ship) DO NOTHING'
            )->execute($craft);

            $state = $this->one(
                $pdo,
                'SELECT epoch, max_seq FROM event_marks WHERE faction = :f AND ship = :s FOR UPDATE',
                $craft
            );

            $epoch = (int) ($state['epoch'] ?? 0);
            $mark = (int) ($state['max_seq'] ?? -1);

            if ($highest < $mark) {
                $epoch++;
                $mark = -1;
            }

            $insert = $pdo->prepare(
                'INSERT INTO events (faction, ship, owner, epoch, seq, happened_at, data)
                 VALUES (:f, :s, :o, :e, :q, to_timestamp(:t), CAST(:d AS jsonb))
                 ON CONFLICT (faction, ship, epoch, seq) WHERE epoch >= 0 DO NOTHING'
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

                $insert->execute($craft + [
                    ':o' => $owner,
                    ':e' => $epoch,
                    ':q' => $seq,
                    ':t' => $happenedAt($event),
                    ':d' => $this->encode($data),
                ]);
            }

            $pdo->prepare(
                'UPDATE event_marks SET epoch = :e, max_seq = GREATEST(max_seq, :q)
                 WHERE faction = :f AND ship = :s'
            )->execute($craft + [':e' => $epoch, ':q' => max($mark, $highest)]);

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
     * HISTORY_ECONOMY_INTERVAL (default 300s) is the floor, per station rather than per
     * key, so an alliance station polled by every member is still sampled once. It is
     * deliberately not the poll interval: the poller keeps calling at its own rate, so a
     * console that is open still sees live numbers, and only the durable copy is thinned.
     */
    public function recordStations(object $body): void
    {
        $stations = $body->stations ?? null;
        if (!is_array($stations) || $stations === []) {
            return;
        }

        $names = [];
        $wanted = [];

        foreach ($stations as $station) {
            if (!is_object($station)) {
                continue;
            }

            $name = $station->name ?? null;
            if (!is_string($name) || $name === '' || !is_object($station->economy ?? null)) {
                continue;
            }

            $faction = $this->factionOf($station->owner ?? null, $names);
            if ($faction !== null) {
                $wanted[] = [$faction, $name, $station];
            }
        }

        if ($wanted === []) {
            return;
        }

        $pdo = $this->db();
        $this->noteFactions($names);

        // One query for every station's last sample rather than one per station: a fleet
        // of forty stations would otherwise be forty round trips before a single write.
        $last = [];
        $rows = $this->all(
            $pdo,
            'SELECT DISTINCT ON (faction, ship) faction, ship, EXTRACT(EPOCH FROM taken_at)::bigint AS t
             FROM station_samples WHERE faction = ANY(CAST(:fs AS bigint[]))
             ORDER BY faction, ship, taken_at DESC',
            [':fs' => $this->pgArray(array_column($wanted, 0))]
        );
        foreach ($rows as $row) {
            $last[$row['faction'] . "\0" . $row['ship']] = (int) $row['t'];
        }

        $now = time();

        $insert = $pdo->prepare(
            'INSERT INTO station_samples
                 (faction, ship, owner, x, y, taken_at, gained, spent, tax, stock, data)
             VALUES (:f, :s, :o, :x, :y, to_timestamp(:t), :g, :p, :a,
                     CAST(:st AS jsonb), CAST(:d AS jsonb))'
        );

        foreach ($wanted as [$faction, $name, $station]) {
            $id = $faction . "\0" . $name;
            if (isset($last[$id]) && $now - $last[$id] < $this->economyInterval) {
                continue;
            }

            $economy = $station->economy;
            $earnings = is_object($economy->earnings ?? null) ? $economy->earnings : new stdClass();
            $position = is_object($station->position ?? null) ? $station->position : null;

            $insert->execute([
                ':f' => $faction,
                ':s' => $name,
                ':o' => $this->kindOf($station->owner ?? null),
                ':x' => $position !== null ? (int) ($position->x ?? 0) : 0,
                ':y' => $position !== null ? (int) ($position->y ?? 0) : 0,
                ':t' => $now,
                ':g' => (int) round((float) ($earnings->fromGoods ?? 0)),
                ':p' => (int) round((float) ($earnings->spentOnGoods ?? 0)),
                ':a' => (int) round((float) ($earnings->fromTax ?? 0)),
                ':st' => $this->encode($economy->stock ?? new stdClass()),
                ':d' => $this->encode($this->stationFacts($station, $economy)),
            ]);

            // Two stations of one faction in the same answer never share a name, but the
            // same answer relayed twice at once would otherwise sample both.
            $last[$id] = $now;
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

        $names = [];
        $wanted = [];

        foreach ($factions as $entry) {
            if (!is_object($entry) || $this->kindOf($entry->owner ?? null) === '') {
                continue;
            }

            $faction = $this->factionOf($entry->owner, $names);
            if ($faction !== null) {
                $wanted[$faction] = $entry;
            }
        }

        if ($wanted === []) {
            return;
        }

        $pdo = $this->db();
        $this->noteFactions($names);

        $last = [];
        $rows = $this->all(
            $pdo,
            'SELECT faction, EXTRACT(EPOCH FROM MAX(taken_at))::bigint AS t
             FROM faction_samples WHERE faction = ANY(CAST(:fs AS bigint[])) GROUP BY faction',
            [':fs' => $this->pgArray(array_keys($wanted))]
        );
        foreach ($rows as $row) {
            $last[(int) $row['faction']] = (int) $row['t'];
        }

        $now = time();

        $insert = $pdo->prepare(
            'INSERT INTO faction_samples (faction, owner, taken_at, money, resources, stations)
             VALUES (:f, :o, to_timestamp(:t), :m, CAST(:r AS jsonb), :n)'
        );

        foreach ($wanted as $faction => $entry) {
            if (isset($last[$faction]) && $now - $last[$faction] < $this->economyInterval) {
                continue;
            }

            // Flattened to material -> amount here rather than stored as the array the
            // mod sends, so a read can pick one material out without unnesting a list.
            $resources = [];
            foreach ((array) ($entry->resources ?? []) as $resource) {
                if (is_object($resource) && is_string($resource->material ?? null)) {
                    $resources[$resource->material] = (float) ($resource->amount ?? 0);
                }
            }

            $insert->execute([
                ':f' => $faction,
                ':o' => $this->kindOf($entry->owner),
                ':t' => $now,
                ':m' => (int) round((float) ($entry->money ?? 0)),
                ':r' => $this->encode($resources),
                ':n' => is_object($entry->stations ?? null) ? (int) ($entry->stations->count ?? 0) : 0,
            ]);
        }

        $this->maybePrune();
    }

    /**
     * Fold one GET /ships/{name} answer into the manifest table: what is in the hold and
     * who is aboard, replacing whatever was there.
     *
     * The fleet listing carries neither, so a goods or passenger search otherwise has to
     * read every craft's detail through the transport - a round trip per craft, repeated by
     * every console that opens and by every member of an alliance separately. With this a
     * search starts from what anyone last saw, and only re-reads the holds that are stale.
     */
    public function recordManifest(string $ship, object $body): void
    {
        $names = [];
        $faction = $this->factionOf($body->owner ?? null, $names);
        if ($faction === null) {
            return;
        }

        $data = [];
        foreach (['cargo', 'captain', 'passengers'] as $field) {
            if (isset($body->{$field})) {
                $data[$field] = $body->{$field};
            }
        }

        $this->noteFactions($names);

        $this->db()->prepare(
            'INSERT INTO manifests (faction, ship, owner, taken_at, data)
             VALUES (:f, :s, :o, now(), CAST(:d AS jsonb))
             ON CONFLICT (faction, ship) DO UPDATE
                 SET owner = EXCLUDED.owner, taken_at = EXCLUDED.taken_at, data = EXCLUDED.data'
        )->execute([
            ':f' => $faction,
            ':s' => $ship,
            ':o' => $this->kindOf($body->owner ?? null),
            ':d' => $this->encode((object) $data),
        ]);
    }

    /**
     * Fold one page of the mod's station feed into station_events.
     *
     * Both feeds land here: GET /economy/events, which carries an owner on every event, and
     * GET /stations/{name}/events, which carries one for the whole page. Each event belongs
     * to the faction that owns the station, as the mod reported it - the same rule every
     * other table follows - so an alliance's stations have one trade log however many
     * members collect it.
     *
     * The mod numbers the feed once per server run, across every faction, so (boot, seq)
     * names one event whoever collects it. Recording is idempotent on it: the poller, an
     * open console and every other member of the alliance can store the same page and only
     * the first insert does anything.
     *
     * Dating is exact rather than anchored to the newest event the way recordEvents has to
     * do it: the feed carries the server's runtime clock at the moment it answered (`now`)
     * next to each event's own (`at`), so an event happened `now - at` seconds before this
     * process received the page.
     *
     * `$advance` is for the collector: the page came from ?owner=all&since=$since, so it
     * is a complete, in-order continuation and the cursor may move to the end of it. It
     * only moves when the page belongs to the run of the server the cursor was for, or
     * starts from zero - a restarted server numbers from zero again, and a cursor carried
     * over from the previous run would skip everything up to the old number.
     */
    public function recordStationEvents(object $body, bool $advance = false, int $since = 0): void
    {
        $events = $body->events ?? null;
        $boot = $body->boot ?? null;

        if (!is_array($events) || !is_scalar($boot) || (string) $boot === '') {
            return;
        }
        $boot = (string) $boot;

        if ($events === [] && !$advance) {
            return;
        }

        $pdo = $this->db();
        $names = [];

        $received = time();
        $serverNow = is_numeric($body->now ?? null) ? (float) $body->now : null;
        $pageOwner = $body->owner ?? null;
        $pageStation = is_string($body->station ?? null) ? $body->station : '';

        $happenedAt = static function (object $event) use ($received, $serverNow): int {
            if ($serverNow === null || !is_numeric($event->at ?? null)) {
                return $received;
            }

            $offset = $serverNow - (float) $event->at;

            return $offset >= 0 && $offset <= 30 * 86400 ? $received - (int) round($offset) : $received;
        };

        $insert = $pdo->prepare(
            'INSERT INTO station_events
                 (faction, station, owner, x, y, boot, seq, kind, happened_at,
                  good, direction, internal, units, credits, data)
             VALUES (:f, :s, :o, :x, :y, :b, :q, :kind, to_timestamp(:t),
                     :g, :dir, :i, :u, :c, CAST(:d AS jsonb))
             ON CONFLICT (boot, seq) DO NOTHING'
        );

        $pdo->beginTransaction();

        try {
            foreach ($events as $event) {
                if (!is_object($event) || !is_numeric($event->seq ?? null)) {
                    continue;
                }

                $station = is_string($event->station ?? null) ? $event->station : $pageStation;
                $kind = (string) ($event->kind ?? '');
                if ($station === '' || $kind === '') {
                    continue;
                }

                $owner = is_object($event->owner ?? null) ? $event->owner : $pageOwner;
                $faction = $this->factionOf($owner, $names);
                if ($faction === null) {
                    continue;
                }

                $sector = is_object($event->sector ?? null) ? $event->sector : null;
                $isTrade = $kind === 'trade';

                // Everything but what became a column or is the same on every row.
                $data = get_object_vars($event);
                unset($data['seq'], $data['station'], $data['owner'], $data['sector'], $data['faction']);

                $insert->execute([
                    ':f' => $faction,
                    ':s' => $station,
                    ':o' => $this->kindOf($owner),
                    ':x' => $sector !== null ? (int) ($sector->x ?? 0) : 0,
                    ':y' => $sector !== null ? (int) ($sector->y ?? 0) : 0,
                    ':b' => $boot,
                    ':q' => (int) $event->seq,
                    ':kind' => $kind,
                    ':t' => $happenedAt($event),
                    ':g' => $isTrade && is_string($event->good ?? null) ? $event->good : null,
                    ':dir' => $isTrade && is_string($event->direction ?? null) ? $event->direction : null,
                    ':i' => $isTrade && ($event->internal ?? false) === true ? 'true' : 'false',
                    ':u' => $isTrade ? (float) ($event->units ?? 0) : 0,
                    ':c' => $isTrade ? (float) ($event->price ?? 0) : 0,
                    ':d' => $this->encode($data),
                ]);
            }

            /*
             * The cursor is the one thing here that belongs to the key rather than a faction:
             * it is how far this key's collector has read a feed scoped to this key's player
             * and alliance. A key the mod has never vouched for through /ping has no row to
             * keep it on, and simply starts from zero next time - its events are stored
             * either way.
             */
            $keyId = $this->keyRow()['id'] ?? null;
            if ($advance && $keyId !== null && is_numeric($body->cursor ?? null)) {
                $state = $this->one(
                    $pdo,
                    'SELECT boot FROM station_feed_state WHERE key_id = :k FOR UPDATE',
                    [':k' => $keyId]
                );

                if ($state === [] || $since === 0 || (string) $state['boot'] === $boot) {
                    $pdo->prepare(
                        'INSERT INTO station_feed_state (key_id, boot, cursor, updated_at)
                         VALUES (:k, :b, :c, now())
                         ON CONFLICT (key_id) DO UPDATE
                             SET boot = EXCLUDED.boot, cursor = EXCLUDED.cursor, updated_at = now()'
                    )->execute([':k' => $keyId, ':b' => $boot, ':c' => (int) $body->cursor]);
                }
            }

            $pdo->commit();
        } catch (Throwable $e) {
            $pdo->rollBack();
            throw $e;
        }

        $this->noteFactions($names);
        $this->maybePrune();
    }

    /**
     * Where the collector left off in the station feed: the server run it was reading and
     * the sequence number to continue after. A key that has never collected reads as run
     * unknown, sequence zero, which is "everything the mod still holds".
     *
     * @return array{boot: ?string, cursor: int}
     */
    public function stationEventCursor(): array
    {
        $keyId = $this->keyRow()['id'] ?? null;
        if ($keyId === null) {
            return ['boot' => null, 'cursor' => 0];
        }

        $row = $this->one(
            $this->db(),
            'SELECT boot, cursor FROM station_feed_state WHERE key_id = :k',
            [':k' => $keyId]
        );

        return $row === []
            ? ['boot' => null, 'cursor' => 0]
            : ['boot' => (string) $row['boot'], 'cursor' => (int) $row['cursor']];
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

    /**
     * The faction a craft in an answer belongs to: its owner's index, as the mod reported
     * it. Collects the owner's name into `$names` on the way, for noteFactions.
     *
     * An owner without an index is only ever a player - every answer the mod gives names
     * an alliance by index - and is taken to be this key's own. An alliance without one is
     * skipped rather than guessed at: the only guess available is the alliance the key was
     * last seen in, which is exactly what must not decide who can read a row.
     */
    private function factionOf(mixed $owner, array &$names): ?int
    {
        if (is_object($owner) && is_numeric($owner->index ?? null)) {
            $index = (int) $owner->index;
            if (is_string($owner->name ?? null) && $owner->name !== '') {
                $names[$index] = [$this->kindOf($owner), $owner->name];
            }
            return $index;
        }

        if ($this->kindOf($owner) === 'alliance') {
            return null;
        }

        return $this->keyRow()['player'] ?? null;
    }

    private function kindOf(mixed $owner): string
    {
        return is_object($owner) ? (string) ($owner->kind ?? '') : '';
    }

    /**
     * Remembers faction names for display. Writes only what changed, so a poll that names
     * the same forty craft owners every pass costs one statement that updates nothing.
     *
     * @param array<int, array{0: string, 1: string}> $names
     */
    private function noteFactions(array $names): void
    {
        $upsert = $this->db()->prepare(
            'INSERT INTO factions (id, kind, name) VALUES (:i, :k, :n)
             ON CONFLICT (id) DO UPDATE SET kind = EXCLUDED.kind, name = EXCLUDED.name
             WHERE factions.kind <> EXCLUDED.kind OR factions.name <> EXCLUDED.name'
        );

        foreach ($names as $index => [$kind, $name]) {
            if ($name !== '') {
                $upsert->execute([':i' => $index, ':k' => $kind, ':n' => $name]);
            }
        }
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
        [$where, $args] = $this->where($filter, 'entered_at', 'left_at');
        if ($where === null) {
            return [];
        }

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
     * The grouping is the database's problem and the index on (faction, x, y) is the whole
     * of the work.
     */
    public function heatmap(array $filter): array
    {
        [$where, $args] = $this->where($filter, 'entered_at', 'left_at');
        if ($where === null) {
            return ['cells' => [], 'maxVisits' => 0, 'maxSeconds' => 0,
                    'ships' => [], 'from' => null, 'to' => null];
        }

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
                    EXTRACT(EPOCH FROM MAX(left_at))::bigint    AS t
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
        [$where, $args] = $this->where($filter, 'happened_at', 'happened_at');
        if ($where === null) {
            return [];
        }

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

    /**
     * The last manifest seen for every craft this key may read, newest first.
     *
     * `at` is when it was read, and it is the caller's to judge: a hold read a minute ago
     * is a fair answer to "who is carrying Iron", one read yesterday is a hint of where to
     * look. Only rows owned by a faction are here - manifests were never kept per key.
     */
    public function manifests(array $filter): array
    {
        $scope = $this->scope();
        $factions = array_values(array_filter([$scope['player'], $scope['alliance']], 'is_int'));
        if ($factions === []) {
            return [];
        }

        $sql = 'SELECT ship, owner, data, EXTRACT(EPOCH FROM taken_at)::bigint AS t
                FROM manifests WHERE faction = ANY(CAST(:fs AS bigint[]))';
        $args = [':fs' => $this->pgArray($factions)];

        if (isset($filter['ship']) && $filter['ship'] !== '') {
            $sql .= ' AND ship = :s';
            $args[':s'] = (string) $filter['ship'];
        }
        if (isset($filter['owner']) && $filter['owner'] !== '') {
            $sql .= ' AND owner = :o';
            $args[':o'] = (string) $filter['owner'];
        }
        if (!empty($filter['from'])) {
            $sql .= ' AND taken_at >= to_timestamp(:f)';
            $args[':f'] = (int) $filter['from'];
        }

        $out = [];
        foreach ($this->all($this->db(), $sql . ' ORDER BY taken_at DESC, ship', $args) as $row) {
            $data = json_decode((string) $row['data'], true);
            $out[] = ['ship' => (string) $row['ship'], 'owner' => (string) $row['owner'],
                      'at' => (int) $row['t']] + (is_array($data) ? $data : []);
        }

        return $out;
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
     *
     * A station is (faction, key_id, ship), not the name alone. A player and their alliance
     * can each own a craft called "Refinery", and differencing the two as one series would
     * subtract one station's books from the other's. key_id is NULL on every owned row and
     * is only there to keep a not-yet-adopted copy apart from the owned one.
     */

    /** The readable rows, the optional craft and owner filters, and the window's upper bound. */
    private function economyScope(array $filter): ?array
    {
        [$sql, $args] = $this->scopeSql();
        if ($sql === null) {
            return null;
        }

        if (isset($filter['ship']) && $filter['ship'] !== '') {
            $sql .= ' AND ship = :s';
            $args[':s'] = (string) $filter['ship'];
        }
        if (isset($filter['owner']) && $filter['owner'] !== '') {
            $sql .= ' AND owner = :o';
            $args[':o'] = (string) $filter['owner'];
        }
        // One sector's stations. Both coordinates or neither: x alone is a column of the
        // galaxy, which nothing asks for.
        if (isset($filter['x'], $filter['y']) && $filter['x'] !== null && $filter['y'] !== null) {
            $sql .= ' AND x = :x AND y = :y';
            $args[':x'] = (int) $filter['x'];
            $args[':y'] = (int) $filter['y'];
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
        $window = ['from' => $from ?: null, 'to' => $to, 'seconds' => $from ? $to - $from : null];

        $scoped = $this->economyScope($filter);
        if ($scoped === null) {
            return ['window' => $window, 'stations' => [], 'totals' => $this->zeroTotals()
                    + ['perHour' => $this->perHour($this->zeroTotals(), 0)], 'factions' => []];
        }

        [$scope, $args] = $scoped;
        $args[':f'] = $from;
        $args[':cap'] = $this->gapCap();

        $rows = $this->all(
            $this->db(),
            "WITH samples AS (
                 SELECT faction, key_id, ship, owner, x, y, taken_at, gained, spent, tax, data
                 FROM station_samples WHERE {$scope}
             ),
             diffs AS (
                 SELECT faction, key_id, ship, owner, x, y, taken_at, data,
                        GREATEST(gained - LAG(gained) OVER w, 0) AS d_gained,
                        GREATEST(spent  - LAG(spent)  OVER w, 0) AS d_spent,
                        GREATEST(tax    - LAG(tax)    OVER w, 0) AS d_tax,
                        EXTRACT(EPOCH FROM taken_at - LAG(taken_at) OVER w) AS gap
                 FROM samples
                 WINDOW w AS (PARTITION BY faction, key_id, ship ORDER BY taken_at)
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
             GROUP BY faction, key_id, ship
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
            'window' => $window,
            'stations' => $stations,
            'totals' => $totals,
            'factions' => $this->factionRows($filter),
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
    public function economySeries(array $filter, string $bucket, bool $byShip = false): array
    {
        $bucket = $bucket === 'day' ? 'day' : 'hour';
        $from = $this->windowStart($filter);
        $to = $this->windowEnd($filter);

        $scoped = $this->economyScope($filter);
        if ($scoped === null) {
            return ['bucket' => $bucket, 'window' => ['from' => $from ?: null, 'to' => $to],
                    'ship' => (string) ($filter['ship'] ?? ''), 'points' => []];
        }

        [$scope, $args] = $scoped;
        $args[':f'] = $from;

        $rows = $this->all(
            $this->db(),
            "WITH samples AS (
                 SELECT faction, key_id, ship, taken_at, gained, spent, tax
                 FROM station_samples WHERE {$scope}
             ),
             diffs AS (
                 SELECT faction, key_id, ship, taken_at,
                        GREATEST(gained - LAG(gained) OVER w, 0) AS d_gained,
                        GREATEST(spent  - LAG(spent)  OVER w, 0) AS d_spent,
                        GREATEST(tax    - LAG(tax)    OVER w, 0) AS d_tax
                 FROM samples
                 WINDOW w AS (PARTITION BY faction, key_id, ship ORDER BY taken_at)
             )
             SELECT EXTRACT(EPOCH FROM date_trunc('{$bucket}', taken_at))::bigint AS at,
                    ship,
                    COALESCE(SUM(d_gained), 0)::bigint AS gained,
                    COALESCE(SUM(d_spent), 0)::bigint  AS spent,
                    COALESCE(SUM(d_tax), 0)::bigint    AS tax
             FROM diffs
             WHERE taken_at >= to_timestamp(:f)
             GROUP BY 1, faction, key_id, ship ORDER BY 1, ship",
            $args
        );

        // One row per station per bucket out of the query, folded into one point per
        // bucket here - with each station's share kept alongside when asked for, which is
        // what a stacked chart of a sector is drawn from.
        $byAt = [];
        foreach ($rows as $row) {
            $at = (int) $row['at'];
            $gained = (int) $row['gained'];
            $spent = (int) $row['spent'];
            $tax = (int) $row['tax'];

            $byAt[$at] ??= ['at' => $at, 'earned' => 0, 'spent' => 0, 'tax' => 0, 'net' => 0]
                + ($byShip ? ['ships' => []] : []);

            $byAt[$at]['earned'] += $gained;
            $byAt[$at]['spent'] += $spent;
            $byAt[$at]['tax'] += $tax;
            $byAt[$at]['net'] += $gained + $tax - $spent;

            if ($byShip) {
                $byAt[$at]['ships'][] = ['ship' => (string) $row['ship'], 'earned' => $gained,
                                         'spent' => $spent, 'tax' => $tax,
                                         'net' => $gained + $tax - $spent];
            }
        }

        return ['bucket' => $bucket, 'window' => ['from' => $from ?: null, 'to' => $to],
                'ship' => (string) ($filter['ship'] ?? ''), 'points' => array_values($byAt)];
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

        $scoped = $this->economyScope($filter);
        if ($scoped === null) {
            return ['goods' => [], 'window' => ['from' => $from ?: null, 'to' => $to]];
        }

        [$scope, $args] = $scoped;
        $args[':f'] = $from;

        $rows = $this->all(
            $this->db(),
            "WITH points AS (
                 SELECT faction, key_id, ship, g.key AS good, taken_at, (g.value)::numeric AS units
                 FROM station_samples, LATERAL jsonb_each_text(stock) g
                 WHERE {$scope}
             ),
             diffs AS (
                 SELECT faction, key_id, ship, good, taken_at, units,
                        units - LAG(units) OVER (PARTITION BY faction, key_id, ship, good
                                                 ORDER BY taken_at) AS d
                 FROM points
             )
             SELECT ship, good,
                    COALESCE(SUM(GREATEST(d, 0)), 0)::bigint  AS units_in,
                    COALESCE(SUM(GREATEST(-d, 0)), 0)::bigint AS units_out,
                    (array_agg(units ORDER BY taken_at DESC))[1]::bigint AS stock
             FROM diffs
             WHERE taken_at >= to_timestamp(:f)
             GROUP BY faction, key_id, ship, good
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

    /**
     * What each station actually did over the window, out of station_events: production
     * against its slot time, units made and used per good, and trades per good at the
     * prices they happened at.
     *
     * This is the measured counterpart of the rates the mod computes from a station's
     * database row, which are a ceiling - every slot busy, every sale at base price.
     *
     * ### The hour it is per
     *
     * `span` is running time plus reload catch-up time: the seconds a factory's production
     * windows cover while its sector was loaded, and the unloaded stretches the game
     * credited it for on reload. That is wall-clock time for a factory, without counting the
     * gaps nobody was collecting - the mod buffers those - and it is what `perHour` divides
     * by. A sector still unloaded when the window ends has not been caught up yet, and its
     * tail is missing from both sides of the division rather than from one.
     *
     * A station with no production windows (a trading post) has no running time to go by,
     * so its span is the time between its first and last recorded event.
     */
    public function economyObserved(array $filter): array
    {
        $from = $this->windowStart($filter);
        $to = $this->windowEnd($filter);
        $window = ['from' => $from ?: null, 'to' => $to];

        [$scope, $args] = $this->stationEventScope($filter);
        if ($scope === null) {
            return ['stations' => [], 'window' => $window];
        }

        $pdo = $this->db();

        $number = static fn (string $field, string $kind): string =>
            "COALESCE(SUM((data->>'{$field}')::float) FILTER (WHERE kind = '{$kind}'), 0)";

        $rows = $this->all(
            $pdo,
            'SELECT faction, station,
                    MAX(owner) AS owner, MAX(x)::int AS x, MAX(y)::int AS y,
                    ' . $number('seconds', 'production') . ' AS seconds,
                    ' . $number('slotSeconds', 'production') . ' AS slot_seconds,
                    ' . $number('busySlotSeconds', 'production') . ' AS busy_slot_seconds,
                    ' . $number('starvedSeconds', 'production') . ' AS starved_seconds,
                    ' . $number('blockedSeconds', 'production') . ' AS blocked_seconds,
                    ' . $number('idleSeconds', 'production') . ' AS idle_seconds,
                    ' . $number('cycles', 'production') . ' AS cycles,
                    ' . $number('boosted', 'production') . ' AS boosted,
                    ' . $number('seconds', 'catchup') . ' AS catchup_seconds,
                    ' . $number('cycles', 'catchup') . " AS catchup_cycles,
                    COUNT(*) FILTER (WHERE kind = 'production')::bigint AS windows,
                    COUNT(*) FILTER (WHERE kind = 'trade')::bigint AS trades,
                    (array_agg(data ORDER BY happened_at DESC) FILTER (WHERE kind = 'production'))[1] AS latest,
                    EXTRACT(EPOCH FROM MIN(happened_at))::bigint AS first_at,
                    EXTRACT(EPOCH FROM MAX(happened_at))::bigint AS last_at
             FROM station_events WHERE {$scope}
             GROUP BY faction, station ORDER BY station, faction",
            $args
        );

        $stations = [];
        foreach ($rows as $row) {
            $latest = json_decode((string) ($row['latest'] ?? 'null'), true);
            $production = [
                'windows' => (int) $row['windows'],
                'seconds' => (float) $row['seconds'],
                'slotSeconds' => (float) $row['slot_seconds'],
                'busySlotSeconds' => (float) $row['busy_slot_seconds'],
                'starvedSeconds' => (float) $row['starved_seconds'],
                'blockedSeconds' => (float) $row['blocked_seconds'],
                'idleSeconds' => (float) $row['idle_seconds'],
                'cycles' => (float) $row['cycles'],
                'boosted' => (float) $row['boosted'],
                'catchupSeconds' => (float) $row['catchup_seconds'],
                'catchupCycles' => (float) $row['catchup_cycles'],
                'slots' => is_array($latest) ? (int) ($latest['slots'] ?? 0) : null,
                'cycleSeconds' => is_array($latest) ? (float) ($latest['cycleSeconds'] ?? 0) : null,
            ];

            $running = $production['seconds'] + $production['catchupSeconds'];
            $span = $running > 0 ? $running : max(0, (int) $row['last_at'] - (int) $row['first_at']);

            $production['utilization'] = $production['slotSeconds'] > 0
                ? round($production['busySlotSeconds'] / $production['slotSeconds'], 4) : null;
            $production['cyclesPerHour'] = $running > 0
                ? round(($production['cycles'] + $production['catchupCycles']) * 3600 / $running, 3) : null;

            $stations[$row['faction'] . "\0" . $row['station']] = [
                'ship' => (string) $row['station'],
                'owner' => (string) $row['owner'],
                'x' => (int) $row['x'],
                'y' => (int) $row['y'],
                'first' => (int) $row['first_at'],
                'last' => (int) $row['last_at'],
                'span' => $span,
                'production' => $production['windows'] > 0 || $production['catchupSeconds'] > 0 ? $production : null,
                'trades' => (int) $row['trades'],
                'goods' => [],
                'traded' => ['sold' => 0.0, 'bought' => 0.0, 'consumed' => 0.0, 'net' => 0.0,
                             'perHour' => null],
            ];
        }

        $good = static function (array &$station, string $name): array {
            $station['goods'][$name] ??= [
                'good' => $name, 'made' => 0.0, 'used' => 0.0,
                'madePerHour' => null, 'usedPerHour' => null,
                'sold' => ['units' => 0.0, 'credits' => 0.0, 'trades' => 0, 'unitPrice' => null],
                'bought' => ['units' => 0.0, 'credits' => 0.0, 'trades' => 0, 'unitPrice' => null],
                'consumed' => ['units' => 0.0, 'credits' => 0.0, 'trades' => 0, 'unitPrice' => null],
                'internalIn' => 0.0, 'internalOut' => 0.0,
            ];

            return $station['goods'][$name];
        };

        /*
         * Units per good, out of the recipe every window carries with it. A window records
         * cycles, not goods, and the recipe travels with it so that a station rebuilt into a
         * different factory does not rewrite what its old windows made. Optional ingredients
         * go in on boosted cycles only; the reload catch-up boosts nothing.
         */
        $recipes = $this->all(
            $pdo,
            "SELECT faction, station, item->>'name' AS good,
                    COALESCE(SUM((data->>'cycles')::float * (item->>'amount')::float)
                        FILTER (WHERE side <> 'ingredients'), 0) AS made,
                    COALESCE(SUM(CASE WHEN item->>'optional' = 'true'
                                      THEN COALESCE((data->>'boosted')::float, 0)
                                      ELSE (data->>'cycles')::float END
                                 * (item->>'amount')::float)
                        FILTER (WHERE side = 'ingredients'), 0) AS used
             FROM station_events,
                  LATERAL (
                      SELECT 'results' AS side, el AS item
                          FROM jsonb_array_elements(COALESCE(data->'results', '[]'::jsonb)) el
                      UNION ALL
                      SELECT 'garbage', el FROM jsonb_array_elements(COALESCE(data->'garbage', '[]'::jsonb)) el
                      UNION ALL
                      SELECT 'ingredients', el FROM jsonb_array_elements(COALESCE(data->'ingredients', '[]'::jsonb)) el
                  ) recipe
             WHERE {$scope} AND kind IN ('production', 'catchup')
             GROUP BY faction, station, item->>'name'",
            $args
        );

        foreach ($recipes as $row) {
            $name = $row['faction'] . "\0" . $row['station'];
            if (!isset($stations[$name]) || (string) $row['good'] === '') {
                continue;
            }

            $entry = $good($stations[$name], (string) $row['good']);
            $entry['made'] += (float) $row['made'];
            $entry['used'] += (float) $row['used'];
            $stations[$name]['goods'][(string) $row['good']] = $entry;
        }

        $trades = $this->all(
            $pdo,
            "SELECT faction, station, good, direction, internal,
                    SUM(units) AS units, SUM(credits) AS credits, COUNT(*)::bigint AS trades
             FROM station_events
             WHERE {$scope} AND kind = 'trade' AND good IS NOT NULL
             GROUP BY faction, station, good, direction, internal",
            $args
        );

        foreach ($trades as $row) {
            $name = $row['faction'] . "\0" . $row['station'];
            $direction = (string) $row['direction'];
            if (!isset($stations[$name]) || !in_array($direction, ['sold', 'bought', 'consumed'], true)) {
                continue;
            }

            $entry = $good($stations[$name], (string) $row['good']);
            $units = (float) $row['units'];

            if ($this->truthy($row['internal'])) {
                // Moved inside the faction for nothing: movement, never a price.
                $entry[$direction === 'bought' ? 'internalIn' : 'internalOut'] += $units;
            } else {
                $entry[$direction]['units'] += $units;
                $entry[$direction]['credits'] += (float) $row['credits'];
                $entry[$direction]['trades'] += (int) $row['trades'];
                $stations[$name]['traded'][$direction] += (float) $row['credits'];
            }

            $stations[$name]['goods'][(string) $row['good']] = $entry;
        }

        foreach ($stations as &$station) {
            $span = $station['span'];

            foreach ($station['goods'] as &$entry) {
                foreach (['sold', 'bought', 'consumed'] as $direction) {
                    $bucket = &$entry[$direction];
                    $bucket['unitPrice'] = $bucket['units'] > 0 ? round($bucket['credits'] / $bucket['units'], 2) : null;
                    unset($bucket);
                }
                if ($span > 0) {
                    $entry['madePerHour'] = round($entry['made'] * 3600 / $span, 3);
                    $entry['usedPerHour'] = round($entry['used'] * 3600 / $span, 3);
                }
            }
            unset($entry);

            ksort($station['goods']);
            $station['goods'] = array_values($station['goods']);

            $traded = &$station['traded'];
            $traded['net'] = $traded['sold'] + $traded['consumed'] - $traded['bought'];
            $traded['perHour'] = $span > 0 ? round($traded['net'] * 3600 / $span, 2) : null;
            unset($traded);
        }
        unset($station);

        return ['stations' => array_values($stations), 'window' => $window];
    }

    /**
     * Stored station events, newest `limit` of them in time order - the trade log.
     * `kind` narrows to one of trade, production and catchup.
     *
     * `before` is the `id` of an event from an earlier answer, and pages back from it. It
     * is a position in the same order the rows are read in rather than a time: `to` only
     * has whole seconds, and a busy trading post trades several times in one of those, so
     * paging by time either repeats a second's events or skips them. Rows are ordered by
     * when they happened, not by id - a reload catch-up or a late collection is stored
     * after events that happened later - so the id is resolved to its place in that order.
     * An id this key cannot see, or that has been cleared, reads as nothing before it.
     */
    public function stationEvents(array $filter): array
    {
        [$scope, $args] = $this->stationEventScope($filter);
        if ($scope === null) {
            return [];
        }

        if (isset($filter['kind']) && $filter['kind'] !== '') {
            $scope .= ' AND kind = :kind';
            $args[':kind'] = (string) $filter['kind'];
        }

        if ((int) ($filter['before'] ?? 0) > 0) {
            $scope .= ' AND (happened_at, id) < (SELECT happened_at, id FROM station_events WHERE id = :before)';
            $args[':before'] = (int) $filter['before'];
        }

        $limit = max(1, (int) ($filter['limit'] ?? 500));

        $rows = $this->all(
            $this->db(),
            "SELECT id, station, owner, x, y, boot, seq, kind, data,
                    EXTRACT(EPOCH FROM happened_at)::bigint AS t
             FROM station_events WHERE {$scope}
             ORDER BY happened_at DESC, id DESC LIMIT {$limit}",
            $args
        );

        $out = [];
        foreach (array_reverse($rows) as $row) {
            // `boot` and `q` together are the mod's own identity for the event, which is what
            // lets a reader merge these with the live feed without showing one twice.
            $event = ['id' => (int) $row['id'], 't' => (int) $row['t'], 'station' => (string) $row['station'],
                      'owner' => (string) $row['owner'], 'x' => (int) $row['x'], 'y' => (int) $row['y'],
                      'boot' => (string) $row['boot'], 'q' => (int) $row['seq']];

            $data = json_decode((string) $row['data'], true);
            if (is_array($data)) {
                $event += $data;
            }

            $out[] = $event;
        }

        return $out;
    }

    /**
     * The WHERE behind both station event reads: the factions this key may read, then
     * station, owner, sector and window. Null when it may read none.
     *
     * @return array{0: ?string, 1: array<string, mixed>}
     */
    private function stationEventScope(array $filter): array
    {
        [$sql, $args] = $this->factionScopeSql();
        if ($sql === null) {
            return [null, []];
        }

        if (isset($filter['ship']) && $filter['ship'] !== '') {
            $sql .= ' AND station = :s';
            $args[':s'] = (string) $filter['ship'];
        }
        if (isset($filter['owner']) && $filter['owner'] !== '') {
            $sql .= ' AND owner = :o';
            $args[':o'] = (string) $filter['owner'];
        }
        if (isset($filter['x'], $filter['y']) && $filter['x'] !== null && $filter['y'] !== null) {
            $sql .= ' AND x = :x AND y = :y';
            $args[':x'] = (int) $filter['x'];
            $args[':y'] = (int) $filter['y'];
        }

        $sql .= ' AND happened_at <= to_timestamp(:t) AND happened_at >= to_timestamp(:f)';
        $args[':t'] = $this->windowEnd($filter);
        $args[':f'] = $this->windowStart($filter);

        return [$sql, $args];
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
    private function factionRows(array $filter): array
    {
        [$scope, $args] = $this->scopeSql();
        if ($scope === null) {
            return [];
        }

        $args[':t'] = $this->windowEnd($filter);
        $args[':f'] = $this->windowStart($filter);

        $rows = $this->all(
            $this->db(),
            "SELECT owner,
                    COUNT(*)::bigint AS samples,
                    (array_agg(money ORDER BY taken_at))[1]::bigint      AS first_money,
                    (array_agg(money ORDER BY taken_at DESC))[1]::bigint AS last_money,
                    (array_agg(resources ORDER BY taken_at DESC))[1]     AS resources,
                    (array_agg(stations ORDER BY taken_at DESC))[1]::int AS stations,
                    EXTRACT(EPOCH FROM MIN(taken_at))::bigint AS first_at,
                    EXTRACT(EPOCH FROM MAX(taken_at))::bigint AS last_at
             FROM faction_samples
             WHERE {$scope} AND taken_at <= to_timestamp(:t) AND taken_at >= to_timestamp(:f)
             GROUP BY faction, key_id, owner ORDER BY owner, faction",
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

    /**
     * What is stored, per craft, so a client can show the shape of it before asking for any
     * - and whose it is, so a client can say which of it is shared.
     */
    public function summary(): array
    {
        $scope = $this->scope();

        [$where, $args] = $this->scopeSql();
        if ($where === null) {
            return ['ships' => [], 'rows' => 0, 'retentionDays' => $this->retentionDays,
                    'recording' => false, 'scope' => $this->describeScope($scope)];
        }

        $ships = [];

        $note = static function (array $row, string $field) use (&$ships): void {
            $name = (string) $row['ship'];
            $id = $row['owner'] . "\0" . $name;

            if (!isset($ships[$id])) {
                $ships[$id] = ['name' => $name, 'owner' => (string) $row['owner'],
                               'visits' => 0, 'events' => 0, 'samples' => 0, 'sectors' => 0,
                               'first' => null, 'last' => null];
            }
            $ships[$id][$field] += (int) $row['n'];
            foreach ([['first', (int) $row['f'], 'min'], ['last', (int) $row['l'], 'max']] as [$slot, $value, $pick]) {
                $ships[$id][$slot] = $ships[$id][$slot] === null ? $value : $pick($ships[$id][$slot], $value);
            }
        };

        $rows = $this->all(
            $this->db(),
            "SELECT ship, owner, COUNT(*)::bigint AS n, COUNT(DISTINCT (x, y))::bigint AS sectors,
                    EXTRACT(EPOCH FROM MIN(entered_at))::bigint AS f,
                    EXTRACT(EPOCH FROM MAX(left_at))::bigint    AS l
             FROM visits WHERE {$where} GROUP BY ship, owner",
            $args
        );
        foreach ($rows as $row) {
            $note($row, 'visits');
            $ships[$row['owner'] . "\0" . $row['ship']]['sectors'] = (int) $row['sectors'];
        }

        foreach ([['events', 'happened_at', 'events'], ['station_samples', 'taken_at', 'samples']]
                 as [$table, $column, $field]) {
            $rows = $this->all(
                $this->db(),
                "SELECT ship, owner, COUNT(*)::bigint AS n,
                        EXTRACT(EPOCH FROM MIN({$column}))::bigint AS f,
                        EXTRACT(EPOCH FROM MAX({$column}))::bigint AS l
                 FROM {$table} WHERE {$where} GROUP BY ship, owner",
                $args
            );
            foreach ($rows as $row) {
                $note($row, $field);
            }
        }

        uasort($ships, static fn (array $a, array $b): int
            => [$a['name'], $a['owner']] <=> [$b['name'], $b['owner']]);

        $total = 0;
        foreach ($ships as $ship) {
            $total += $ship['visits'] + $ship['events'] + $ship['samples'];
        }

        // Whether there is an economy series at all, which is what tells a client to
        // offer the view rather than draw an empty chart. A deployment that upgraded
        // mid-month has travel history and no station samples, and should say so.
        $economy = $this->one(
            $this->db(),
            "SELECT COUNT(*)::bigint AS n, COUNT(DISTINCT (owner, ship))::bigint AS stations,
                    EXTRACT(EPOCH FROM MIN(taken_at))::bigint AS f
             FROM station_samples WHERE {$where}",
            $args
        );

        // The measured half of the economy: what stations recorded from inside themselves.
        // Zero on a bridge collecting from a mod that predates the station hooks.
        [$factions, $factionArgs] = $this->factionScopeSql();
        $activity = $factions === null ? [] : $this->one(
            $this->db(),
            "SELECT COUNT(*)::bigint AS n, COUNT(DISTINCT (faction, station))::bigint AS stations,
                    COUNT(*) FILTER (WHERE kind = 'trade')::bigint AS trades,
                    EXTRACT(EPOCH FROM MIN(happened_at))::bigint AS f
             FROM station_events WHERE {$factions}",
            $factionArgs
        );

        return [
            'ships' => array_values($ships),
            'rows' => $total + (int) ($activity['n'] ?? 0),
            'retentionDays' => $this->retentionDays,
            'recording' => true,
            'scope' => $this->describeScope($scope),
            'economy' => [
                'samples' => (int) ($economy['n'] ?? 0),
                'stations' => (int) ($economy['stations'] ?? 0),
                'since' => isset($economy['f']) ? (int) $economy['f'] : null,
                'interval' => $this->economyInterval,
                'events' => (int) ($activity['n'] ?? 0),
                'trades' => (int) ($activity['trades'] ?? 0),
                'recordedStations' => (int) ($activity['stations'] ?? 0),
                'eventsSince' => isset($activity['f']) ? (int) $activity['f'] : null,
            ],
        ];
    }

    /** The scope as a client wants to show it: names, and whether the alliance is included. */
    private function describeScope(array $scope): array
    {
        $ids = array_values(array_filter([$scope['player'], $scope['alliance']], 'is_int'));
        $names = [];

        if ($ids !== []) {
            foreach ($this->all($this->db(), 'SELECT id, name FROM factions WHERE id = ANY(CAST(:ids AS bigint[]))',
                                [':ids' => $this->pgArray($ids)]) as $row) {
                $names[(int) $row['id']] = (string) $row['name'];
            }
        }

        $describe = static fn (?int $id): ?array
            => $id === null ? null : ['index' => $id, 'name' => $names[$id] ?? ''];

        return [
            'player' => $describe($scope['player']),
            'alliance' => $describe($scope['alliance']),
            'verified' => $scope['verified'],
        ];
    }

    /**
     * Removes this player's own history, or one craft's share of it.
     *
     * Personal rows only - the player's, and whatever this key recorded before rows had
     * owners. An alliance's history belongs to every member, and the bridge has no way to
     * ask the game which of them may throw it away, so no member can.
     */
    public function clear(?string $ship): array
    {
        $scope = $this->scope();
        if ($scope['key'] === null) {
            return ['cleared' => true, 'ship' => $ship, 'removed' => 0];
        }

        $pdo = $this->db();
        $removed = 0;

        $mine = '(faction = :p OR (faction IS NULL AND key_id = :k))';
        $args = [':p' => $scope['player'], ':k' => $scope['key']];
        $craft = '';
        if ($ship !== null) {
            $craft = ' AND ship = :s';
            $args[':s'] = $ship;
        }

        $pdo->beginTransaction();

        try {
            foreach (['visits', 'events', 'station_samples', 'faction_samples'] as $table) {
                if ($ship !== null && $table === 'faction_samples') {
                    continue;
                }
                $statement = $pdo->prepare("DELETE FROM {$table} WHERE {$mine}{$craft}");
                $statement->execute($args);
                $removed += $statement->rowCount();
            }

            $personal = [':p' => $scope['player']] + ($ship !== null ? [':s' => $ship] : []);
            if ($scope['player'] !== null) {
                foreach (['event_marks', 'manifests'] as $table) {
                    $pdo->prepare("DELETE FROM {$table} WHERE faction = :p{$craft}")->execute($personal);
                }

                // Station events only ever had owners, and name their craft `station`.
                $statement = $pdo->prepare('DELETE FROM station_events WHERE faction = :p'
                    . ($ship !== null ? ' AND station = :s' : ''));
                $statement->execute($personal);
                $removed += $statement->rowCount();
            }

            $legacy = [':k' => $scope['key']] + ($ship !== null ? [':s' => $ship] : []);
            $pdo->prepare("DELETE FROM ship_state WHERE key_id = :k{$craft}")->execute($legacy);

            $pdo->commit();
        } catch (Throwable $e) {
            $pdo->rollBack();
            throw $e;
        }

        return ['cleared' => true, 'ship' => $ship, 'removed' => $removed];
    }

    /**
     * Drops rows past the retention window, and past a hard row cap if the window alone is
     * not enough.
     *
     * Across the whole store rather than for this key: retention is one setting for every
     * row, and with rows owned by factions there is no "this key's share" to prune. Public
     * because the poller calls it on its own timer, which is where this work belongs - see
     * maybePrune for why it also runs, rarely, from the request path.
     */
    public function prune(): int
    {
        $pdo = $this->db();
        $cutoff = time() - $this->retentionDays * 86400;
        $removed = 0;

        foreach ([['visits', 'left_at'], ['events', 'happened_at'],
                  ['station_samples', 'taken_at'], ['faction_samples', 'taken_at'],
                  ['station_events', 'happened_at']] as [$table, $column]) {
            $statement = $pdo->prepare(
                "DELETE FROM {$table} WHERE {$column} < to_timestamp(:c)"
                . ($table === 'visits' ? ' AND NOT open' : '')
            );
            $statement->execute([':c' => $cutoff]);
            $removed += $statement->rowCount();

            // Still over the cap for the window alone - a single very busy month. Trim the
            // oldest rather than letting one faction fill the volume. Unadopted rows are
            // counted per key, which is who they still belong to; station events came
            // after rows had owners and have no key_id at all.
            foreach ($table === 'station_events' ? ['faction'] : ['faction', 'key_id'] as $owner) {
                $over = $this->all(
                    $pdo,
                    "SELECT {$owner} AS o, COUNT(*)::bigint AS n FROM {$table}
                     WHERE {$owner} IS NOT NULL GROUP BY {$owner} HAVING COUNT(*) > :max",
                    [':max' => $this->maxRows]
                );

                foreach ($over as $row) {
                    $statement = $pdo->prepare(
                        "DELETE FROM {$table} WHERE id IN (
                             SELECT id FROM {$table} WHERE {$owner} = :o ORDER BY {$column}, id LIMIT :n)"
                    );
                    $statement->bindValue(':o', (int) $row['o'], PDO::PARAM_INT);
                    $statement->bindValue(':n', (int) $row['n'] - $this->maxRows, PDO::PARAM_INT);
                    $statement->execute();
                    $removed += $statement->rowCount();
                }
            }
        }

        // A manifest nobody has refreshed in the whole window describes a craft that is
        // probably gone. It is one row per craft, so it is not counted as history removed.
        $pdo->prepare('DELETE FROM manifests WHERE taken_at < to_timestamp(:c)')->execute([':c' => $cutoff]);

        /*
         * The notification log, which is not history and is kept on a much shorter leash:
         * Notifications::trim already caps it per player, and this is only the floor for a
         * player who has stopped using the bridge entirely. Undelivered rows go too - one
         * that has been waiting a month is not worth sending.
         *
         * Marks for craft nothing has seen in the window go with them, or a rule about a
         * fleet that has been rebuilt would carry the old craft's state for ever.
         */
        $pdo->prepare('DELETE FROM notifications WHERE created_at < to_timestamp(:c)')
            ->execute([':c' => $cutoff]);
        $pdo->prepare('DELETE FROM notification_marks WHERE seen_at < to_timestamp(:c)')
            ->execute([':c' => $cutoff]);

        return $removed;
    }

    /* -------------------------------- internals ----------------------------- */

    private function db(): PDO
    {
        return $this->pdo ??= Db::connect();
    }

    /**
     * This key's row, or null for a key the store has never been told about. Only ever
     * created by recordPing: a row claims an identity, and only the mod can vouch for one.
     *
     * @return array{id: int, player: ?int, alliance: ?int, verified: ?int, legacy: bool}|null
     */
    private function keyRow(): ?array
    {
        if ($this->keyRow === false) {
            return null;
        }
        if (is_array($this->keyRow)) {
            return $this->keyRow;
        }

        $row = $this->one(
            $this->db(),
            'SELECT id, player, alliance, legacy,
                    EXTRACT(EPOCH FROM verified_at)::bigint AS verified
             FROM api_keys WHERE key_hash = :h',
            [':h' => $this->hash]
        );

        if (!isset($row['id'])) {
            $this->keyRow = false;
            return null;
        }

        $int = static fn (mixed $v): ?int => $v === null ? null : (int) $v;

        return $this->keyRow = [
            'id' => (int) $row['id'],
            'player' => $int($row['player']),
            'alliance' => $int($row['alliance']),
            'verified' => $int($row['verified']),
            'legacy' => $this->truthy($row['legacy']),
        ];
    }

    /**
     * The rows this key may read, as SQL over unqualified column names. The SQL is null
     * when there are none, so a caller answers empty without asking the database.
     *
     * @return array{0: ?string, 1: array<string, mixed>}
     */
    private function scopeSql(): array
    {
        $scope = $this->scope();
        [$factions, $args] = $this->factionScopeSql();
        $parts = $factions === null ? [] : [$factions];

        if ($scope['key'] !== null) {
            $parts[] = '(faction IS NULL AND key_id = :sk)';
            $args[':sk'] = $scope['key'];
        }

        if ($parts === []) {
            return [null, []];
        }

        return ['(' . implode(' OR ', $parts) . ')', $args];
    }

    /**
     * The owned half of scopeSql alone: the player's rows, and the alliance's while the
     * membership is current. For tables that only ever had owners - station_events has no
     * key_id to fall back on - and null when the key reads no faction at all.
     *
     * @return array{0: ?string, 1: array<string, mixed>}
     */
    private function factionScopeSql(): array
    {
        $scope = $this->scope();

        $factions = array_values(array_filter([$scope['player'], $scope['alliance']], 'is_int'));
        if ($factions === []) {
            return [null, []];
        }

        return ['faction = ANY(CAST(:scope AS bigint[]))', [':scope' => $this->pgArray($factions)]];
    }

    /**
     * Builds the WHERE shared by the travel and event reads.
     *
     * A window overlaps a row when the row ends after `from` and starts before `to`, which
     * is not the same as either endpoint being inside it: a craft parked in one sector for
     * a week belongs in every window that week touches.
     *
     * @return array{0: ?string, 1: array<string, mixed>}
     */
    private function where(array $filter, string $start, string $end): array
    {
        [$sql, $args] = $this->scopeSql();
        if ($sql === null) {
            return [null, []];
        }

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

    /** A Postgres array literal of integers, bound as one parameter. */
    private function pgArray(array $ints): string
    {
        return '{' . implode(',', array_map('intval', array_unique($ints))) . '}';
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
