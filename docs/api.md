# Endpoints

All responses are wrapped in the transport envelope described in
[protocol.md](protocol.md); the shapes below are the `body` field.

## GET /ping

Service metadata. Call it first to check the API version.

```json
{
  "api": 1, "mod": "0.4.0", "game": "2.5.13",
  "galaxy": {"name": "defaultgalaxy", "seed": "..."},
  "server": {"runtime": 1234.5, "players": 1},
  "player": {"index": 1, "name": "...", "online": true}
}
```

## GET /ships

Lists owned craft. Reads the ship database, so it works for craft in unloaded sectors
and while the owning player is offline.

| query | values | default |
|---|---|---|
| `type` | `ship`, `station`, `all` | `ship` |
| `owner` | `player`, `alliance`, `all` | `player` |

```json
{
  "count": 2,
  "ships": [
    {
      "name": "Ore Hound",
      "owner": {"kind": "player", "index": 1, "name": "..."},
      "type": "Ship",
      "position": {"x": -134, "y": 88},
      "availability": "Available",
      "status": "Idle",
      "usable": {"ok": true}
    }
  ]
}
```

`availability` is `Available`, `InBackground` (out on a captain mission) or `Destroyed`.

`usable` is the check every captain mission runs first, so it is the field to filter on
when picking ships for work:

```json
{"ok": false, "code": "NoCaptain", "message": "Ship has no captain."}
```

`code` is one of `Unavailable`, `NotAShip`, `NoCaptain`, `BadCrew`, `BadEnergy`,
`Damaged`, `UnderAttack`.

## GET /ships/{name}

Everything the ship database knows. The name is percent-encoded in the path, so
`Ore Hound` becomes `/ships/Ore%20Hound`. Accepts the same `owner` query parameter.

Includes every field from the listing, plus:

| field | notes |
|---|---|
| `captain` | `null` if none. `classes` resolve to names (`Miner`, `Merchant`, ...), `perks` are ints. |
| `crew` | `size`, `maxSize`, `requirementsFulfilled`, and `byProfession` / `ideal` breakdowns |
| `cargo` | `capacity`, `free`, `used`, and `goods` flattened to an array |
| `hyperspace` | `range`, `cooldown`, `canPassRifts`, `impaired` |
| `shields`, `durability`, `energy` | `energy.sufficient` is the derived check |
| `dps` | `turrets`, `fighters`, `total` |
| `turrets` | identical designs collapsed to one entry with a `count`, each carrying mining efficiencies |
| `systems`, `hangar` | installed subsystems and fighter squads |
| `requirements` | crew / turret slot / fighter start / fighter squad checks |
| `blocks`, `planValue`, `reconstructionValue` | |

Errors: `404 no_such_ship` when the caller does not own it, `404 no_ship_data` when it is
owned but has no database row yet.

## GET /missions

The mission types this API knows, and the galaxy's material names in index order.

```json
{
  "missions": [{"mission": "mine", "startable": true}, {"mission": "escort", "startable": false}],
  "materials": ["Iron", "Titanium", "Naonite", "Trinium", "Xanion", "Ogonite", "Avorion"]
}
```

`escort` is attached automatically by the game to escorting ships and cannot be started
directly.

## GET /ships/{name}/missions

The same catalog, resolved for one ship. Area sizes and configurable ranges depend on the
captain - a Miner captain raises Mine's maximum duration - so this is the useful form.

```json
{
  "mission": "mine",
  "areaSizes": [{"x": 15, "y": 15}],
  "areaFixed": false,
  "shipRequiredInArea": true,
  "configurable": {"duration": {"from": 0.5, "to": 2.0, "default": 1.0}},
  "materials": ["Iron", "..."]
}
```

`areaFixed` means the game recentres the area on the ship regardless of what you send.
Trade reports three alternative area shapes.

## POST /ships/{name}/missions/{mission}/preview

Side-effect free, and a genuine dry run: it runs the same area analysis, validation and
prediction that a start runs, using the game's own `calculatePrediction` - the function
behind the order window's yield and risk figures.

```jsonc
{
  "area": {"lower": {"x": -323, "y": 312}, "upper": {"x": -309, "y": 326}},  // or {"center": {"x": .., "y": ..}}
  "config": {"duration": 2, "safeMode": false},
  "materials": ["Iron", "Titanium"],      // omit to select all; also accepted inside config
  "escorts": ["Escort One"]
}
```

Omit `area` entirely and it is centred on the ship at the size this mission requires.
Material selection is by name: the game keys it by index internally, from 0 for Mine and
Salvage but from 1 for Refine, and this API never exposes that.

```jsonc
{
  "mission": "mine", "ship": "Prospector",
  "area": {"lower": {}, "upper": {}, "origin": {}, "stats": {"numSectors": 225, "noMansSectors": 26}},
  "config": {"duration": 2, "materials": ["Iron", "Titanium"], "escorts": []},
  "prediction": {"yields": [{"displayName": "Iron", "from": 52536, "to": 65670}],
                 "attackChance": {"value": 0.41}},
  "assessment": ["The area doesn't contain many asteroid fields.", "..."],
  "errors": {},
  "canStart": true
}
```

`errors` is empty when the mission is startable. Otherwise it carries any of `usable`
(the ship-level check), `command` (the mission's own validation) and `prediction`, each
with the game's own wording:

```json
{"command": {"template": "Not enough turret slots for all turrets!", "args": {}, "text": "..."}}
```

Duration and other numeric config are clamped to the command's own limits, exactly as the
game clamps them, and the clamped values are echoed back.

## POST /ships/{name}/missions/{mission}/start

Same request body as preview. Validates first and refuses with `422` and the full preview
body if the mission could not start, so a rejected start tells you why in the same shape a
preview would have.

On success the ship's availability becomes `InBackground` and the response carries
`"started": true`.

**Requires the owning player to be logged in** - `409 owner_offline` otherwise. Mission
state lives in a script attached to the player, and those only run while that player is in
game; captain missions do not tick for offline players in vanilla either.

The game's own `startCommand` reports failure only as an in-game chat message and returns
nothing, so this endpoint verifies afterwards by reading the ship's availability back. A
silent refusal comes back as `422 start_rejected` rather than a false success.

## GET /ships/{name}/mission

Live status. `{"active": false}` when the ship is not out on one.

```json
{
  "ship": "Prospector", "active": true, "availability": "InBackground",
  "mission": "mine",
  "progress": {"template": "...", "args": {"timeRemaining": "42m"}, "text": "..."},
  "config": {}, "prediction": {}, "areaStats": {},
  "yields": 2
}
```

Progress text is refreshed by the game once a minute, so it can be up to that stale.

## POST /ships/{name}/mission/recall

Recalls a ship. A command may refuse - a ship mid-repair, for instance - in which case
`recalled` is false and `note` explains. Pass `?force=true` to bypass, which skips the
command's own finalisation.

## POST /ships/{name}/mission/collect

Collects waiting yields into the owner's account. Returns `collected` and `remaining`.

## POST /ships/{name}/travel

Moves a ship anywhere in the galaxy. This is a Travel captain mission under a shorter
name: it goes through the same analysis, prediction and start path as
`/ships/{name}/missions/travel/start` and returns the same body, so the response carries
a real route prediction and attack chance rather than just an acknowledgement.

```jsonc
{"to": {"x": -300, "y": 310}, "swiftness": 2}
```

`swiftness` is 0 (careful, slow, unlikely to be attacked) to 3 (reckless, fast, risky) and
defaults to 2.

Prefer this to `/orders` for anything that is not tactical. It loads no sectors, works
wherever the ship is, and the game drives it to completion.

The destination is checked before an area analysis is spent on it. The game refuses to
send a ship somewhere it could already reach in one hop, so these come straight back:

| code | when |
|---|---|
| `422 already_there` | the ship is in that sector |
| `422 destination_too_close` | inside jump range with no rift between, or on the far side of a gate or wormhole out of the ship's current sector |

The same rule is enforced after the analysis too, since only then is the real route known:
a route of two sectors or fewer sets `errors.start` to the game's own
`"This route is too short."` and `canStart` to false. That applies to preview as well, so
a preview of a travel mission no longer claims a start would succeed when it would not.

**Requires the owning player to be logged in.**

## POST /ships/{name}/orders

Enqueues in-sector orders on the ship's own order chain - the same chain the map UI drives.

The engine's dispatch is fire-and-forget: it runs on the ship's next update tick, returns
nothing, and silently discards the call if the sector is not resident. So this endpoint
does not answer immediately. It holds the request open until the ship reports back a chain
holding the orders that were sent, and answers:

| status | meaning |
|---|---|
| `200` | `confirmed: true` - the ship reported a chain holding these orders |
| `202` | `confirmed: false` - dispatched, but no such chain was reported within the window |

`202` is not proof of failure. A one-shot order that completes instantly can land and clear
again inside the window. `GET /ships/{name}/events` shows what actually happened.

```jsonc
{
  "clear": true,
  "orders": [
    {"type": "jump", "to": {"x": 201, "y": 200}},
    {"type": "patrol"}
  ]
}
```

Response:

```json
{
  "ship": "Ore Hound", "confirmed": true,
  "chain": [{"name": "Jump", "action": 1}, {"name": "Patrol", "action": 6}],
  "activeIndex": 1, "finished": false,
  "dispatched": ["jump", "patrol"], "cleared": true, "oneShot": false
}
```

`clear` defaults to true and wipes whatever the ship was doing first.

### Order types

Two families, and the difference is forced by the engine rather than chosen here.

**Chainable** - these enqueue and can be combined, in order:

| type | options |
|---|---|
| `jump` | `to: {x, y}` |
| `patrol` | |
| `repair` | |
| `aggressive` | `attackCivilians`, `canFinish` (both default false) |

**One-shot** - each is implemented in the engine as a wrapper that clears the chain, adds
one order and runs it. They cannot be combined with anything and must be sent alone;
`422 order_not_chainable` otherwise. `clear` is irrelevant for them.

| type |
|---|
| `mine` |
| `salvage` |
| `refine` |

The reason for the split is that `invokeEntityFunction` can only reach functions the game
registers with `callable()`. `addMineOrder`, `addSalvageOrder` and `addRefineOresOrder` are
not registered, so those three have to go through their `onUser*` wrappers - and those
wrappers clear and run the chain themselves.

Orders needing an entity id - attack, board, dock, escort - are not exposed, because this
API never hands out sector entity ids.

### Captain requirements

The order chain refuses orders it will not carry out and reports the refusal only as a chat
message to a calling player, which an API caller is not. Those gates are therefore checked
before dispatch and answered `422 needs_captain`, rather than being dispatched into silence.

| rule | applies to |
|---|---|
| captain, **or** the owner in the ship's sector | every order (`canReceivePlayerOrder`) |
| captain always | `mine`, `salvage` |
| captain **or** a player at the controls | `jump` (it changes sector) |

`mine` and `salvage` need a captain because the engine only skips that check when handed a
target entity, which this API never has.

### Other errors

`422 order_after_terminal` - the chain refuses to enqueue past `patrol` or a persistent
`mine`/`salvage`; enforced here rather than discovered later.
`409 sector_not_loaded` - the ship's sector is not in memory; use `/travel`.
`409 ship_in_background` - it is out on a captain mission.

**Requires the owning player to be logged in.**

## GET /ships/{name}/events

What the ship has actually been doing, newest last.

This exists because the order chain narrates itself by chat message to whoever gave the
order - `"Order completed. Awaiting new orders."`, `"Jump not possible. Terminating orders
in (x:y)"` - and an API caller never receives those. There is no server-side hook on
outgoing chat, and `onChatMessage` fires only for messages a player *sends*.

The same information is published a second way: every change to a ship's order info or AI
status raises a callback on the owning Player or Alliance. The mod registers those and
records them as they fire. Nothing here is polled.

| query | notes |
|---|---|
| `since` | a `cursor` from a previous response; returns only newer events |
| `limit` | newest N events (default and max 200) |

```json
{
  "ship": "Ore Hound", "cursor": 16, "recording": true, "watchers": 1, "dropped": 0,
  "events": [
    {"seq": 13, "at": 7421, "kind": "order", "chain": [{"name": "Aggressive", "action": 5}],
     "activeIndex": 0, "finished": false, "idle": false, "sector": {"x": -316, "y": 319}},
    {"seq": 15, "at": 7422, "kind": "status", "text": "Attacking Enemies",
     "template": "Attacking Enemies /* ship AI status*/", "args": {}}
  ]
}
```

- **Sequence numbers are global, not per ship**, so one cursor works across a whole fleet.
- `idle` is set when a chain empties or finishes - the field to watch for "this ship is free".
- `text` has the game's translator hints stripped; `template` keeps them, so you can still
  match on the untranslated string.
- Consecutive duplicates are dropped. The engine republishes unchanged status text whenever
  the AI re-evaluates, which would otherwise bury the real transitions.
- `recording` is false when no player agent is in a position to see the callbacks fire.
  **Player scripts do not run for a logged-out player, so a quiet log then means nobody was
  watching, not that nothing happened.** `watchers` is how many agents are watching, which
  is the same question asked more precisely.
- **Alliance craft are not tied to the key holder.** Their callbacks are raised on the
  Alliance object, and every online member's agent registers against it, so an alliance
  fleet keeps recording while any one member is in game - whether or not that member owns
  this key. Only personal craft go quiet when the key's own player logs out.
- The log is in memory, capped at 200 events per ship, and empty after a server restart. It
  is a recent-activity feed, not an audit trail. If you want one that survives both, the
  bridge keeps a copy - see [Bridge-local endpoints](#bridge-local-endpoints).

Reads work offline; only the recording needs some agent online.

## GET /stations

Every station the caller owns, with its books. Reads the ship database, so it works for
stations in unloaded sectors and with every player logged out - which is the normal state
of a player's own stations.

| query | values | default |
|---|---|---|
| `owner` | `player`, `alliance`, `all` | `player` |

Only craft that run one of the game's merchant scripts appear. A ship is never in here,
and neither is a defence platform or anything else with no trading manager; use
`/ships?type=station` for a plain list of stations regardless.

```json
{
  "count": 1,
  "stations": [
    {
      "name": "Rusty Refinery",
      "owner": {"kind": "player", "index": 1, "name": "..."},
      "type": "Station",
      "position": {"x": 12, "y": -4},
      "availability": "Available",
      "usable": {"ok": false, "code": "NotAShip", "message": "This is not a ship."},
      "sectorLoaded": false,
      "cargo": {"capacity": 12000, "free": 5000, "used": 7000},
      "economy": {
        "kind": "factory",
        "scripts": ["factory.lua"],
        "production": {"factory": "${good} Refinery ${size}", "title": "Oil Refinery",
                       "style": "Factory", "slots": 3, "active": 2, "margin": 635},
        "earnings": {"fromGoods": 4000000, "spentOnGoods": 1500000,
                     "fromTax": 25000, "net": 2525000},
        "stock": {"Oil": 900, "Raw Oil": 40, "Energy Cell": 1200},
        "settings": {"buyPriceFactor": 0.9, "sellPriceFactor": 1.1}
      }
    }
  ]
}
```

`earnings` are **running totals since the station was founded**, not a rate. That is the
only form the game keeps them in: a `TradingManager` holds three counters and no history.
Two readings and the time between them make a rate, which is what
[`/history/economy/summary`](#get-historyeconomysummary) does.

`stock` is good name to units held, and is here rather than only on the detail endpoint
because it is what a time series needs. The earnings counters are one number for the whole
station and cannot say which line earned it; differencing the stock good by good can say
what was produced and what left.

This is the one call the bridge's economy history is built from, so it is flat and cheap
on purpose - the priced goods lists live on the detail endpoint below.

## GET /stations/{name}

One station in full: everything [`/ships/{name}`](#get-shipsname) reports, plus the
`economy` block with its production chain and the goods it trades.

Answers `409 not_a_station` for a craft that runs no merchant script.

```json
{
  "name": "Rusty Refinery",
  "sectorLoaded": false,
  "economy": {
    "kind": "factory",
    "scripts": ["factory.lua"],
    "production": {
      "factory": "${good} Refinery ${size}", "title": "Oil Refinery",
      "style": "Factory", "mine": false,
      "ingredients": [
        {"name": "Energy Cell", "amount": 5, "optional": null, "price": 61, "size": 1,
         "value": 305, "stock": 1200, "perHour": 3408.75},
        {"name": "Raw Oil", "amount": 10, "price": 66, "size": 2, "value": 660, "stock": 40,
         "perHour": 6817.5}
      ],
      "results": [{"name": "Oil", "amount": 5, "price": 320, "size": 2,
                   "value": 1600, "stock": 900, "perHour": 3408.75}],
      "garbage": [],
      "slots": 3, "active": 2, "running": [{"progress": 0.25}, {"progress": 0.8}],
      "inputValue": 965, "outputValue": 1600, "margin": 635,
      "rate": {"cycleSeconds": 15.84, "cyclesPerHour": 681.75,
               "productionCapacity": 100, "capacityKnown": true},
      "inputValuePerHour": 657888.75, "outputValuePerHour": 1090800,
      "marginPerHour": 432911.25,
      "shuttleVolume": 20
    },
    "goods": {
      "buys": [
        {"name": "Energy Cell", "plural": "Energy Cells", "price": 61, "size": 1,
         "basePrice": 55, "stock": 1200, "maxStock": 4000, "fill": 0.3,
         "illegal": false, "stolen": false, "dangerous": false, "suspicious": false}
      ],
      "sells": [
        {"name": "Oil", "price": 320, "size": 2, "basePrice": 352,
         "stock": 900, "maxStock": 2000, "fill": 0.45}
      ]
    },
    "earnings": {"fromGoods": 4000000, "spentOnGoods": 1500000,
                 "fromTax": 25000, "net": 2525000},
    "settings": {
      "buyPriceFactor": 0.9, "sellPriceFactor": 1.1,
      "buysFromOthers": true, "sellsToOthers": false,
      "activelyRequest": true, "activelySell": false,
      "policies": {"sellsIllegal": false, "buysIllegal": false}
    }
  }
}
```

- `kind` is the station's primary merchant script: `factory`, `tradingpost`, `consumer`,
  `seller`, `equipmentdock`, `shipyard`, `resourcedepot`, `turretfactory`, and so on. A
  station that runs several - a shipyard also runs a repair dock and a consumer - is named
  after the one that defines it, and `scripts` lists them all.
- `kind` does **not** identify a factory. A Solar Power Plant, an Iron Mine, a Gas
  Collector and a Book Factory all run `factory.lua` and all report `factory`. What tells
  them apart is `production.title`: the production's own `factory` template resolved
  against the good the line makes, which is the name the game puts on the hull, minus the
  roman-numeral size suffix - the factory's size is not in the secured data. Use it rather
  than `kind` anywhere a station is being named to a human.
- `price` on a good is the goods index's base value; `basePrice` is that times the
  station's own price factor, which is what the game's own trade UI shows as the base.
  **Neither is what a trade will actually settle at.** The real price also carries a
  supply/demand factor that lives in the sector's `economyupdater` script and a relations
  factor for the counterparty, and neither is in the ship database.
- `maxStock` is the cap the station itself uses to decide it has no room to produce. The
  cargo bay is split evenly between every good traded, so adding a good lowers the cap on
  all the others. `fill` is `stock / maxStock`: a **sold** good at 1 has nowhere to put the
  next cycle, and a **bought** good at 0 is an ingredient the line is waiting on.
- `margin` prices one production cycle at the goods index's own values. It says whether a
  chain is worth running; it is not revenue, since the result still has to be sold.
- `optional` marks an ingredient the line will use if it has it, for a faster cycle, and
  will run without.
- `rate` is how fast the line runs, reproduced from the game's own
  `Factory.refreshProductionTime()`: one cycle takes
  `max(15, value of results and waste / productionCapacity / (1 + average good level / 100))`
  seconds, and `slots` of them run in parallel, so `cyclesPerHour` is
  `slots * 3600 / cycleSeconds`. `perHour` on every ingredient, result and waste good, and
  the three `...PerHour` values, are the per-cycle figures at that pace. **It is a ceiling**:
  every slot busy, which a line out of an ingredient or with a full bay is not. It is also
  the only way to compare two stations' amounts, since cycle length differs between lines.
- `productionCapacity` comes from the station's block plan. Reading a plan loads it out of
  the database, so it is cached per station until the plan's block count changes. When
  the plan cannot be read, `capacityKnown` is false and the game's floor of 100 stands in -
  the slowest the station could be. `boost` is `2` on a line with optional ingredients: a
  cycle started with one in the bay runs twice as fast, which the rates above do not
  assume.
- `secured` is false when the engine has not written this craft's scripts to its database
  row yet - a station founded since the last save. Everything else is then empty rather
  than wrong, which otherwise reads exactly like a factory with no line and no income.

### Where these numbers come from, and how fresh they are

Not from the station's `Entity` - that only exists while its sector is resident, and a
player's stations sit in sectors nobody flies through, so an entity read would answer
"sector not loaded" for exactly the stations their owner cares about.

They come from the craft's database row instead. Every merchant script writes its state
there through `secure()`, and `ShipDatabaseEntry:getSecuredScriptValues()` reads it back.
The cost is that a snapshot is only as new as the last time the engine called `secure()`:
on unload, and on the server's regular saves.

`sectorLoaded` is the flag that matters:

- **false** - the sector is unloaded, and the figures are exactly what the station held
  when it went quiet. Which is also all that has happened to it.
- **true** - the sector is resident, and the figures can trail the live entity by up to
  one save interval.

## GET /economy

The faction ledger: what the caller holds, and what their stations have made.

| query | values | default |
|---|---|---|
| `owner` | `player`, `alliance`, `all` | `player` |

Pass `?owner=all` for the player and their alliance together, which is usually what you
want here - an alliance station's earnings land in the alliance's account rather than in
the founder's.

```json
{
  "count": 2,
  "factions": [
    {
      "owner": {"kind": "player", "index": 1, "name": "..."},
      "money": 12500000,
      "resources": [
        {"material": "Iron", "value": 0, "amount": 40000},
        {"material": "Titanium", "value": 1, "amount": 9000}
      ],
      "stations": {
        "count": 7,
        "earnings": {"fromGoods": 41000000, "spentOnGoods": 12000000,
                     "fromTax": 90000, "net": 29090000}
      }
    }
  ]
}
```

`stations.earnings` is the sum of the running totals of every station the faction owns, so
it is gross lifetime income from trade. `money` is what actually survived crew wages, ship
losses and everything the owner spent it on; the two are not meant to reconcile.

## GET /galaxy/route

Runs the game's own `calculateJumpPath`, the same pathfinder the travel analysis uses.

| query | notes |
|---|---|
| `ship` | take origin, jump range and rift capability from a ship |
| `fromX`, `fromY`, `range`, `rifts` | or give them explicitly |
| `toX`, `toY` | required |

```json
{
  "from": {"x": 0, "y": 0}, "to": {"x": 60, "y": 0},
  "reachable": true, "jumps": 12, "distance": 60.0,
  "route": [{"x": 0, "y": 0}, "..."],
  "jumpRange": 5.0, "canPassRifts": false
}
```

`reachable` is false when the pathfinder stopped short of the destination - check it rather
than assuming the last sector in `route` is where you asked to go.

Explicitly expensive and rate limited to one call every two seconds per player;
`429 route_busy` otherwise.

## GET /galaxy/info

The galaxy's fixed shape. Nothing here depends on what anyone has seen, so it never
changes for a given galaxy.

```json
{
  "name": "apitest", "seed": "...",
  "dimensions": 1000, "bounds": {"min": -499, "max": 500},
  "barrier": {"min": 147, "max": 150},
  "materialBelts": {"Iron": 428.5, "Avorion": 21.4},
  "materials": ["Iron", "..."],
  "homeSector": {"x": -120, "y": 90},
  "knownSectors": 412
}
```

`materialBelts` gives the distance from the core at which each material peaks, converted
from the balancing curves' internal fractions into sector coordinates. `barrier` is the
Avorion ring.

## GET /map/sectors

Known sectors, straight off the player or alliance record. Works offline.

| query | values | default |
|---|---|---|
| `owner` | `player`, `alliance`, `all` | `player` |
| `bbox` | `minX,minY,maxX,maxY`, inclusive, corners in any order | whole galaxy |
| `visited` | `true`, `false` | both |
| `faction` | faction index | any |
| `since` | server runtime; only knowledge newer than this | any |
| `stations` | minimum station count | any |
| `limit`, `offset` | paging | 100 |

```json
{
  "count": 2, "total": 412, "offset": 0, "limit": 100, "truncated": false,
  "sectors": [
    {
      "coordinates": {"x": 0, "y": 0}, "name": "Origin",
      "visited": true, "hasContent": true, "factionIndex": 5,
      "numStations": 2, "numShips": 4, "numAsteroids": 0, "numWrecks": 0,
      "influence": 0.2, "timeStamp": 1234.5,
      "deathLocation": false, "tagged": false,
      "owner": {"kind": "player", "index": 1, "name": "..."}
    }
  ]
}
```

Ordering is by `y` then `x`, so paging is stable between calls.

## GET /map/sectors/{x}/{y}

One known sector in full: everything from the listing plus `stations`,
`gateDestinations`, `wormHoleDestinations`, `note`, `customEntries`,
`stationsByFaction`, `shipsByFaction` and a `balancing` block.

Station titles come back in both forms - `name` is the flat string to match on, `title`
keeps the game's template and arguments:

```json
{"name": "Iron Mine", "title": {"template": "${material} Mine", "args": {"material": "Iron"}, "text": "Iron Mine"}}
```

`404 sector_unknown` when the caller has never seen it. That is what `/map/predict` is for.

## GET /map/predict/{x}/{y}

What the galaxy seed says is in a sector, computed with the generator's own decision
layer. **No sector is loaded**, and it works for sectors nobody has ever visited.

```json
{
  "coordinates": {"x": 10, "y": 10}, "name": "Kaan Prime", "source": "predicted",
  "regular": true, "offgrid": false, "blocked": false, "hasContent": true,
  "gates": true, "ancientGates": false, "centralArea": true,
  "factionIndex": 3, "template": "sectors/factoryfield",
  "numStations": 6, "numShips": 12, "numAsteroids": 0,
  "stations": [{"name": "Turret Factory", "title": {}}],
  "gateDestinations": [{"x": 40, "y": 40}],
  "balancing": {},
  "known": {}
}
```

`regular` sectors are the ones with stations; `offgrid` holds everything else; `blocked`
means a rift sits there and nothing is generated at all. `known` is present only when the
caller has also seen the sector, so one call tells you both what the seed says and what was
actually observed.

`known` is the same compact form `/map/sectors` returns, not the full detail - it is there
to tell prediction from observation at a glance, not to replace `/map/sectors/{x}/{y}`.

Two things prediction cannot know.

The first is anything that happened after generation: stations players built or destroyed,
ships that moved, asteroids already mined.

The second is sectors the game created outside the seed's decision layer. **A player's home
sector is one of them** - the server picks it by walking a circle at radius ~450 looking for
inhabited space, not by asking whether the seed put content there, and then populates it. So
a home sector routinely predicts as empty while `/map/sectors/{x}/{y}` shows five stations.
Prefer observation over prediction wherever both exist; that is exactly why `known` is
included here.

The first prediction after a server start pays for building the rift and faction maps, which
takes a moment. Everything after that is cheap, and both are cached for the life of the
server process.

`balancing` is the same block `/map/sectors/{x}/{y}` carries:

```json
{
  "distanceToCore": 14.1, "techLevel": 51, "richness": 7.8, "pirateLevel": 31.4,
  "highestMaterial": "Avorion",
  "materials": {"Iron": 0.05, "Avorion": 0.4},
  "insideBarrier": true, "inRift": false
}
```

## GET /map/search

The live station search: find every sector with a matching station, whether or not anyone
has been there.

| query | notes |
|---|---|
| `station` | what to look for; case-insensitive substring, comma-separated for alternatives |
| `bbox` | required when `predict=true` |
| `predict` | `true` extends the search into unvisited sectors via the seed |
| `owner` | `player`, `alliance`, `all` |
| `limit` | default 100 |

```json
{
  "query": {"station": ["turret factory"], "predict": true},
  "count": 2,
  "results": [
    {
      "coordinates": {"x": 10, "y": 10}, "name": "Kaan Prime",
      "source": "predicted", "visited": false, "factionIndex": 3,
      "matches": ["Turret Factory"],
      "stations": [{"name": "Turret Factory"}]
    }
  ],
  "scanned": 1681,
  "truncated": false
}
```

`source` is `known` or `predicted`; a sector the caller has visited is always reported from
observation, never predicted twice.

`truncated` is `false`, or `"limit"`, `"budget"` or `"timeout"` when the answer is partial -
narrow the `bbox`, raise `limit`, or search in pieces.

A predicted search is real work: it runs the galaxy generator over every sector in the box.
It is capped at 10000 sectors per request and is deliberately spread across server ticks
rather than run in one, so it takes a few seconds of wall clock and does not stall the
server. Sectors are ruled out by a cheap seed hash first, and only the ~3% holding regular
content cost a full generator run.

# Bridge-local endpoints

Everything above is the mod's. `/history/*` is not: it is answered by the HTTP bridge in
`docker/bridge/`, out of its own store, and never reaches the game server.

## Why it is not part of the mod

The mod's event log is a ring buffer in server memory - 200 entries per ship, gone at the
next restart. That is the right shape for "what is this ship doing now" and no use for
"where has this fleet been this month". Making it durable on the mod side means writing a
growing file from a galaxy script on the server's own tick, which is a bad trade: a month
of travel data paid for in frame time on a running game server.

The station books have the same shape of problem for a different reason. The game keeps
three money counters per station and no history at all, so the mod can only ever report a
lifetime total - and "what did this factory make this week" is a question about two
readings, not one.

So the bridge keeps the copy instead, in a Postgres database alongside it. The bridge
already relays every call and four of them carry everything the store needs, so recording
costs a couple of statements on requests that were happening anyway and nothing at all on
the game side.

Postgres rather than a flat file because every overlay is an aggregate - the heatmap is a
`GROUP BY x, y`, a track is an ordered window, the summary is a count per craft - and a
file makes each of those a full scan in PHP. The volume is small either way: a visit row is
written only when a craft changes sector, so a parked fleet costs nothing.

## What it records, and when

| from | what |
|---|---|
| `GET /ships` | each craft's sector, as a **visit** - opened when it arrives, closed when it moves on |
| `GET /ships/{name}/events` | the mod's own order and status events, kept past the 200 and past a restart |
| `GET /stations` | each station's running earnings totals and its stock per good, as a **sample** |
| `GET /economy` | the faction's money and resources, likewise |

Positions come from the ship database, which the mod reads **with every player logged out**,
so the travel record keeps filling whether or not anything is online to fly.

**Nothing in the mod pushes.** History accumulates only while something is calling the API,
and the mod's event log is a 200-entry ring buffer that drops its oldest entry whether or
not anyone collected it. The compose stack runs a `poller` service for exactly this - set
`POLL_KEYS` to the keys whose fleets should be recorded and it calls these endpoints
every `POLL_INTERVAL` seconds (default 30), which is also the accuracy of a travel track.

Without a poller the record covers only the moments a console or a script happened to be
running, and a gap in it is a gap in who was looking rather than a gap in what happened.
Either way dwell is reported as *observed* seconds: time nobody was watching counts as zero
rather than being guessed at.

**Economy samples are thinned on the way in.** Unlike a visit, a sample cannot be extended
in place - a time series is exactly the repetition - so a row per station per pass would be
thousands a day, all of them copies: the mod reads a station's books out of its database
row, and the game only rewrites that row when it saves. `HISTORY_ECONOMY_INTERVAL` (default
300s) is the floor between two stored samples of the same station. The poller keeps calling
at its own rate either way, so a console that is open still shows live numbers; only the
durable copy is thinned.

Event timestamps are reconstructed rather than stamped on arrival. The mod tags each event
with the server's uptime in seconds, which dates nothing on its own but spaces events
exactly, so the newest in a batch is anchored to the clock and the rest walk back by their
own offsets. A caller collecting an afternoon's backlog in one call gets an afternoon's
timeline, not one crowded second.

## Storage and privacy

The store is keyed by a SHA-256 of the API key and never holds the key itself. That has two
consequences worth stating:

- An unknown key reads an **empty** history rather than anyone else's, which is why these
  routes need no key check of their own.
- Nothing is ever written except off the back of a call the mod itself answered 2xx, which
  is the real authentication. A caller who cannot get a 200 out of the mod cannot make the
  store exist.

It lives in Postgres, in the `history` Docker volume. `HISTORY_DB_HOST=""` turns the whole
thing off and every route below answers `404 history_disabled`; `HISTORY_DAYS` (default 30)
sets how far back it goes.

Craft names reach the database as bound parameters, never as SQL - a ship called
`'; DROP TABLE visits; --` is a row value and nothing more.

## GET /history/summary

What is on disk, per craft.

```json
{
  "ships": [
    {"name": "Ore Hound", "visits": 41, "events": 190, "samples": 0, "sectors": 12,
     "first": 1757630000, "last": 1757719400}
  ],
  "rows": 231, "retentionDays": 30, "recording": true,
  "economy": {"samples": 560, "stations": 2, "since": 1757630100, "interval": 300}
}
```

`economy` says whether there is a station series at all, which is what tells a client to
offer the view rather than draw an empty chart - a deployment upgraded mid-month has travel
history and no samples yet. Per craft, `samples` counts the station readings held for it.

## GET /history/visits

Every sector a craft was seen to occupy, oldest first. The visit in progress is included
and flagged `"open": true`, so "where is it now" is part of the same answer.

| query | notes |
|---|---|
| `ship` | one craft by name; omit for the whole fleet |
| `owner` | `player` or `alliance` |
| `from`, `to` | Unix seconds |
| `limit` | newest N (default 2000, max 20000) |

```json
{"visits": [{"t": 1757630000, "e": 1757630600, "s": "Ore Hound", "x": 12, "y": -5, "o": "player"}]}
```

`t` is when the craft was first seen there and `e` when it was last seen there, so `e - t`
is observed dwell.

## GET /history/heatmap

The same visits collapsed onto the sector grid. Takes the same query parameters.

```json
{
  "cells": [{"x": 12, "y": -5, "visits": 3, "seconds": 5400}],
  "maxVisits": 3, "maxSeconds": 5400,
  "ships": ["Ore Hound"], "from": 1757630000, "to": 1757719400
}
```

`maxVisits` and `maxSeconds` are there to scale a colour ramp without a second pass. When
`maxSeconds` is 0 - a fleet recorded only in short bursts - weight by `visits` instead.

## GET /history/events

The persisted event log. Same query parameters as `/history/visits`; each row is the mod's
own event object wrapped in `t` (Unix seconds), `s` (craft), `q` (the mod's sequence
number) and `o` (owner kind).

Sequence numbers restart with the server, so `q` does not identify an event on its own.

## GET /history/economy/summary

What each station earned over a window, and what the faction was holding.

The mod reports earnings as running totals since a station was founded, because that is
all the game keeps. This differences consecutive samples and sums the differences, which
is what turns a lifetime total into "what did this place make this week".

| query | notes |
|---|---|
| `station` (or `ship`) | one station by name; omit for all of them |
| `owner` | `player` or `alliance` |
| `from`, `to` | Unix seconds |

```json
{
  "window": {"from": 1757630000, "to": 1757716400, "seconds": 86400},
  "stations": [
    {
      "ship": "Rusty Refinery", "owner": "player", "x": 12, "y": -4,
      "kind": "factory", "produces": ["Oil"], "factory": "${good} Refinery ${size}",
      "factoryTitle": "Oil Refinery",
      "samples": 280, "first": 1757630100, "last": 1757716300, "observed": 84000,
      "earned": 410000, "spent": 90000, "tax": 4000, "net": 324000,
      "perHour": {"earned": 17571.43, "spent": 3857.14, "net": 13885.71}
    }
  ],
  "totals": {"earned": 410000, "spent": 90000, "tax": 4000, "net": 324000,
             "observed": 84000, "stations": 1,
             "perHour": {"earned": 17571.43, "spent": 3857.14, "net": 13885.71}},
  "factions": [
    {
      "owner": "player", "samples": 280, "first": 1757630100, "last": 1757716300,
      "money": {"first": 11800000, "last": 12500000, "change": 700000},
      "resources": {"Iron": 40000, "Titanium": 9000},
      "stations": 7
    }
  ]
}
```

- **Rates are per `observed` hour, not per wall-clock hour.** Nothing in the mod pushes, so
  a stretch with no samples is a stretch when nobody was asking; counting it as a quiet
  hour would report a working station as idle. A single gap longer than four sampling
  intervals is capped, so one weekend with the stack down does not swallow the denominator.
- **The window applies to the later sample of each pair, and the scan below it is not
  bounded.** A station sampled at 09:55 and 10:05 earned something between those readings,
  and asking about "since 10:00" returns it. Starting the scan at the window edge would
  silently lose the first minutes of every window.
- **A counter that fell contributes zero, never a negative.** The counters only rise while
  a station stands, so a drop means the row was reset - destroyed and rebuilt, or founded
  again under the same name - and the honest reading of that pair is "this measures
  nothing" rather than a refund.
- `factions` is not differenced. Money is a level rather than a counter, and a balance that
  fell is as meaningful as one that rose, so it reports where the window started and ended.
  `stations.earnings` above is gross trade income; `money` is what survived wages, losses
  and spending. They are not meant to reconcile.

## GET /history/economy/series

The same numbers bucketed, which is what a chart wants. Same query parameters, plus:

| query | values | default |
|---|---|---|
| `bucket` | `hour`, `day` | `hour` |

```json
{
  "bucket": "hour", "window": {"from": 1757630000, "to": 1757716400}, "ship": "",
  "points": [{"at": 1757631600, "earned": 20000, "spent": 4000, "tax": 200, "net": 16200}]
}
```

| `x`, `y` | one sector's stations; both or neither | |
| `by` | `ship` - add each station's share to every point | |

```json
{"at": 1757631600, "earned": 20000, "spent": 4000, "tax": 200, "net": 16200,
 "ships": [{"ship": "Rusty Refinery", "earned": 15000, "spent": 4000, "tax": 200, "net": 11200},
           {"ship": "Sun Farm", "earned": 5000, "spent": 0, "tax": 0, "net": 5000}]}
```

Omit `station` and the points are every station summed; name one and they are that
station's. `ships` is only there with `by=ship`, and its shares add up to the point. A bucket is attributed to the **later** sample of each pair, so an interval
straddling a boundary lands wholly in the bucket it ended in - a rounding error of at most
one sampling interval, and the alternative is apportioning income across buckets on an
assumption of evenness the data does not support.

## GET /history/economy/goods

Units in and out per good, which is as close as anything gets to "what did it sell".

A station's own books cannot answer that: a `TradingManager` keeps one money counter for
the whole station and never attributes it to a good. What it does keep, good by good, is
how many units are in the bay, and differencing that says which way each good moved.

```json
{
  "window": {"from": 1757630000, "to": 1757716400},
  "goods": [
    {"ship": "Rusty Refinery", "good": "Oil", "in": 400, "out": 380, "net": 20, "stock": 900},
    {"ship": "Rusty Refinery", "good": "Raw Oil", "in": 0, "out": 240, "net": -240, "stock": 40}
  ]
}
```

`in` is units that appeared - produced by the line, bought from a passing trader, or
delivered by a supply ship. `out` is units that left, whether sold, consumed as an
ingredient, or shuttled to another of your stations. **The split between those causes is
not recoverable from here and is not guessed at**; the fields are named for what they
actually measure.

`stock` is the latest reading in the window, so a good with a large `in`, a small `out` and
a high `stock` is a line filling its own bay - which is what stops it producing.

## POST /history/clear

Drops everything stored for this key, or one craft's share of it with `?ship=`.

```json
{"cleared": true, "ship": "Ore Hound", "removed": 231}
```
