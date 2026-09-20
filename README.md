<div align="center">

<img src="logo.svg" alt="Automation API" width="300">

# Automation API

**An Avorion server mod that turns your fleet into a JSON API.**

Read your ships, captain missions and map knowledge over HTTP, so an external program can
plan and dispatch mining, trading and salvage runs instead of you clicking through the
galaxy map.

[![Steam Workshop](https://img.shields.io/badge/Steam_Workshop-Automation_API-1b2838?logo=steam&logoColor=white)](https://steamcommunity.com/sharedfiles/filedetails/?id=3799355928)
[![Avorion 2.5+](https://img.shields.io/badge/Avorion-2.5%2B-1f6feb)](https://www.avorion.net/)
[![version 0.7.1](https://img.shields.io/badge/version-0.7.1-8957e5)](modinfo.lua)
[![server-side only](https://img.shields.io/badge/server--side-only-2ea043)](#install)
[![Lua 5.2 sandbox](https://img.shields.io/badge/Lua-5.2%20sandbox-2C2D72?logo=lua&logoColor=white)](#how-it-talks-to-the-outside-world)
[![license](https://img.shields.io/github/license/Rustypredator/avorion-automation-api?color=3fb950)](LICENSE)

[**Workshop**](https://steamcommunity.com/sharedfiles/filedetails/?id=3799355928) · [**API reference**](docs/api.md) · [**Protocol**](docs/protocol.md) · [**Bridge guide**](docs/external.md) · [**Web console**](#web-console)

</div>

---

- read your fleet, including craft in unloaded sectors and while you are offline
- preview a captain mission with the game's own yield and risk prediction, then start it
- automate captain missions per craft: the mod sends the ship back out whenever it is free,
  picking the duration, trade route and deposit that stay under an ambush-chance ceiling and
  inside the trade customer's patience - shared across an alliance, running with no client
- move ships across the galaxy, or give in-sector orders, and watch what they actually do
- send a ship to a sector, to wherever another of your craft is, or to a named location from
  a library you and your alliance share
- plan routes that prefer gates or wormholes, take the fewest jumps, keep out of rifts or stay
  in no man's space, and have the ship fight, hold or press on when enemies show up on the way
- farm bosses: loop jumps through empty space in the AI or Swoks ring while you fly the ship; the ship recognises the boss, sends fighters for the loot and sits out the 30 minute cooldown after a kill
- let idle ships defend themselves: aggressive while enemies are in the sector, idle after
- and let them know when to stop: below a hull or shield threshold a ship breaks off and
  runs for known space, friendly space, one of your stations or a named location
- get told about it while you are away from the machine: the bridge pushes to ntfy, Gotify
  or a webhook when a craft is attacked, is losing a fight, runs, goes idle or goes missing
- query known sectors, and predict unvisited ones straight from the galaxy seed
- read your stations' books - production chain, stock, and what each one has earned - and
  keep a series of them, so a lifetime total becomes credits an hour
- record what your stations actually do, from inside them: every trade at the price it
  settled at, and every production cycle against the slot time it had

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

### 1. Get the mod into the galaxy

**From the Workshop.** Put the Workshop ID in the galaxy's `modconfig.lua` and the server
downloads and updates the mod itself:

```lua
mods = {
    {workshopid = "3799355928"}
}
```

**From this repo.** Clone it anywhere and point at the folder **by path** - a local copy
has no Workshop ID to resolve:

```lua
mods = {
    {path = "/absolute/path/to/avorion-automation-api"}
}
```

For a dedicated server `modconfig.lua` lives in the galaxy folder, e.g.
`~/.avorion/galaxies/defaultgalaxy/modconfig.lua`.

### 2. Start the server with an absolute `--datapath`

Not specific to this mod, but it breaks this one loudly: give the server an **absolute**
`--datapath`, never a relative one.

```
# wrong
./bin/AvorionServer --galaxy-name defaultgalaxy --datapath ./galaxies

# right
./bin/AvorionServer --galaxy-name defaultgalaxy --datapath /home/avorion/.avorion/galaxies
```

A relative datapath is resolved against the server process's working directory, so the
galaxy folder - and with it `moddata/` - lands wherever the process happened to be started
from. Start the server from a service file, a different shell or a container with another
`WorkingDirectory` and the same command points at a different galaxy directory. Mods that
read or write files under `moddata/` then write into a directory nobody else is looking at:
here that means the bridge process watches one `requests/` folder while the mod polls
another, so requests are never picked up and responses never appear, with no error on
either side.

### 3. Start the server and take a key

Start it. The server console should show `Found 1 mods` and then two lines from the mod:

```
AutomationAPI: v0.7.1 ready, API v1, transport directory: moddata/AutomationAPI
AutomationAPI: transport directories ready: requests, responses, events, keys
```

The first is the path a bridge has to be pointed at. The second means the mod could create
and write its directories; if it could not, it says which one and why instead, and repeats
nothing until the answer changes.

From then on it prints one throughput line a minute, and only when something happened:

```
AutomationAPI: [21:14:03] 12 requests, 12 responses, 0 failures in the last 60s
```

`failures` counts what went wrong at the mod's end - a request it could not read, a
response it could not write, and any 5xx it produced itself. A 401 or a 404 is a normal
answer and is not counted. Requests still waiting on background work are reported as
`still in flight`; a number that only grows is the sign worth chasing. `Config.statsInterval`
and `Config.statsWhenIdle` in
[`config.lua`](data/scripts/lib/automationapi/config.lua) change the period, turn the line
off, or make it a heartbeat that prints even when idle.

In game, run `/apikey new` to get a key. It is shown once. To let non-admins run the
command, add `<command name="apikey"/>` to `defaultAuthorizationGroup` in
`<galaxy>/admin.xml`.

Making a key is the only part that has to happen in game. Naming, checking and revoking
your keys are on the console's **Keys** tab and at [`/keys`](docs/api.md#keys) - see
[Managing your keys](#managing-your-keys).

The mod is `serverSideOnly`, so clients do not download it and do not need it installed.

### 4. Run a bridge process

This part the Workshop cannot do for you. The mod has no socket of its own, so nothing
answers HTTP until a bridge process is running beside the server - either the Docker stack
in [`docker/`](docker/) or your own, per [docs/external.md](docs/external.md). Until then
the API is reachable only over the file transport shown below.

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

## Web console

`web/` is a browser console for the API - fleet overview, cargo, loadout, captain
missions, orders, travel, a galaxy map, a live per-ship event log and a per-station economy
view. It is plain HTML and JavaScript with no build step and no CDN, and all of its logic
runs in the browser: it holds your key, talks to the API directly and stores nothing on a
server.

The fleet filter searches names, status, sector and owner, and also the goods a craft is
carrying: type `fusion` and the stations holding Fusion Cores come up, with the matching
part of their manifest on the row. Holds are not in the listing endpoint, so that half of
the search reads `/ships/{name}` once per craft, at background priority behind anything you
are doing and cached for two minutes - it happens only once you have typed something.

Select a station and the **Economy** tab shows what it has earned and every good it trades,
with its stock against the cap the station itself works to - and the bridge's own series
underneath, turning that lifetime total into credits an hour and a bar per hour or day. The
**Production** tab beside it draws the line itself as a node graph: ingredients on the left,
the factory in the middle, results and waste on the right, one arrow each. Mission and
Travel are not offered for a station: the game refuses both outright.

The **Orders** tab moves cargo too: pick another craft of yours or your alliance in the same
sector, see both holds, and tick the goods to give or take and how many - or all of it. A
target out of reach is docked with or flown to first. Programs on the **Automation** tab have
the same step, with goods picked from the hold as it is now or named for what it will hold
when the step runs, so a craft can farm or mine, fly home and unload by itself - and a
transfer with a craft in another sector travels there first.

The **Automation** tab lists every craft set to do something by itself, stations with a
captain included, with a search box over names, sectors and what each is set to do. A
station's program holds only steps that keep it where it is: standing orders, orders, cargo
and waits. Destinations on the **Travel** tab, in the mission planner and in route and
travel steps can be a sector, another craft - flown to wherever it is at the time - or a
location from the library kept on the Automation tab, which your alliance shares.

The **Mission** tab's **Automation** section turns whatever the planner below it holds into a
rule: set a ceiling on the ambush chance, a duration window, how many trade flights the
customer should have to sit through, a deposit cap or a credit reserve, and put what matters
in order - profit an hour, total yield, safety, time away, fewest flights, smallest deposit.
Trade rules scan the area around the ship every way it fits before each contract, so they
pick from whatever routes are open near the ship at the time, can prefer or avoid goods, and
take the deposit that keeps the ambush chance under your ceiling. Name escorts to make a
pair: the pair goes out together, a required escort holds the ship back until it is ready,
an optional one is left behind when it is not. **Test limits** runs the check without
starting anything and lists every option it weighed with why each would or would not go. Once
saved, the mod does the rest; the fleet list badges each automated craft with what its rule is
doing, and every alliance member's console shows the same rules and state.

The standing orders on the **Orders** and **Automation** tabs include **break off and run**:
set a hull or shield threshold in percent and where the craft should go, and it clears its
chain and jumps out rather than dying where it stands. Beside it the console shows the hull
and shield the craft itself last published, and how its last run ended.

The **Keys** tab is your credentials: the API keys the mod issued you, and which of them
the bridge's background services are allowed to call the API with. See
[Managing your keys](#managing-your-keys) and [Enrolling a key](#enrolling-a-key).

The **Alerts** tab is where push notifications are set up - channels, rules and what has
already been sent. It reads its whole form from the bridge, so it offers whatever that
bridge knows how to watch and send to.

The **Industry** tab puts those lines together, one sector at a time. Each station in the
sector is a card with its ingredients down one edge and its results down the other, wired
to the stations it feeds, so a sector reads as the production chain it actually is.

Amounts are per hour rather than per cycle, because a cycle's length differs from line to
line: the mod reproduces the game's own cycle time for every station, from the value of
what it makes and its plan's production capacity. So if one station makes 75 of a good an
hour and another uses 60, the sector has 15 left over. Goods the sector uses faster than
it makes come in from the left for the shortfall, goods left over leave on the right, and
the **Goods balance** underneath lists every one with what the difference is worth and the
nearest of your stations elsewhere that would cover it. **Projected revenue** adds that up:
every surplus sold and every shortfall bought, for the sector and for each station's share.

It does that on one of two bases. **Measured** runs each station at the rate it was recorded
running - its real cycles against its slot time, with how busy each line was and whether it
idled for want of an ingredient or of room - and prices each good at what it actually
traded for. **Ceiling** is every slot busy and every sale at base price, which is what the
game's own formula says the line could do. A station with nothing recorded yet keeps its
ceiling either way, and the card says so. Under it the bridge's history
draws what the sector actually earned, stacked by station per hour or day; the station's
own **Economy** tab draws its history as earned, spent and net lines.

All of it comes from `/stations` and the bridge's `/history/economy/observed`; clicking a
station opens it in the Fleet view,
and a station's Production tab links back to its sector.

The heading on both is the station's real identity rather than its script. Every factory in
the game - a Solar Power Plant, an Iron Mine, a Book Factory - runs the same `factory.lua`
and reports the same `kind`, so the mod resolves the production's own title template against
the good the line makes and reports that as `production.title`.

The map can also draw where a fleet has actually been - a heatmap of time spent per sector
and a per-craft travel track - out of the history the bridge keeps. See
[Fleet history](#fleet-history).

The Docker stack in `docker/` serves it from the API's own origin:

```bash
cd docker
cp .env.example .env      # point GALAXY_DIR at the directory holding moddata/
                          # and set POSTGRES_PASSWORD to anything
docker compose up -d --build
```

Start the game server first. The mod creates the transport directory and owns it, and the
server console says which one it picked - `GALAXY_DIR` is that path with
`/moddata/AutomationAPI` taken off the end. If that is not the directory you expected, check
the server's `--datapath` is [absolute](#2-start-the-server-with-an-absolute---datapath). Point it somewhere else and Docker will make
the directory itself rather than failing, at which point nothing can write to it; the
bridge answers `bridge_unavailable` or `transport_not_writable` and says so.

`tools/e2e.sh` tests the whole deployment - mounts, ownership, round trip, history,
station economy - without Avorion, by running the real mod code against a throwaway
directory.

Then open `http://<your-api-host>/console/` and paste an API key. The address field is
already filled in with the page's own origin, so there is nothing else to set.

The console's browser notifications (a boss spawning, a cooldown ending) need a secure context:
HTTPS, or the page opened on `localhost`. The stack also serves HTTPS with a self-signed
certificate for the names in `TLS_HOSTS` - trust Caddy's local CA once and open
`https://<name>/console/` instead. [docs/local-testing.md](docs/local-testing.md#the-bridge-over-https)
has the steps.

You can also just open `web/index.html` off disk, but then the page and the API are
different origins and the browser has to be let through. The bridge sends the CORS
headers for that by default (`CORS_ORIGIN` in `.env` narrows or disables them), which
includes the one Chrome wants before a page off your disk may reach an address on your
own network. A bridge built before those headers existed refuses the page with no usable
error - rebuild it. Serving the console from `/console/` sidesteps the whole question.

## Fleet history

The mod's event log is a ring buffer in server memory: 200 entries per ship, gone at the
next restart. That is the right shape for *what is this ship doing now* and no use for
*where has this fleet been this month* - and making it durable on the mod side would mean
writing a growing file from a galaxy script on the game server's own tick, which is a month
of travel data paid for in frame time.

Station books have the same shape of problem for a different reason. The game keeps three
money counters per station and no history at all, so the mod can only ever report a
lifetime total - and *what did this factory make this week* is a question about two
readings. So the bridge samples those counters too, along with each station's stock good by
good, which is the only way to see what a line actually moved: the counters are one number
for the whole station and never say which good earned it.

So the bridge keeps the copy. It relays every call already, and a handful of them carry
everything the store needs:

| from | what it records |
|---|---|
| `GET /ships` | each craft's sector, as a visit - opened on arrival, closed when it moves on |
| `GET /ships/{name}/events` | the mod's own events, past the 200 and past a restart |
| `GET /stations` | each station's running earnings totals and its stock per good |
| `GET /economy` | the faction's money and resources |
| `GET /economy/events` | every trade and production window the stations recorded, paged forward with a cursor |
| `GET /ships/{name}` | the craft's hold and who is aboard - the latest only, for the console's goods search |
| `GET /ping` | which player the key belongs to and which alliance they are in |

Positions come from the ship database, which reads fine **with every player logged out**, so
the travel record keeps filling whether or not anyone is flying. So do the station books:
they are read out of the same database rows, not off a loaded sector.

Read it at `/history/summary`, `/history/visits`, `/history/heatmap`, `/history/events`,
`/history/manifests`, `/history/economy/summary`, `/history/economy/series`,
`/history/economy/goods`, `/history/economy/observed` and `/history/economy/events` - full
reference in [docs/api.md](docs/api.md#bridge-local-endpoints). The console draws the
travel overlays on the map and the economy ones on the station's Economy tab.

A few things to know about it:

- **Nothing in the mod pushes.** Movement is only recorded when something asks for `/ships`,
  and the mod's own event log is a 200-entry ring buffer that drops its oldest entry whether
  or not anyone collected it. The `poller` service is what keeps something asking - and it
  only does so for players who have enrolled a key, on the console's **Keys** tab under
  *Background services*. Without that the history only covers the moments a console
  happened to be open, and dwell is reported as *observed* seconds rather than guessed at
  either way.
- **Alliance history is shared; your own stays yours.** A row belongs to whoever owns the
  craft, as the mod reported it, so an alliance's fleet has one history whichever member's
  console or poller saw it, and every current member reads it. Your own craft are readable
  by your keys only - all of them, since it is one history per player. The bridge asks the
  mod which alliance a key's player is in every few minutes (`HISTORY_VERIFY_TTL`, default
  300s), so leaving an alliance takes its history with it, and while the game server is
  down nobody reads alliance history at all. No member can clear it.
- **It stores only a SHA-256 of your API key**, and nothing is written except off the back
  of a call the mod itself answered. A key the mod refuses reads nothing. The one
  exception is a key you *enrol*, below, which has to be kept because the poller presents
  it. One member enrolling is enough to keep an alliance's fleet recorded; each player's
  own fleet needs that player.

Upgrading from a bridge that kept history per key needs nothing done by hand. The schema
migrates on the first connection, each key keeps reading exactly what it recorded, and the
first time the mod vouches for that key again - the console connecting, or the next poller
pass - its rows move onto the player and alliance they belong to. Two members' copies of the
same alliance craft are merged rather than doubled. A player who has left their alliance
since keeps their old copy of its craft, readable by that key alone.

It lives in Postgres, in the `history` Docker volume. `HISTORY_DB_HOST=""` turns it off
entirely; `HISTORY_DAYS` (default 30) sets how far back it keeps, and the poller deletes
anything older on an hourly pass. Economy samples are additionally thinned to one per
station per `HISTORY_ECONOMY_INTERVAL` (default 300s) - the mod reads a station's books out
of its database row, and the game only rewrites that row when it saves, so a faster sample
is a copy of the last one.

## Push notifications

Avorion is a game you leave running, and the console's browser notifications only reach a
tab that is open on a machine that is awake. So the bridge does the other half: it watches
what the poller has already recorded and pushes an alert to **ntfy**, **Gotify** or a
**webhook** - a self-hosted or free service with a phone app, or anything else you can point
a JSON POST at.

Nothing new is asked of the game. Every alert is built from rows the history store already
holds, plus one craft listing per key per pass, so the game server pays nothing for it.

Nine things a rule can watch: a craft coming **under attack**, its **hull** or **shield**
falling below a fraction of its own maximum, it **breaking off and running** (and where it
got to), going **out of orders**, a **route or boss loop ending**, a **boss** spawning or
dying, its **status line** matching some text, and a craft **going missing** from the fleet.
Thresholds fire on the way down and rearm once the craft has recovered, and every rule has a
quiet period, so one long fight is one buzz rather than forty.

Rules and channels belong to a player, not to a faction - which is the opposite of
everything else the bridge stores, and right here: what a craft did is shared by an
alliance, but whose phone buzzes is not. A rule can widen to your alliance's craft and is
still yours, sent to your channels; another member configures their own and sees nothing of
yours. Channel tokens are never handed back out by the API.

Set them up on the console's **Alerts** tab, or through
[`/notifications`](docs/api.md#push-notifications). Nothing is sent until a key of yours
is enrolled for alerts - see [Enrolling a key](#enrolling-a-key). Unlike the poller, one member is *not*
enough for an alliance - each player who wants alerts enrols themselves, because a rule is
theirs and goes to their channels.

## Managing your keys

A key is not a password: it is the whole account, and anything holding one can do
everything to your craft that you can. The console's **Keys** tab lists yours by
fingerprint - the eight characters `/apikey list` prints - says which one the page itself
is using and what the background services are doing with each, lets you name them, and
revokes them. The same is at [`/keys`](docs/api.md#keys).

New keys are only ever made in game, with `/apikey new`. That is deliberate: a key that
could mint another could never really be revoked, because whoever took it would just make
a second one while you deleted the first. Your chat window is the one place a stolen key
cannot reach.

## Enrolling a key

The poller and the notifier are ordinary API clients: they make the same calls the console
does, so they need one of your keys to make them with. You give them one on the console's
**Keys** tab under *Background services*, or at
[`/services`](docs/api.md#background-services), and pick the two opt-ins separately -
*record my fleet* and *send me alerts* are different things to want.

It takes effect within one pass. Nothing has to be restarted and nobody has to edit a file,
which is the point: on a shared server, `POLL_KEYS` in `.env` meant every player who wanted
a fleet watched was a job for whoever runs the box, and that person ended up holding
everybody's credentials in a text file.

**This is the one thing that stores a key rather than a hash of one**, because a background
service has to present a key and no hash will do. What that means in practice:

- The rows are encrypted with a secret the stack generates into the `enrol_secret` volume
  on first start. That buys nothing against someone already inside the stack, and
  everything against a database dump that travels without the secret - a backup, a copy of
  a volume, a decommissioned disk. Back that volume up with the database; lose it and
  everyone re-enrols.
- The key is never handed back out. Reads answer with a hash as the row's id.
- **forget** deletes it outright, and so does switching both opt-ins off. Revoking the key
  in game with `/apikey revoke` stops it just as dead.
- If you would rather not enrol the key you use day to day, make a second one with
  `/apikey new` and enrol that. It can be revoked on its own.

`POLL_KEYS` and `NOTIFY_KEYS` still work for one start after an upgrade: whatever is listed
is moved into the database once and the settings are then ignored. Take them out of `.env`
afterwards.

An alert is never quicker than the poller, and a craft records nothing while its owner is
logged out, so nothing about it can raise one then. That is the same limit the history store
has, and it is worth knowing, because a missed alert is more surprising than a gap in a
heatmap.

## Endpoints

Full reference in [docs/api.md](docs/api.md).

| endpoint | |
|---|---|
| `GET /ping` | service metadata and API version |
| `GET /keys`, `POST /keys/{fingerprint}`, `.../delete` | your own API keys: list, rename, revoke (new ones are `/apikey new` in game) |
| `GET /ships` | owned craft, with the usability check every mission runs first |
| `GET /ships/{name}` | captain, crew, cargo, turrets, systems, hyperspace, requirements |
| `GET /missions`, `GET /ships/{name}/missions` | mission catalog, resolved for one ship |
| `POST /ships/{name}/missions/{mission}/preview` | dry run with the game's own prediction |
| `POST /ships/{name}/missions/{mission}/start` | start it |
| `GET /ships/{name}/mission` | live status |
| `POST /ships/{name}/mission/recall`, `.../collect` | recall, and collect yields |
| `GET /automation/missions`, `GET`/`POST /ships/{name}/mission/automation` | mission automation rules and what they are doing |
| `POST /ships/{name}/mission/automation/evaluate`, `.../delete` | dry-run a rule's limits, or remove it |
| `GET /automation/programs`, `GET`/`POST /ships/{name}/program`, `.../control`, `.../delete` | order programs: steps a craft works through until conditions are met, looping |
| `GET /automation/missions/library`, `POST /automation/missions/library/{name}`, `.../delete` | mission library: named mission rules that program mission steps fly |
| `GET /locations`, `POST /locations/{name}`, `.../delete` | location library: named sectors to send ships to, shared with the alliance |
| `POST /ships/{name}/travel` | alias of the Travel captain mission's start |
| `POST /ships/{name}/orders` | in-sector order chain: jump, patrol, repair, mine, ... |
| `POST /ships/{name}/route` | plan a route with preferences and fly it as an order chain |
| `POST /ships/{name}/farm` | boss farming: loop through empty space in a boss ring |
| `GET`/`POST /ships/{name}/automation`, `.../stop` | the ship's plan, standing orders (fight enemies, collect loot, break off and run), stop |
| `GET`/`POST /ships/{name}/transfer` | cargo transfer: the holds a craft could trade with, and moving goods into or out of another craft of yours or your alliance |
| `GET /ships/{name}/events` | what the ship has actually been doing |
| `GET /stations`, `GET /stations/{name}` | your stations' books: production, goods, earnings |
| `GET /economy` | the faction ledger, and what its stations have made |
| `GET /stations/{name}/events`, `GET /economy/events` | what stations actually did: trades at real prices, production cycles, reload catch-up |
| `GET /galaxy/info`, `GET /galaxy/route` | galaxy shape, and route planning |
| `GET /map/sectors`, `GET /map/sectors/{x}/{y}` | known sectors |
| `GET /map/predict/{x}/{y}`, `GET /map/search` | unvisited sectors, from the seed |
| `GET /history/*` | where the fleet has been, and what its stations earned - served by the bridge, not the mod |
| `GET`/`POST /notifications/*` | push notification channels and rules - also the bridge's, not the mod's |
| `GET`/`POST /services/*` | which of your keys the bridge's poller and notifier may use - the bridge's too |

## What needs the owner online

Every read works with nobody logged in, because the bridge runs on the Galaxy.

Writes do not. Starting, recalling and collecting missions, travel, routes, farming,
automation settings, cargo transfers and in-sector orders all
answer `409 owner_offline` when the owning player is not in game. That is a vanilla
limitation rather than a shortcut here: mission state lives in a player script, and captain
missions do not tick for offline players in the base game.

The **event feed** is a player script too, but the question it asks is narrower than "is the
key holder online". Alliance craft raise their callbacks on the Alliance object and every
online member's agent registers against them, so an alliance fleet keeps recording while any
one member is in game - whoever that is. Only personal craft go quiet when their own owner
logs out. `recording` and `watchers` on the event feed say which case you are in.

**Mission automation** keeps its rules on the server and its loop in the bridge, so no client
has to stay connected - but each start it makes is still a start, and waits until the owner
(or, for alliance craft, any member) is in game.

**Push notifications** are the bridge's own and need no client either, but they are built
out of what the poller collected, so they inherit the line above: an alert about a craft's
orders, its fights or its flee comes from the event feed, and that goes quiet when nobody
who could record it is in game. Hull, shield and a craft going missing come from the ship
database instead, and keep working on an empty server.

Ship *positions* need nobody at all: they come from the ship database, which is why the
bridge's [fleet history](#fleet-history) keeps filling on an empty server.

## Documentation

| | |
|---|---|
| [docs/api.md](docs/api.md) | every endpoint, its parameters and response shape, including the bridge's `/history`, `/notifications` and `/services` |
| [docs/protocol.md](docs/protocol.md) | the file transport, envelopes, status codes, auth |
| [docs/external.md](docs/external.md) | writing the bridge process and clients against it |
| [docs/local-testing.md](docs/local-testing.md) | a local server, the bridge over HTTPS, and the boss lab |

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

Planned routes, boss farming and standing orders need a third place, because only a script in
the ship's own sector can see enemies in it: `data/scripts/entity/orderchain.lua` extends
vanilla's order chain. It puts a plan's hops on the ordinary chain, watches the sector while
the ship flies them, and publishes its state alongside the chain in the order info the agent
already forwards. Its state is saved with the chain's own, so no script is added to any craft.

Everything else is pure Lua under `data/scripts/lib/automationapi/`: the JSON codec, router,
auth, serializers, the route planner and the per-endpoint handlers.

Six files share a path with the game's own, and Avorion inserts a mod's copy of such a file
into the vanilla one, ahead of its final `return`, rather than replacing it:

- `data/scripts/galaxy/init.lua` attaches the bridge, and `data/scripts/player/init.lua` and
  `data/scripts/alliance/init.lua` the agent, with one `addScriptOnce` line each.
- `data/scripts/entity/orderchain.lua` wraps `updateServer`, `getOrderInfo`, `secure` and
  `restore`. A mod that replaces `orderchain.lua` outright instead of extending it switches
  the automation off, which `GET /ships/{name}/automation` shows as `reported: false`.
- `data/scripts/lib/tradingmanager.lua` and `data/scripts/entity/merchants/factory.lua` hand
  the vanilla file's locals to `automationapi/stationhooks.lua`, which wraps the trade and
  production functions to record what player and alliance stations actually do. The game's
  economy log has no read API; these are the calls that write it.

All six depend on vanilla names - `TradingManager`, `production`, `newProductionError`,
`currentProductions`, the order chain's functions and whatever else they wrap - and need
re-checking against the game's copies after an Avorion update. A renamed station hook turns
recording off rather than breaking a station: every hook checks what it wraps and records
inside `pcall`.

## Development

The pure-Lua modules run outside the game against a mocked Avorion environment:

```bash
for t in bridge ships missions missionautomation movement navigation orderchain map shipevents economy stationevents; do lua5.4 tests/test_$t.lua; done
```

The bridge's history store is PHP over Postgres, so it is tested against a throwaway
database. `tools/dbtest.sh` starts one, runs `tests/test_history.php` in the image the
bridge is built from, and takes both down again:

```bash
tools/dbtest.sh
```

The browser console is tested the same way, against a headless DOM and a fake API. `web/`
deliberately has no build step and no dependencies, so jsdom lives in the test runner
rather than in the repo: `tools/uitest.sh` installs it inside a node image and mounts the
repo read-only.

```bash
tools/uitest.sh
```

It pins the parts of the console that are decided rather than displayed - which subtabs a
craft is offered, whether the live event feed and the bridge's copy of it merge or double,
and which end of the ship log the newest entry is at. All three are silent when they break.

Against the real game, `tools/localserver.sh` runs a headless dedicated server on a test galaxy
and drives its console, and the boss lab in `devsetup.lua` checks the engine calls the farm
makes - see [docs/local-testing.md](docs/local-testing.md). Your paths go in the gitignored
`tools/local.env`.

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
- `getScripts()` and `getSecuredScriptValues()` keyed by script index rather than as a
  sequence, so a station reader that assumes `1..n` finds nothing

## Security

An API key identifies exactly one player, and every request acts as that player. Keys are
stored in plaintext in the galaxy's globals file, deliberately: anyone who can read that
file can already read and write the request directory, which is full control of this API.
Treat filesystem access to the galaxy folder as equivalent to holding every key, and keep
the bridge process bound to localhost.

## License

GPL-3.0. See [LICENSE](LICENSE).

---

<div align="center">

<sub>Built for <a href="https://www.avorion.net/">Avorion</a> 2.5+ · <a href="https://steamcommunity.com/sharedfiles/filedetails/?id=3799355928">Steam Workshop</a> · <a href="https://github.com/Rustypredator/avorion-automation-api/issues">Issues</a></sub>

</div>
