# avorion-automation-api

A server-side Avorion mod that exposes your ships, captain missions and map knowledge as a
JSON API, so an external program can plan and dispatch mining, trading and salvage missions
instead of you clicking through the galaxy map.

- read your fleet, including craft in unloaded sectors and while you are offline
- preview a captain mission with the game's own yield and risk prediction, then start it
- move ships across the galaxy, or give in-sector orders, and watch what they actually do
- query known sectors, and predict unvisited ones straight from the galaxy seed

## How it talks to the outside world

It cannot open a socket, and neither can any other Avorion mod. The game's Lua sandbox nils
out `os.execute`, `io.popen`, `os.getenv` and `package.loadlib`, ships PUC Lua 5.2 rather
than LuaJIT (so no `ffi`), and links neither libcurl nor OpenSSL. There is no HTTP or socket
type anywhere in the scripting API.

So the mod speaks JSON over files in the galaxy's `moddata/` folder, and a small process on
the same machine turns that into HTTP. Everything that matters - routing, authentication,
validation, serialization - lives in the mod, which keeps that process down to about 150
lines in any language.

```
your planner ──HTTP──▶ bridge process ──files──▶ moddata/AutomationAPI/ ──▶ the mod
```

The mod ships no bridge process; you run one. [docs/external.md](docs/external.md) is the
guide to writing it, with a complete reference implementation.

## Install

1. Clone this repo anywhere.
2. Point the galaxy's `modconfig.lua` at it **by path** (not by id - the game resolves mods
   by folder path):

   ```lua
   mods = {
       {path = "/absolute/path/to/avorion-automation-api"}
   }
   achievementsEnabled = false
   ```

   For a dedicated server that is `<galaxy>/modconfig.lua`, e.g.
   `~/.avorion/galaxies/defaultgalaxy/modconfig.lua`.
3. Start the server. The log should show `Found 1 mods` and then
   `AutomationAPI: v0.1.0 ready`.
4. In game, run `/apikey new` to get a key. It is shown once. To let non-admins run the
   command, add `<command name="apikey"/>` to `defaultAuthorizationGroup` in
   `<galaxy>/admin.xml`.

The mod is `serverSideOnly`, so clients do not download it and do not need it installed.

## First request

Without a bridge process, straight against the file transport:

```bash
DIR=~/.avorion/galaxies/defaultgalaxy/moddata/AutomationAPI
ID=$(uuidgen | tr -d -)

# write to a name the mod ignores, then rename it into place
cat > "$DIR/requests/$ID.part.json" <<JSON
{"id":"$ID","key":"avo_...","method":"GET","path":"/ping"}
JSON
mv "$DIR/requests/$ID.part.json" "$DIR/requests/$ID.json"

until python3 -c "import json,sys;json.load(open(sys.argv[1]))" "$DIR/responses/$ID.json" 2>/dev/null
do sleep 0.1; done
cat "$DIR/responses/$ID.json"; rm "$DIR/responses/$ID.json"
```

## Endpoints

Full reference in [docs/api.md](docs/api.md).

| endpoint | |
|---|---|
| `GET /ping` | service metadata and API version |
| `GET /ships` | owned craft, with the usability check every mission runs first |
| `GET /ships/{name}` | captain, crew, cargo, turrets, systems, hyperspace, requirements |
| `GET /missions`, `GET /ships/{name}/missions` | mission catalog, resolved for one ship |
| `POST /ships/{name}/missions/{mission}/preview` | dry run with the game's own prediction |
| `POST /ships/{name}/missions/{mission}/start` | start it |
| `GET /ships/{name}/mission` | live status |
| `POST /ships/{name}/mission/recall`, `.../collect` | recall, and collect yields |
| `POST /ships/{name}/travel` | send a ship anywhere in the galaxy |
| `POST /ships/{name}/orders` | in-sector order chain: jump, patrol, repair, mine, ... |
| `GET /ships/{name}/events` | what the ship has actually been doing |
| `GET /galaxy/info`, `GET /galaxy/route` | galaxy shape, and the game's own pathfinder |
| `GET /map/sectors`, `GET /map/sectors/{x}/{y}` | known sectors |
| `GET /map/predict/{x}/{y}`, `GET /map/search` | unvisited sectors, from the seed |

## What needs the owner online

Every read works with nobody logged in, because the bridge runs on the Galaxy.

Writes do not. Starting, recalling and collecting missions, travel and in-sector orders all
answer `409 owner_offline` when the owning player is not in game, and the ship event feed
records nothing then either. That is a vanilla limitation rather than a shortcut here:
mission state lives in a player script, and captain missions do not tick for offline players
in the base game.

## Documentation

| | |
|---|---|
| [docs/api.md](docs/api.md) | every endpoint, its parameters and response shape |
| [docs/protocol.md](docs/protocol.md) | the file transport, envelopes, status codes, auth |
| [docs/external.md](docs/external.md) | writing the bridge process and clients against it |

## Architecture

Two scripts, because the game forces the split:

- `data/scripts/galaxy/automationapi/bridge.lua` runs on the Galaxy, so it ticks whether or
  not anyone is logged in. It owns the transport, auth, routing and every read.
- `data/scripts/player/automationapi/agent.lua` runs on the Player. Everything that writes
  goes through it, and it forwards ship order and status callbacks back to the bridge.

The split is not a style choice. A galaxy script calling `Player:invokeFunction` **segfaults
the server** - no error, no return code, the process dies. Verified against 2.5.13 with the
exact call shape vanilla uses, and every vanilla caller of the background simulation is a
player script. So the bridge parks a job and the agent, running in the one context where the
call is legal, executes it and reports back.

Everything else is pure Lua under `data/scripts/lib/automationapi/`: the JSON codec, router,
auth, serializers and the per-endpoint handlers.

Both vanilla overlays exist only to add one `addScriptOnce` line each:
`data/scripts/galaxy/init.lua` attaches the bridge, `data/scripts/player/init.lua` attaches
the agent. They are the only vanilla files this mod replaces, and they need re-checking
against the game's copies after an Avorion update.

## Development

The pure-Lua modules run outside the game against a mocked Avorion environment:

```bash
for t in bridge ships missions movement map shipevents; do lua5.4 tests/test_$t.lua; done
```

`tests/mock_avorion.lua` deliberately reproduces the sandbox's hostile behaviour rather
than a convenient version of it, so bugs that would otherwise only show up in game fail in
tests instead. It reproduces, among others:

- `os.rename` reporting success and then losing the file
- `Player:invokeFunction` being fatal outside a player script
- engine enums being userdata that `pairs()` will not iterate
- `sectorspecifics` exposing its static functions only through an instance
- `orderchain` reaching only functions the game marks `callable()`
- a captured owner handle serving a cached `ShipInfo` that never advances
- `Simulation.getCommandUIData` raising for an idle ship, traceback and all

## Security

An API key identifies exactly one player, and every request acts as that player. Keys are
stored in plaintext in the galaxy's globals file, deliberately: anyone who can read that
file can already read and write the request directory, which is full control of this API.
Treat filesystem access to the galaxy folder as equivalent to holding every key, and keep
the bridge process bound to localhost.

## License

GPL-3.0. See [LICENSE](LICENSE).
