# Local testing

How to run a change against a real Avorion server on your own machine, before anyone else
sees it. The unit tests (`tests/test_*.lua`, see the README's Development section) run the mod
against a mock of the game. This is the step after: the real engine, a real galaxy and the
real Docker bridge, with the web console on top.

Everything machine-specific - where the game is installed, which galaxy, your API key - lives
in two gitignored files, `tools/local.env` and `docker/.env`. Nothing in this document needs
your paths anywhere else.

## What you need

- Avorion installed (the dedicated server binary ships with the game: `bin/AvorionServer`)
- a galaxy of its own for testing. The boss lab below spawns ships and bosses into it.
- `docker` with compose, `lua5.4`, `curl`, `python3`

## One-time setup

### The test galaxy loads the repo

Point the galaxy's `modconfig.lua` at your checkout, so the server runs the working tree and
there is no copy step:

```lua
-- <galaxies>/<galaxy>/modconfig.lua
mods = {
    {path = "/absolute/path/to/avorion-automation-api"}
}
```

Scripts are read when an entity or player loads them, so a changed library shows up on the next
`/run`, while a changed `orderchain.lua` or `bridge.lua` needs the server restarted.

### tools/local.env

```bash
cp tools/local.env.example tools/local.env
```

Fill in `AVORION_DIR` (the directory holding `bin/AvorionServer`), `GALAXY_DATAPATH` and
`GALAXY_NAME` (the galaxy is `GALAXY_DATAPATH/GALAXY_NAME`), and `PLAYER_INDEX` - yours is the
number in `players/player_<n>.dat` in the galaxy folder.

### docker/.env

```bash
cp docker/.env.example docker/.env
```

For a local stack the settings that matter are:

```bash
GALAXY_DIR=/absolute/path/to/galaxies/<galaxy>   # the directory holding moddata/
BRIDGE_USER=1000:1000                            # `id -u`:`id -g`, so the bridge owns its files
POSTGRES_PASSWORD=<openssl rand -hex 24>
TLS_HOSTS="localhost 127.0.0.1"
TLS_DEFAULT_SNI=127.0.0.1
```

## The local server

`tools/localserver.sh` runs the dedicated server headless, with its console on a pipe, so both
you and scripts can send it commands:

```bash
tools/localserver.sh start          # waits until the mod reports ready
tools/localserver.sh log 50         # the server's output (.local/server/server.log)
tools/localserver.sh cmd '/save'    # any console command
tools/localserver.sh run 'print(Server().name)'
tools/localserver.sh key            # a fresh API key for PLAYER_INDEX - put it in tools/local.env
tools/localserver.sh stop           # /save, /stop; SIGINT if the console is wedged
```

Look for these lines in the log after `start`. Anything else about AutomationAPI is worth reading:

```
AutomationAPI: v0.5.3 ready, API v1, transport directory: .../moddata/AutomationAPI
AutomationAPI: transport directories ready: requests, responses, events, keys
```

Two things to know about the console:

- **`/run` takes one short line.** The console reads a line per command, strips semicolons
  and truncates long lines, and what is left over can wedge it until the server is stopped. Anything
  longer than a call belongs in `data/scripts/lib/automationapi/devsetup.lua`, which exists for
  exactly this. `tools/localserver.sh run` adds `data/scripts/lib` to the package path first,
  because a bare `/run` cannot `include` mod libraries.
- Every `/run` logs `Error while adding` first. The console tries the line as an expression
  before running it as statements; the message is noise.

Do not open the same galaxy from the game client's own "host" menu while this runs - two servers
on one save.

## The bridge over HTTPS

```bash
tools/localserver.sh start          # the game first: the mod creates moddata/
cd docker && docker compose up -d --build
```

The stack answers on plain HTTP (`http://localhost/`) as before, and on HTTPS for every name in
`TLS_HOSTS`, with a certificate from Caddy's own local CA. HTTPS matters for the console:
browsers only allow notifications in a secure context, which is HTTPS or a page on `localhost`
itself. From another machine, `http://192.168.x.y/console/` gets no notifications.

### Trusting the CA

The CA is created on first start and kept in the `caddy_data` volume, so this is once per
browser (and again only if that volume is deleted):

```bash
docker compose -f docker/docker-compose.yml cp \
    api:/data/caddy/pki/authorities/local/root.crt ./caddy-root.crt
```

- **Firefox:** Settings → Privacy & Security → Certificates → View Certificates → Authorities →
  Import, tick "trust this CA to identify websites".
- **Chrome/Chromium:** Settings → Privacy and security → Security → Manage certificates →
  Authorities (on Linux) → Import.
- **System-wide on Arch** (curl, most tools): `sudo trust anchor --store caddy-root.crt`.
  Other distributions use `update-ca-certificates` or `update-ca-trust`.

Do not just click through the certificate warning. Browsers treat an overridden certificate
error differently from a trusted one, and notifications are among the features that can be
withheld.

For another machine on your network, add its name or IP to `TLS_HOSTS` and recreate the
container (`docker compose up -d --force-recreate api`). A browser sends no server name when it
opens an IP address, so Caddy has to be told which certificate to present then: set
`TLS_DEFAULT_SNI` to that IP. One IP works this way, and hostnames need no extra setting.

### Checking it

```bash
. tools/local.env
curl --cacert caddy-root.crt -H "X-API-Key: $API_KEY" "$API_URL/ping"
curl --cacert caddy-root.crt -H "X-API-Key: $API_KEY" "$API_URL/ships"
```

Then open `https://localhost/console/`, paste the key, and press the bell in the top bar.

## The boss lab

Boss farming only does something after ten jumps with a player aboard and a 4% roll. The lab
helpers in `devsetup.lua` set up the part that happens in the sector - a boss, its loot, a
carrier with fighters - on demand, and print what the engine answers to the calls
`entity/orderchain.lua` makes.

### Headless, no client needed

Each step runs in the sector's next update. `tools/localserver.sh lab` sends it, waits a few
seconds (`WAIT=10` for more) and prints the lab's output. The lab uses sector `LAB_X:LAB_Y`,
380:0 by default, inside the Swoks ring. Pick an empty sector.

```bash
tools/localserver.sh lab load        # twice: loading takes a moment
tools/localserver.sh lab setup       # a carrier for PLAYER_INDEX, and Swoks
tools/localserver.sh lab fighters    # 12 fighters with pilots (needs a frame after setup)
tools/localserver.sh lab report      # what a farm sees: boss, loot by kind, hangar, stats
tools/localserver.sh lab kill        # Swoks dies; money, resources, cargo, a subsystem, a torpedo
tools/localserver.sh lab loot        # every squad on CollectLoot
tools/localserver.sh lab report      # ...a minute later: what the fighters took
tools/localserver.sh lab recall
tools/localserver.sh lab pickup      # the stat Transporter Software adds
tools/localserver.sh lab plan route  # a plan through the mod's orderchain callable
tools/localserver.sh lab state       # what the orderchain publishes
tools/localserver.sh lab clear       # delete everything the lab made
tools/localserver.sh lab forget      # and its carriers' rows in your ship database
```

`setup transporter` builds the carrier with a transporter block. Always finish with `clear` then
`forget`. A deleted craft keeps its row in the owner's ship database, and without `forget` every
lab carrier stays in `/ships` and the console's fleet list.

A farm plan sent with `lab plan farm` ends at once with `pilot_left`, because nobody is aboard.
That is correct, and it is as far as a headless test of the farm loop itself can go.

### What it established (Avorion 2.5.13)

| question | answer |
|---|---|
| does `getEntitiesByScript("entity/story/swoks.lua")` find Swoks | yes, title `Boss Swoks ${num}` with its argument resolves to "Boss Swoks III" |
| does the AI see Swoks as an enemy on arrival | no: `isEnemyPresent` is false with him in the sector, which is why a farm stops for the boss script and not for enemies |
| what Swoks leaves | `CargoLoot` (most of it), `TurretLoot`, `ResourceLoot`, `SystemUpgradeLoot`, `MoneyLoot` |
| what `Loot:isCollectable(ship)` means | whether the ship has room: cargo is collectable on any ship with a cargo bay, never without one. A torpedo drop has no loot component and is not collectable without torpedo storage. |
| do fighters on `CollectLoot` launch and collect | yes, only as many squads as the hangar supports. Money, resources, turrets and subsystems were all gone within a minute. |
| what fighters need for cargo | a transporter block **and** the `FighterCargoPickup` stat. Either one alone and every cargo drop stays. |
| does the `Transporter` component tell a transporter block apart | no, every ship has it. `Plan():getNumBlocks(BlockType.Transporter)` does. |
| `FighterOrders.Return` | the squad was back in the hangar within 25 s |
| `getSquadFighters` | counts fighters in the hangar only, not the ones out |

### In game, with the client

What the lab cannot do headless is the part that needs you at the controls: the farm loop
itself, and fighters and orders on a ship a player is flying. Join the local server, board a
carrier with fighters in a boss ring, start the farm from the console's Travel tab, and on an
empty sector of the loop spawn the boss beside you:

```bash
tools/localserver.sh run 'include("automationapi/devsetup").spawnBoss(1, "swoks")'   # or "ai"
```

Then check, in the Travel tab and the notifications:

1. the boss shows up as **in sector** and the loop stops for it, before it turns hostile
2. killing it counts a kill and starts the cooldown countdown
3. the fighters launch for the loot, cargo only with a transporter block and the software
4. they return before the ship moves on, and the ship sits the cooldown out without jumping
5. with the page in the background: "Boss spawned", "Boss killed" and, once the pause is over,
   "Boss cooldown over". Set the pause to 1 minute on the farm form for that last one.

## Cargo transfers: still to check in the engine

The transfer is built from the calls vanilla's transfer window makes
(`entity/transfercrewgoods.lua`) and is tested against a model of them, not against the game
yet. These are the assumptions it rests on, and the order to check them in. Put a ship with
cargo and a captain next to one of your stations in the test galaxy, then use the Orders tab.

| assumption | how to see it |
|---|---|
| `Sector():getEntitiesByFaction(index)` finds the target by owner and name | a transfer in reach answers `done`, not `target_not_here` (the code falls back to scanning ships and stations if the call does not exist) |
| `removeCargo`/`addCargo` with a good from `getCargos()` behave as in `transferCargo` | the holds change by the amounts reported; stolen goods stay stolen |
| a station's `freeCargoSpace` is its real room, and a factory picks up goods added this way as stock | the station's Economy tab shows the stock grow |
| `getNearestDistance` of a docked ship is under 20 | a transfer after docking answers `done` without `out_of_range` |
| `DockToStation` enchained without a calling player docks the ship, and the chain empties once it is docked | the ship docks, and the transfer finishes after it |
| `ShipAI():setFly(target.translationf, target.radius + ship.radius)` brings two ships within reach without ramming | a ship-to-ship transfer from a few km away ends `done`, not `timeout` |

## Cleaning up

```bash
tools/localserver.sh lab clear && tools/localserver.sh lab forget
cd docker && docker compose down        # add -v to drop history and the Caddy CA
tools/localserver.sh stop
```

Keys made with `tools/localserver.sh key` stay valid in the test galaxy until revoked - `/apikey
list` and `/apikey revoke <fingerprint>` in game.
