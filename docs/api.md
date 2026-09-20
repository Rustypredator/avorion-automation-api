# Endpoints

All responses are wrapped in the transport envelope described in
[protocol.md](protocol.md); the shapes below are the `body` field.

## GET /ping

Service metadata. Call it first to check the API version.

```json
{
  "api": 1, "mod": "0.7.0", "game": "2.5.13",
  "galaxy": {"name": "defaultgalaxy", "seed": "..."},
  "server": {"runtime": 1234.5, "players": 1},
  "player": {"index": 1, "name": "...", "online": true,
             "alliance": {"index": 77, "name": "..."}}
}
```

`player.alliance` is `null` for a player in no alliance. It is always present, so its absence
means a mod older than the field. The bundled bridge decides who may read an alliance's
shared history off it; see [Storage and privacy](#storage-and-privacy).

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
      "usable": {"ok": true},
      "hasCaptain": true,
      "condition": {"hull": 0.87, "shield": 1}
    }
  ]
}
```

`availability` is `Available`, `InBackground` (out on a captain mission) or `Destroyed`.

`condition` is how much of the hull and of the shield is left, each as a fraction of that
craft's own maximum, so "which of my craft is hurt" is one call rather than one per craft.
Either half is absent where the database row will not say, and the whole field is absent
for a craft with no row. It comes out of the ship database, which the game rewrites when it
saves or when the sector unloads - a craft being shot at right now reports live on its own
automation feed instead, as `automation.vitals` in
[GET /ships/{name}/automation](#get-shipsnameautomation).

`hasCaptain` says whether the craft has a captain in command. For a station, whose `usable`
is always `NotAShip`, it is what decides whether it can be automated: a station with a
captain takes standing orders, orders that keep it where it is, cargo transfers and
programs of those, exactly as a ship does.

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
| `passengers` | captains aboard but not in command, each in the same shape as `captain`; empty array if none |
| `crew` | `size`, `maxSize`, `requirementsFulfilled`, and `byProfession` / `ideal` breakdowns |
| `cargo` | `capacity`, `free`, `used`, and `goods` flattened to an array |
| `hyperspace` | `range`, `cooldown`, `canPassRifts`, `impaired` |
| `shields`, `durability`, `energy` | `energy.sufficient` is the derived check |
| `dps` | `turrets`, `fighters`, `total` |
| `turrets` | identical designs collapsed to one entry with a `count`, each carrying mining efficiencies |
| `systems`, `hangar` | installed subsystems and fighter squads |
| `requirements` | crew / turret slot / fighter start / fighter squad checks |
| `blocks`, `planValue`, `reconstructionValue` | |
| `orders` | the order chain's state, decoded from the engine's JSON; `null` when there is none. See below. |
| `orderInfo` | the engine's order info string, verbatim. Prefer `orders`. |

`orders` uses the same chain shape as the order events, plus where each link goes:

```json
{
  "chain": [
    {"name": "Jump", "action": 1, "sector": {"x": -309, "y": 258}},
    {"name": "Fly Through", "action": 11, "gate": true, "sector": {"x": -308, "y": 249}}
  ],
  "activeIndex": 2,
  "finished": false,
  "sector": {"x": -309, "y": 258},
  "defense": "Enemy ships seen: attack combat ships",
  "autoAI": {"hullRatio": 0.8, "messages": 1}
}
```

`activeIndex` is 1-based, `0` when nothing runs. `gate` is only present on fly-through
links (`false` means a wormhole). `extra` holds any other top-level values a script put in
the chain state, and is left out when there are none. `automation` is the ship's automation
state as of the last save, in the shape [`GET /ships/{name}/automation`](#get-shipsnameautomation)
returns; that endpoint prefers the live copy.

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

`configurable` lists single values only. Procure, sell, supply and maintenance take lists
instead (see [List-shaped configs](#list-shaped-configs)); the placeholders the game
reports for them are left out.

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
(the ship-level check), `config` (a list config that cannot be flown, see below),
`command` (the mission's own validation) and `prediction`, each with the game's own
wording where the game has one:

```json
{"command": {"template": "Not enough turret slots for all turrets!", "args": {}, "text": "..."}}
```

Duration and other numeric config are clamped to the command's own limits, exactly as the
game clamps them, and the clamped values are echoed back.

### Trade routes

A trade preview also carries `routes`: every route the area analysis found (up to four),
in the game's order. A trade mission flies one of them, picked by `config.goodName`, and
needs a `config.deposit` - the down payment the captain buys with. Without a `goodName`
the preview still answers, with `errors.prediction` saying no route is selected, so a
first preview with an empty config is how you learn which goods an area offers.

```jsonc
"routes": [{
  "good": "Oil", "price": 320, "size": 2,
  "lowest": -0.2, "highest": 0.15,
  "margin": 0.35,                         // the order window's "%" column
  "profitPerUnit": 112,                   // its "¢/u" column, before captain perks
  "from": {"x": -310, "y": 318}, "to": {"x": -300, "y": 322},
  "deposit": 98304,                       // the order window's slider maximum
  "maxAvailable": 400, "perFlight": 200,  // the game spreads a contract evenly over its flights
  "flights": {"from": 2, "to": 2},
  "profitPerFlight": {"from": 25200, "to": 28000},
  "contractProfit": {"from": 50400, "to": 56000},
  "flightTime": 1500, "attackChance": 0.08,
  "selected": false                       // true for the route config.goodName names
}]
```

Every figure after `to` is the game's own `calculatePrediction` run for that route at
`deposit`, which is what the order window offers at most: every unit on offer, or as many
as the free cargo space holds, at the pre-perk purchase price. `contractProfit` is all of
`maxAvailable` at the perk-adjusted margin; each flight pays out 90-100% of its figure,
hence the range. A route the ship cannot fly at all has `error` in place of the
predicted figures.

Sending a route's `good` as `goodName` and its `deposit` as `deposit` (and `maxDeposit`)
reproduces what the game would start at full down payment.

Which routes an area offers depends on which stations fall inside it, and the ship only
has to be somewhere in the area, not in its middle. Finding the best contract means
previewing the area at several placements around the ship: the console's **Scan
placements** does this, trying each of the three shapes with the ship in every corner, the
middle of every side and the centre. Each placement is a separate area analysis, so run
them one after another - a second analysis for the same ship answers
`409 analysis_in_progress`.

### List-shaped configs

Procure, sell, supply and maintenance are configured with lists. The API takes them in
the shape below, builds what the game's order window would build from it, and echoes
them back in the same shape. Names are matched case-insensitively. A malformed list is
refused whole with `400` and one of `bad_goods`, `bad_routes`, `bad_crew`,
`bad_torpedoes`, `bad_fighters`.

The choices depend on the ship, its captain and the area, so each of these previews
carries `options`: what the order window would offer. A first preview with an empty
config is how you learn them.

**procure**: up to five goods to buy. `stolen` procures illegally (smugglers only).

```jsonc
"config": {"goods": [{"name": "Energy Cell", "amount": 500, "stolen": false}]}

"options": {
  "goods": [{"name": "Energy Cell", "availability": "area"}],  // or "elsewhere" (merchant, double price), "stolen" (smuggler)
  "maxGoods": 5, "stolenAllowed": false,
  "captain": {"merchant": false, "smuggler": false}
}
```

**sell**: goods from the hold. `stolen` picks the stolen stack of that good.

```jsonc
"config": {"goods": [{"name": "Energy Cell", "amount": 300, "stolen": false}]}

"options": {
  "cargo": [{"name": "Energy Cell", "amount": 300, "stolen": false, "illegal": false,
             "dangerous": false, "suspicious": false, "price": 61, "size": 1,
             "sellable": true}],                    // whether this captain can sell it in this area
  "captain": {"merchant": false, "smuggler": false}
}
```

**supply**: up to five routes between your own stations. `goods` is optional and narrows
what is carried; the goods themselves come from what the two stations trade, matched
against the area analysis the same way the order window matches them. The echo's
`carried` shows the result. A route that cannot be flown (unknown station, both in one
sector, nothing traded between them, a rift in the way) sets `errors.config` naming the
route, and `canStart` is false.

```jsonc
"config": {"routes": [{"from": "Solar Plant", "to": "Oil Refinery", "goods": ["Energy Cell"]}]}

"options": {
  "maxRoutes": 5,
  "stations": [{"name": "Solar Plant", "title": "Solar Power Plant", "position": {"x": 12, "y": 10},
                "deliveries": [{"to": "Oil Refinery", "goods": ["Energy Cell"], "blocked": false}]}]
}
```

**maintenance**: repairs are always included when needed. `crew` is `none`, `required`
or `maximum`. A torpedo line fills `percentage` of the free torpedo storage. A fighter
line is per hangar squad (`squad` from 0), up to 12 fighters a squad; `weaponType`
`"shuttle"` buys boarding shuttles, which are always Common. Warheads, weapon types and
rarities can be ids or names (`"Neutron"`, `"ChainGun"`, `"Rare"`); the echo carries both.
Lines at 0 are dropped, as the order window drops them.

```jsonc
"config": {
  "crew": "required",
  "torpedoes": [{"warhead": "Neutron", "rarity": "Rare", "percentage": 50}],
  "fighters": [{"squad": 0, "weaponType": "ChainGun", "rarity": 2, "amount": 8}]
}

"options": {
  "crew": ["none", "required", "maximum"],
  "rarities": [{"id": 0, "name": "Common"}, "... up to 3, Exceptional"],
  "warheads": [{"id": 2, "name": "Neutron"}],       // on sale around the ship
  "squads": [{"squad": 0, "name": "Alpha", "fighters": 4, "buyable": 8,
              "weaponTypes": [{"id": 0, "name": "ChainGun"}], "shuttles": false}]
}
```

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

## Mission automation

A rule per craft that has the mod send it back out on a captain mission whenever it is free,
as long as the mission stays inside the rule's limits. The loop runs in the galaxy bridge -
no client has to stay connected - and every start it makes is the ordinary start: the same
assessment preview runs, then the same agent handshake.

- **Rules are stored per owning faction**, as Server values, so they survive restarts. An
  alliance craft's rule is one document: every member reads the same rule and the same live
  state, and a member with `ManageShips` can change it.
- **A start still needs someone in game**: the owner for their own craft, any alliance member
  for alliance craft. Until then the rule waits in phase `offline`.
- **Alliance starts run under the rank of the member who last saved the rule.** Demote them
  and the rule stops (`blocked`) until someone with `ManageShips` saves it again. A trade
  deposit also needs `SpendResources`.
- **Automatable missions**: mine, salvage, trade, expedition, scout, refine, sell, procure,
  maintenance. Travel ends elsewhere and supply never finishes, so neither can be repeated.

Each check runs an area analysis - one, or one per area of a sweep - and predicts every
config worth trying against each:

| mission | what is searched |
|---|---|
| mine, salvage | every half hour of duration the captain allows |
| expedition | 30, 60, 90 and 120 minutes |
| trade | every route in the area, at every flight count from the fewest the cargo bay allows, each with the smallest deposit that achieves it; goods in `goods.avoid` are skipped |
| others | the config as given |

Options that break a limit - or that the game itself would refuse - are dropped. Of the rest,
a good in `goods.prefer` goes first, then the rule's `priorities` decide in order, each
breaking the ties of the one before; remaining ties go to the lower ambush chance, then the
better value an hour. At most one check starts per pass, and never on the last free analysis
slot.

### Sweeps

A trade analysis offers at most four routes, chosen from the stations inside the area, and a
route a contract just flew is hidden for two hours. One area around the ship therefore often
has nothing left worth flying. A rule with `"area": {"mode": "sweep"}` (the default for trade)
lays the area around the craft at nine placements - centre, each corner, the middle of each
side - at every shape the captain allows (trade: 17x17, 29x11, 11x29), and judges every
candidate from every one of them together. The chosen option starts in the area it was found
in. Areas are analysed one after another, each waiting for a free slot below the one kept for
the console, so a sweep takes a while: up to `Config.missionAutomationSweepTimeout` (600s),
after which it is ranked on what it has. A mission whose area the game recentres on the ship
anyway sweeps its shapes only.

The deposit search runs in every area, so `maxAttackChance` picks, per route and area, the
deposit that stays under the ceiling - the ambush chance depends on the area as well as the
deposit.

### Pairs

A rule's `escorts` go out with the craft, and the pair stays together: the game moves each
escort to its primary when the mission ends, wherever that is. Every escort is required unless
it is in `optionalEscorts`.

- Before each check the automation asks each escort what the start would: is it available, not
  driven by a program, within one jump of the primary (measured with the escort's own drive)
  and on the same side of the barrier unless it can cross rifts, and usable (captain, crew,
  energy, undamaged). The game answers these only in chat, so they are asked here first.
- A **required** escort that is not ready holds the primary back in phase `escort`, with the
  reason. Nothing brings it over by itself; move it, and the pair goes on the next check.
- An **optional** escort that is not ready is left behind, logged with why, and the limits
  judge the mission without it - so a pair whose ambush chance only fits with the escort
  still waits.
- An escort belongs to **one enabled pair** at a time, and an escort cannot lead a pair of
  its own. An escort may keep a rule of its own; it waits in phase `paired` while its primary's
  rule is on. Switching the primary's rule off frees it.

### Trade and the impatient customer

The captain's warnings are about flights, not time. A contract always gets three flights;
after that, each flight ends it early with a 35% chance (`TradeCommand:update`), paying for
the flights flown plus the deposit back. So `maxFlights` is the patience limit, and the
figures account for it: `completionChance` is 0.65^(flights - 3), `expectedFlights` and
`value` are what the contract is expected to deliver before the customer walks.

A bigger deposit means fewer flights, but past a richness-scaled threshold it also stretches
the attack window from one hour towards three. `maxFlights` and `maxAttackChance` therefore
pull against each other, and the trade search exists to find the deposit that satisfies both.

### The rule

```json
{
  "mission": "trade",
  "enabled": true,
  "objective": "hourly",
  "priorities": ["hourly", "fewestFlights", "safest"],
  "area": {"mode": "sweep"},
  "goods": {"prefer": ["Energy Cell"], "avoid": ["Oil"]},
  "limits": {
    "maxAttackChance": 0.1,
    "maxFlights": 3,
    "maxDeposit": 2000000,
    "minCreditsLeft": 5000000
  },
  "config": {},
  "escorts": ["Wingman", "Picket"],
  "optionalEscorts": ["Picket"],
  "collectYields": true
}
```

| field | |
|---|---|
| `priorities` | criteria in order: `hourly` (value per hour away), `total` (biggest value), `safest` (lowest ambush chance), `shortest` (least time away), `fewestFlights` (trade: least chance the customer walks), `cheapest` (smallest deposit or budget). Each breaks the ties of the one before |
| `objective` | the first priority. Sent on its own, it replaces `priorities` with itself |
| `area.mode` | `ship` recentres on the craft at every check, at `size` (default: the first the captain allows) with the craft at `placement` (fractions of each side, default the centre); `sweep` tries every placement at every shape, or at the shapes in `sizes` (default for trade, see [Sweeps](#sweeps)); `fixed` takes `lower` and `upper` |
| `goods` | trade only: `prefer` goes first among the options that pass, `avoid` is never tried. Names as in the goods table, matched case-blind |
| `config`, `materials`, `escorts` | as for a start. A searched field (a duration, a trade route and deposit) is chosen by the check, not taken from here |
| `optionalEscorts` | escorts the craft may leave behind; the rest are required (see [Pairs](#pairs)) |
| `collectYields` | collect waiting yields before each check |

Every limit is optional. Units are the same for every mission:

| limit | unit | |
|---|---|---|
| `maxAttackChance` | fraction, 0-1 | the order window's attack chance |
| `maxDuration`, `minDuration` | seconds | time away; for trade, the whole contract |
| `maxFlights` | flights | trade only: the customer's patience |
| `maxDeposit` | credits | trade deposit, procure budget, maintenance price |
| `minCreditsLeft` | credits | the owner's account after paying the deposit |
| `minValue` | credits or resource units | the expected yield: trade and sell in credits, mine, salvage and refine in resources |

### GET /automation/missions

Every rule the caller can see with its live state. `?owner=player|alliance` narrows it; the
default is both.

```json
{
  "serverTime": 18234.5,
  "automations": [{"ship": "Prospector", "owner": {"kind": "player"}, "rule": {}, "state": {},
                   "pairing": null, "dryRun": null}],
  "pairs": [{"owner": {"kind": "player"}, "primary": "Hauler",
             "escorts": [{"name": "Wingman", "required": true}, {"name": "Picket", "required": false}]}],
  "supported": ["expedition", "maintenance", "mine", "procure", "refine", "salvage", "scout", "sell", "trade"],
  "limits": ["maxAttackChance", "maxDeposit", "maxDuration", "maxFlights", "minCreditsLeft", "minDuration", "minValue"],
  "criteria": ["cheapest", "fewestFlights", "hourly", "safest", "shortest", "total"]
}
```

`pairs` lists every enabled rule with escorts. An entry's `pairing` is, for a craft with
escorts, `{"role": "primary", "active": true, "escorts": [{"name", "required", "ready",
"problem"}]}` - `problem` is why an escort could not go right now - and for a craft another
enabled rule names as escort, `{"role": "escort", "primary": "Hauler", "required": true}`.

Timestamps in `state` are server runtime seconds, like `serverTime`, so compare them with it
rather than with a wall clock. `state` is `null` until the loop has looked at the rule, and
starts empty after a server restart.

```json
{
  "phase": "blocked",
  "message": "Nothing within the limits: ambush chance 14% is above 10%",
  "since": 18100.2, "nextCheckAt": 18400.2, "busy": false, "progress": null,
  "dispatches": 6,
  "lastDispatch": {"at": 16020.0, "mission": "trade", "summary": "trade, Oil, 3 flights, 1.0h, ambush 8%, ~412000 ¢/h", "candidate": {}},
  "lastEvaluation": {"at": 18100.2, "tried": 9, "passing": 0, "chosen": null, "candidates": []},
  "lastCollect": {"at": 18099.0, "collected": 3},
  "log": [{"at": 18100.2, "phase": "blocked", "message": "...", "detail": null}]
}
```

| phase | |
|---|---|
| `waiting` | will be checked on a coming pass |
| `evaluating` | an analysis is running for it; during a sweep `progress` is `{"done", "total"}` areas |
| `escort` | a required escort is not ready; `message` says which and why |
| `paired` | the craft escorts another craft's enabled rule, so its own rule waits |
| `starting` | the start job is with the owner's agent |
| `running` | out on a mission the automation sent it on |
| `busy` | out on a mission started some other way |
| `blocked` | nothing passes the limits, the ship is unusable, or the rule's author lost their rank - retried after `Config.missionAutomationRetry` (300s) |
| `offline` | nobody who could start it is in game |
| `missing` | the owner no longer has a craft by that name |
| `error` | the check or start failed; `message` says how |
| `program` | an enabled program drives the craft and flies this rule in its mission steps |
| `disabled` | switched off |

### GET /ships/{name}/mission/automation

One craft's rule and state, in the shape of an `automations` entry. `rule` and `state` are
`null` when it has none.

### POST /ships/{name}/mission/automation

Creates or updates the rule. Fields left out keep their stored values, so `{"enabled": false}`
is the whole of switching a craft off. `limits`, when given, replaces the stored limits.

Pass `ifRevision` - the `rule.revision` you last read, `0` for a new rule - and a save that
would overwrite someone else's change is refused with `409 rule_changed`, the current revision
and rule in `details`. Alliance craft need `ManageShips` (`403 missing_privilege`). An
unknown limit, material, good, priority or escort is `400 bad_rule`; a mission that cannot be
automated is `422 not_automatable`. An escort already in another enabled pair, a craft that
escorts another trying to lead a pair, or an escort that leads a pair of its own is
`409 escort_paired`, with `escort` and `primary` in `details`.

### POST /ships/{name}/mission/automation/delete

Removes the rule. `{"deleted": true}` if there was one.

### POST /ships/{name}/mission/automation/evaluate

A dry run of one check - the analysis and every option, ranked, with the reason each would or
would not go - and nothing started. The body is merged over the stored rule without saving
it, so limits can be tried before they are committed; `{}` checks the stored rule as is.
Works with the owner offline.

A check over one area answers `200` with the result below. A sweep is far longer than a
request may wait, so it answers `202` at once with `{"evaluating": true, "dryRun": {...}}`
and the result lands in the craft's `dryRun` (served by `GET /ships/{name}/mission/automation`
and the list): `{"running", "done", "total", "startedAt", "finishedAt", "by", "result",
"error"}`, `result` being the body below. A second dry run of the same craft while one runs
is `409 evaluation_running`.

Escorts are mustered as the loop would: optional escorts that are not ready are left out of
the figures, a required one is kept in them and named in `waitingFor` (`{"escort",
"problem"}`), in which case `wouldStart` is false.

```json
{
  "wouldStart": true,
  "waitingFor": null,
  "evaluation": {
    "objective": "hourly", "priorities": ["hourly"], "tried": 60, "passing": 7,
    "areas": 27, "analysed": 27,
    "area": {"lower": {"x": -324, "y": 311}, "upper": {"x": -308, "y": 327}},
    "escorts": {"going": ["Wingman"], "left": [{"name": "Picket", "problem": "out on a mission"}]},
    "chosen": {"passes": true},
    "candidates": [{
      "passes": true,
      "preferred": true,
      "config": {"goodName": "Oil", "deposit": 34304, "escorts": ["Wingman"]},
      "route": {"good": "Oil", "from": {"x": -310, "y": 318}, "to": {"x": -300, "y": 322}},
      "area": {"lower": {"x": -324, "y": 311}, "upper": {"x": -308, "y": 327}},
      "metrics": {
        "attackChance": 0.07, "duration": 3600, "flights": 3, "expectedFlights": 3,
        "completionChance": 1, "patience": "safe", "cost": 34304,
        "value": 53760, "valueUnit": "credits", "hourly": 53760
      },
      "violations": []
    }]
  },
  "assessment": ["We do not have to fly often. ..."]
}
```

`area` is the area the chosen option was found in, and each candidate names its own. A sweep
sees the same route from several areas; `candidates` lists each route and flight count once,
at its best-ranked area, while `tried` and `passing` count them all.

`patience` follows the captain's wording thresholds: `safe` up to 3 flights, `small risk` to
5, `real risk` to 10, `likely lost` beyond.

## Order programs

A program per craft: a list of steps the mod works it through by itself, each until its
conditions are met, then on to the next step, to a step by number - which is how a program
loops - or to its end. For example, farm bosses until the hold is 80% full, fly to a trade
station, go back to step 1.

- **Stored and run like mission automation.** Programs are Server values per owning faction
  with a revision; the runner is in the galaxy bridge. Alliance programs are shared, and run
  under the rank of the member who last saved them.
- **Every step is an ordinary request.** A route step is `POST /ships/{name}/route`, a farm
  step `POST /ships/{name}/farm`, an orders step `POST /ships/{name}/orders`, a standing step
  `POST /ships/{name}/automation`, issued internally with the program's authority - so each is
  validated, refused and confirmed exactly as a client's call would be, and needs what that
  call needs (the owner online, the sector loaded, a captain). A mission step runs the craft's
  mission automation rule once: its escorts mustered (a required one not ready fails the step
  with `escort_unavailable`), the analysis or sweep, the best option inside its limits, the
  ordinary start.
- **While a program runs, the craft's mission rule does not dispatch by itself** (its state
  shows phase `program`). When the program finishes or is switched off, the rule takes over
  again.
- **A refused step is retried** every minute (`status: retrying`, `message` says why). A route
  or travel step refused with `already_there` is not refused: the ship is where it was sent,
  so the step's action counts as over and arrived (the `arrived` condition holds).
- **Stations with a captain run programs too**, of the steps that leave them where they are:
  `orders`, `standing`, `transfer` and `wait`. A station's program with a `route`, `farm`,
  `travel` or `mission` step is `400 bad_program`.
- **After a restart the current step starts over.** Where a program has got to is kept apart
  from the program, so moving on does not change its revision.

### Steps

```jsonc
{
  "name": "fill up",                       // optional
  "action": {"type": "farm", "boss": "auto"},
  "until": {"match": "any", "conditions": [{"type": "cargo", "op": ">=", "percent": 80}]},
  "repeat": false,
  "then": "next"                           // "next", "start" (step 1), "stop", or {"goto": n}
}
```

| action | fields | ends by itself |
|---|---|---|
| `route` | a [destination](#destinations): `to {x, y}`, `target` (+ `targetOwner`) or `location`; optionally `onEnemies`, `attackCivilians`, `preferGates`, `preferWormholes`, `fewestJumps`, `avoidRifts`, `preferUncontrolled` as for `/route` | when the plan ends (arrived, or stopped) |
| `farm` | `boss`, `onEnemies`, `attackCivilians`, `collectLoot`, `bossCooldown` as for `/farm` | never - needs a condition |
| `orders` | `orders`, `clear` as for `/orders` | when the chain runs out |
| `mission` | optionally `library`, the name of a [library mission](#mission-library), or `rule`, a mission automation rule of its own; with neither, the craft's stored rule | when the craft is back |
| `travel` | a [destination](#destinations) as for `route`, optionally `swiftness` (0-3) as for `/travel` | when the craft is back, at the destination |
| `standing` | `standing`, `attackCivilians` as for `POST /ships/{name}/automation` | at once |
| `transfer` | `target`, `targetOwner`, `direction`, `goods` or `all`, `approach` as for [`/transfer`](#post-shipsnametransfer); optionally `travelToTarget` (default true) | when the ship reports the transfer over - moved, refused on the way, or given up. A target in another sector is travelled to first, see below |
| `wait` | - | never - needs a condition |

A step with no conditions ends with its action. One with conditions ends when `any` (the
default) or `all` of them hold, checked every two seconds; with `repeat` the action starts
again each time it ends while they do not. A route or farm still flying when its step ends is
stopped first.

| condition | fields | met when |
|---|---|---|
| `cargo` | `op` (`>=`, `<=`), `percent` | the hold's used share compares so |
| `good` | `name`, `op`, `amount` | the hold's amount of that good compares so |
| `bossKills` | `count` | this step's farm has killed that many bosses |
| `arrived` | - | this step's route arrived |
| `planEnded` | - | this step's route or farm ended, however |
| `missionReturned` | - | this step's mission is back |
| `elapsed` | `seconds` | the step has run that long |
| `enemies` | `present` (default true) | the ship last reported enemies in its sector, or none |
| `idle` | - | the ship has no chain, plan or standing order at work |
| `at` | `x`, `y` | the craft is in that sector |

Cargo and position come from the ship database; enemies, plans and boss kills from what the
ship last reported. A condition whose facts are not known yet counts as not met.

A route or travel step naming a `target` craft or a `location` resolves it when the step
starts, so it flies to wherever the craft is then, or to the location as the library has it
then. A location a program names cannot be deleted, and renaming it renames it in the
faction's programs.

**A transfer with a craft in another sector.** When the step starts, the ship is first sent
to the target: a Travel mission (`POST /ships/{name}/travel` with `target`), or, when the game
refuses one as `destination_too_close`, a planned route (`POST /ships/{name}/route`). The
state's `leg` is `travel` or `route` meanwhile. Once the leg is over the step starts again: a
target found in the sector gets its cargo moved, one that moved on meanwhile is flown after
again. Conditions are checked throughout, and a step that ends mid-leg stops a leg route still
flying. `travelToTarget: false` skips the leg, and the step is retried until the two craft
meet some other way (`not_same_sector`). A station's transfer never travels.

### GET /automation/programs

Every program the caller can see (`?owner=player|alliance|all`, default all), with what each
is doing, and the vocabulary.

```json
{
  "serverTime": 7310,
  "programs": [{
    "ship": "Ore Hound", "owner": {"kind": "player"},
    "program": {"name": "Farm and sell", "enabled": true, "revision": 3,
                "updatedBy": {"index": 1, "name": "Rusty"}, "steps": []},
    "state": {
      "status": "running", "message": "Farming bosses.", "since": 7290,
      "step": 1, "stepSince": 7010, "phase": "active", "attempts": 0,
      "planId": "p4-7011", "leg": null, "bossKills": 1,
      "conditions": [{"text": "cargo >= 80%", "met": false}],
      "log": [{"at": 7010, "status": "running", "step": 1, "message": "Farming bosses."}]
    }
  }],
  "actions": ["farm", "mission", "orders", "route", "standing", "travel", "wait"],
  "conditions": ["arrived", "at", "bossKills", "cargo", "elapsed", "enemies", "good", "idle", "missionReturned", "planEnded"],
  "maxSteps": 20
}
```

| `state.status` | meaning |
|---|---|
| `starting` | the step's action has been sent and not answered yet |
| `running` | the step's action is under way, or over and waiting for the conditions |
| `waiting` | nothing can be done yet: owner offline, or just saved |
| `retrying` | the step's action was refused; tried again after a minute |
| `finished` | the program ran to its end (`then: "stop"`, or past the last step) |
| `disabled` | switched off |
| `error` | the craft or the authority to run it is gone |

### GET /ships/{name}/program

One craft's program and state, in the shape of a `programs` entry; `program` is absent when
it has none.

### POST /ships/{name}/program

Creates or updates the program: `name`, `enabled`, `steps`. Fields left out keep their stored
values; `steps`, when given, replaces them all and starts the program over at step 1.
Switching it off and on keeps its place (the step it was on starts its action again). At most
20 steps and 8 conditions per step.

Pass `ifRevision` as for mission rules: `409 program_changed` if someone saved since. A
malformed program is `400 bad_program` (`details.known` lists actions or conditions where one
is unknown); a mission step's own rule is checked as a mission rule is, and a `library` name
must be in the craft owner's library. Alliance craft need `ManageShips`.

### POST /ships/{name}/program/control

`{"action": "restart"}` moves the program to step 1, `{"action": "goto", "step": n}` to step
n. The step moved to starts its action on the next pass; whatever the previous step started is
left as it is. Errors: `400 bad_control`, `400 bad_step`, `404 no_program`.

### POST /ships/{name}/program/delete

Removes the program. `{"deleted": true}` if there was one.

### Mission library

Named mission rules a faction keeps for its programs' mission steps: a rule without a craft,
under a name like `Refine, safe`. A step names one, and the runner loads it when the step
starts, so an edit applies to every program flying it from its next start. Player craft fly
the player's library, alliance craft the alliance's (`?owner=alliance`), which every member
shares.

#### GET /automation/missions/library

`?owner=player|alliance|all` (default all).

```json
{
  "missions": [{
    "name": "Refine, safe", "owner": {"kind": "player", "index": 1, "name": "Rusty"},
    "rule": {"mission": "refine", "objective": "hourly", "area": {"mode": "ship"}, "limits": {"maxAttackChance": 0.05}},
    "revision": 2, "updatedBy": {"index": 1, "name": "Rusty"}, "updatedAt": 1757940000,
    "usedBy": ["Ore Hound"]
  }],
  "maxName": 48
}
```

`usedBy` lists the craft whose programs name the mission.

#### POST /automation/missions/library/{name}

Creates or updates the mission called `name`. The body is a rule as for
`POST /ships/{name}/mission/automation`, merged over the stored one, except that a library
mission has no `enabled`. `rename` moves it to a new name, and the programs naming it follow
without a new revision. `ifRevision` as for rules. Errors: `400 bad_name`, `400 bad_rule`,
`422 not_automatable`, `409 library_changed`, `409 name_taken`, `403 missing_privilege`.

#### POST /automation/missions/library/{name}/delete

Removes it: `{"deleted": true}` if there was one. A mission a program still names is
`409 mission_in_use`, with the craft in `details.usedBy`.

## Locations

The location library: sectors a faction keeps under a name - `Home`, `Iron belt` - to give
as a destination instead of coordinates. A player has their own library and sees their
alliance's, which every member shares and any member may add to.

### GET /locations

`?owner=player|alliance|all` (default all).

```json
{
  "locations": [{
    "name": "Home", "owner": {"kind": "player", "index": 1, "name": "Rusty"},
    "x": 10, "y": -4, "note": "the shipyard",
    "revision": 2, "updatedBy": {"index": 1, "name": "Rusty"}, "updatedAt": 1757940000,
    "usedBy": ["Ore Hound"]
  }],
  "maxName": 48,
  "maxLocations": 200
}
```

`usedBy` lists the craft of the same faction whose programs name the location.

### POST /locations/{name}

Creates or updates the location called `name` in the caller's library, or the alliance's with
`?owner=alliance`: `{"x", "y", "note"}`, merged over the stored one - a new location needs `x`
and `y`, a `null` note clears it. `rename` moves it to a new name, and the programs naming it
follow without a new revision. `ifRevision` as for rules. Errors: `400 bad_name`,
`400 bad_coordinates`, `400 bad_note`, `409 location_changed`, `409 name_taken`,
`409 too_many_locations` (200 per library).

### POST /locations/{name}/delete

Removes it: `{"deleted": true}` if there was one. A location a program still names is
`409 location_in_use`, with the craft in `details.usedBy`.

### Destinations

Everything that sends a ship somewhere - `/travel`, the travel mission's `preview` and
`start`, `/route`, `GET /galaxy/route` and route and travel program steps - takes the
destination one of three ways, exactly one at a time:

| field | goes to |
|---|---|
| `to {x, y}` | that sector |
| `target`, optionally `targetOwner` (`player`/`alliance`) | the sector a craft of the caller or their alliance is in when the request is made; stations included |
| `location` | a location from the library - the one of the ship's owner first, then the caller's other one |

The answer carries `destination`: `{"kind": "sector"|"craft"|"location", "name", "owner",
"x", "y"}`. Errors: `400 conflicting_destination` (more than one given), `404 no_such_target`,
`409 target_in_background` (the craft is out on a captain mission and has no sector),
`404 no_such_location`.

## POST /ships/{name}/travel

An alias of `POST /ships/{name}/missions/travel/start`, kept for existing callers. It takes
the [destination](#destinations) at the top level and `swiftness` alongside it, and returns
the same body:

```jsonc
{"to": {"x": -300, "y": 310}, "swiftness": 2}
{"target": "Trade Hub", "swiftness": 2}
{"location": "Home"}
```

A station is `422 station_cannot_move`.

`swiftness` is 0 (careful, slow, unlikely to be attacked) to 3 (reckless, fast, risky) and
defaults to 2.

A Travel captain mission loads no sectors, works wherever the ship is and survives the owner
logging out once started. To fly a route as orders instead - with gate, rift and
faction-space preferences, and a response to enemies on the way - use
[`POST /ships/{name}/route`](#post-shipsnameroute).

### Destination checks

These apply to the travel mission however it is started - this alias, or `preview` and
`start` on `/missions/travel`. The game refuses to send a ship somewhere it could already
reach in one hop, and says so only after an area analysis has been spent, so the destination
is checked first:

| code | when |
|---|---|
| `422 already_there` | the ship is in that sector |
| `422 destination_too_close` | inside jump range with no rift between, or on the far side of a gate or wormhole out of the ship's current sector |

The same rule is enforced after the analysis too, since only then is the real route known:
a route of two sectors or fewer sets `errors.start` to the game's own
`"This route is too short."` and `canStart` to false.

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
`409 sector_not_loaded` - the ship's sector is not in memory; a Travel captain mission moves
a ship wherever it is.
`409 ship_in_background` - it is out on a captain mission.

**Requires the owning player to be logged in.**

## POST /ships/{name}/route

Plans a route and has the ship fly it as an order chain. The plan is this mod's own search
rather than the game's `calculateJumpPath`, which takes no preferences:

```jsonc
{
  "to": {"x": -120, "y": 88},   // or "target": "Trade Hub", or "location": "Home"
  "preferGates": true,          // take known gates whenever they save time
  "preferWormholes": false,     // take known wormholes whenever they save time
  "fewestJumps": false,         // the fewest hops of any kind; the others only break ties
  "avoidRifts": false,          // keep a rift-capable ship out of rifts, as if it were not
  "preferUncontrolled": true,   // stay in no man's space where a detour allows
  "onEnemies": "fight",         // fight | hold | continue
  "attackCivilians": false,
  "dryRun": false               // plan only; nothing is sent to the ship
}
```

The destination is any of the three [destinations](#destinations). Gates and wormholes cost
more than a jump by default, since flying to one takes longer, so they are only taken when
they save jumps; `preferGates` and `preferWormholes` each make their own kind cheap
(`preferGates` used to cover wormholes as well). `fewestJumps` counts every hop as one - jump,
gate or wormhole - and searches for the fewest; with it, the other preferences only choose
between routes of equally few hops, never add one.

The response is the plan in [`GET /galaxy/route`](#get-galaxyroute)'s planner shape, plus the
dispatch:

```json
{
  "ship": "Ore Hound", "planId": "p4-7310", "confirmed": true,
  "reachable": true, "planner": "automation",
  "jumps": 9, "gates": 1, "wormholes": 0, "controlledSectors": 0, "distance": 61.2,
  "destination": {"kind": "sector", "x": -120, "y": 88},
  "hops": [{"x": -5, "y": 3, "kind": "jump", "distance": 5.8, "controlled": false, "rift": false}],
  "route": [{"x": 0, "y": 0}, {"x": -5, "y": 3}],
  "onEnemies": "fight", "attackCivilians": false, "dryRun": false,
  "automation": {"plan": {"id": "p4-7310", "kind": "route", "phase": "running"}},
  "chain": [{"name": "Jump", "action": 1}]
}
```

The hops go onto the ship's ordinary order chain - jumps as jumps, gates and wormholes as
fly-through orders - so the Orders view, the galaxy map and `GET /ships/{name}/events` all
show them. While the ship flies them it checks its sector every second:

| `onEnemies` | when enemies are present |
|---|---|
| `fight` (default) | replace the route with an aggressive order; once the sector has been clear for five seconds, pick the route up at the hop it was interrupted on |
| `hold` | replace the route with an aggressive order that never finishes, and stay |
| `continue` | ignore them and keep jumping |

`attackCivilians` decides both whether civilian ships count as enemies and whether the
aggressive order attacks them.

The request is held open until the ship reports the plan it took up, as `/orders` is:
`200 confirmed: true` when it did, `422` when it refused, and `202 confirmed: false` when it
said nothing inside the window - which is what a server where another mod replaced
`orderchain.lua` outright looks like.

| error | when |
|---|---|
| `422 already_there` | the ship is in that sector |
| `422 station_cannot_move` | the craft is a station (so for `/farm`, and a `jump` in `/orders`) |
| `422 no_route` | the planner found none; `reason` is `no_route`, `destination_in_rift`, `barrier`, `search_limit` or `timeout` |
| `422 needs_captain` | no captain and nobody at the controls |
| `422 plan_refused` | the ship refused a hop the engine would not allow; the message names it |
| `400 bad_on_enemies` | |

Plus the world checks `/orders` makes, before any planning: `409 owner_offline`,
`409 ship_in_background`, `409 sector_not_loaded`. A dry run skips those. Planning is rate
limited with `GET /galaxy/route`, one call every two seconds per player.

The ship's sector has to stay loaded for the ship to fly; the engine does not simulate a
craft in a sector nobody is near, and a plan waits with it.

**Requires the owning player to be logged in.**

## POST /ships/{name}/farm

Boss farming. The game spawns a boss after **ten consecutive jumps into empty space** - no
regular or off-grid content, not blocked by a rift, not a home sector - inside one of two
rings around the core, each jump also having a 4% chance of its own:

| `boss` | ring (distance from the core, exclusive) |
|---|---|
| `ai` | 240 - 340 |
| `swoks` | 350 - 430 |
| `auto` (default) | the ring the ship is in, else the nearer one |

This finds two empty sectors in the ring one jump apart, plans a way there if the ship is not
on one already, and sends the ship round the pair in a loop:

```jsonc
{"boss": "auto", "onEnemies": "fight", "attackCivilians": false,
 "collectLoot": true, "bossCooldown": 1800, "dryRun": false}
```

| field | notes |
|---|---|
| `collectLoot` | default `true`: after a fight, send the fighters for the loot before jumping on |
| `bossCooldown` | seconds to stop jumping after a boss is killed, `0` to `14400`, default `1800` (vanilla's); `0` keeps jumping |

```json
{
  "ship": "Ore Hound", "boss": "ai", "ring": {"min": 240, "max": 340},
  "loop": [{"x": 290, "y": 1}, {"x": 293, "y": 4}],
  "approach": [{"x": 287, "y": 0, "kind": "jump"}],
  "hops": [{"x": 287, "y": 0, "kind": "jump"}, {"x": 290, "y": 1, "kind": "jump"}],
  "loopFrom": 2, "piloted": true, "collectLoot": true, "bossCooldown": 1800,
  "planId": "p5-7322", "confirmed": true
}
```

The rules this works around, all vanilla's (`player/story/spawnrandombosses.lua`):

- **The jump counter belongs to the player, not the ship.** It counts the sector changes of
  the player aboard, so a captain flying the loop alone never spawns anything. A farm is
  refused with `422 needs_pilot` unless a player is at the controls, and stops itself
  (`last.outcome: "pilot_left"`) if they leave.
- A jump into a sector with regular content resets the counter, which is why the loop only
  uses empty sectors. The approach may pass through anything; counting starts on the loop.
- After a boss dies, nothing spawns for 30 minutes, for Swoks and the AI alike (one timer per
  player), and jumps in that time are not counted at all. The timer lives in the player
  script's memory, so the game forgets it on logout or restart.

What the ship does about it, on its own:

- **The boss is recognised** by the script vanilla puts on it (`entity/story/swoks.lua`,
  `entity/story/aibehaviour.lua`) and published as `plan.bossPresent`. A farm stops for a boss
  even before it turns hostile - Swoks arrives friendly to the player he spawned for.
- **A kill** is a boss gone from the sector while the ship is still in it; vanilla gives a boss
  no other way out with a player present, short of paying Swoks off through his dialog. It
  counts in `plan.bossKills` and starts `plan.cooldown`.
- **Looting** (`collectLoot`): once the sector is clear, if there is loot the ship may take
  and it has fighters, the chain is cleared and every squad is ordered to collect loot. Cargo
  drops only count when the ship's fighters can pick cargo up, which takes both a transporter
  block and the `FighterCargoPickup` stat from Transporter Software of rare or better (either
  alone and fighters leave cargo alone - verified in the engine); money, resources, turrets and
  subsystems always count. Drops the ship has no room for (`Loot:isCollectable`), such as
  torpedoes without torpedo storage, never count. It ends when none is left, nothing was picked up for 45 s, no fighter launched within
  20 s, or after 5 minutes. The fighters are then recalled and the ship waits up to 90 s for
  them to land before anything else, since a jump leaves them behind; stragglers after that are
  pulled in with `Hangar.collectAllFighters`.
- **Cooldown**: with a cooldown running, the ship sits with an empty chain until it is over,
  then resumes the loop by itself. Enemies meanwhile are fought as `onEnemies` says, and a pilot
  leaving the controls does not end the farm until it is about to jump again.

`onEnemies` applies as for routes; with `fight` the loop resumes after the boss is dealt with.
With `continue` the ship neither stops for a boss nor, jumping on, sees it die. A dry run needs
nobody aboard and reports `piloted`.

Errors: `400 bad_boss`, `400 bad_collect_loot`, `400 bad_boss_cooldown`, `422 needs_pilot`, `422 no_hyperspace`, `422 no_farm_loop` (no pair of
empty sectors near the ring point), `422 no_route` (none to the loop), plus the world checks
above.

**Requires the owning player to be logged in.**

## GET /ships/{name}/automation

What the ship's automation is doing, as the ship itself last reported it.

```json
{
  "ship": "Ore Hound", "source": "live", "reported": true,
  "automation": {
    "version": 2,
    "standing": {"enemies": {"enabled": true, "mode": "interrupt"},
                 "loot": {"enabled": true, "mode": "idle"},
                 "flee": {"enabled": true, "hull": 0.4, "shield": 0,
                          "requireEnemies": true, "hops": 1, "to": {"kind": "known"}}},
    "autoAggressive": true, "attackCivilians": false,
    "enemies": false, "defenceFights": 3, "lootRuns": 5,
    "vitals": {"hull": 0.65, "shield": 1},
    "sector": {"x": 290, "y": 1},
    "plan": {
      "id": "p5-7322", "kind": "farm", "phase": "running", "onEnemies": "fight",
      "hops": 3, "hop": 2, "loopFrom": 2, "jumps": 14, "fights": 1,
      "target": {"x": 293, "y": 4}, "boss": "swoks",
      "bossPresent": null, "bossKills": 1,
      "lastKill": {"name": "swoks", "title": "Boss Swoks III", "sector": {"x": 293, "y": 4}},
      "collectLoot": true, "lootResult": "collected",
      "loot": {"instant": 0, "cargo": 2, "cargoPickup": false, "fighters": 6, "deployed": 0},
      "cooldown": {"left": 1740, "total": 1800}
    },
    "last": {"id": "p4-7310", "kind": "route", "outcome": "arrived", "jumps": 9, "fights": 0,
             "sector": {"x": -120, "y": 88}},
    "reaction": null,
    "lastReaction": {"kind": "loot", "outcome": "done", "lootResult": "collected",
                     "resumed": true, "sector": {"x": 290, "y": 1}}
  }
}
```

| field | notes |
|---|---|
| `source` | `live` from the event feed, `database` from the ship's row (as of the last save), `none` |
| `reported` | false until the ship has published anything - its sector has not loaded since the mod was installed, or another mod replaced `orderchain.lua` |
| `plan.phase` | `running`, `fighting` or `holding`; farms also `looting`, `returning` (waiting for fighters to land) and `cooldown`. `plan` is absent when there is none |
| `plan.bossPresent` | farms: `{name, title}` of the boss in the sector, absent when there is none |
| `plan.cooldown` | farms: `{left, total}` seconds while a kill's cooldown runs. Republished once a minute, so count down from when it arrived |
| `plan.loot` | farms: the last loot count - `instant` (any fighter), `cargo` (needs `cargoPickup`: transporter block and software), `fighters`, `deployed` |
| `plan.lootResult` | farms: how the last looting ended - `collected`, `stalled`, `timeout`, `no_launch`, `no_fighters`; `_recalled` appended when stragglers had to be pulled in |
| `plan.hop` | the hop being flown, 1-based, counting the approach |
| `last.outcome` | `arrived`, `stopped`, `replaced` (other orders took over), `refused`, `resume_failed`, `pilot_left` |
| `standing` | the ship's standing orders. `enemies` and `loot` are each `{enabled, mode}`; `flee` carries thresholds and a destination instead, see [POST /ships/{name}/automation](#post-shipsnameautomation). Absent on ships running a mod version from before standing orders, and `standing.flee` absent on those from before the flee order |
| `vitals` | hull and shield as fractions of this craft's own maximum, as the craft itself reports them. Rounded to 5% and rate limited, because every publish is an event in the craft's feed - so it is a condition reading, not a damage meter. Absent until the craft has published one, which it only does while it is hurt or has some automation switched on |
| `flee` | the flee order taking the craft out of a fight right now: `{reason, phase, hops, hopsLeft, from, target, hull, shield, to}`. `reason` is `hull` or `shield`; `phase` is `jumping`, or `stuck` when it has nowhere to go yet. Absent when there is none, and it is never alongside a `reaction` |
| `lastFlee` | how the last one went: `{reason, outcome, detail, hops, from, sector, hull, shield}`. `outcome` is `arrived` (where it was sent), `escaped` (out, short of the destination), `failed` (never got away - `detail` says why), `stopped`, `switched_off` or `replaced` |
| `autoAggressive` | kept for older clients: `standing.enemies.enabled` |
| `reaction` | a standing order holding the ship right now: `{kind, mode, phase, resumes, loot, lootResult}`. `phase` is `fighting`, `looting` or `returning`; `resumes` says whether an interrupted chain comes back afterwards. Absent when there is none, and never alongside `plan` |
| `lastReaction.outcome` | `done`, `replaced` (orders from elsewhere; the old chain is not put back), `switched_off` (the chain is put back), `stopped` |
| `defenceFights`, `lootRuns` | fights and loot runs started by standing orders, over the life of the ship |
| `transfer` | a [cargo transfer](#post-shipsnametransfer) on its way to a craft out of reach: `{id, target, direction, all, goods, phase}`, `phase` `docking` or `approaching`. Absent when there is none |
| `lastTransfer` | how the last transfer ended: `{id, target, direction, outcome, reason, message, moved, short, total, approached, sector}` - see [the outcomes](#post-shipsnametransfer) |

Works offline, from the database copy.

## POST /ships/{name}/automation

The ship's standing orders: what it does by itself, without a plan, while its sector is
loaded.

| order | what it does |
|---|---|
| `enemies` | turns aggressive while enemies are in the sector, until it has been clear for five seconds |
| `loot` | sends every squad for loot in the sector, then waits for the fighters to land. Needs fighters aboard; cargo drops only count with a transporter block and Transporter Software (rare or better). Never under fire. Loot that could not all be taken (a stall, fighters that would not launch) is left alone in that sector for two minutes |
| `flee` | breaks off and jumps out when the craft's hull or shield falls below a threshold. See [the flee order](#the-flee-order) below |

`enemies` and `loot` each have a `mode`:

| mode | when it may take the ship |
|---|---|
| `idle` | only while the ship has no orders (the default) |
| `interrupt` | whatever it is doing. The chain is put aside whole and put back afterwards, at the order it was on; loops keep their indices |

A fight that leaves loot goes on to the loot when the loot order applies to what the ship was
doing: always if it was idle, only in `interrupt` mode if a chain is waiting. Enemies arriving
while the fighters are out are fought.

Both need a captain, as vanilla requires for any order; a ship somebody is flying is left to
them. While a plan runs, the plan's own `onEnemies` and `collectLoot` govern, and the standing
orders wait. A planned route, which has no loot setting of its own, collects loot after its
fights when the loot order is on in `interrupt` mode. Sending orders or a plan while a standing
order holds the ship ends it, and the chain it put aside is not put back. Switching an order
off while it holds the ship ends it and puts the chain back.

```jsonc
{
  "standing": {
    "enemies": {"enabled": true, "mode": "interrupt"},
    "loot": {"enabled": true},
    "flee": {
      "enabled": true,
      "hull": 0.4,
      "shield": 0,
      "requireEnemies": true,
      "hops": 1,
      "to": {"kind": "known"}
    }
  },
  "attackCivilians": false
}
```

### The flee order

`standing.flee` takes a craft out of a fight it is losing. It has no `mode`: it outranks
everything - a planned route, a boss farm, a fight it was told to pick, a cargo transfer on
its way - because none of those matter once the craft is about to be lost. Unlike the other
two it never puts the interrupted chain back: those orders are what flew it into the fight.

| field | notes |
|---|---|
| `enabled` | whether the order is on |
| `hull` | flee below this fraction of the craft's own maximum hull. `0` does not watch the hull |
| `shield` | the same for the shield. At least one of the two has to be set, or nothing would ever fire |
| `requireEnemies` | only flee while there are enemies in the sector (the default). `false` flees on the threshold alone, which catches a craft bleeding out after a fight |
| `hops` | the most jumps one flee may make, 1 to 10. Only meaningful for the destinations that can be further than one jump |
| `to` | where to run; see below |

A threshold is a fraction from 0 to 1, so one rule fits a freighter and a battleship.
Anything above 1 is read as a percentage, since a fraction cannot be - `81` and `0.81` are
the same request, and the answer reports the fraction.

`to.kind` is one of:

| kind | where it goes |
|---|---|
| `known` | a sector the owner has already been to, inside one jump, picked at random - a predictable bolthole is one an attacker can follow the craft to every time. If the owner knows nowhere in range, any valid sector in range |
| `safe` | the nearest sector in jump range held by a faction that is not hostile to the owner, which polices it. Falls back to `known` when there is none |
| `station` | towards the nearest station of the owner or their alliance. `"name": "any"` widens it to the nearest craft of the fleet |
| `location` | towards a sector from the [location library](#locations), as `"name"`. Checked when the order is set, so a typo is `404 no_such_location` rather than a craft running somewhere unexpected mid-fight |
| `sector` | towards fixed `x` and `y` |

A craft attacked in the very sector it was told to run to leaves anyway, by the `known`
rule: getting out is the point, and anywhere else beats dying at home.

The last three can be further than one jump, and are walked towards a hop at a time rather
than routed: the route planner is a galaxy-side search sliced across ticks and a craft being
shot at cannot wait for one, and a greedy step towards the destination is out of this sector
either way, which is the urgent half. The flee ends when the craft reaches the destination
(`arrived`), when it runs out of `hops` short of it (`escaped`), or after four minutes of
finding nowhere to jump (`failed`).

A destination is replaced whole rather than merged: sending `{"to": {"kind": "known"}}` over
a `location` destination drops its name.

Every part is optional: an order or field left out stays as the ship has it. `attackCivilians`
decides whether civilian ships count as enemies, for the standing orders and the ship's enemy
check alike. `autoAggressive` is the older name for `standing.enemies.enabled` and is still
accepted; sending both with different values is `400 conflicting_settings`.

The settings are saved on the ship and survive restarts; a ship saved with `autoAggressive`
on comes back with the `enemies` order in `idle` mode. The answer is held until the ship
reports the new settings, as for routes. It gives the ship no order, so only the world checks
apply, not the captain ones.

Errors: `400 no_settings`, `400 bad_setting`, `400 bad_standing` (not an object, an unknown
order - `details.known` lists them - or an order that sets nothing), `400 bad_standing_mode`,
`400 conflicting_settings`, `400 bad_threshold` (outside 0 to 100, or an enabled flee order
with both thresholds at 0), `400 bad_flee_hops`, `400 bad_flee_to` (`details.known` lists the
kinds), `404 no_such_location`.

**Requires the owning player to be logged in.**

## POST /ships/{name}/automation/stop

Ends the ship's plan, a flee in progress, a standing order holding the ship, or a cargo
transfer on its way to its target, and clears its order chain. The standing orders are settings and stay as they were.
Answered once the ship reports it has none of them.

**Requires the owning player to be logged in.**

## GET /ships/{name}/transfer

The craft's hold, and every other craft of yours and of your alliance with theirs: what a
[transfer](#post-shipsnametransfer) could move, and where to. Alliance craft are listed only
when your rank has ManageShips. Read from the ship database, so it works offline - and for a
craft in a loaded sector, the hold can trail the craft by a moment.

| query | notes |
|---|---|
| `sameSector` | `true` lists only craft in the same sector, the ones a transfer can reach now |

```json
{
  "ship": {
    "name": "Ore Hound", "type": "Ship", "owner": {"kind": "player", "index": 1, "name": "Rusty"},
    "position": {"x": 12, "y": -4}, "sector": {"x": 12, "y": -4},
    "availability": "Available", "captain": true,
    "cargo": {"capacity": 500, "free": 180, "used": 320,
              "goods": [{"name": "Iron", "amount": 300, "size": 1, "price": 10, "stolen": false, "...": "..."}]}
  },
  "targets": [
    {"name": "Rusty Refinery", "type": "Station", "owner": {"kind": "player", "index": 1, "name": "Rusty"},
     "position": {"x": 12, "y": -4}, "availability": "Available", "sameSector": true,
     "cargo": {"capacity": 12000, "free": 5000, "used": 7000, "goods": ["..."]}}
  ],
  "count": 1
}
```

Targets in the same sector come first, then the rest by name.

## POST /ships/{name}/transfer

Moves goods between the craft and another of yours or of your alliance in the same sector,
as the game's own transfer window does.

```jsonc
{
  "target": "Rusty Refinery",
  "targetOwner": "player",          // optional: player or alliance, when both own a craft of that name
  "direction": "give",              // give: into the target (default), take: out of it
  "goods": [
    {"name": "Iron", "amount": 120},  // amount left out (or null): all of that good
    {"name": "Iron", "stolen": true}  // stolen: true only stolen ones, false only clean ones
  ],
  "approach": true                  // default true; see below
}
```

`"all": true` instead of `goods` moves the whole hold, whatever it holds when the ship gets to
it. A good named without `stolen` takes the clean ones first. What does not fit in the
receiving hold stays where it is and is reported; nothing is lost.

The transfer is carried out by the ship, which reads both holds as they really are - the
request is not checked against the database's copy of either. Vanilla's rule decides whether
the two are in reach: their nearest points at most 20 apart, or as far as the longer
transporter reaches. Out of reach, with `approach`:

- a **station** is docked with, with the game's own dock order;
- a **ship** is flown to, until the two are in reach;

and the goods move the moment they are, which the ship reports in its automation state. An
approach is an order: it needs a captain and nobody at the controls, it ends a route, farm or
standing order holding the ship, and it gives up after five minutes. Orders given to the ship
meanwhile end it, as does [stop](#post-shipsnameautomationstop). A transfer in reach touches
nothing the ship is doing, and needs no captain.

A **station** in the path is served by the ship at the other end, the other way round: a
station that gives is a ship that takes. The ship is then the one that has to be orderable,
and its event feed is where the transfer is reported (`carriedOutBy`). Two stations cannot
transfer between themselves.

The answer is held until the ship reports the transfer done, refused, or under way:

```json
{
  "ship": "Ore Hound", "owner": {"kind": "player", "index": 1, "name": "Rusty"},
  "target": {"name": "Rusty Refinery", "owner": {"kind": "player", "index": 1, "name": "Rusty"}},
  "sector": {"x": 12, "y": -4}, "transferId": "t3-8120",
  "direction": "give", "all": false, "goods": [{"name": "Iron", "amount": 120}], "approach": true,
  "summary": "give 120 Iron to Rusty Refinery",
  "carriedOutBy": {"name": "Ore Hound", "owner": {"kind": "player", "index": 1, "name": "Rusty"}},
  "confirmed": true, "done": true,
  "result": {"id": "t3-8120", "outcome": "done", "total": 120, "approached": false,
             "moved": [{"name": "Iron", "amount": 120}], "target": "Rusty Refinery", "direction": "give"}
}
```

| field | notes |
|---|---|
| `done` | `true` with `result` once it is over; `false` with `phase` (`docking`, `approaching`) while the ship gets in reach |
| `result.outcome` | `done`, `partial` (some moved, see `short`), `nothing_moved`, `refused`; later, in the automation state, also `replaced` and `stopped` |
| `result.moved` | `[{name, amount, stolen?}]` per kind of good moved |
| `result.short` | `[{name, wanted, moved, reason}]` for what was not: `not_held`, `no_space`, `not_enough`; with `all`, `[{reason: "no_space"}]` |
| `result.reason` | why it was refused or given up: `target_not_here`, `target_gone`, `same_craft`, `not_permitted`, `out_of_range`, `needs_captain`, `piloted`, `timeout`, `no_goods`; `empty_hold` when `all` found nothing |

Refused by the ship, the answer is `422` with `error.code` set to the reason. Errors checked
before anything is sent: `400 no_target`, `400 no_goods`, `400 bad_goods`, `400 bad_direction`,
`400 conflicting_goods`, `400 bad_approach`, `400 bad_target_owner`, `404 no_such_target`,
`403 missing_privilege` (either craft is the alliance's, and your rank lacks ManageShips),
`409 target_in_background`, `422 same_craft`, `422 not_same_sector` (`details` has both
sectors), `422 no_ship`, and the world checks every order has: `409 owner_offline`,
`409 ship_in_background`, `409 sector_not_loaded`. A `202` means the ship did not report
back in time, as for [orders](#post-shipsnameorders).

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
  factor for the counterparty, and neither is in the ship database. What trades actually
  settled at is in `observed`, below.
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
- `observed` is what the station has **actually done** since the server started, recorded
  from inside it - see [Recorded from inside the station](#recorded-from-inside-the-station).
  It is on the listing too, and absent for a station nothing has been recorded for yet.

```json
"observed": {
  "since": 120.5, "last": 7320.5, "trades": 30,
  "production": {
    "seconds": 7200, "slotSeconds": 21600, "busySlotSeconds": 10800,
    "starvedSeconds": 1800, "blockedSeconds": 0, "idleSeconds": 0,
    "cycles": 100, "boosted": 0, "catchupSeconds": 0, "catchupCycles": 0,
    "slots": 3, "cycleSeconds": 72, "utilization": 0.5, "cyclesPerHour": 50
  },
  "goods": [
    {"name": "Oil", "made": 500, "used": 0, "madePerHour": 250, "usedPerHour": 0,
     "sold": {"units": 400, "credits": 136000, "trades": 10, "unitPrice": 340},
     "bought": {"units": 0, "credits": 0, "trades": 0},
     "consumed": {"units": 0, "credits": 0, "trades": 0},
     "internalIn": 0, "internalOut": 0}
  ]
}
```

  `utilization` is busy slot time over slot time. `starvedSeconds` and `blockedSeconds` are
  the seconds in which at least one slot sat idle for want of an ingredient or of room for
  the result, and `idleSeconds` those with no reason given. `cyclesPerHour` is over
  `seconds + catchupSeconds`, running time plus the unloaded stretches the game caught the
  factory up for - its real rate, where `production.rate.cyclesPerHour` is its ceiling.
  `made` and `used` are cycles times the recipe, optional ingredients counted on boosted
  cycles only. `unitPrice` is the average a good actually traded at. `internalIn` and
  `internalOut` are units moved between your own stations or to an alliance member, which
  change hands for nothing and so are never counted as a price.

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

### Recorded from inside the station

The game writes every station trade into its owner's economy log, and nothing reads that log
back - there is no getter and no callback. So the mod does not read it. It extends the two
scripts that write it: `data/scripts/lib/tradingmanager.lua`, behind every merchant script,
and `data/scripts/entity/merchants/factory.lua`, the production loop. Both of the mod's copies
are appended to the game's own, and wrap the vanilla functions without changing what they do.

What that records, per player and alliance station:

- **trades** - the good, the units, the price the counterparty actually paid, the owner's
  share, the transaction tax, who the counterparty was and which ship docked. Docked ships
  buying and selling, other stations' shuttles, and a population consuming what a habitat
  bought.
- **production windows** - once a minute per factory: the cycles started and how many were
  boosted, busy slot time, and why idle slots were idle, with the recipe it ran.
- **catch-up** - the production the game runs in one step when an unloaded sector loads
  again, as cycles over the seconds it covers.

It records **with every player logged out**, and only while the station's sector is loaded:
nothing runs in an unloaded sector. That loses no money - a player station makes no trades
while unloaded, and production is caught up on reload - but a sector that has not been
loaded since has nothing recorded yet. AI stations are not recorded.

The mod holds this in memory: running totals per station (`observed`, above) and a feed per
owning faction of the last 5000 events (`Config.stationEventsPerFaction`), both empty after a
restart. The bridge's poller collects the feed into its history store; see
[`/history/economy/observed`](#get-historyeconomyobserved).

## GET /stations/{name}/events

One station's recorded activity, oldest first. With `since` the page runs forward from it;
without, it is the newest `limit` events.

| query | values | default |
|---|---|---|
| `since` | a `cursor` from a previous response | - |
| `limit` | 1 - 1000 | 1000 |
| `owner` | `player`, `alliance`, `all` | `player` |

```json
{
  "station": "Rusty Refinery",
  "owner": {"kind": "player", "index": 1, "name": "..."},
  "boot": "1757716400", "now": 7320.5,
  "cursor": 482, "more": false, "gap": false,
  "recording": true,
  "observed": {"...": "as on /stations/{name}"},
  "events": [
    {"seq": 480, "at": 7250.1, "kind": "trade", "station": "Rusty Refinery", "faction": 1,
     "sector": {"x": 12, "y": -4},
     "direction": "sold", "channel": "docked", "good": "Oil", "units": 50,
     "price": 17000, "unitPrice": 340, "ownerAmount": 17000, "tax": 340,
     "internal": false, "ship": "Oil Barge",
     "counterparty": {"index": 900, "name": "The Xsotan Traders", "kind": "ai"}},
    {"seq": 481, "at": 7260.0, "kind": "production", "station": "Rusty Refinery",
     "seconds": 60, "slotSeconds": 180, "busySlotSeconds": 120, "starvedSeconds": 30,
     "blockedSeconds": 0, "idleSeconds": 0, "cycles": 2, "boosted": 0, "utilization": 0.667,
     "slots": 3, "cycleSeconds": 72,
     "results": [{"name": "Oil", "amount": 5}],
     "ingredients": [{"name": "Raw Oil", "amount": 10}], "garbage": []},
    {"seq": 482, "at": 7300.0, "kind": "catchup", "station": "Rusty Refinery",
     "seconds": 3600, "cycles": 50, "results": ["..."], "ingredients": ["..."], "garbage": []}
  ]
}
```

- `direction` is the station's side: `sold`, `bought`, or `consumed` (a population eating
  what it bought, and paying for it). `channel` is `docked`, `direct` (another station, or a
  trader that never docks) or `population`.
- `at` and `now` are the server's uptime clock, so an event happened `now - at` seconds
  before the answer. `boot` changes when the server restarts, and `seq` starts again from
  zero with it.
- `recording` is whether the station's sector is loaded right now.

## GET /economy/events

Every recorded event for the caller's stations in one feed - the call a collector makes.

| query | values | default |
|---|---|---|
| `owner` | `player`, `alliance`, `all` | `player` |
| `since` | a `cursor` from a previous response | - |
| `limit` | 1 - 1000 | 1000 |

The same envelope as above, plus `owners`, with an `owner` on every event. With `since` a
page runs **forward** from it: `more: true` means ask again with the `cursor` returned, until
`more` is false. `gap: true` means events after `since` had already fallen out of the buffer
before they were collected - poll more often. A different `boot` than last time means the
server restarted, and the collector should start again from `since=0`.

Registered as `/economy/events` rather than under `/stations/` so it cannot shadow a station
that happens to be called "events".

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

Plans a route without sending anything. With no preferences this runs the game's own
`calculateJumpPath`, the same pathfinder the travel analysis uses; with any of them it runs
this mod's planner, which is what [`POST /ships/{name}/route`](#post-shipsnameroute) flies.

| query | notes |
|---|---|
| `ship` | take origin, jump range and rift capability from a ship |
| `fromX`, `fromY`, `range`, `rifts` | or give them explicitly |
| `toX`, `toY` | the destination; or `target` (+ `targetOwner`), or `location`, as [destinations](#destinations) take them |
| `preferGates`, `preferWormholes`, `fewestJumps`, `avoidRifts`, `preferUncontrolled` | `true`/`false`; giving any of them selects the mod's planner. See [`/route`](#post-shipsnameroute) for what each does |

```json
{
  "from": {"x": 0, "y": 0}, "to": {"x": 60, "y": 0},
  "reachable": true, "jumps": 12, "distance": 60.0,
  "route": [{"x": 0, "y": 0}, "..."],
  "jumpRange": 5.0, "canPassRifts": false, "planner": "engine"
}
```

`reachable` is false when the pathfinder stopped short of the destination - check it rather
than assuming the last sector in `route` is where you asked to go.

The mod's planner (`"planner": "automation"`) answers in the same shape and adds `hops` - each
with `kind` (`jump`, `gate`, `wormhole`), `distance`, `controlled` (faction space) and `rift` -
along with `gates` (gates and wormholes), `wormholes`, `controlledSectors`, `preferences`,
and `reason` when unreachable. A named destination adds `destination`. It
works from the same facts the engine does: jump range, rift geometry, the barrier, and the
gates and wormholes the player or their alliance know about. It is not an exhaustive search:
each step considers a fixed set of directions at full and two-thirds range rather than every
sector in reach, which keeps it affordable at long jump ranges and costs little in route
length. Crossing the barrier is only planned for ships that can pass rifts. Every jump is
re-checked against the engine when the ship takes the route up.

It is sliced across server ticks (`Config.routePlanStepsPerTick`) and gives up after
`Config.routePlanMaxExpansions` sectors, answering unreachable with `reason: "search_limit"`.

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

Everything above is the mod's. `/history/*` and `/notifications/*` are not: they are
answered by the HTTP bridge in `docker/bridge/`, out of its own store, and never reach the
game server.

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
| `GET /ships/{name}` | the craft's hold, captain and passengers, as a **manifest** - the latest only |
| `GET /ping` | which player the key belongs to, and which alliance they are in |
| `GET /economy/events`, `GET /stations/{name}/events` | the stations' recorded trades, production windows and catch-ups, as **station events** |

Positions come from the ship database, which the mod reads **with every player logged out**,
so the travel record keeps filling whether or not anything is online to fly.

**Nothing in the mod pushes.** History accumulates only while something is calling the API,
and the mod's event log is a 200-entry ring buffer that drops its oldest entry whether or
not anyone collected it. The compose stack runs a `poller` service for exactly this: for
every key enrolled with [`POST /services/enrol`](#background-services) it calls these
endpoints every `POLL_INTERVAL` seconds (default 30), which is also the accuracy of a
travel track.

It asks for `/ships?owner=all&type=all`, so an alliance's craft and everybody's stations
are recorded, not just the calling player's own ships. Stations are left out of the visit
log - a station's visit never ends, which is not a record of travel and would take over
the heatmap - and out of the per-craft event calls, since the order chain does not run on
one and the answer is always empty. What a station does is recorded through
`/stations` and `/economy/events` instead.

The station events are the one collection that is not a snapshot at all: they sit in the
mod's buffer until something pages through `/economy/events`, and the poller does that on
every pass with `POLL_ECONOMY` on, carrying a cursor from pass to pass so nothing between two
passes is skipped. It logs a line if the mod dropped events before they were collected.

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

**A row belongs to the faction that owns the craft** - the player, or their alliance - as the
mod reported it in the answer being recorded, not to the key that relayed it. So an
alliance's fleet has one history however many members are polling it, and a player with two
keys has one history rather than two.

What a key may read:

- **its player's rows**, always;
- **its alliance's rows**, only while the mod has confirmed the membership within
  `HISTORY_VERIFY_TTL` seconds (default 300). A read that finds the confirmation older than
  that relays a `GET /ping` for the key through the transport first. If that cannot be done -
  the game server is down - the read gets the player's rows and no alliance rows. A player
  who left the alliance still has a working key, so an old confirmation is not good enough;
- **rows recorded before rows had owners**, until they are adopted - see below.

A key the mod refuses (`401`) reads nothing. Nothing is ever written except off the back of a
call the mod itself answered 2xx, and a row's owner comes out of that answer rather than out
of anything the caller sent. The store keeps a SHA-256 of each key and never the key itself.

### Upgrading from per-key history

A bridge from before faction ownership kept every row against the key that recorded it. The
schema migrates on first connection and each key goes on reading exactly what it recorded.
The first time the mod vouches for that key again - a relayed `/ping`, which the console makes
on connecting and the poller makes every pass, or the check a `/history` read makes - its rows
move onto their owners: player craft to the player, alliance craft to the alliance the player
is in now. A visit another member already contributed for the same stay is widened rather than
duplicated, and an event both collected is kept once.

A player in no alliance at that moment keeps their old alliance rows private to the key,
rather than carrying them into whichever alliance they join next.

Station events came after rows had owners and have nothing to adopt: each is stored under
the faction that owns the station, as the feed names it, and an alliance event whose feed
does not say which alliance is dropped rather than guessed at. The mod numbers the feed once
per server run, so the same event collected by two members is stored once. Only the
collector's position in the feed is kept per key, since a key's feed covers its player and
alliance together. Clearing history takes the player's station events and leaves that
position where it is, so what was just cleared is not collected again.

A database built by the first, unmerged cut of station recording also reads as version 3,
without the ownership step. The migration tells it apart, drops the two station tables it
made, which name no owner, and runs the ownership step before creating them again.

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
    {"name": "Ore Hound", "owner": "player", "visits": 41, "events": 190, "samples": 0,
     "sectors": 12, "first": 1757630000, "last": 1757719400}
  ],
  "rows": 231, "retentionDays": 30, "recording": true,
  "scope": {"player": {"index": 1, "name": "..."}, "alliance": {"index": 77, "name": "..."},
            "verified": true},
  "economy": {"samples": 560, "stations": 2, "since": 1757630100, "interval": 300}
}
```

`scope` is whose history the answer covers. `alliance` is `null` for a player in no alliance,
and also when the membership could not be confirmed just now - `verified` is `false` then.

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

## GET /history/economy/observed

What each station **actually did** over the window, out of the station events the bridge
collected: production against slot time, units per good, and trades at the prices they
happened at. It is the measured counterpart of the `rate` on `/stations/{name}`, which is a
ceiling.

Takes `station` (or `ship`), `owner`, `x` and `y` together, `from` and `to`.

```json
{
  "window": {"from": 1757630000, "to": 1757716400},
  "stations": [{
    "ship": "Rusty Refinery", "owner": "player", "x": 12, "y": -4,
    "first": 1757630120, "last": 1757716380, "span": 7200, "trades": 30,
    "production": {
      "windows": 120, "seconds": 7200, "slotSeconds": 21600, "busySlotSeconds": 10800,
      "starvedSeconds": 1800, "blockedSeconds": 0, "idleSeconds": 0,
      "cycles": 100, "boosted": 0, "catchupSeconds": 0, "catchupCycles": 0,
      "slots": 3, "cycleSeconds": 72, "utilization": 0.5, "cyclesPerHour": 50
    },
    "goods": [
      {"good": "Oil", "made": 500, "used": 0, "madePerHour": 250, "usedPerHour": 0,
       "sold": {"units": 400, "credits": 136000, "trades": 10, "unitPrice": 340},
       "bought": {"units": 0, "credits": 0, "trades": 0, "unitPrice": null},
       "consumed": {"units": 0, "credits": 0, "trades": 0, "unitPrice": null},
       "internalIn": 0, "internalOut": 0}
    ],
    "traded": {"sold": 136000, "bought": 70000, "consumed": 0, "net": 66000, "perHour": 33000}
  }]
}
```

`span` is what the per-hour figures divide by: the seconds the station's production windows
cover while loaded plus the unloaded stretches the game caught it up for on reload. For a
factory that is wall-clock time without the gaps nobody was collecting, since the mod buffers
those. A sector still unloaded at the end of the window has not been caught up yet, and its
tail is missing from both sides of the division. A station with no production windows - a
trading post - has no running time to go by, so its span is the time between its first and
last event.

The fields are those of [`observed`](#get-stationsname) on the mod's own station detail,
over the window rather than since the server started.

## GET /history/economy/events

The stored station events themselves, newest `limit` in time order: the trade log. Takes
the same filters as above, plus `kind` - `trade`, `production` or `catchup` - and `before`.

```json
{"events": [
  {"id": 9120, "t": 1757716200, "station": "Rusty Refinery", "owner": "player", "x": 12, "y": -4,
   "boot": "1757716400", "q": 480,
   "kind": "trade", "direction": "sold", "good": "Oil", "units": 50, "price": 17000, "...": "..."}
]}
```

To read the whole log, page back: pass the `id` of the first (oldest) event of a page as
`before` for the page ahead of it, until a page comes back shorter than `limit`. `before` is
a position in the log's own order, not a time, so events that share a second are neither
repeated nor skipped. `boot` and `q` are the mod's run and `seq` for the event, which is how
to merge this with the live [`/economy/events`](#get-economyevents) feed without doubling
what both hold.

## GET /history/manifests

The last hold and crew list the bridge relayed for each craft, newest first. One per craft,
replaced whenever anyone reads `GET /ships/{name}` - not a series.

| query | notes |
|---|---|
| `ship` | one craft by name |
| `owner` | `player` or `alliance` |
| `from` | Unix seconds; only manifests read since |

```json
{"manifests": [
  {"ship": "Ore Hound", "owner": "player", "at": 1757719400,
   "cargo": {"capacity": 6000, "free": 1100, "used": 4900, "goods": [{"name": "Iron Ore", "amount": 2400}]},
   "captain": {"name": "Vex", "...": "..."}, "passengers": []}
]}
```

`cargo`, `captain` and `passengers` are exactly as `GET /ships/{name}` returned them. `at` is
when that was, and judging it is up to the caller: the console searches stored manifests
straight away and re-reads any older than two minutes live.

## POST /history/clear

Drops this player's own history, or one craft's share of it with `?ship=`. That is the
player's rows under every one of their keys.

```json
{"cleared": true, "ship": "Ore Hound", "removed": 231}
```

Alliance history is never cleared: it belongs to every member, and the bridge cannot ask the
game which of them may delete it. `?owner=alliance` answers `403 history_shared`.

# Push notifications

`/notifications/*` is the bridge's, like `/history/*`. Avorion is a game you leave running,
and a browser notification only reaches a tab that is open on a machine that is awake -
which is exactly not the case when a fleet is grinding overnight. These are rules over what
the bridge has already collected, pushed out to a phone.

## How it works, and what that costs

Nothing new is asked of the game. The mod already publishes everything an alert could be
built from - each craft's order and status events, whether there are enemies in its sector,
its hull and shield - and the poller is already collecting all of it into Postgres for the
history store. A second service, `notifier`, reads those rows, decides what crossed a line
somebody cared about, and does one HTTP POST per alert. Its one live call is the craft
listing, once per key per pass.

The consequences are worth stating plainly, because a missed alert is more surprising than
a gap in a heatmap:

* An alert is never quicker than the poller. `POLL_INTERVAL` is the floor.
* A craft records nothing while its owner is logged out, because the player scripts that
  capture its events do not run then. Nothing about it can raise an alert.
* A player has to have [enrolled a key](#background-services) with `notify` on for their
  rules to be run at all. Unlike the poller, one member is **not** enough for an alliance:
  a rule belongs to a player and goes to that player's channels.

## Whose they are

A rule and a channel belong to the player an API key is, never to a faction. Everything in
the history store is the other way round on purpose - what a craft did is shared by an
alliance - but whose phone buzzes is not. Two members of one alliance want different things
from the same fleet, and neither should be able to switch the other's alerts off or read
the other's ntfy token.

A rule can widen its scope to the player's alliance craft with `alliance: true`, and is
still that player's rule, sent to that player's channels. That needs the mod to confirm the
membership, so a player who has left stops hearing about the fleet even though they kept
their key.

Identity comes from the mod, exactly as it does for the history store: the bridge relays a
`/ping` when its answer about a key is older than `HISTORY_VERIFY_TTL`. A key the mod will
not vouch for reads and writes nothing, and gets `401 unknown_key`.

## Channels

Where a message goes.

| kind | needs | notes |
|---|---|---|
| `ntfy` | `url`, `config.topic` | Free, self-hostable, and an app on both phone platforms. Published as JSON to the server root, so a non-ASCII craft name survives the title. `token` is an access token, or `user:password` |
| `gotify` | `url`, `token` | Self-hosted. Posted to `/message` with the application token in a header, so it stays out of the push server's access log |
| `webhook` | `url` | The notification as JSON to any URL, with `config.headers` of your choosing. Discord, Slack, Home Assistant, an Apprise container or a script of your own all live behind this. `token` is sent as `Authorization: Bearer` |

A channel's token is a credential the bridge has to be able to present, so unlike an API
key it cannot be stored as a hash. It is never handed back out: reads answer `hasToken`
instead, and a save that leaves `token` out keeps whatever is stored. Send `""` to clear it.

### GET /notifications/channels

```json
{
  "channels": [
    {"name": "Phone", "kind": "ntfy", "url": "https://ntfy.sh",
     "config": {"topic": "avorion-rusty"}, "enabled": true, "hasToken": true,
     "updated": 1730000000}
  ]
}
```

### POST /notifications/channels

Creates one, or replaces the one of that name.

```json
{"name": "Phone", "kind": "ntfy", "url": "https://ntfy.sh",
 "config": {"topic": "avorion-rusty"}, "token": "tk_...", "enabled": true}
```

Answers `{"channel": {...}}`. Errors: `400 bad_name`, `400 bad_channel` (an unknown kind, a
URL that is not `http`/`https`, ntfy without a topic, Gotify without a token, headers that
are not an object of words to text).

### POST /notifications/channels/delete

`{"name": "Phone"}`. Answers `{"removed": true, "rules": ["Under attack"]}` - the rules that
named it, which now reach every other channel instead. They are not changed, and not
silently left sending to nothing either.

### POST /notifications/channels/test

`{"name": "Phone"}`, or no body for every enabled channel. Sent immediately rather than
queued, since whoever asked is waiting to find out whether the channel works.

```json
{"results": [{"channel": "Phone", "ok": true, "status": 200, "error": ""}]}
```

A failure reports the status code and nothing else. The URL is one the player chose, often
a private address, and returning its body would turn a channel into a way of reading pages
off the network the bridge sits on.

## Rules

When to send one.

| kind | source | options |
|---|---|---|
| `combat` | events | `ends` - also tell me when the fight is over |
| `hull` | level | `below` - the fraction of hull left |
| `shield` | level | `below` |
| `flee` | events | - |
| `idle` | events | - |
| `plan` | events | - |
| `boss` | events | - |
| `status` | events | `contains` - text to look for in the craft's status line, case insensitive |
| `gone` | fleet | - |

`source` decides how a rule behaves:

* **level** is a value that moves. It fires on the way down past `below` and rearms only
  once the craft has recovered 5% past it again, so a craft sitting on the line does not
  buzz once a pass. `below` takes a fraction or a percentage, like the flee thresholds.
* **events** is a point in time, out of the craft's event feed, and fires on the edge - a
  fight starting, a plan ending, a boss going down.
* **fleet** is the shape of the fleet itself. `gone` fires for a craft that was in the
  listing and is not any more: destroyed, sold, or handed over. Nothing fires until a
  craft has been seen at least once, and an empty listing raises nothing at all - that is
  far more likely to be the mod reloading than a fleet wiped out in one pass. It also
  fires if you leave the alliance whose craft it was.

Every rule has a `quiet` period, in seconds: the floor between two of that rule about one
craft. A fight is a long sequence of events and none of them is worth a second buzz.

A player evaluated for the first time starts from now. Writing a first rule does not replay
a month of history onto a phone.

### GET /notifications/rules

```json
{
  "rules": [
    {"id": 3, "name": "Losing a fight", "kind": "hull", "enabled": true,
     "ship": "", "alliance": false, "config": {"below": 0.4},
     "channels": ["Phone"], "priority": 4, "quiet": 300, "updated": 1730000000}
  ]
}
```

### POST /notifications/rules

Creates one, or replaces the one of that name.

```jsonc
{
  "name": "Losing a fight",
  "kind": "hull",
  "config": {"below": 0.4},
  "ship": "",            // "" is every craft in scope
  "alliance": false,     // also watch the alliance's craft
  "channels": [],        // [] is every channel the player has
  "priority": 4,         // 1 to 5; mapped onto whatever the service uses
  "quiet": 300,
  "enabled": true
}
```

Answers `{"rule": {...}}`. Errors: `400 bad_name`, `400 bad_kind`, `400 bad_config` (an
option the kind does not take, or the wrong shape), `400 bad_priority`, `400 bad_quiet`,
`400 bad_ship`, `404 no_such_channel`, `409 no_alliance`.

### POST /notifications/rules/delete

`{"name": "Losing a fight"}`. Answers `{"removed": true}`.

### GET /notifications/kinds

The catalogue above, as data: `{"kinds": {...}, "channelKinds": {...}}`. The only call here
that needs no identity, so a client can build its form before it has a key that works. The
bundled console draws its form from this rather than from a copy of its own.

### GET /notifications

Everything at once, which is what a console opening the page wants: `player`, `alliance`,
`channels`, `rules`, `log` (the 50 newest), `kinds`, `channelKinds`, and `pending`, the
number of notifications raised but not yet delivered.

### GET /notifications/log

`?limit=` up to 500, newest first.

```json
{
  "log": [
    {"rule": "Losing a fight", "kind": "hull", "ship": "Ore Hound",
     "title": "Ore Hound: hull at 35%", "body": "Hull is below 40% and was 65%.",
     "priority": 4, "at": 1730000000, "delivered": 1730000001,
     "attempts": 1, "error": "", "data": {}}
  ]
}
```

`delivered` is null while a notification is still in the outbox. A send that fails is backed
off - 30s, 60s, 2m, 4m, 8m - and given up on after six attempts, because an alert about a
fight an hour ago is noise. One channel succeeding counts as delivered: the point is that
the player hears about it, not that every route worked.


# Background services

Served by the bridge, not the mod. `GET`/`POST /services/*`.

The `poller` and the `notifier` are ordinary API clients: they make the same calls a
console does, over HTTP, and the mod authenticates them like anything else. So they need
one of the player's keys to make those calls with, and something has to say whose.

Up to schema 5 that was `POLL_KEYS` and `NOTIFY_KEYS` in the stack's `.env`. These
endpoints replace it. A player enrols their own key, the keys live in the database, and
each service re-reads them at the top of every pass - so enrolling takes effect within one
interval, nothing is restarted, and an admin never handles anybody else's credential.

## What is stored, and why it is a key rather than a hash

Everywhere else the bridge keeps a SHA-256 of a key and never the key, because it only
ever has to *recognise* one. A background service has to *present* one, and no hash the
mod will accept can be derived from another. There is no version of "call the API as this
player while they are asleep" that does not keep the player's key.

So `service_keys.secret` is the key, encrypted with AES-256-GCM under a secret from
`ENROL_SECRET`, or from the file at `ENROL_SECRET_FILE` (default `/run/enrol/secret`,
which the compose stack generates into a volume on first start). Worth being plain about
what that buys: nothing against someone already inside the stack, who can read the secret
and the database alike; everything against the rows travelling without the secret, which
is a backup, a copied volume, a decommissioned disk. Losing the secret is not corruption -
the services skip what they cannot open and log it - but every player has to enrol again,
so the volume deserves the same backup as the database.

The key is never handed back out. A row's `id` is that same SHA-256, which is not the key
and cannot be walked back to it.

Enrolment is refused outright, with `503 enrolment_disabled`, where no secret is
configured. A bridge that cannot store a key safely does not store one another way.

## GET /services/kinds

The catalogue: what a key can be enrolled for. Needs no identity and works with no secret
configured, so a client can explain the feature - including explaining that this
deployment has it switched off - before it holds a key that works.

```json
{
  "services": {
    "poll":   {"title": "Record my fleet", "about": "..."},
    "notify": {"title": "Send me alerts",  "about": "..."}
  },
  "available": true,
  "reason": ""
}
```

## GET /services

The catalogue, plus this player's own enrolments. Never anybody else's.

```json
{
  "services": {"poll": {}, "notify": {}},
  "enrolled": [
    {"id": "9f86d081...", "label": "my fleet", "poll": true, "notify": false,
     "enrolledAt": 1730000000, "usedAt": 1730000600, "failures": 0, "error": ""}
  ]
}
```

`usedAt` is the last pass that worked. `failures` and `error` are the last one that did
not, which is how a player finds out their key was revoked rather than wondering why
nothing arrives.

## POST /services/enrol

```json
{"key": "avo_...", "poll": true, "notify": true, "label": "my fleet"}
```

`key` is optional and usually left out: without it the bridge enrols the key the call was
made with, which is the one the console is already signed in as, so nothing has to be
pasted anywhere. Give one to enrol a different key - a second key from `/apikey new`, so
it can be revoked on its own - and the bridge relays a `/ping` for it first. A key the mod
will not answer for is `400 bad_key`; one belonging to a different player is
`403 not_your_key`.

Enrolling a key already enrolled updates it in place and clears its failure count, which
is how a player asks for one to be tried again.

**Both opt-ins false removes the enrolment**, deleting the stored key. A key the bridge is
not going to present is one it has no business holding.

Answers `{"entry": {...}}`, or `{"entry": null}` when that last case applies.

## POST /services/update

```json
{"id": "9f86d081...", "notify": false}
```

Changes what an enrolment is used for without the key being sent again - which is what the
console's two switches do. A service left out of the body is left as it was. As above,
switching the last one off deletes the row. `404 not_enrolled` if the id is not one of
this player's.

## POST /services/forget

```json
{"id": "9f86d081..."}
```

Deletes the stored key. Answers `{"removed": true}`, or `404 not_enrolled`.

## What the services do with a failure

A pass that works clears the row's failure count and stamps `usedAt`. A pass that fails
counts, and the reason is kept for the player to read. `401` or `403` from the mod is the
key having been revoked, or the galaxy replaced under it, which is not worth retrying for
a week - that goes straight to the ceiling and the row stops being read. Everything else
is an outage and takes 20 passes to get there. The row stays visible either way, and
enrolling again clears it.
