# Implementing an external service

The mod has no socket. Everything outside the game reaches it by writing JSON files into
the galaxy's `moddata/AutomationAPI/requests/` and reading them back out of
`responses/`. [protocol.md](protocol.md) specifies that transport; this document is the
implementer's guide to it - what an external process has to get right, a complete reference
bridge, and the patterns a client on the other side of it should follow.

Two kinds of external service are involved, and you may want either or both:

- a **bridge**: a process on the server machine that turns HTTP into request files and
  responses back into HTTP. It holds no logic of its own.
- a **client**: your planner, dashboard or bot. It talks HTTP to the bridge, or writes the
  files itself and skips HTTP entirely.

Both need the same thing from the machine: read and write access to the galaxy folder. The
transport is filesystem-local, so a bridge runs on the server host and your client can live
anywhere the bridge is reachable.

## The transaction

Every call, in any language, is the same six steps:

1. Pick an `id`. `[A-Za-z0-9_-]+`, unique per in-flight request. 16 random hex bytes is
   plenty; a UUID with the dashes stripped works too.
2. Serialize the envelope: `{id, key, method, path, query, body}`.
3. Write it to `requests/<id>.part.json`, then `rename()` it to `requests/<id>.json`.
4. Poll for `responses/<id>.json`.
5. Read and parse it. **If parsing fails, discard and retry** - you caught a partial write.
6. Delete the file, and return `status` and `body` to the caller.

### Rules that are not optional

| rule | why |
|---|---|
| Write to a name containing a `.` first, then rename in | The mod picks up anything matching `^[A-Za-z0-9_-]+\.json$` on its next poll, half-written or not. `<id>.part.json` fails that filter, and your `rename()` is atomic in the ordinary way because your process is not sandboxed. |
| Retry on a parse failure instead of erroring | The mod **cannot** write responses atomically. Inside the sandbox `os.rename()` returns `true` and then loses the file, so responses are written straight to their final name and can be observed mid-write. JSON is the integrity check. |
| Delete the response once parsed | Otherwise the mod deletes it 60 seconds later and you have raced it for nothing. |
| Keep requests under 256 KB | Larger files are refused with `400`. |
| Send `query` and `body` as JSON objects, or omit them | Anything else is ignored, silently, and your parameters vanish. |
| Keep query values as **strings** | The mod compares them to `"true"`, `"all"`, `"ship"` and parses numbers with `tonumber`, which accepts strings. A JSON `true` or `100` will not match where a string would. |
| Percent-encode path segments | Ship names contain spaces: `/ships/Ore%20Hound`. The mod decodes each segment. An HTTP server hands you the already-encoded path, so pass it through untouched rather than decoding and re-encoding. |
| Give the client a timeout longer than 20 s | The mod answers `504` itself at 20 seconds. A shorter client timeout turns a slow-but-fine request into a lost one, and leaves a response file behind. |

### Throughput and latency

The mod polls its request directory every 0.2 s and handles at most 4 requests per poll, so
the ceiling is **about 20 requests per second** and the floor for any single call is
~200-450 ms of transport latency. Queue depth beyond that just waits; nothing is dropped.

Three kinds of call take materially longer, and all three answer on one connection rather
than handing back a job id, so a bridge needs no job-tracking machinery:

| kind | typical |
|---|---|
| mission preview and start (a background area analysis runs) | 1-3 s |
| any write (parked for the player agent, which polls 4x/second) | +0.5 s |
| `/map/search?predict=true` (the galaxy generator, sliced across ticks) | up to ~9 s |

## Mapping HTTP onto the envelope

| HTTP | envelope |
|---|---|
| request method | `method` |
| path, still percent-encoded | `path` |
| query string, parsed to single string values | `query` |
| JSON request body, or `{}` | `body` |
| `X-API-Key` header (or `Authorization: Bearer ...`) | `key` |
| response `status` | `status` |
| response JSON | `body` |

Take the key from a header rather than the URL so it stays out of access logs, and do not
let the bridge hold a key of its own - one key is one player, and the mod acts as whoever
the key belongs to.

## Reference bridge

Standard library only, no dependencies, ~120 lines. It is the whole bridge: no routing, no
validation, no caching, because all of that already happened inside the mod.

```python
#!/usr/bin/env python3
"""HTTP bridge for the Avorion Automation API.

    ./bridge.py --galaxy ~/.avorion/galaxies/defaultgalaxy
    curl -H 'X-API-Key: avo_...' http://127.0.0.1:8080/ping
"""

import argparse
import json
import os
import secrets
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qsl, urlparse

POLL = 0.05
# The mod answers 504 itself at 20s; stay above that so its answer wins.
TIMEOUT = 30.0


class Transport:
    def __init__(self, root):
        self.requests = os.path.join(root, "requests")
        self.responses = os.path.join(root, "responses")

    def call(self, key, method, path, query, body):
        request_id = secrets.token_hex(16)          # matches [A-Za-z0-9_-]+
        envelope = {
            "id": request_id,
            "key": key,
            "method": method,
            "path": path,
            "query": query,
            "body": body,
        }

        # Write under a name the mod's filter rejects, then rename in. Our rename is
        # atomic, so the mod never reads a half-written request.
        staged = os.path.join(self.requests, request_id + ".part.json")
        final = os.path.join(self.requests, request_id + ".json")
        with open(staged, "w", encoding="utf-8") as handle:
            json.dump(envelope, handle)
        os.rename(staged, final)

        return self._collect(request_id)

    def _collect(self, request_id):
        path = os.path.join(self.responses, request_id + ".json")
        deadline = time.monotonic() + TIMEOUT

        while time.monotonic() < deadline:
            try:
                with open(path, "r", encoding="utf-8") as handle:
                    payload = json.load(handle)
            except FileNotFoundError:
                time.sleep(POLL)
                continue
            except (ValueError, UnicodeDecodeError):
                # The mod cannot write responses atomically, so a failed parse means we
                # caught it mid-write. Retry rather than fail.
                time.sleep(POLL)
                continue

            try:
                os.unlink(path)
            except OSError:
                pass
            return payload

        return {"status": 504, "body": {"error": {
            "code": "bridge_timeout",
            "message": "No response within %.0fs." % TIMEOUT,
        }}}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "avorion-automation-bridge"
    transport = None

    def do_GET(self):
        self._forward("GET")

    def do_POST(self):
        self._forward("POST")

    def _forward(self, method):
        key = self.headers.get("X-API-Key", "")
        auth = self.headers.get("Authorization", "")
        if not key and auth.startswith("Bearer "):
            key = auth[7:]
        if not key:
            return self._reply(401, {"error": {
                "code": "unauthorized", "message": "Missing X-API-Key header."}})

        url = urlparse(self.path)
        # .path stays percent-encoded, which is what the mod expects. Query values stay
        # strings: the mod compares them against "true", "all" and friends.
        query = dict(parse_qsl(url.query, keep_blank_values=True))

        body = {}
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            try:
                body = json.loads(self.rfile.read(length))
            except ValueError:
                return self._reply(400, {"error": {
                    "code": "malformed_json", "message": "Body is not valid JSON."}})
            if not isinstance(body, dict):
                return self._reply(400, {"error": {
                    "code": "malformed_request", "message": "Body must be an object."}})

        reply = self.transport.call(key, method, url.path, query, body)
        self._reply(reply.get("status", 500), reply.get("body") or {})

    def _reply(self, status, body):
        payload = json.dumps(body).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--galaxy", required=True,
                        help="galaxy folder, e.g. ~/.avorion/galaxies/defaultgalaxy")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8080)
    args = parser.parse_args()

    root = os.path.join(os.path.expanduser(args.galaxy), "moddata", "AutomationAPI")
    if not os.path.isdir(os.path.join(root, "requests")):
        raise SystemExit("no request directory at %s - is the mod loaded?" % root)

    Handler.transport = Transport(root)
    ThreadingHTTPServer((args.host, args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
```

`ThreadingHTTPServer` matters: every call spends most of its life waiting on a file, and a
single-threaded server would serialize calls that the mod is happy to handle four at a time.

### Running it

```bash
./bridge.py --galaxy ~/.avorion/galaxies/defaultgalaxy --port 8080
curl -H 'X-API-Key: avo_...' http://127.0.0.1:8080/ping
curl -H 'X-API-Key: avo_...' 'http://127.0.0.1:8080/ships?owner=all'
curl -H 'X-API-Key: avo_...' -H 'Content-Type: application/json' \
     -d '{"to": {"x": -300, "y": 310}, "swiftness": 2}' \
     http://127.0.0.1:8080/ships/Ore%20Hound/travel
```

As a systemd unit, running as the same user as the game server:

```ini
[Unit]
Description=Avorion Automation API bridge
After=avorion.service

[Service]
ExecStart=/opt/avorion-bridge/bridge.py --galaxy /home/avorion/.avorion/galaxies/defaultgalaxy
User=avorion
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

### Porting it

Nothing above is Python-specific. Any language with JSON, `rename()` and a directory listing
does it in the same number of lines; the only two subtleties are the staged rename on the way
in and the parse-or-retry on the way out. A bridge that skips either will work for weeks and
then corrupt a request under load.

## Error handling

The full status table is in [protocol.md](protocol.md). What matters for an implementation is
which failures are worth retrying:

| status | retry? |
|---|---|
| `409 owner_offline` | Yes, once the owner is back. Not a bug - writes need the owning player in game. |
| `429 route_busy` | Yes, after the cooldown. `/galaxy/route` allows one call every 2 s per player. |
| `504 timeout` | Maybe. The work may have landed anyway; re-read state before re-sending a write. |
| `500` | No. Something raised in Lua; the traceback is in the server log. |
| `4xx` otherwise | No. The request is wrong, and sending it again will not fix it. |

Errors always arrive as `body.error` with a stable `code`, a human `message` and sometimes
`details`. Branch on `code`, never on `message` - the messages are the game's own wording and
change with it.

**A write that fails validation returns the full preview body**, not just an error. A rejected
`start` comes back `422` carrying the same `errors`, `prediction` and `assessment` a preview
would have, so a client can show why without a second call.

## Writing a client

### Check the API version first

`GET /ping` returns `api`, the surface version, alongside the mod and game versions. It is
bumped when a response shape changes incompatibly. Check it on startup and refuse to run
against a number you do not know.

### Ships are addressed by name

There are no entity ids anywhere in this API, by design. The name in `/ships/{name}` is the
craft's name, percent-encoded. Two ships with the same name are ambiguous - rename one.

### Writes need the owner online, reads do not

Every read works with nobody logged in. Every write - mission start, recall, collect, travel,
orders - answers `409 owner_offline` otherwise, and the event feed records nothing. Plan for a
client that keeps reading and queues its writes rather than one that assumes a session.

### Preview before you start

`preview` runs the same analysis, validation and prediction as `start` with no side effects,
including the game's own `calculatePrediction` behind the order window's yield and risk
figures. Use it to rank candidate ships and areas; `canStart` tells you whether the start
would be accepted.

### Follow ships through the event feed

`GET /ships/{name}/events` is the only way to learn *why* a ship stopped - the order chain
narrates itself by chat message to whoever gave the order, and an API caller never receives
those. Consume it as a cursor loop:

```
cursor = None
loop:
    r = GET /ships/{name}/events?since={cursor}
    cursor = r.cursor
    handle r.events
```

- Sequence numbers are **global, not per ship**, so one cursor works across a whole fleet.
- `idle` is the field to watch for "this ship is free and can be given work".
- `recording: false` means no player agent is in a position to see the callbacks fire, so a
  quiet log proves nothing. For a personal craft that is its owner being logged out. For an
  **alliance** craft it takes every member being out: the callbacks are raised on the
  Alliance object and every online member's agent registers against them, so an alliance
  fleet keeps recording while any one member is in game.
- The log is in memory, capped at 200 events per ship, and empty after a server restart. It
  is a recent-activity feed, not an audit trail - persist anything you need to keep. The
  bundled bridge already does, out of the answers it relays; see *Bridge-local endpoints*
  in [docs/api.md](api.md) for the shape, or lift the approach into your own bridge.

### Do not poll harder than the mod moves

`GET /ships/{name}/mission` progress text is refreshed by the game once a minute, so polling
it faster than that returns the same answer while spending your 20 requests/second. The event
feed is push-driven on the mod's side and is the cheaper way to notice change.

`GET /stations` is the same argument with a longer period. A station's books are read out of
its database row, which the game rewrites only when it saves or unloads the sector, so two
calls a minute apart routinely return identical numbers. Sample it on the order of minutes;
the bundled bridge stores at most one sample per station per `HISTORY_ECONOMY_INTERVAL`
(default 300s) for exactly this reason.

### Station earnings are totals, not rates

The three counters in `economy.earnings` are lifetime sums since the station was founded -
the only form the game keeps them in. Any rate is yours to derive from two readings and the
time between them, and two things make that less obvious than it looks:

- A counter that has **fallen** is a reset, not a refund. It means the station was destroyed
  and rebuilt, or founded again under the same name, so the honest reading of that pair is
  zero rather than a large negative.
- Divide by time you actually **observed**, not wall-clock time. A gap in your sampling is a
  gap in who was looking; counting it as a quiet hour reports a working station as idle.

Both are what the bundled bridge's `/history/economy/*` endpoints do; see *Bridge-local
endpoints* in [docs/api.md](api.md).

### Prefer observation to prediction

`/map/predict` and `predict=true` searches run the galaxy generator and know only what the
seed decided. They cannot know what players built or destroyed, and they miss sectors the
game created outside the seed's decision layer - **a home sector routinely predicts empty
while `/map/sectors/{x}/{y}` shows five stations**. `/map/predict` includes a `known` block
whenever the caller has also seen the sector; when it is there, trust it over the prediction.

Predicted searches are capped at 10000 sectors and answer partially rather than failing:
check `truncated`, which is `false` or one of `"limit"`, `"budget"`, `"timeout"`.

## Skipping HTTP

A client on the server machine can implement the six-step transaction directly and drop the
bridge - the `Transport` class above is the entire dependency, and it is 40 lines. Do that if
your planner already runs next to the game; run a bridge when you want more than one client,
a client on another host, or ordinary HTTP tooling.

Either way the concurrency rules are the same: unique ids per in-flight request, and nothing
shared between callers except the directory.

## Security

An API key is a bearer credential that identifies exactly one player, and every request acts
as that player. There are no scopes.

- **Bind the bridge to localhost** unless you have put real authentication in front of it. It
  forwards whatever key it is handed and enforces nothing itself.
- Anyone with write access to `moddata/AutomationAPI/requests/` can call this API without a
  key of their own by reading one out of the galaxy's globals file, where keys are stored in
  plaintext. Treat filesystem access to the galaxy folder as equivalent to holding every key.
- Keys are shown once, on creation. `/apikey list` shows only 8-character fingerprints;
  `/apikey revoke <fingerprint>` and `/apikey revokeall` withdraw them.
- Do not put the key in a URL, where it lands in access logs and browser history.

## Conformance checklist

Before trusting an implementation under load:

- [ ] request ids are unique per in-flight request and match `[A-Za-z0-9_-]+`
- [ ] requests are staged under a name containing a `.`, then renamed in
- [ ] a response that fails to parse is retried, not surfaced as an error
- [ ] responses are deleted after being read
- [ ] the client timeout exceeds the mod's 20 s
- [ ] `query` and `body` are objects, and query values are strings
- [ ] path segments are percent-encoded and not double-decoded
- [ ] `body.error.code` is what the client branches on, not `message`
- [ ] `api` from `/ping` is checked at startup
