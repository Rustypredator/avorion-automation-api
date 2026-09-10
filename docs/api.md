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
