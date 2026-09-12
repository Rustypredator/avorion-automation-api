<?php

declare(strict_types=1);

/**
 * Durable history for one API key.
 *
 * The mod's own event log is a ring buffer in server memory: 200 entries per ship, gone
 * at the next restart, and only written while some player agent is online to see the
 * callbacks fire. That is the right shape for "what is this ship doing now" and the wrong
 * one for "where has this fleet been all month", which is what a map overlay needs.
 *
 * So the bridge keeps a copy. Every answer it relays past on its way back to the caller is
 * also appended here, which costs one file write on calls that were happening anyway and
 * needs nothing at all from the Lua side - where a growing file on the server tick would
 * be a genuinely bad idea.
 *
 * Two files, both JSON Lines, both append-only:
 *
 *   visits.jsonl - one line per sector a craft was seen to occupy, closed off when it
 *                  moves on. Positions come from GET /ships, which reads the ship
 *                  database, so this keeps recording with every player logged out. It is
 *                  what the heatmap and the travel track are built from.
 *   events.jsonl - the mod's own order and status events, kept past the ring buffer's
 *                  200 and past a server restart.
 *
 * ### On keying by the API key
 *
 * The directory is named for a SHA-256 of the key and never holds the key itself: this
 * process deliberately owns no credential, and storing one would change that. A key is
 * 256 bits of randomness, so the name cannot be guessed, and a key nobody has ever used
 * simply addresses a directory that does not exist.
 *
 * That is what lets reads skip validation - an unknown key reads an empty history rather
 * than someone else's. Writes are a different matter and are only ever made after the mod
 * has answered a call successfully, which is the actual authentication. A caller who
 * cannot get a 200 out of the mod cannot make this directory exist.
 *
 * ### What it does not know
 *
 * Nothing here polls. History accumulates while *something* is calling the API - the
 * console with a tab open, a cron job, your own script - and a gap in the files is a gap
 * in who was looking, not a gap in what happened. Dwell times are therefore reported as
 * observed seconds: time nobody was watching is counted as zero rather than guessed at.
 */
final class History
{
    private const VISITS = 'visits.jsonl';
    private const EVENTS = 'events.jsonl';
    private const STATE = 'state.json';
    private const LOCK = '.lock';
    private const PRUNED = '.pruned';

    /** How often pruning is even considered, in seconds. */
    private const PRUNE_EVERY = 3600;

    private string $dir;
    private int $retentionDays;
    private int $maxBytes;

    public function __construct(string $root, string $key)
    {
        $this->dir = rtrim($root, '/') . '/' . substr(hash('sha256', $key), 0, 32);
        $this->retentionDays = max(1, (int) (getenv('HISTORY_DAYS') ?: 30));
        $this->maxBytes = max(256 * 1024, (int) (getenv('HISTORY_MAX_BYTES') ?: 16 * 1024 * 1024));
    }

    public function exists(): bool
    {
        return is_dir($this->dir);
    }

    public function directory(): string
    {
        return $this->dir;
    }

    /* ------------------------------- recording ------------------------------ */

    /**
     * Fold one GET /ships answer into the visit log.
     *
     * A craft that has not moved produces no line - it only extends the visit already
     * open for it in state.json. A craft that has moved closes that visit out and opens
     * the next. So the file grows with travel rather than with polling, and a fleet
     * parked for a week costs nothing.
     */
    public function recordShips(object $body): void
    {
        $ships = $body->ships ?? null;
        if (!is_array($ships) || $ships === []) {
            return;
        }

        $now = time();
        $closed = [];

        $this->withState(static function (array $state) use ($ships, $now, &$closed): array {
            $known = $state['ships'] ?? [];

            foreach ($ships as $ship) {
                $name = is_object($ship) ? ($ship->name ?? null) : null;
                $position = is_object($ship) ? ($ship->position ?? null) : null;

                if (!is_string($name) || $name === '' || !is_object($position)) {
                    continue;
                }
                if (!isset($position->x, $position->y)) {
                    continue;
                }

                $x = (int) $position->x;
                $y = (int) $position->y;
                $owner = is_object($ship->owner ?? null) ? (string) ($ship->owner->kind ?? '') : '';

                $open = $known[$name] ?? null;

                if (is_array($open) && (int) $open['x'] === $x && (int) $open['y'] === $y) {
                    // Same sector: the visit simply got longer.
                    $known[$name]['e'] = $now;
                    continue;
                }

                if (is_array($open)) {
                    $closed[] = [
                        't' => (int) $open['t'],
                        'e' => (int) $open['e'],
                        's' => $name,
                        'x' => (int) $open['x'],
                        'y' => (int) $open['y'],
                        'o' => (string) ($open['o'] ?? ''),
                    ];
                }

                $known[$name] = ['x' => $x, 'y' => $y, 't' => $now, 'e' => $now, 'o' => $owner];
            }

            $state['ships'] = $known;
            $state['seen'] = $now;

            return $state;
        });

        if ($closed !== []) {
            $this->append(self::VISITS, $closed);
        }
    }

    /**
     * Fold one GET /ships/{name}/events answer into the event log.
     *
     * Sequence numbers are the mod's and are global, monotonic, and reset to zero on a
     * server restart. A batch whose highest sequence sits below what is already stored is
     * therefore a restart rather than a replay, and the stored mark is dropped instead of
     * swallowing every event until the counter catches up again - which, on a busy galaxy,
     * is hours.
     */
    public function recordEvents(string $ship, object $body): void
    {
        $events = $body->events ?? null;
        if (!is_array($events) || $events === []) {
            return;
        }

        $now = time();
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
         * with time() lands an afternoon's worth of events on a single second.
         *
         * The mod stamps each event with Server().unpausedRuntime, which is seconds of
         * server uptime - no use as a date on its own, but exact as a spacing. The newest
         * event in a batch is the one closest to now, so anchoring that to the clock and
         * walking the rest back by their own offsets dates the whole batch. It is wrong by
         * however long the newest event sat in the buffer before anyone asked, which is one
         * poll interval for anything watched live, and it degrades gracefully: an event
         * without a usable stamp simply gets the arrival time it would have had anyway.
         */
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

        $lines = [];

        $this->withState(static function (array $state) use (
            $events, $ship, $owner, $now, $highest, $happenedAt, &$lines
        ): array {
            $marks = $state['seqs'] ?? [];
            $mark = (int) ($marks[$ship] ?? -1);

            if ($highest < $mark) {
                $mark = -1;
            }

            foreach ($events as $event) {
                if (!is_object($event)) {
                    continue;
                }

                $seq = (int) ($event->seq ?? 0);
                if ($seq <= $mark) {
                    continue;
                }

                $line = ['t' => $happenedAt($event), 's' => $ship, 'q' => $seq, 'o' => $owner];

                foreach (get_object_vars($event) as $field => $value) {
                    if ($field === 'seq') {
                        continue;
                    }
                    $line[$field] = $value;
                }

                $lines[] = $line;
            }

            $marks[$ship] = max($mark, $highest);
            $state['seqs'] = $marks;

            return $state;
        });

        if ($lines !== []) {
            $this->append(self::EVENTS, $lines);
        }
    }

    /* -------------------------------- reading ------------------------------- */

    /**
     * Every visit, oldest first, with the one currently open appended so that "where is
     * it right now" is part of the same answer rather than a separate call.
     */
    public function visits(array $filter): array
    {
        $out = $this->scan(self::VISITS, $filter);

        foreach ($this->openVisits() as $open) {
            if ($this->keep($open, $filter)) {
                $out[] = $open;
            }
        }

        usort($out, static fn (array $a, array $b): int => $a['t'] <=> $b['t']);

        $limit = (int) ($filter['limit'] ?? 0);
        if ($limit > 0 && count($out) > $limit) {
            // Keep the newest: a caller drawing a track wants where the ship has been
            // lately, and can page back with `from` for the rest.
            $out = array_slice($out, -$limit);
        }

        return $out;
    }

    /** Visits collapsed onto the grid: how often each sector was entered, and for how long. */
    public function heatmap(array $filter): array
    {
        $cells = [];
        $ships = [];
        $first = null;
        $last = null;

        foreach ($this->visits($filter + ['limit' => 0]) as $visit) {
            $key = $visit['x'] . ',' . $visit['y'];

            if (!isset($cells[$key])) {
                $cells[$key] = ['x' => $visit['x'], 'y' => $visit['y'], 'visits' => 0, 'seconds' => 0];
            }

            $cells[$key]['visits']++;
            // Observed seconds only. A visit that opened and closed between two polls is
            // a real visit of zero measured duration, not a missing one.
            $cells[$key]['seconds'] += max(0, (int) $visit['e'] - (int) $visit['t']);

            $ships[$visit['s']] = true;
            $first = $first === null ? $visit['t'] : min($first, $visit['t']);
            $last = $last === null ? $visit['e'] : max($last, $visit['e']);
        }

        $maxVisits = 0;
        $maxSeconds = 0;
        foreach ($cells as $cell) {
            $maxVisits = max($maxVisits, $cell['visits']);
            $maxSeconds = max($maxSeconds, $cell['seconds']);
        }

        return [
            'cells' => array_values($cells),
            'maxVisits' => $maxVisits,
            'maxSeconds' => $maxSeconds,
            'ships' => array_keys($ships),
            'from' => $first,
            'to' => $last,
        ];
    }

    public function events(array $filter): array
    {
        $out = $this->scan(self::EVENTS, $filter);

        $limit = (int) ($filter['limit'] ?? 0);
        if ($limit > 0 && count($out) > $limit) {
            $out = array_slice($out, -$limit);
        }

        return $out;
    }

    /** What is on disk, per craft, so a client can show the shape of it before asking for any. */
    public function summary(): array
    {
        $ships = [];

        $note = static function (string $name, string $field, int $t, int $e) use (&$ships): void {
            if (!isset($ships[$name])) {
                $ships[$name] = ['name' => $name, 'visits' => 0, 'events' => 0,
                                 'sectors' => 0, 'first' => $t, 'last' => $e];
            }
            $ships[$name][$field]++;
            $ships[$name]['first'] = min($ships[$name]['first'], $t);
            $ships[$name]['last'] = max($ships[$name]['last'], $e);
        };

        $sectors = [];

        foreach ($this->scan(self::VISITS, []) as $visit) {
            $note($visit['s'], 'visits', (int) $visit['t'], (int) $visit['e']);
            $sectors[$visit['s']][$visit['x'] . ',' . $visit['y']] = true;
        }

        foreach ($this->openVisits() as $visit) {
            $note($visit['s'], 'visits', (int) $visit['t'], (int) $visit['e']);
            $sectors[$visit['s']][$visit['x'] . ',' . $visit['y']] = true;
        }

        foreach ($this->scan(self::EVENTS, []) as $event) {
            $note($event['s'], 'events', (int) $event['t'], (int) $event['t']);
        }

        foreach ($ships as $name => $_) {
            $ships[$name]['sectors'] = count($sectors[$name] ?? []);
        }

        ksort($ships);

        return [
            'ships' => array_values($ships),
            'bytes' => $this->bytes(),
            'retentionDays' => $this->retentionDays,
            'recording' => $this->exists(),
        ];
    }

    /** Removes everything stored for this key, or just one craft's share of it. */
    public function clear(?string $ship): array
    {
        if (!$this->exists()) {
            return ['cleared' => true, 'ship' => $ship, 'removed' => 0];
        }

        if ($ship === null) {
            $removed = 0;
            foreach ([self::VISITS, self::EVENTS, self::STATE, self::PRUNED] as $file) {
                $path = $this->dir . '/' . $file;
                if (is_file($path)) {
                    $removed++;
                    @unlink($path);
                }
            }

            return ['cleared' => true, 'ship' => null, 'removed' => $removed];
        }

        $removed = 0;
        foreach ([self::VISITS, self::EVENTS] as $file) {
            $removed += $this->rewrite($file, static function (array $row) use ($ship, &$removed): bool {
                return ($row['s'] ?? null) !== $ship;
            });
        }

        $this->withState(static function (array $state) use ($ship): array {
            unset($state['ships'][$ship], $state['seqs'][$ship]);
            return $state;
        });

        return ['cleared' => true, 'ship' => $ship, 'removed' => $removed];
    }

    /* -------------------------------- internals ----------------------------- */

    /** The visit each craft is in the middle of, which has not been written out yet. */
    private function openVisits(): array
    {
        $state = $this->readState();
        $out = [];

        foreach (($state['ships'] ?? []) as $name => $open) {
            if (!is_array($open)) {
                continue;
            }
            $out[] = [
                't' => (int) $open['t'],
                'e' => (int) $open['e'],
                's' => (string) $name,
                'x' => (int) $open['x'],
                'y' => (int) $open['y'],
                'o' => (string) ($open['o'] ?? ''),
                'open' => true,
            ];
        }

        return $out;
    }

    private function keep(array $row, array $filter): bool
    {
        if (isset($filter['ship']) && $filter['ship'] !== '' && ($row['s'] ?? null) !== $filter['ship']) {
            return false;
        }
        if (isset($filter['owner']) && $filter['owner'] !== '' && ($row['o'] ?? '') !== $filter['owner']) {
            return false;
        }

        $to = (int) ($row['e'] ?? $row['t'] ?? 0);
        $from = (int) ($row['t'] ?? 0);

        if (!empty($filter['from']) && $to < (int) $filter['from']) {
            return false;
        }
        if (!empty($filter['to']) && $from > (int) $filter['to']) {
            return false;
        }

        return true;
    }

    /** Streams one JSONL file, keeping the rows a filter accepts. */
    private function scan(string $file, array $filter): array
    {
        $path = $this->dir . '/' . $file;
        if (!is_file($path)) {
            return [];
        }

        $handle = @fopen($path, 'rb');
        if ($handle === false) {
            return [];
        }

        $out = [];

        while (($line = fgets($handle)) !== false) {
            $line = trim($line);
            if ($line === '') {
                continue;
            }

            $row = json_decode($line, true);
            // A line truncated by a torn write is dropped rather than failing the read.
            // Appends are locked, so this should not happen; if it does, one lost row is
            // a far better outcome than an unreadable history.
            if (!is_array($row)) {
                continue;
            }

            if ($this->keep($row, $filter)) {
                $out[] = $row;
            }
        }

        fclose($handle);

        return $out;
    }

    private function append(string $file, array $rows): void
    {
        if (!$this->ensureDir()) {
            return;
        }

        $blob = '';
        foreach ($rows as $row) {
            $encoded = json_encode($row, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
            if (is_string($encoded)) {
                $blob .= $encoded . "\n";
            }
        }

        if ($blob === '') {
            return;
        }

        // LOCK_EX around an append, so two PHP threads answering two calls at once cannot
        // interleave half-lines into the same file.
        @file_put_contents($this->dir . '/' . $file, $blob, FILE_APPEND | LOCK_EX);

        $this->maybePrune($file);
    }

    private function readState(): array
    {
        $raw = @file_get_contents($this->dir . '/' . self::STATE);
        if (!is_string($raw) || $raw === '') {
            return [];
        }

        $state = json_decode($raw, true);

        return is_array($state) ? $state : [];
    }

    /**
     * Read-modify-write of state.json under an exclusive lock.
     *
     * The state holds each craft's open visit and each craft's highest seen sequence
     * number, both of which two concurrent calls would otherwise clobber - and a lost
     * sequence mark means every event in between gets written twice.
     */
    private function withState(callable $fn): void
    {
        if (!$this->ensureDir()) {
            return;
        }

        $lock = @fopen($this->dir . '/' . self::LOCK, 'cb');
        if ($lock === false) {
            return;
        }

        @flock($lock, LOCK_EX);

        $state = $fn($this->readState());

        $encoded = json_encode($state, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
        if (is_string($encoded)) {
            @file_put_contents($this->dir . '/' . self::STATE, $encoded);
        }

        @flock($lock, LOCK_UN);
        fclose($lock);
    }

    private function ensureDir(): bool
    {
        if (is_dir($this->dir)) {
            return true;
        }

        // Suppressed: two threads racing to create the same directory is normal, and the
        // is_dir below is the real answer either way.
        @mkdir($this->dir, 0o770, true);

        return is_dir($this->dir);
    }

    private function bytes(): int
    {
        $total = 0;
        foreach ([self::VISITS, self::EVENTS, self::STATE] as $file) {
            $total += (int) @filesize($this->dir . '/' . $file);
        }

        return $total;
    }

    /**
     * Drops rows past the retention window, and past a hard size cap if the window alone
     * is not enough. Throttled hard: this rewrites a file, and doing it on every call
     * would turn a cheap append into an O(n) one.
     */
    private function maybePrune(string $file): void
    {
        $stamp = $this->dir . '/' . self::PRUNED;
        $last = (int) @filemtime($stamp);

        if ($last > 0 && time() - $last < self::PRUNE_EVERY) {
            return;
        }

        @touch($stamp);

        $cutoff = time() - $this->retentionDays * 86400;
        $this->rewrite($file, static fn (array $row): bool => (int) ($row['e'] ?? $row['t'] ?? 0) >= $cutoff);

        if ((int) @filesize($this->dir . '/' . $file) <= $this->maxBytes) {
            return;
        }

        // Still too large for the window alone - a single very busy month. Halve it,
        // oldest first, rather than letting one key fill the volume.
        $rows = $this->scan($file, []);
        $keep = array_slice($rows, (int) (count($rows) / 2));
        $this->replace($file, $keep);
    }

    /** Rewrites a file keeping the rows a predicate accepts. Returns how many went. */
    private function rewrite(string $file, callable $keep): int
    {
        $path = $this->dir . '/' . $file;
        if (!is_file($path)) {
            return 0;
        }

        $rows = $this->scan($file, []);
        $kept = array_values(array_filter($rows, $keep));

        if (count($kept) === count($rows)) {
            return 0;
        }

        $this->replace($file, $kept);

        return count($rows) - count($kept);
    }

    private function replace(string $file, array $rows): void
    {
        $blob = '';
        foreach ($rows as $row) {
            $encoded = json_encode($row, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
            if (is_string($encoded)) {
                $blob .= $encoded . "\n";
            }
        }

        // Write beside it and rename in. Unlike the mod - whose sandbox loses a renamed
        // file outright - this is an ordinary process, so the swap is atomic and a reader
        // never sees a half-rewritten log.
        $staged = $this->dir . '/' . $file . '.part';

        if (@file_put_contents($staged, $blob, LOCK_EX) === false) {
            @unlink($staged);
            return;
        }

        if (!@rename($staged, $this->dir . '/' . $file)) {
            @unlink($staged);
        }
    }
}
