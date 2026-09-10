# Endpoints

All responses are wrapped in the transport envelope described in
[protocol.md](protocol.md); the shapes below are the `body` field.

## GET /ping

Service metadata. Call it first to check the API version.

```json
{
  "api": 1, "mod": "0.1.0", "game": "2.5.13",
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
