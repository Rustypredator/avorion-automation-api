<?php

declare(strict_types=1);

/**
 * Sending one notification to one push service.
 *
 * This is the only part of the stack that talks to anything outside it, and it is
 * deliberately the dumbest: it takes a channel row and a notification row, does one HTTP
 * POST, and says whether it worked. Everything about when to send, to whom, and what to
 * say has already been decided in notifications.php.
 *
 * ### Why these three
 *
 * A notification has to survive the player closing the browser tab and walking away from
 * the machine, which is the whole point - Avorion is a game you leave running. The
 * browser notifications the console already raises cannot do that.
 *
 *   ntfy      free, self-hostable, and an app on both phone platforms. Publishing is one
 *             unauthenticated POST to a topic on a public server, which makes it the one
 *             service a player can be set up on in under a minute. Published as JSON to
 *             the server root rather than as headers to /<topic>, because the header form
 *             has to ASCII-escape the title and ship names are not ASCII.
 *   gotify    self-hosted only, one application token per sender, and the same app story.
 *             The natural choice for someone already running their own services.
 *   webhook   the escape hatch: the notification as JSON to any URL, with headers of the
 *             caller's choosing. Discord, Slack, Home Assistant, an Apprise container, or
 *             a script of one's own all live behind this.
 *
 * ### On what is trusted here
 *
 * The URL comes from the player who owns the channel, so this posts wherever they say -
 * which for a self-hosted push server is usually a private address, and is the point.
 * That makes a channel a request forgery primitive by design, and the mitigation is that
 * it is the player's own bridge, reachable only by their own key, and the response body
 * is never handed back to them: a failed send reports the status code and nothing else.
 */
final class Push
{
    /** Seconds one send may take. A push server that is slow must not hold the loop. */
    private const TIMEOUT = 10;

    /** The kinds a channel may be, and what each one needs. */
    public const KINDS = [
        'ntfy' => [
            'title' => 'ntfy',
            'url' => 'The ntfy server, e.g. https://ntfy.sh',
            'fields' => ['topic' => 'The topic to publish to (required)'],
            'token' => 'Access token, or user:password. Leave empty for an open topic.',
        ],
        'gotify' => [
            'title' => 'Gotify',
            'url' => 'The Gotify server, e.g. https://gotify.example.com',
            'fields' => [],
            'token' => 'An application token from Gotify (required)',
        ],
        'webhook' => [
            'title' => 'Webhook',
            'url' => 'Any URL that takes a JSON POST',
            'fields' => ['headers' => 'Extra request headers, as an object'],
            'token' => 'Sent as "Authorization: Bearer <token>" when set.',
        ],
    ];

    /**
     * One notification to one channel.
     *
     * @param array{kind: string, url: string, token: string, config: array<string, mixed>,
     *              name: string} $channel
     * @param array{title: string, body: string, priority: int, kind: string, ship: string,
     *              data: array<string, mixed>} $note
     *
     * @return array{ok: bool, status: int, error: string}
     */
    public static function send(array $channel, array $note): array
    {
        $kind = (string) ($channel['kind'] ?? '');

        return match ($kind) {
            'ntfy' => self::ntfy($channel, $note),
            'gotify' => self::gotify($channel, $note),
            'webhook' => self::webhook($channel, $note),
            default => ['ok' => false, 'status' => 0,
                        'error' => 'unknown channel kind "' . $kind . '"'],
        };
    }

    /**
     * What is wrong with a channel, or "" when nothing is.
     *
     * Checked when the channel is saved rather than only when it is used: a typo in a
     * topic should be an error in front of whoever made it, not a notification that
     * silently goes nowhere three hours later.
     *
     * @param array{kind: string, url: string, token: string, config: array<string, mixed>} $channel
     */
    public static function invalid(array $channel): string
    {
        $kind = (string) ($channel['kind'] ?? '');
        if (!isset(self::KINDS[$kind])) {
            return 'kind must be one of ' . implode(', ', array_keys(self::KINDS));
        }

        $url = (string) ($channel['url'] ?? '');
        if ($url === '') {
            return 'url is required';
        }

        $scheme = strtolower((string) (parse_url($url, PHP_URL_SCHEME) ?: ''));
        if ($scheme !== 'http' && $scheme !== 'https') {
            return 'url must be http:// or https://';
        }
        if ((string) (parse_url($url, PHP_URL_HOST) ?: '') === '') {
            return 'url has no host';
        }

        if ($kind === 'ntfy' && trim((string) ($channel['config']['topic'] ?? '')) === '') {
            return 'ntfy needs a topic';
        }
        if ($kind === 'gotify' && (string) ($channel['token'] ?? '') === '') {
            return 'gotify needs an application token';
        }

        $headers = $channel['config']['headers'] ?? [];
        if ($headers !== [] && !is_array($headers)) {
            return 'headers must be an object of name to value';
        }
        foreach (is_array($headers) ? $headers : [] as $name => $value) {
            if (!is_string($name) || !is_scalar($value)
                || preg_match('/^[A-Za-z0-9-]+$/', $name) !== 1) {
                return 'header names must be words and values must be text';
            }
        }

        return '';
    }

    /* ------------------------------- the drivers ------------------------------ */

    /**
     * ntfy, as a JSON publish to the server root.
     *
     * @param array<string, mixed> $channel
     * @param array<string, mixed> $note
     *
     * @return array{ok: bool, status: int, error: string}
     */
    private static function ntfy(array $channel, array $note): array
    {
        $payload = [
            'topic' => trim((string) ($channel['config']['topic'] ?? '')),
            'title' => (string) $note['title'],
            'message' => (string) $note['body'],
            // ntfy's scale is 1..5 and means the same thing ours does.
            'priority' => self::clamp((int) $note['priority'], 1, 5),
            'tags' => [self::tag((string) $note['kind'])],
        ];

        $headers = [];
        $token = (string) ($channel['token'] ?? '');

        if ($token !== '') {
            // A token from ntfy is presented as a bearer; anything with a colon in it is
            // taken as the user:password form its docs also accept.
            $headers[] = str_contains($token, ':')
                ? 'Authorization: Basic ' . base64_encode($token)
                : 'Authorization: Bearer ' . $token;
        }

        return self::post(rtrim((string) $channel['url'], '/') . '/', $payload, $headers);
    }

    /**
     * @param array<string, mixed> $channel
     * @param array<string, mixed> $note
     *
     * @return array{ok: bool, status: int, error: string}
     */
    private static function gotify(array $channel, array $note): array
    {
        // Gotify's scale is 0..10, and it decides how loudly the app reacts: 0..3 is
        // silent, 8 and up buzzes. Ours is 1..5, so it is stretched onto that.
        $priority = [1 => 1, 2 => 3, 3 => 5, 4 => 7, 5 => 9][self::clamp((int) $note['priority'], 1, 5)];

        $payload = [
            'title' => (string) $note['title'],
            'message' => (string) $note['body'],
            'priority' => $priority,
        ];

        // The token goes in the header rather than the query string, so it stays out of
        // the push server's access log.
        return self::post(rtrim((string) $channel['url'], '/') . '/message', $payload,
                          ['X-Gotify-Key: ' . (string) ($channel['token'] ?? '')]);
    }

    /**
     * The notification itself as JSON, for anything not listed above.
     *
     * @param array<string, mixed> $channel
     * @param array<string, mixed> $note
     *
     * @return array{ok: bool, status: int, error: string}
     */
    private static function webhook(array $channel, array $note): array
    {
        $headers = [];

        foreach ((array) ($channel['config']['headers'] ?? []) as $name => $value) {
            if (is_string($name) && is_scalar($value)) {
                $headers[] = $name . ': ' . $value;
            }
        }

        $token = (string) ($channel['token'] ?? '');
        if ($token !== '') {
            $headers[] = 'Authorization: Bearer ' . $token;
        }

        return self::post((string) $channel['url'], [
            'title' => (string) $note['title'],
            'message' => (string) $note['body'],
            'priority' => (int) $note['priority'],
            'kind' => (string) $note['kind'],
            'ship' => (string) $note['ship'],
            'rule' => (string) ($note['rule'] ?? ''),
            'data' => (object) ($note['data'] ?? []),
            'source' => 'avorion-automation-api',
        ], $headers);
    }

    /* -------------------------------- plumbing -------------------------------- */

    /**
     * @param array<string, mixed> $payload
     * @param list<string> $headers
     *
     * @return array{ok: bool, status: int, error: string}
     */
    private static function post(string $url, array $payload, array $headers): array
    {
        $curl = curl_init($url);
        if ($curl === false) {
            return ['ok' => false, 'status' => 0, 'error' => 'could not open a connection'];
        }

        curl_setopt_array($curl, [
            CURLOPT_POST => true,
            CURLOPT_POSTFIELDS => json_encode($payload, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE),
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_TIMEOUT => self::TIMEOUT,
            CURLOPT_CONNECTTIMEOUT => 5,
            // A push server that redirects is a push server that is misconfigured, and
            // following one would resend the body somewhere the player did not name.
            CURLOPT_FOLLOWLOCATION => false,
            CURLOPT_HTTPHEADER => array_merge(['Content-Type: application/json'], $headers),
        ]);

        $raw = curl_exec($curl);
        $status = (int) curl_getinfo($curl, CURLINFO_HTTP_CODE);
        $error = curl_error($curl);
        curl_close($curl);

        if (!is_string($raw)) {
            return ['ok' => false, 'status' => 0, 'error' => $error !== '' ? $error : 'no answer'];
        }

        if ($status >= 200 && $status < 300) {
            return ['ok' => true, 'status' => $status, 'error' => ''];
        }

        /*
         * The status code and nothing else. The body is whatever the URL the player named
         * chose to return, and handing it back through the API would turn a channel into
         * a way of reading pages off the network this bridge sits on.
         */
        return ['ok' => false, 'status' => $status, 'error' => 'the push server answered HTTP ' . $status];
    }

    /** An emoji ntfy understands, per notification kind, so a phone can be read at a glance. */
    private static function tag(string $kind): string
    {
        return [
            'combat' => 'crossed_swords',
            'hull' => 'broken_heart',
            'shield' => 'shield',
            'flee' => 'runner',
            'idle' => 'zzz',
            'plan' => 'checkered_flag',
            'boss' => 'skull',
            'status' => 'speech_balloon',
            'gone' => 'skull_and_crossbones',
            'test' => 'wave',
        ][$kind] ?? 'satellite';
    }

    private static function clamp(int $value, int $low, int $high): int
    {
        return max($low, min($high, $value));
    }
}
