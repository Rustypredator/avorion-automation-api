<?php

declare(strict_types=1);

require_once __DIR__ . '/db.php';
require_once __DIR__ . '/history.php';
require_once __DIR__ . '/push.php';

/**
 * Push notifications: what a player wants to be told about, and what has been sent.
 *
 * ### Why this lives in the bridge
 *
 * Because the mod cannot open a socket, and nothing about an alert is worth the game's
 * tick. The Lua side already publishes everything an alert could be built from - a ship's
 * order and status events, its hull and shield, whether there are enemies in its sector -
 * and the bridge is already keeping a durable copy of all of it in Postgres for the
 * history store. Rules over that copy cost the game server nothing at all.
 *
 * So the whole feature is: rows in this database, a loop that reads new events and decides
 * what crossed a line, and one HTTP POST per alert. src/notify.php is the loop and
 * src/push.php is the POST.
 *
 * ### Whose they are
 *
 * A notification belongs to a player, not to a faction - see db.php, version 5. History
 * rows are the other way round on purpose: what a craft did is shared by an alliance, but
 * who gets woken up at two in the morning is not. A rule may widen its scope to the
 * player's alliance craft with `alliance`, and is still that player's rule, sent to that
 * player's channels.
 *
 * Identity comes from History: the mod says which player a key belongs to, and an alliance
 * scope needs that answer to be current. A key the mod will not vouch for configures
 * nothing and receives nothing.
 *
 * ### What it can and cannot see
 *
 * Exactly what the poller has collected. The mod pushes nothing, its own event log is a
 * ring buffer, and player scripts only run while that player is online - so an alert is as
 * timely as POLL_INTERVAL and as complete as the poller's coverage. A fleet nobody is
 * polling raises nothing. That is the same limit the history store has, written down here
 * because a missed alert is more surprising than a gap in a heatmap.
 */
final class Notifications
{
    /**
     * What a rule can watch.
     *
     * Served to clients as-is at GET /notifications/kinds, so the console builds its form
     * from this rather than from a copy that drifts. `source` says where the answer comes
     * from and, with it, how the rule behaves:
     *
     *   events    point in time, out of the craft's event feed. Fires per event.
     *   level     a value that goes up and down. Fires on the way down past the
     *             threshold, and rearms once it has recovered past it again.
     *   fleet     the shape of the fleet itself, out of the craft listing.
     */
    public const KINDS = [
        'combat' => [
            'title' => 'Under attack',
            'source' => 'events',
            'about' => 'Enemies turned up in the craft\'s sector.',
            'options' => [
                'ends' => ['kind' => 'boolean', 'default' => false,
                           'title' => 'Also tell me when the fight is over'],
            ],
        ],
        'hull' => [
            'title' => 'Hull below',
            'source' => 'level',
            'about' => 'The craft\'s hull fell below a fraction of its maximum.',
            'options' => [
                'below' => ['kind' => 'fraction', 'default' => 0.5, 'title' => 'Hull left'],
            ],
        ],
        'shield' => [
            'title' => 'Shield below',
            'source' => 'level',
            'about' => 'The craft\'s shield fell below a fraction of its capacity.',
            'options' => [
                'below' => ['kind' => 'fraction', 'default' => 0.5, 'title' => 'Shield left'],
            ],
        ],
        'flee' => [
            'title' => 'Broke off and ran',
            'source' => 'events',
            'about' => 'The flee standing order took the craft out of a fight, and where '
                . 'it ended up.',
            'options' => [],
        ],
        'idle' => [
            'title' => 'Out of orders',
            'source' => 'events',
            'about' => 'The craft finished its chain and is sitting there.',
            'options' => [],
        ],
        'plan' => [
            'title' => 'Route or boss loop ended',
            'source' => 'events',
            'about' => 'A planned route or a boss farm finished, was refused, or was '
                . 'interrupted.',
            'options' => [],
        ],
        'boss' => [
            'title' => 'Boss spawned or killed',
            'source' => 'events',
            'about' => 'A boss turned up in the sector a craft is farming, or went down.',
            'options' => [],
        ],
        'status' => [
            'title' => 'Status message matches',
            'source' => 'events',
            'about' => 'The craft\'s own status line contains some text. The catch-all: '
                . '"no captain", "out of fuel", anything the game says.',
            'options' => [
                'contains' => ['kind' => 'text', 'default' => '',
                               'title' => 'Text to look for, case insensitive'],
            ],
        ],
        'gone' => [
            'title' => 'Craft gone',
            'source' => 'fleet',
            'about' => 'A craft that was in the fleet is not any more - destroyed, sold, '
                . 'or handed over. Note that it also fires if you leave the alliance whose '
                . 'craft it was.',
            'options' => [],
        ],
    ];

    /** Notifications kept per player. The log is a convenience, not a record. */
    private const LOG_KEEP = 500;

    /** Attempts at one undelivered notification before it is given up on. */
    private const MAX_ATTEMPTS = 6;

    /** Craft events read in one evaluation pass. */
    private const EVENT_PAGE = 2000;

    private ?PDO $pdo = null;

    public function __construct(private History $history)
    {
    }

    /* ------------------------------- identity ------------------------------- */

    /**
     * The player these notifications belong to, or null when the mod will not say who
     * this key is. Null is an answer, not an error: the caller turns it into a 401.
     */
    public function player(): ?int
    {
        $scope = $this->history->scope();
        $player = $scope['player'] ?? null;

        return is_int($player) ? $player : null;
    }

    /**
     * The factions a rule of this player may watch. The player always; their alliance
     * only when it wants it and only while the mod still confirms the membership - a
     * player who has left keeps their key, and should stop hearing about the fleet.
     *
     * @return list<int>
     */
    private function factions(bool $withAlliance): array
    {
        $scope = $this->history->scope();
        $factions = [];

        if (is_int($scope['player'] ?? null)) {
            $factions[] = $scope['player'];
        }
        if ($withAlliance && is_int($scope['alliance'] ?? null)) {
            $factions[] = $scope['alliance'];
        }

        return $factions;
    }

    /* -------------------------------- channels ------------------------------- */

    /**
     * Every channel of this player, without the tokens.
     *
     * A token is a credential this process has to be able to present, so unlike an API
     * key it cannot be stored as a hash - and that makes never handing it back the only
     * protection it has. `hasToken` is what a console needs to show the field as set.
     *
     * @return list<array<string, mixed>>
     */
    public function channels(): array
    {
        $player = $this->player();
        if ($player === null) {
            return [];
        }

        $out = [];

        foreach ($this->all('SELECT name, kind, url, config, enabled, token,
                                    EXTRACT(EPOCH FROM updated_at)::bigint AS updated
                             FROM notification_channels WHERE player = :p ORDER BY name',
                            [':p' => $player]) as $row) {
            $out[] = [
                'name' => (string) $row['name'],
                'kind' => (string) $row['kind'],
                'url' => (string) $row['url'],
                'config' => $this->decode((string) $row['config']),
                'enabled' => $this->truthy($row['enabled']),
                'hasToken' => (string) $row['token'] !== '',
                'updated' => (int) $row['updated'],
            ];
        }

        return $out;
    }

    /**
     * Creates a channel or replaces one of the same name.
     *
     * `token` left out of an update keeps the stored one, so a console can save the rest
     * of a channel without holding a secret it was never given. An empty string clears it.
     *
     * @param array<string, mixed> $input
     *
     * @return array{error?: array{status: int, code: string, message: string},
     *               channel?: array<string, mixed>}
     */
    public function saveChannel(array $input): array
    {
        $player = $this->player();
        if ($player === null) {
            return $this->unknownKey();
        }

        $name = $this->name($input['name'] ?? null);
        if ($name === null) {
            return $this->fail(400, 'bad_name', 'A channel needs a name of 1 to 48 characters.');
        }

        $existing = $this->one(
            'SELECT token, kind, url, config, enabled FROM notification_channels
             WHERE player = :p AND name = :n',
            [':p' => $player, ':n' => $name]
        );

        $kind = (string) ($input['kind'] ?? ($existing['kind'] ?? ''));
        $url = trim((string) ($input['url'] ?? ($existing['url'] ?? '')));

        $config = $input['config'] ?? null;
        if (!is_array($config)) {
            $config = $existing !== [] ? $this->decode((string) $existing['config']) : [];
        }

        // Left out means "keep what is stored", which is how a console saves a channel it
        // was never shown the token of. "" means clear it.
        $token = array_key_exists('token', $input)
            ? (string) $input['token']
            : (string) ($existing['token'] ?? '');

        $channel = ['kind' => $kind, 'url' => $url, 'token' => $token, 'config' => $config];

        $wrong = Push::invalid($channel);
        if ($wrong !== '') {
            return $this->fail(400, 'bad_channel', $wrong);
        }

        $enabled = $input['enabled']
            ?? ($existing === [] ? true : $this->truthy($existing['enabled']));
        if (!is_bool($enabled)) {
            return $this->fail(400, 'bad_channel', "'enabled' must be true or false.");
        }

        $this->exec(
            'INSERT INTO notification_channels (player, name, kind, url, token, config, enabled)
             VALUES (:p, :n, :k, :u, :t, CAST(:c AS jsonb), :e)
             ON CONFLICT (player, name) DO UPDATE
                 SET kind = EXCLUDED.kind, url = EXCLUDED.url, token = EXCLUDED.token,
                     config = EXCLUDED.config, enabled = EXCLUDED.enabled, updated_at = now()',
            [':p' => $player, ':n' => $name, ':k' => $kind, ':u' => $url, ':t' => $token,
             ':c' => $this->encode((object) $config), ':e' => $enabled ? 1 : 0]
        );

        foreach ($this->channels() as $saved) {
            if ($saved['name'] === $name) {
                return ['channel' => $saved];
            }
        }

        return ['channel' => []];
    }

    /**
     * @return array{error?: array{status: int, code: string, message: string},
     *               removed?: bool, rules?: list<string>}
     */
    public function deleteChannel(string $name): array
    {
        $player = $this->player();
        if ($player === null) {
            return $this->unknownKey();
        }

        /*
         * Rules name their channels by name rather than by id, so deleting one leaves any
         * rule that named it sending to nothing. Say which, rather than silently making
         * some of the player's alerts stop arriving - that is precisely the failure this
         * whole feature exists to avoid.
         */
        $orphaned = [];
        foreach ($this->rules() as $rule) {
            if (in_array($name, $rule['channels'], true)) {
                $orphaned[] = $rule['name'];
            }
        }

        $removed = $this->exec(
            'DELETE FROM notification_channels WHERE player = :p AND name = :n',
            [':p' => $player, ':n' => $name]
        );

        return ['removed' => $removed > 0, 'rules' => $orphaned];
    }

    /* --------------------------------- rules --------------------------------- */

    /**
     * @return list<array<string, mixed>>
     */
    public function rules(): array
    {
        $player = $this->player();
        if ($player === null) {
            return [];
        }

        $out = [];

        foreach ($this->all('SELECT id, name, kind, enabled, ship, alliance, config, channels,
                                    priority, quiet,
                                    EXTRACT(EPOCH FROM updated_at)::bigint AS updated
                             FROM notification_rules WHERE player = :p ORDER BY name',
                            [':p' => $player]) as $row) {
            $channels = $this->decode((string) $row['channels']);

            $out[] = [
                'id' => (int) $row['id'],
                'name' => (string) $row['name'],
                'kind' => (string) $row['kind'],
                'enabled' => $this->truthy($row['enabled']),
                // "" is every craft in scope, which is the useful default for "tell me
                // when anything of mine is in trouble".
                'ship' => (string) $row['ship'],
                'alliance' => $this->truthy($row['alliance']),
                'config' => $this->decode((string) $row['config']),
                'channels' => array_values(array_filter($channels, 'is_string')),
                'priority' => (int) $row['priority'],
                'quiet' => (int) $row['quiet'],
                'updated' => (int) $row['updated'],
            ];
        }

        return $out;
    }

    /**
     * @param array<string, mixed> $input
     *
     * @return array{error?: array{status: int, code: string, message: string},
     *               rule?: array<string, mixed>}
     */
    public function saveRule(array $input): array
    {
        $player = $this->player();
        if ($player === null) {
            return $this->unknownKey();
        }

        $name = $this->name($input['name'] ?? null);
        if ($name === null) {
            return $this->fail(400, 'bad_name', 'A rule needs a name of 1 to 48 characters.');
        }

        $existing = $this->one(
            'SELECT kind, ship, alliance, config, channels, priority, quiet, enabled
             FROM notification_rules WHERE player = :p AND name = :n',
            [':p' => $player, ':n' => $name]
        );

        $kind = (string) ($input['kind'] ?? ($existing['kind'] ?? ''));
        if (!isset(self::KINDS[$kind])) {
            return $this->fail(400, 'bad_kind',
                'A rule watches one of: ' . implode(', ', array_keys(self::KINDS)) . '.');
        }

        $config = $input['config'] ?? null;
        if (!is_array($config)) {
            $config = $existing !== [] ? $this->decode((string) $existing['config']) : [];
        }

        $wrong = $this->checkConfig($kind, $config);
        if ($wrong !== '') {
            return $this->fail(400, 'bad_config', $wrong);
        }

        $channels = $input['channels'] ?? null;
        if (!is_array($channels)) {
            $channels = $existing !== [] ? $this->decode((string) $existing['channels']) : [];
        }
        $channels = array_values(array_filter($channels, 'is_string'));

        // An empty list is "every channel I have", which keeps a one-channel setup - the
        // common one - from needing the channel named on every rule.
        $known = array_column($this->channels(), 'name');
        foreach ($channels as $channel) {
            if (!in_array($channel, $known, true)) {
                return $this->fail(404, 'no_such_channel',
                    'There is no channel called "' . $channel . '".');
            }
        }

        $ship = trim((string) ($input['ship'] ?? ($existing['ship'] ?? '')));
        if (strlen($ship) > 200) {
            return $this->fail(400, 'bad_ship', 'A craft name is at most 200 characters.');
        }

        $priority = (int) ($input['priority'] ?? ($existing['priority'] ?? 3));
        if ($priority < 1 || $priority > 5) {
            return $this->fail(400, 'bad_priority', "'priority' is 1 to 5.");
        }

        $quiet = (int) ($input['quiet'] ?? ($existing['quiet'] ?? 300));
        if ($quiet < 0 || $quiet > 86400) {
            return $this->fail(400, 'bad_quiet', "'quiet' is seconds, 0 to 86400.");
        }

        foreach (['enabled', 'alliance'] as $flag) {
            if (array_key_exists($flag, $input) && !is_bool($input[$flag])) {
                return $this->fail(400, 'bad_rule', "'" . $flag . "' must be true or false.");
            }
        }

        $enabled = $input['enabled'] ?? ($existing === [] ? true : $this->truthy($existing['enabled']));
        $alliance = $input['alliance'] ?? ($existing === [] ? false : $this->truthy($existing['alliance']));

        if ($alliance && !is_int($this->history->scope()['alliance'] ?? null)) {
            return $this->fail(409, 'no_alliance',
                'The mod does not currently report you as being in an alliance, so a rule '
                . 'cannot watch one.');
        }

        $this->exec(
            'INSERT INTO notification_rules
                 (player, name, kind, enabled, ship, alliance, config, channels, priority, quiet)
             VALUES (:p, :n, :k, :e, :s, :a, CAST(:c AS jsonb), CAST(:h AS jsonb), :r, :q)
             ON CONFLICT (player, name) DO UPDATE
                 SET kind = EXCLUDED.kind, enabled = EXCLUDED.enabled, ship = EXCLUDED.ship,
                     alliance = EXCLUDED.alliance, config = EXCLUDED.config,
                     channels = EXCLUDED.channels, priority = EXCLUDED.priority,
                     quiet = EXCLUDED.quiet, updated_at = now()',
            [':p' => $player, ':n' => $name, ':k' => $kind, ':e' => $enabled ? 1 : 0,
             ':s' => $ship, ':a' => $alliance ? 1 : 0, ':c' => $this->encode((object) $config),
             ':h' => $this->encode($channels), ':r' => $priority, ':q' => $quiet]
        );

        foreach ($this->rules() as $saved) {
            if ($saved['name'] === $name) {
                return ['rule' => $saved];
            }
        }

        return ['rule' => []];
    }

    /**
     * @return array{error?: array{status: int, code: string, message: string}, removed?: bool}
     */
    public function deleteRule(string $name): array
    {
        $player = $this->player();
        if ($player === null) {
            return $this->unknownKey();
        }

        $removed = $this->exec('DELETE FROM notification_rules WHERE player = :p AND name = :n',
                               [':p' => $player, ':n' => $name]);

        return ['removed' => $removed > 0];
    }

    /**
     * What a rule's options have to look like. Kept next to the catalogue rather than
     * spread through the evaluation, so a kind is described in exactly one place.
     *
     * @param array<string, mixed> $config
     */
    private function checkConfig(string $kind, array $config): string
    {
        foreach ($config as $option => $value) {
            if (!isset(self::KINDS[$kind]['options'][$option])) {
                $known = array_keys(self::KINDS[$kind]['options']);

                return $known === []
                    ? 'The "' . $kind . '" rule takes no options.'
                    : 'The "' . $kind . '" rule takes only: ' . implode(', ', $known) . '.';
            }

            $wanted = self::KINDS[$kind]['options'][$option]['kind'];

            if ($wanted === 'boolean' && !is_bool($value)) {
                return "'" . $option . "' must be true or false.";
            }
            if ($wanted === 'text' && (!is_string($value) || strlen($value) > 200)) {
                return "'" . $option . "' is text of at most 200 characters.";
            }
            if ($wanted === 'fraction') {
                if (!is_numeric($value) || $value <= 0 || $value > 100) {
                    return "'" . $option . "' is a fraction from 0 to 1, or a percentage "
                        . 'up to 100.';
                }
            }
        }

        if ($kind === 'status' && trim((string) ($config['contains'] ?? '')) === '') {
            return "A 'status' rule needs 'contains' set to the text to look for.";
        }

        return '';
    }

    /**
     * A rule's threshold as a fraction. Percentages are accepted the same way the mod
     * accepts them for the flee order, because a person thinks in percent.
     */
    private function threshold(array $config, float $fallback): float
    {
        $value = (float) ($config['below'] ?? $fallback);
        if ($value > 1) {
            $value /= 100;
        }

        return max(0.0, min(1.0, $value));
    }

    /* ------------------------------- the log --------------------------------- */

    /**
     * @return list<array<string, mixed>>
     */
    public function log(int $limit = 50): array
    {
        $player = $this->player();
        if ($player === null) {
            return [];
        }

        $out = [];

        foreach ($this->all(
            'SELECT rule, kind, ship, title, body, priority, data,
                    EXTRACT(EPOCH FROM created_at)::bigint AS created,
                    EXTRACT(EPOCH FROM delivered_at)::bigint AS delivered,
                    attempts, error
             FROM notifications WHERE player = :p ORDER BY id DESC LIMIT :l',
            [':p' => $player, ':l' => max(1, min(500, $limit))]
        ) as $row) {
            $out[] = [
                'rule' => (string) $row['rule'],
                'kind' => (string) $row['kind'],
                'ship' => (string) $row['ship'],
                'title' => (string) $row['title'],
                'body' => (string) $row['body'],
                'priority' => (int) $row['priority'],
                'data' => $this->decode((string) $row['data']),
                'at' => (int) $row['created'],
                'delivered' => $row['delivered'] !== null ? (int) $row['delivered'] : null,
                'attempts' => (int) $row['attempts'],
                'error' => (string) $row['error'],
            ];
        }

        return $out;
    }

    /**
     * Everything a console needs to draw the whole view in one call.
     *
     * @return array<string, mixed>
     */
    public function summary(): array
    {
        $player = $this->player();

        return [
            'player' => $player,
            'alliance' => $this->history->scope()['alliance'] ?? null,
            'channels' => $this->channels(),
            'rules' => $this->rules(),
            'log' => $this->log(50),
            'kinds' => self::KINDS,
            'channelKinds' => Push::KINDS,
            // A rule can only fire off events something has collected. Say so here rather
            // than letting a player conclude the rules are broken.
            'pending' => $player === null ? 0 : (int) ($this->one(
                'SELECT COUNT(*)::bigint AS n FROM notifications
                 WHERE player = :p AND delivered_at IS NULL',
                [':p' => $player]
            )['n'] ?? 0),
        ];
    }

    /* ------------------------------- raising --------------------------------- */

    /**
     * Puts one notification in the outbox. Returns its id, or 0 when it was not raised.
     *
     * @param array<string, mixed> $note
     */
    public function raise(int $player, array $note, ?int $ruleId = null): int
    {
        $row = $this->one(
            'INSERT INTO notifications
                 (player, rule_id, rule, kind, ship, title, body, priority, data, next_try)
             VALUES (:p, :i, :r, :k, :s, :t, :b, :y, CAST(:d AS jsonb), now())
             RETURNING id',
            [':p' => $player, ':i' => $ruleId, ':r' => (string) ($note['rule'] ?? ''),
             ':k' => (string) ($note['kind'] ?? ''), ':s' => (string) ($note['ship'] ?? ''),
             ':t' => (string) $note['title'], ':b' => (string) ($note['body'] ?? ''),
             ':y' => max(1, min(5, (int) ($note['priority'] ?? 3))),
             ':d' => $this->encode((object) ($note['data'] ?? []))]
        );

        return (int) ($row['id'] ?? 0);
    }

    /**
     * Sends a test notification to one channel, or to every enabled channel.
     *
     * Delivered inline rather than queued: whoever pressed the button is waiting to find
     * out whether the channel works, and "it will be attempted shortly" is not an answer.
     *
     * @return array{error?: array{status: int, code: string, message: string},
     *               results?: list<array<string, mixed>>}
     */
    public function test(?string $only = null): array
    {
        $player = $this->player();
        if ($player === null) {
            return $this->unknownKey();
        }

        $note = [
            'rule' => 'test',
            'kind' => 'test',
            'ship' => '',
            'title' => 'Automation API',
            'body' => 'This is a test notification. Your channel works.',
            'priority' => 3,
            'data' => ['test' => true],
        ];

        $results = [];
        $found = false;

        foreach ($this->sendable($player) as $channel) {
            if ($only !== null && $channel['name'] !== $only) {
                continue;
            }
            $found = true;

            $sent = Push::send($channel, $note);
            $results[] = [
                'channel' => $channel['name'],
                'ok' => $sent['ok'],
                'status' => $sent['status'],
                'error' => $sent['error'],
            ];
        }

        if (!$found) {
            return $this->fail(404, 'no_channel', $only !== null
                ? 'There is no enabled channel called "' . $only . '".'
                : 'You have no enabled channels to send to.');
        }

        return ['results' => $results];
    }

    /* ------------------------------ delivering ------------------------------- */

    /**
     * Sends what is waiting, for every player, and returns how many went out.
     *
     * Not scoped to one player: this is the notifier's half, and one loop drains the
     * whole outbox. A send that fails is backed off rather than retried immediately - a
     * push server that is down stays down for minutes, not milliseconds - and given up on
     * after MAX_ATTEMPTS, because a notification about a fight an hour ago is noise.
     *
     * @return array{sent: int, failed: int}
     */
    public function deliver(int $limit = 100): array
    {
        $pending = $this->all(
            'SELECT id, player, rule, kind, ship, title, body, priority, data, attempts
             FROM notifications
             WHERE delivered_at IS NULL AND attempts < :m AND (next_try IS NULL OR next_try <= now())
             ORDER BY id LIMIT :l',
            [':m' => self::MAX_ATTEMPTS, ':l' => max(1, min(1000, $limit))]
        );

        $sent = 0;
        $failed = 0;
        $channels = [];

        foreach ($pending as $row) {
            $player = (int) $row['player'];
            $channels[$player] ??= $this->sendable($player);

            $note = [
                'rule' => (string) $row['rule'],
                'kind' => (string) $row['kind'],
                'ship' => (string) $row['ship'],
                'title' => (string) $row['title'],
                'body' => (string) $row['body'],
                'priority' => (int) $row['priority'],
                'data' => $this->decode((string) $row['data']),
            ];

            $wanted = $this->decode((string) $row['data'])['channels'] ?? [];
            $errors = [];
            $delivered = false;
            $tried = false;

            foreach ($channels[$player] as $channel) {
                if (is_array($wanted) && $wanted !== []
                    && !in_array($channel['name'], $wanted, true)) {
                    continue;
                }

                $tried = true;
                $result = Push::send($channel, $note);

                // One channel that works is a delivered notification. The point is that
                // the player hears about it, not that every route succeeded.
                if ($result['ok']) {
                    $delivered = true;
                } else {
                    $errors[] = $channel['name'] . ': ' . $result['error'];
                }
            }

            if (!$tried) {
                $errors[] = 'no channel to send to';
            }

            if ($delivered) {
                $sent++;
                $this->exec(
                    'UPDATE notifications SET delivered_at = now(), attempts = attempts + 1,
                            error = :e WHERE id = :i',
                    [':i' => (int) $row['id'], ':e' => implode('; ', $errors)]
                );
                continue;
            }

            $failed++;
            $attempts = (int) $row['attempts'] + 1;

            // 30s, 60s, 2m, 4m, 8m. Long enough to sit out a restart, short enough that a
            // notification still means something when it arrives.
            $backoff = 30 * (2 ** min(4, $attempts - 1));

            $this->exec(
                "UPDATE notifications SET attempts = :a, error = :e,
                        next_try = now() + (:b || ' seconds')::interval WHERE id = :i",
                [':i' => (int) $row['id'], ':a' => $attempts,
                 ':e' => implode('; ', $errors), ':b' => (string) $backoff]
            );
        }

        return ['sent' => $sent, 'failed' => $failed];
    }

    /**
     * One player's channels, ready to send through, tokens and all.
     *
     * @return list<array<string, mixed>>
     */
    private function sendable(int $player): array
    {
        $out = [];

        foreach ($this->all('SELECT name, kind, url, token, config FROM notification_channels
                             WHERE player = :p AND enabled ORDER BY name',
                            [':p' => $player]) as $row) {
            $out[] = [
                'name' => (string) $row['name'],
                'kind' => (string) $row['kind'],
                'url' => (string) $row['url'],
                'token' => (string) $row['token'],
                'config' => $this->decode((string) $row['config']),
            ];
        }

        return $out;
    }

    /* ------------------------------ evaluating ------------------------------- */

    /**
     * Runs this player's rules over what has happened since the last pass.
     *
     * `$fleet` is a decoded GET /ships answer - the craft listing, which carries each
     * craft's position, status and condition and keeps working with everyone logged out.
     * Everything else comes out of the `events` table, which the poller fills.
     *
     * @param list<object> $fleet
     *
     * @return array{raised: int, events: int}
     */
    public function evaluate(array $fleet): array
    {
        $player = $this->player();
        if ($player === null) {
            return ['raised' => 0, 'events' => 0];
        }

        $rules = array_values(array_filter($this->rules(), static fn (array $r): bool => $r['enabled']));
        if ($rules === []) {
            // Still move the cursor, or switching a rule on would replay a week of events.
            $this->skipEvents($player);

            return ['raised' => 0, 'events' => 0];
        }

        /*
         * Every faction in scope, whether or not a rule currently wants the alliance's.
         *
         * Tempting to read only what is asked for, and wrong: the cursor is one number
         * per player, so leaving the alliance's events unread would leave it pointing at
         * an id in the middle of them. Switching an alliance rule on would then replay
         * however many of them had piled up since - which is the one thing the cursor
         * exists to prevent. What each rule may see is decided per rule, in covers().
         */
        $factions = $this->factions(true);
        if ($factions === []) {
            return ['raised' => 0, 'events' => 0];
        }

        [$events, $cursor] = $this->newEvents($player, $factions);

        // Craft by name, with the owner kind, so a rule that does not want the alliance's
        // craft can leave them out without a second listing.
        $craft = [];
        foreach ($fleet as $entry) {
            if (is_object($entry) && is_string($entry->name ?? null)) {
                $craft[$entry->name] = $entry;
            }
        }

        $raised = 0;

        foreach ($rules as $rule) {
            $raised += self::KINDS[$rule['kind']]['source'] === 'level'
                ? $this->evaluateLevel($player, $rule, $craft, $events)
                : ($rule['kind'] === 'gone'
                    ? $this->evaluateGone($player, $rule, $craft)
                    : $this->evaluateEvents($player, $rule, $events));
        }

        if ($cursor > 0) {
            $this->exec(
                'INSERT INTO notification_watch (player, last_event) VALUES (:p, :c)
                 ON CONFLICT (player) DO UPDATE SET last_event = EXCLUDED.last_event,
                                                    updated_at = now()',
                [':p' => $player, ':c' => $cursor]
            );
        }

        return ['raised' => $raised, 'events' => count($events)];
    }

    /**
     * Craft events this player has not been shown yet.
     *
     * @param list<int> $factions
     *
     * @return array{0: list<array<string, mixed>>, 1: int}
     */
    private function newEvents(int $player, array $factions): array
    {
        $since = (int) ($this->one('SELECT last_event FROM notification_watch WHERE player = :p',
                                   [':p' => $player])['last_event'] ?? 0);

        /*
         * A player who has never been evaluated starts from now rather than from the
         * beginning of the history. Replaying a month of events as push notifications the
         * first time somebody writes a rule would be a memorable way to lose a user.
         */
        if ($since === 0) {
            $newest = (int) ($this->one('SELECT COALESCE(MAX(id), 0) AS id FROM events', [])['id'] ?? 0);
            $this->exec(
                'INSERT INTO notification_watch (player, last_event) VALUES (:p, :c)
                 ON CONFLICT (player) DO UPDATE SET last_event = EXCLUDED.last_event',
                [':p' => $player, ':c' => $newest]
            );

            return [[], 0];
        }

        $places = [];
        $args = [':s' => $since];
        foreach (array_values($factions) as $index => $faction) {
            $places[] = ':f' . $index;
            $args[':f' . $index] = $faction;
        }

        $rows = $this->all(
            'SELECT id, ship, owner, data, EXTRACT(EPOCH FROM happened_at)::bigint AS at
             FROM events WHERE id > :s AND faction IN (' . implode(', ', $places) . ')
             ORDER BY id LIMIT ' . self::EVENT_PAGE,
            $args
        );

        $events = [];
        $cursor = $since;

        foreach ($rows as $row) {
            $cursor = max($cursor, (int) $row['id']);
            $events[] = [
                'ship' => (string) $row['ship'],
                'owner' => (string) $row['owner'],
                'at' => (int) $row['at'],
                'data' => $this->decode((string) $row['data']),
            ];
        }

        return [$events, $cursor];
    }

    /** Moves the cursor past everything without looking at it. */
    private function skipEvents(int $player): void
    {
        $newest = (int) ($this->one('SELECT COALESCE(MAX(id), 0) AS id FROM events', [])['id'] ?? 0);

        $this->exec(
            'INSERT INTO notification_watch (player, last_event) VALUES (:p, :c)
             ON CONFLICT (player) DO UPDATE SET last_event = EXCLUDED.last_event, updated_at = now()',
            [':p' => $player, ':c' => $newest]
        );
    }

    /** Whether a rule cares about this craft at all. */
    private function covers(array $rule, string $ship, string $owner): bool
    {
        if ($rule['ship'] !== '' && $rule['ship'] !== $ship) {
            return false;
        }

        return $owner !== 'alliance' || $rule['alliance'];
    }

    /**
     * The point-in-time kinds, one pass over the new events.
     *
     * @param array<string, mixed> $rule
     * @param list<array<string, mixed>> $events
     */
    private function evaluateEvents(int $player, array $rule, array $events): int
    {
        $raised = 0;

        foreach ($events as $event) {
            if (!$this->covers($rule, $event['ship'], $event['owner'])) {
                continue;
            }

            $note = match ($rule['kind']) {
                'combat' => $this->combatOf($rule, $event),
                'flee' => $this->fleeOf($rule, $event),
                'idle' => $this->idleOf($rule, $event),
                'plan' => $this->planOf($rule, $event),
                'boss' => $this->bossOf($rule, $event),
                'status' => $this->statusOf($rule, $event),
                default => null,
            };

            if ($note !== null && $this->fire($player, $rule, $event['ship'], $note)) {
                $raised++;
            }
        }

        return $raised;
    }

    /**
     * Enemies in the sector, as the ship itself reports them.
     *
     * Edge-triggered off the mark rather than off the event, because the ship republishes
     * its state for all sorts of reasons and only the change from quiet to not is news.
     *
     * @return array<string, mixed>|null
     */
    private function combatOf(array $rule, array $event): ?array
    {
        $automation = $event['data']['automation'] ?? null;
        if (!is_array($automation) || !array_key_exists('enemies', $automation)) {
            return null;
        }

        $fighting = $automation['enemies'] === true;
        $mark = $this->mark($rule['id'], $event['ship']);

        if ($fighting === $mark['firing']) {
            return null;
        }

        $this->setMark($rule['id'], $event['ship'], ['firing' => $fighting]);

        if (!$fighting) {
            if (($rule['config']['ends'] ?? false) !== true) {
                return null;
            }

            return ['title' => $event['ship'] . ' is clear',
                    'body' => 'No enemies left in ' . $this->where($automation) . '.',
                    'force' => true];
        }

        return [
            'title' => $event['ship'] . ' is under attack',
            'body' => 'Enemies in ' . $this->where($automation) . '.'
                . $this->condition($automation),
            'force' => true,
        ];
    }

    /**
     * @return array<string, mixed>|null
     */
    private function fleeOf(array $rule, array $event): ?array
    {
        $automation = $event['data']['automation'] ?? null;
        if (!is_array($automation)) {
            return null;
        }

        $mark = $this->mark($rule['id'], $event['ship']);
        $running = is_array($automation['flee'] ?? null);

        if ($running && !$mark['firing']) {
            $this->setMark($rule['id'], $event['ship'], ['firing' => true]);
            $flee = $automation['flee'];

            return [
                'title' => $event['ship'] . ' is running',
                'body' => sprintf('Broke off in %s: %s below the threshold.%s',
                    $this->where($automation),
                    (string) ($flee['reason'] ?? 'hull'),
                    $this->condition($automation)),
                'force' => true,
            ];
        }

        if (!$running && $mark['firing']) {
            $this->setMark($rule['id'], $event['ship'], ['firing' => false]);
            $last = $automation['lastFlee'] ?? null;

            if (!is_array($last)) {
                return null;
            }

            $outcome = (string) ($last['outcome'] ?? '');
            $where = is_array($last['sector'] ?? null)
                ? sprintf('(%d:%d)', (int) $last['sector']['x'], (int) $last['sector']['y'])
                : 'somewhere';

            return [
                'title' => $event['ship'] . ' ' . match ($outcome) {
                    'arrived', 'escaped' => 'got away',
                    'failed' => 'could not get away',
                    default => 'stopped running',
                },
                'body' => match ($outcome) {
                    'arrived', 'escaped' => 'It is in ' . $where . ' now.',
                    'failed' => 'It is still in ' . $where . ': '
                        . (string) ($last['detail'] ?? 'no way out'),
                    default => 'The flee ended in ' . $where . ' (' . $outcome . ').',
                },
                // Not getting away is the one worth waking up for.
                'priority' => $outcome === 'failed' ? min(5, $rule['priority'] + 1) : null,
                'force' => true,
            ];
        }

        return null;
    }

    /**
     * @return array<string, mixed>|null
     */
    private function idleOf(array $rule, array $event): ?array
    {
        if (($event['data']['kind'] ?? '') !== 'order') {
            return null;
        }

        $idle = ($event['data']['idle'] ?? false) === true;
        $mark = $this->mark($rule['id'], $event['ship']);

        if ($idle === $mark['firing']) {
            return null;
        }

        $this->setMark($rule['id'], $event['ship'], ['firing' => $idle]);
        if (!$idle) {
            return null;
        }

        $automation = is_array($event['data']['automation'] ?? null) ? $event['data']['automation'] : [];

        return [
            'title' => $event['ship'] . ' is out of orders',
            'body' => 'It finished its chain in ' . $this->where($automation) . '.',
        ];
    }

    /**
     * @return array<string, mixed>|null
     */
    private function planOf(array $rule, array $event): ?array
    {
        $last = $event['data']['automation']['last'] ?? null;
        if (!is_array($last) || !is_string($last['id'] ?? null)) {
            return null;
        }

        $mark = $this->mark($rule['id'], $event['ship']);
        if ($mark['token'] === $last['id']) {
            return null;
        }

        $this->setMark($rule['id'], $event['ship'], ['token' => (string) $last['id']]);

        $outcome = (string) ($last['outcome'] ?? 'ended');
        $kind = (string) ($last['kind'] ?? 'plan');
        $where = is_array($last['sector'] ?? null)
            ? sprintf(' in (%d:%d)', (int) $last['sector']['x'], (int) $last['sector']['y'])
            : '';

        return [
            'title' => $event['ship'] . ': ' . $kind . ' ' . $outcome,
            'body' => trim(sprintf('The %s ended%s. %s', $kind, $where,
                (string) ($last['reason'] ?? ''))),
        ];
    }

    /**
     * @return array<string, mixed>|null
     */
    private function bossOf(array $rule, array $event): ?array
    {
        $automation = $event['data']['automation'] ?? null;
        if (!is_array($automation)) {
            return null;
        }

        $plan = is_array($automation['plan'] ?? null) ? $automation['plan'] : [];
        $present = is_array($plan['bossPresent'] ?? null) ? $plan['bossPresent'] : null;
        $killed = is_array($plan['lastKill'] ?? null) ? $plan['lastKill'] : null;

        /*
         * Both halves in one token, "<boss here>/<kills so far>", because they are two
         * changes to the same thing and a farm loop goes round them over and over. The
         * kill counter is what makes the second one detectable: lastKill on its own stays
         * set between kills, so it says which boss died and never that another one has.
         */
        $here = $present !== null ? (string) ($present['name'] ?? '?') : '';
        $kills = (string) ($plan['bossKills'] ?? '');
        $token = $here . '/' . $kills;

        if ($here === '' && $kills === '') {
            return null;
        }

        $mark = $this->mark($rule['id'], $event['ship']);
        if ($mark['token'] === $token) {
            return null;
        }

        [$wasHere, $wasKills] = array_pad(explode('/', $mark['token'], 2), 2, '');
        $this->setMark($rule['id'], $event['ship'], ['token' => $token]);

        // Nothing was known about this craft before, so there is no change to report -
        // only a first sighting of whatever state it happens to be in.
        if ($mark['token'] === '') {
            return null;
        }

        if ($kills !== $wasKills && $killed !== null) {
            return [
                'title' => 'Boss down',
                'body' => sprintf('%s killed %s in %s.', $event['ship'],
                    (string) ($killed['title'] ?? $killed['name'] ?? 'the boss'),
                    $this->where($automation)),
            ];
        }

        if ($here === '' || $here === $wasHere) {
            return null;
        }

        return [
            'title' => 'Boss spawned',
            'body' => sprintf('%s is in %s with %s.', $event['ship'],
                $this->where($automation),
                (string) ($present['title'] ?? $present['name'] ?? 'a boss')),
            'priority' => min(5, $rule['priority'] + 1),
        ];
    }

    /**
     * @return array<string, mixed>|null
     */
    private function statusOf(array $rule, array $event): ?array
    {
        if (($event['data']['kind'] ?? '') !== 'status') {
            return null;
        }

        $text = trim((string) ($event['data']['text'] ?? ''));
        $wanted = trim((string) ($rule['config']['contains'] ?? ''));

        if ($text === '' || $wanted === '' || stripos($text, $wanted) === false) {
            return null;
        }

        return ['title' => $event['ship'], 'body' => $text];
    }

    /**
     * Hull and shield: a value that moves, so the rule fires on the way down and rearms
     * once the craft has recovered past the line again.
     *
     * Two sources, and the newer wins. The craft listing reads the ship database row,
     * which the game rewrites when it saves - reliable, and minutes old. The craft's own
     * automation feed carries the live number while its sector is loaded, which is
     * precisely when it is being shot at.
     *
     * @param array<string, object> $craft
     * @param list<array<string, mixed>> $events
     */
    private function evaluateLevel(int $player, array $rule, array $craft, array $events): int
    {
        $field = $rule['kind'];
        $below = $this->threshold($rule['config'], 0.5);
        $values = [];

        foreach ($craft as $name => $entry) {
            $owner = is_object($entry->owner ?? null) ? (string) ($entry->owner->kind ?? '') : '';
            if (!$this->covers($rule, (string) $name, $owner)) {
                continue;
            }

            $value = $entry->condition->{$field} ?? null;
            if (is_numeric($value)) {
                $values[(string) $name] = (float) $value;
            }
        }

        foreach ($events as $event) {
            if (!$this->covers($rule, $event['ship'], $event['owner'])) {
                continue;
            }

            $vitals = $event['data']['automation']['vitals'] ?? null;
            if (is_array($vitals) && is_numeric($vitals[$field] ?? null)) {
                $values[$event['ship']] = (float) $vitals[$field];
            }
        }

        $raised = 0;

        foreach ($values as $ship => $value) {
            $mark = $this->mark($rule['id'], (string) $ship);
            $firing = $mark['firing'];

            /*
             * Rearming needs a margin, or a craft sitting exactly on the line would fire
             * every time a regenerating shield ticked past it. 5% is the resolution the
             * ship publishes at, so it is the smallest margin that means anything.
             */
            if ($firing && $value >= $below + 0.05) {
                $this->setMark($rule['id'], (string) $ship, ['firing' => false, 'value' => $value]);
                continue;
            }

            if ($firing || $value >= $below) {
                $this->setMark($rule['id'], (string) $ship, ['value' => $value]);
                continue;
            }

            $this->setMark($rule['id'], (string) $ship, ['firing' => true, 'value' => $value]);

            $note = [
                'title' => sprintf('%s: %s at %d%%', $ship, $field, (int) round($value * 100)),
                'body' => sprintf('%s is below %d%% and was %s.',
                    ucfirst($field), (int) round($below * 100),
                    $mark['value'] === null ? 'not being watched' : (int) round($mark['value'] * 100) . '%'),
                'force' => true,
            ];

            if ($this->fire($player, $rule, (string) $ship, $note)) {
                $raised++;
            }
        }

        return $raised;
    }

    /**
     * A craft that was in the fleet and is not any more.
     *
     * The mark is what "was in the fleet" means, so nothing fires until a craft has been
     * seen at least once. An empty listing raises nothing at all: that is far more likely
     * to be a mod that is reloading than a fleet that was wiped out in one pass.
     *
     * @param array<string, object> $craft
     */
    private function evaluateGone(int $player, array $rule, array $craft): int
    {
        if ($craft === []) {
            return 0;
        }

        $raised = 0;

        foreach ($craft as $name => $entry) {
            $owner = is_object($entry->owner ?? null) ? (string) ($entry->owner->kind ?? '') : '';
            if ($this->covers($rule, (string) $name, $owner)) {
                $this->setMark($rule['id'], (string) $name, ['firing' => true]);
            }
        }

        $seen = $this->all(
            'SELECT subject FROM notification_marks WHERE rule_id = :r AND firing',
            [':r' => $rule['id']]
        );

        foreach ($seen as $row) {
            $ship = (string) $row['subject'];
            if (isset($craft[$ship])) {
                continue;
            }

            $this->exec('DELETE FROM notification_marks WHERE rule_id = :r AND subject = :s',
                        [':r' => $rule['id'], ':s' => $ship]);

            if ($this->fire($player, $rule, $ship, [
                'title' => $ship . ' is gone',
                'body' => 'It is no longer in the fleet listing - destroyed, sold, or '
                    . 'handed to somebody else.',
                'force' => true,
            ])) {
                $raised++;
            }
        }

        return $raised;
    }

    /**
     * Raises one notification for a rule, unless the quiet period says not to.
     *
     * @param array<string, mixed> $rule
     * @param array<string, mixed> $note
     */
    private function fire(int $player, array $rule, string $ship, array $note): bool
    {
        if ($rule['quiet'] > 0) {
            $recent = $this->one(
                "SELECT 1 AS hit FROM notifications
                 WHERE rule_id = :r AND ship = :s
                   AND created_at > now() - (:q || ' seconds')::interval LIMIT 1",
                [':r' => $rule['id'], ':s' => $ship, ':q' => (string) $rule['quiet']]
            );

            if ($recent !== []) {
                return false;
            }
        }

        $this->raise($player, [
            'rule' => $rule['name'],
            'kind' => $rule['kind'],
            'ship' => $ship,
            'title' => (string) $note['title'],
            'body' => (string) ($note['body'] ?? ''),
            'priority' => (int) ($note['priority'] ?? $rule['priority']),
            // The channels the rule wants, carried on the row: delivery happens in a
            // separate pass and must not have to look the rule up again, not least
            // because the rule may be gone by then.
            'data' => ['channels' => $rule['channels']],
        ], $rule['id']);

        $this->trim($player);

        return true;
    }

    /**
     * @return array{firing: bool, value: ?float, token: string}
     */
    private function mark(int $ruleId, string $subject): array
    {
        $row = $this->one(
            'SELECT firing, value, token FROM notification_marks
             WHERE rule_id = :r AND subject = :s',
            [':r' => $ruleId, ':s' => $subject]
        );

        return [
            'firing' => $this->truthy($row['firing'] ?? false),
            'value' => isset($row['value']) && $row['value'] !== null ? (float) $row['value'] : null,
            'token' => (string) ($row['token'] ?? ''),
        ];
    }

    /**
     * @param array{firing?: bool, value?: float, token?: string} $change
     */
    private function setMark(int $ruleId, string $subject, array $change): void
    {
        $current = $this->mark($ruleId, $subject);

        $this->exec(
            'INSERT INTO notification_marks (rule_id, subject, firing, value, token, seen_at)
             VALUES (:r, :s, :f, :v, :t, now())
             ON CONFLICT (rule_id, subject) DO UPDATE
                 SET firing = EXCLUDED.firing, value = EXCLUDED.value,
                     token = EXCLUDED.token, seen_at = now()',
            [':r' => $ruleId, ':s' => $subject,
             ':f' => ($change['firing'] ?? $current['firing']) ? 1 : 0,
             ':v' => $change['value'] ?? $current['value'],
             ':t' => $change['token'] ?? $current['token']]
        );
    }

    /** Keeps the log to LOG_KEEP rows per player. */
    private function trim(int $player): void
    {
        $this->exec(
            'DELETE FROM notifications WHERE player = :p AND id <= (
                 SELECT id FROM notifications WHERE player = :p
                 ORDER BY id DESC OFFSET :k LIMIT 1
             ) AND delivered_at IS NOT NULL',
            [':p' => $player, ':k' => self::LOG_KEEP]
        );
    }

    /* -------------------------------- plumbing ------------------------------- */

    /** Where a craft is, out of whatever the automation state carried. */
    private function where(array $automation): string
    {
        $sector = $automation['sector'] ?? null;

        return is_array($sector)
            ? sprintf('(%d:%d)', (int) ($sector['x'] ?? 0), (int) ($sector['y'] ?? 0))
            : 'its sector';
    }

    /** " Hull 40%, shield 0%." when the state carried them, else "". */
    private function condition(array $automation): string
    {
        $vitals = $automation['vitals'] ?? null;
        if (!is_array($vitals)) {
            return '';
        }

        $parts = [];
        foreach (['hull', 'shield'] as $field) {
            if (is_numeric($vitals[$field] ?? null)) {
                $parts[] = sprintf('%s %d%%', $field, (int) round((float) $vitals[$field] * 100));
            }
        }

        return $parts === [] ? '' : ' ' . ucfirst(implode(', ', $parts)) . '.';
    }

    private function name(mixed $value): ?string
    {
        if (!is_string($value)) {
            return null;
        }

        $name = trim($value);

        return $name === '' || strlen($name) > 48 ? null : $name;
    }

    /**
     * @return array{error: array{status: int, code: string, message: string}}
     */
    private function unknownKey(): array
    {
        return $this->fail(401, 'unknown_key',
            'The mod does not recognise this key, or could not be asked. Notifications '
            . 'belong to a player, so the bridge has to be told which one this is.');
    }

    /**
     * @return array{error: array{status: int, code: string, message: string}}
     */
    private function fail(int $status, string $code, string $message): array
    {
        return ['error' => ['status' => $status, 'code' => $code, 'message' => $message]];
    }

    private function db(): PDO
    {
        return $this->pdo ??= Db::connect();
    }

    /**
     * @param array<string, mixed> $args
     *
     * @return list<array<string, mixed>>
     */
    private function all(string $sql, array $args): array
    {
        $statement = $this->db()->prepare($sql);

        foreach ($args as $key => $value) {
            $statement->bindValue($key, $value,
                is_int($value) ? PDO::PARAM_INT : PDO::PARAM_STR);
        }

        $statement->execute();

        return $statement->fetchAll();
    }

    /**
     * @param array<string, mixed> $args
     *
     * @return array<string, mixed>
     */
    private function one(string $sql, array $args): array
    {
        $rows = $this->all($sql, $args);

        return $rows[0] ?? [];
    }

    /**
     * @param array<string, mixed> $args
     */
    private function exec(string $sql, array $args): int
    {
        $statement = $this->db()->prepare($sql);

        foreach ($args as $key => $value) {
            $statement->bindValue($key, $value,
                $value === null ? PDO::PARAM_NULL
                    : (is_int($value) ? PDO::PARAM_INT : PDO::PARAM_STR));
        }

        $statement->execute();

        return $statement->rowCount();
    }

    /** Postgres hands booleans back as "t"/"f" over this driver, not as PHP bools. */
    private function truthy(mixed $value): bool
    {
        return $value === true || $value === 't' || $value === 1 || $value === '1';
    }

    /**
     * @return array<string, mixed>
     */
    private function decode(string $json): array
    {
        $value = json_decode($json, true);

        return is_array($value) ? $value : [];
    }

    private function encode(mixed $value): string
    {
        return json_encode($value, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE) ?: '{}';
    }
}
