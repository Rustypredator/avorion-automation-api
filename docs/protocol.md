# Transport protocol

The mod cannot open a socket. Avorion's Lua sandbox nils out `os.execute`, `io.popen`,
`os.getenv` and `package.loadlib`, forces `load`/`loadfile` to text mode, ships PUC Lua 5.2
rather than LuaJIT (so no `ffi`), and links neither libcurl nor OpenSSL. No socket, HTTP or
URL type appears anywhere in the scripting API.

So the mod speaks JSON over files, and a separate process on the same machine turns that
into HTTP. That process is deliberately dumb: routing, authentication, validation and
serialization all live in the mod, so a bridge is roughly 150 lines in any language.

## Directories

Everything lives under the galaxy folder, which is the only place the sandbox permits
writes:

```
<galaxy>/moddata/AutomationAPI/
  requests/    <id>.json   written by the client, deleted by the mod
  responses/   <id>.json   written by the mod, deleted by the client
  events/                  reserved
```

`<galaxy>` is the server's galaxy directory, e.g. `~/.avorion/galaxies/defaultgalaxy`.
The mod creates all three on startup.

## Request

```json
{
  "id": "5f3c1e9a",
  "key": "avo_...",
  "method": "GET",
  "path": "/ships/My%20Hauler",
  "query": {"owner": "alliance"},
  "body": {}
}
```

| field | required | notes |
|---|---|---|
| `id` | yes | Filename stem. `[A-Za-z0-9_-]+`. Must be unique per request. |
| `key` | yes | An API key. Create one in game with `/apikey new`. |
| `method` | no | Defaults to `GET`. |
| `path` | yes | Must start with `/`. Segments are percent-decoded, so ship names with spaces work. |
| `query` | no | Object. Non-object values are ignored. |
| `body` | no | Object. Non-object values are ignored. |

The request file must be **at most 256 KB** and its name must match `^[A-Za-z0-9_-]+\.json$`.

### Writing a request atomically

Write to a name the mod ignores, then `rename()` it into place:

```
requests/<id>.part.json   ->   requests/<id>.json
```

`<id>.part.json` contains a `.`, so it fails the `^[A-Za-z0-9_-]+\.json$` filter and is
never picked up half-written. The client is an ordinary process, so its `rename()` is
atomic in the usual way.

## Response

```json
{
  "id": "5f3c1e9a",
  "status": 200,
  "body": {},
  "error": null
}
```

`status` mirrors HTTP. `body` carries the payload on success and `{"error": {...}}` on
failure:

```json
{"error": {"code": "unauthorized", "message": "Unknown or missing API key.", "details": null}}
```

`code` is stable and meant to be branched on; `message` is for humans.

| status | meaning |
|---|---|
| 200 | fine |
| 202 | accepted, but the game cannot confirm the outcome (see the movement endpoints) |
| 400 | malformed request or JSON |
| 401 | unknown or missing API key |
| 403 | authenticated, but not permitted (alliance privileges) |
| 404 | no such endpoint, ship, or sector |
| 405 | wrong method for that path |
| 409 | right request, wrong state - most often the owning player is offline |
| 422 | the game rejected it; `details` carries the in-game reason |
| 429 | rate limited |
| 500 | a Lua error; the traceback is in the server log |
| 504 | the request timed out server-side (default 20s) |

### Reading a response safely

**The mod cannot write responses atomically.** Inside the sandbox `os.rename()` returns
`true` and then loses the file: the source disappears and the destination is never created.
This is verified against Avorion 2.5.13; plain writes to the same directory work normally.

So a response may be observed mid-write. JSON is its own integrity check:

1. Poll for `responses/<id>.json`.
2. Read it and parse it.
3. **If parsing fails, discard and retry** - you caught a partial write.
4. Delete the file once parsed.

Responses the client never collects are deleted by the mod after 60 seconds.

## Timing

The mod polls every 0.2s and handles at most 4 requests per poll, so expect ~200-450ms of
transport latency. Endpoints that need a background area analysis take seconds; the mod
simply withholds the response until the work lands, so the client makes one ordinary
request and waits. After 20 seconds it answers `504` instead.

## Authentication

Keys are created in game:

```
/apikey new [label]        create a key (shown once)
/apikey list               list keys by 8-character fingerprint
/apikey revoke <fprint>    revoke one
/apikey revokeall          revoke all
```

A key identifies exactly one player, and every request acts as that player.

`/apikey` has to be run by a player - the server console and RCON have no account to
attach a key to. For non-admins to run it, add it to `<galaxy>/admin.xml` under
`defaultAuthorizationGroup`:

```xml
<defaultAuthorizationGroup>
    <commands>
        <command name="apikey"/>
    </commands>
</defaultAuthorizationGroup>
```

### On key storage

Keys are stored in plaintext in the galaxy's globals file. That is a deliberate trade-off:
anyone who can read that file can already read and write the request directory, which is
full control of this API. Hashing would protect nothing. Treat filesystem access to the
galaxy folder as equivalent to holding every key, and keep the bridge process bound to
localhost.

## Worked example

```bash
GALAXY=~/.avorion/galaxies/defaultgalaxy/moddata/AutomationAPI
ID=$(uuidgen | tr -d -)

cat > "$GALAXY/requests/$ID.part.json" <<JSON
{"id":"$ID","key":"avo_...","method":"GET","path":"/ping"}
JSON
mv "$GALAXY/requests/$ID.part.json" "$GALAXY/requests/$ID.json"

# poll until it parses, then delete
until python3 -c "import json,sys;json.load(open(sys.argv[1]))" "$GALAXY/responses/$ID.json" 2>/dev/null; do sleep 0.1; done
cat "$GALAXY/responses/$ID.json"
rm "$GALAXY/responses/$ID.json"
```
