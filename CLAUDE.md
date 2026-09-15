# CLAUDE.md

Orientation for agents working in this repo. Read this first, then open only the files the
task touches. User-facing details live in [README.md](README.md) and `docs/`; this file is
the map.

## What this is

**AutomationAPI** is a server-side-only Avorion (2.5+) mod that exposes ships, captain
missions, movement, map knowledge and station economy as a JSON API. The Avorion Lua
sandbox (PUC Lua 5.2) has no sockets, so the mod reads request files and writes response
files under `moddata/AutomationAPI/`. A separate "bridge" process (PHP in `docker/`)
turns HTTP into those files. Routing, auth, validation and serialization all live in the
mod. The bridge is kept deliberately thin, except for the Postgres history store.

```
client/web console ──HTTP──▶ docker/bridge (PHP) ──files──▶ moddata/AutomationAPI/{requests,responses,keys}
                                   │                                 │
                                Postgres (history)          galaxy/automationapi/bridge.lua (the mod)
```

Version source of truth: `modinfo.lua`. Use `tools/bump.sh X.Y.Z` to change it, never edit
by hand. The version is copied into `config.lua`, `README.md`, `docs/protocol.md` and
`docs/api.md`, and `tests/test_version.lua` checks that the copies agree.

## Directory map

```
modinfo.lua                     mod manifest (id, version, serverSideOnly)
data/scripts/                   everything the game loads
  galaxy/init.lua               vanilla overlay: + addScriptOnce(bridge.lua)
  player/init.lua               vanilla overlay: + addScriptOnce(automationapi/agent.lua)
  alliance/init.lua             vanilla overlay: + addScriptOnce(agent.lua) on alliances
  entity/orderchain.lua         APPENDED onto vanilla orderchain.lua (wraps updateServer,
                                getOrderInfo, secure, restore): route plans, enemy
                                handling, standing orders (enemies/loot, idle or
                                interrupt+resume), boss farming run on the ship
  commands/apikey.lua           /apikey chat command (new/list/revoke keys)
  galaxy/automationapi/bridge.lua   Galaxy script: transport loop, auth, router, all reads,
                                    job queue for writes, stats console line
  player/automationapi/agent.lua    Player/Alliance script: executes write jobs (Simulation
                                    calls, order chain), forwards ship order/status callbacks
  lib/automationapi/            pure(ish) Lua modules, loaded with include("automationapi/x")
    config.lua        all tunables + transport root resolution/probing (rootOverride)
    router.lua        path patterns, Router.fail(status, code, msg), Router.DEFERRED, dispatch
    json.lua          codec; Json.array() marks arrays (empty table encodes as {} otherwise)
    serialize.lua     game values -> JSON-safe tables (NaN, userdata, sparse tables)
    auth.lua          API keys -> player index, stored as Server values
    owner.lua         resolve acting faction (player vs alliance, ?owner=), findShip, privileges
    shipdata.lua      ShipDatabaseEntry reads (work offline / unloaded sectors)
    shipevents.lua    in-memory per-ship event ring buffer (200)
    economy.lua       station books from getSecuredScriptValues (TradingManager state)
    enums.lua         engine userdata enums -> names
    missiontypes.lua  API mission keys <-> vanilla command UUIDs, config/area building
    missionrules.lua  pure arithmetic for mission automation limits/candidates
    programrules.lua  order program vocabulary: actions, conditions, validation, evaluation
    analysis.lua      background area analysis runner (async, deferred responses)
    factionscope.lua  fakes getParentFaction() while vanilla command code runs
    routes.lua        calculateJumpPath wrapper, coordinate parsing, travel destination gates
    routeplanner.lua  own weighted A* with preferences, boss-farm loop picker
    sectors.lua       known sectors + seed-based prediction (SectorSpecifics)
    devsetup.lua      NOT loaded; console helpers: spawn a test ship, spawnBoss, bossLab
                      (boss + loot + carrier in a sector, prints engine answers)
    handlers/         one module per endpoint group, each exposes .register(router)
      meta.lua              GET /ping
      ships.lua             /ships, /ships/{name}, /ships/{name}/events
      missions.lua          catalog, preview, start, status, recall, collect; owns
                            Missions.enqueue (job queue) + Missions.tick
      missionautomation.lua per-craft automation rules (Server values) + loop (.tick)
      programs.lua          order programs (Server values) + runner (.tick); steps run as
                            internal router:dispatch requests to the real endpoints
      movement.lua          /travel (mission alias), /orders (in-sector order chain)
      navigation.lua        /route, /farm, /automation (talks to entity/orderchain.lua)
      map.lua               /galaxy/*, /map/* (sliced scans across ticks)
      economy.lua           /stations, /stations/{name}, /economy
docs/
  api.md        every endpoint + response shapes, incl. bridge-local /history/*
  protocol.md   file transport, envelopes, status codes, auth, root resolution
  external.md   how to write a bridge/client; reference Python bridge
  local-testing.md  local server, bridge over HTTPS (self-signed), boss lab + findings
docker/                         deployment only, NOT shipped to Workshop
  docker-compose.yml            services: api (FrankenPHP bridge), db (Postgres), poller, init
  Caddyfile, .env.example       plain HTTP site + self-signed HTTPS site (TLS_HOSTS)
  bridge/public/index.php       HTTP <-> file relay, serves /history/*, records history
  bridge/src/db.php             PDO connection + schema/migrations
  bridge/src/history.php        history store: visits, events, station/faction samples, manifests
  bridge/src/poll.php           poller loop (POLL_KEYS) calling the API over HTTP
web/                            browser console, no build step, no deps, NOT shipped
  index.html, app.css
  api.js      request queue with priorities/pacing (mod cap is about 20 calls/s)
  app.js      the whole console UI (~7.4k lines: fleet, missions, orders + standing orders,
              Automation tab (programs + mission rules + standing orders per craft), economy,
              industry)
  map.js      canvas galaxy map, heatmap/travel overlays
tests/
  mock_avorion.lua   hostile mock of the sandbox (Mock.install/reset/addPlayer/addAlliance/
                     addShip/addKnownSector/addPredictedSector/setOffline/setOnline/setClock)
  test_*.lua         one per area; dofile the real bridge.lua and drive requests
  test_history.php   history store against real Postgres (via tools/dbtest.sh)
  test_console.js    web console under jsdom (via tools/uitest.sh)
tools/
  bump.sh       set version everywhere
  copy.sh       copy shippable files (git-tracked data/ docs/ tests/ + top-level) to mods dir
  fakeserver.lua  runs real bridge.lua on a real clock against MOCK_ROOT (prints API keys)
  e2e.sh        docker stack + fakeserver end-to-end
  dbtest.sh     throwaway Postgres + test_history.php
  uitest.sh     node image + jsdom + test_console.js
  localserver.sh  headless AvorionServer on the test galaxy, console via FIFO
                  (start/stop/cmd/run/lab/key/log); paths in gitignored tools/local.env
```

## Request lifecycle (the important part)

1. `bridge.lua` `update()` polls `requests/` every `Config.pollInterval` (0.2s), up to
   `maxRequestsPerPoll` (4). Only files matching `^[A-Za-z0-9_-]+\.json$` are read. Clients
   write `<id>.part.json` and then rename it into place.
2. `handleRequest` validates the envelope, `Auth.resolve(key)` finds the player index, and
   it builds `ctx`: `{requestId, method, path, query, body, playerIndex, player, now, complete}`.
3. `router:dispatch` runs the handler inside pcall. A handler returns one of:
   - `body` (200) or `status, body`
   - `Router.fail(status, code, message, details)` for an error envelope (a raw error becomes a 500)
   - `Router.DEFERRED`, with a later call to `ctx.complete(status, body)`. The request times
     out with 504 after `Config.requestTimeout` (20s).
4. The response goes to `responses/<id>.json` as `{id, status, body, error}`. Responses the
   client never collects are deleted after `responseTtl`.

### Reads vs writes: forced script split

- A **galaxy script must never call `Player:invokeFunction`**, because it segfaults the server.
  Reads (ship DB, sectors, predictions, previews) therefore run in the bridge.
- **Writes** (mission start/recall/collect, orders, routes, automation) call
  `Missions.enqueue(job)`, which returns `DEFERRED`. `agent.lua` on the owning Player (or
  on the Alliance, for alliance craft, because a player script gets result code 7 there)
  polls `bridge.takeJobs` / `takeAllianceJobs`, runs the job and calls `bridge.reportJobs`.
  The job's `onResult` then completes the request. Writes answer `409 owner_offline` when
  no agent can run.
- Ship order/status callbacks travel from agent to `bridge.pushShipEvent` to `shipevents.lua`.
- In-sector behaviour (enemy detection, gate hops) must run on the ship, in
  `entity/orderchain.lua`. Its state reaches the bridge through `getOrderInfo`, which the
  agent forwards like any other order event.

## Adding or changing an endpoint

1. Put the handler in the matching `lib/automationapi/handlers/*.lua` inside its
   `register(router)`. For a new group, create a module and register it in
   `bridge.lua` `initialize()`.
2. Use `Owner.resolve(ctx)` / `Owner.findShip(ctx, name)` for the acting faction, and
   `ShipData`/`Serialize` for output. Wrap list results in `Json.array({})`.
3. Fail with `Router.fail(...)` and a stable snake_case `code`.
4. Heavy work (scans, route planning) must be sliced across ticks and capped by `Config`,
   because everything runs on the server tick.
5. Add or extend `tests/test_<area>.lua` using `mock_avorion.lua`. If the mock lacks an
   engine call, add it there and keep it as hostile as the real sandbox.
6. Document it in `docs/api.md` (and the endpoint table in `README.md`). If the console
   uses it, update `web/app.js`. If the bridge should record it, update `docker/bridge`.

## Sandbox gotchas (all reproduced in the mock)

- No `os.execute`/`io.popen`/`os.getenv`, no ffi, text-mode `load` only, Lua 5.2 semantics.
- `io.open` is sandbox-checked but `createDirectory`/`listFilesOfDirectory`/`deleteFile`
  are not, so they can disagree about relative paths. See `Config.probeDirectory`.
- `os.rename` can report success and still lose the file.
- Engine enums are userdata, so `pairs()` yields nothing. Use `enums.lua`.
- `getScripts()` / `getSecuredScriptValues()` are keyed by script index, not a 1..n sequence.
- `Simulation.getCommandUIData` raises for idle ships. `sectorspecifics` exposes statics only
  through an instance. `orderchain` exposes only `callable()` functions.
- Player names are not identities. Use player indices.
- Scripts need the `-- namespace X` comment line. Do not remove it.
- The init overlays copy vanilla files. After an Avorion update, re-diff them (and
  `orderchain.lua` hooks) against the game's copies.

## Running tests

```bash
# all Lua tests (from repo root; each exits non-zero on failure)
for t in tests/test_*.lua; do lua5.4 "$t" || echo "FAILED: $t"; done

tools/dbtest.sh    # PHP history store (needs docker)
tools/uitest.sh    # web console under jsdom (needs docker)
tools/e2e.sh       # full docker stack against fakeserver (needs docker + lua)
tools/localserver.sh start   # real game server on the test galaxy, see docs/local-testing.md
```

Against the real engine: `tools/localserver.sh lab <step>` drives the boss lab. `/run` lines
must be one short line (the console strips `;` and truncates, and can wedge); put anything
bigger in `devsetup.lua`. Running e2e while the local stack is up: set
`COMPOSE_PROJECT_NAME=something-else`, or its `down -v` removes the stack's volumes.

Lua tests must run from the repo root. They set `package.path` to
`data/scripts/lib/?.lua;tests/?.lua` and `dofile` the real `bridge.lua`.

## Conventions

- Comment density is high and explanatory ("why", including verified game behaviour).
  Match it. Section banners look like `-- #### NAME #### --`.
- Lib modules are `local M = {} ... return M`, loaded with `include("automationapi/...")` in
  game and `require("automationapi.x")` in tests.
- Errors have stable `code`s that clients branch on. Changing a response shape
  incompatibly means bumping `Config.apiVersion`.
- Anything shipped to the Workshop comes from git-tracked `data/`, `docs/`, `tests/` and
  top-level files (see `tools/copy.sh`). `docker/`, `web/` and `tools/` are dev/deploy only.
