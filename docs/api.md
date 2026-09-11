# Endpoints

All responses are wrapped in the transport envelope described in
[protocol.md](protocol.md); the shapes below are the `body` field.

## GET /ping

Service metadata. Call it first to check the API version.

```json
{
  "api": 1, "mod": "0.1.6", "game": "2.5.13",
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
  "ship": "Ore Hound", "cursor": 16, "recording": true, "dropped": 0,
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
- `recording` is false when the owner is logged out. **Player scripts do not run for a
  logged-out player, so a quiet log then means nobody was watching, not that nothing
  happened.**
- The log is in memory, capped at 200 events per ship, and empty after a server restart. It
  is a recent-activity feed, not an audit trail.

Reads work offline; only the recording needs the owner online.

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
