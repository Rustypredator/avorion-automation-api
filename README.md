# avorion-automation-api

A server-side Avorion mod that exposes your ships, captain missions and map knowledge as a
JSON API, so an external program can plan and dispatch mining, trading and salvage missions
instead of you clicking through the galaxy map.

## How it talks to the outside world

It cannot open a socket, and neither can any other Avorion mod. The game's Lua sandbox nils
out `os.execute`, `io.popen`, `os.getenv` and `package.loadlib`, ships PUC Lua 5.2 rather
than LuaJIT (so no `ffi`), and links neither libcurl nor OpenSSL. There is no HTTP or socket
type anywhere in the scripting API.

So the mod speaks JSON over files in the galaxy's `moddata/` folder, and a small process on
the same machine turns that into HTTP. Everything that matters - routing, authentication,
validation, serialization - lives in the mod, which keeps that process down to about 150
lines in any language. See [docs/protocol.md](docs/protocol.md).

```
your planner ──HTTP──▶ bridge process ──files──▶ moddata/AutomationAPI/ ──▶ the mod
```

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
4. In game, run `/apikey new` to get a key. To let non-admins run it, add
   `<command name="apikey"/>` to `defaultAuthorizationGroup` in `<galaxy>/admin.xml`.

The mod is `serverSideOnly`, so clients do not download it and do not need it installed.

## Status

| phase | scope | state |
|---|---|---|
| A | transport, auth, routing, `/ping` | done |
| B | ship list and ship detail | done |
| C | mission catalog, preview, start, status, recall, collect | done |
| D | ship movement, in-sector orders, route planning | done |
| E | map knowledge, seed prediction, station search | done |
| F | per-ship event log | done |
| F | reference HTTP bridge | not started |

Reads work while the owning player is offline. Starting a mission does not: captain missions
are driven by a player script, so they only run while that player is logged in. That is a
vanilla limitation - captain missions do not tick for offline players either.

## Development

The pure-Lua modules run outside the game against a mocked Avorion environment:

```bash
for t in bridge ships missions movement map; do lua5.4 tests/test_$t.lua; done
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

## Architecture

Two scripts, because the game forces the split:

- `data/scripts/galaxy/automationapi/bridge.lua` runs on the Galaxy, so it ticks whether or
  not anyone is logged in. It owns the transport, auth, routing and every read.
- `data/scripts/player/automationapi/agent.lua` runs on the Player. Everything that writes
  goes through it.

The split is not a style choice. A galaxy script calling `Player:invokeFunction` **segfaults
the server** - no error, no return code, the process dies. Verified against 2.5.13 with the
exact call shape vanilla uses, and every vanilla caller of the background simulation is a
player script. So the bridge parks a job and the agent, running in the one context where the
call is legal, executes it and reports back.

Both vanilla overlays exist only to add one `addScriptOnce` line each:
`data/scripts/galaxy/init.lua` attaches the bridge, `data/scripts/player/init.lua` attaches
the agent.
