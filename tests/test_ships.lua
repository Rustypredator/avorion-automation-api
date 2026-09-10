-- Ship listing and detail endpoints, against the mocked ship database.

package.path = "data/scripts/lib/?.lua;tests/?.lua;" .. package.path

local Mock = require("mock_avorion")
Mock.install()
Mock.reset()

local Json = require("automationapi.json")
local Config = require("automationapi.config")
local Auth = require("automationapi.auth")

dofile("data/scripts/galaxy/automationapi/bridge.lua")
local Bridge = AutomationApiBridge

local failures = 0
local function check(cond, msg)
    if cond then print("  ok   " .. msg)
    else failures = failures + 1; print("  FAIL " .. msg) end
end

-- #### WORLD #### --

Mock.addPlayer(1, "Rustypredator")
Mock.addPlayer(2, "Someone Else")
Mock.addAlliance(77, "Rusty Industries", 1, {[AlliancePrivilege.ManageShips] = true})

local crew = {size = 42, maxSize = 60}
function crew:getWorkforce()
    return {[{value = CrewProfessionType.Pilot}] = 3.5}
end
function crew:getNumMembersByProfession()
    return {[{value = CrewProfessionType.Pilot}] = 4, [{value = CrewProfessionType.Miner}] = 12}
end

Mock.addShip(1, "Ore Hound",
{
    x = -134, y = 88, statusText = "Idle",
    captain = {name = "Vex", nickName = "The Patient", displayName = "Vex the Patient",
               level = 3, tier = 2, experience = 500, experiencePercentage = 0.4, salary = 900,
               primaryClass = 4, secondaryClass = 6,
               getPerks = function() return 1, 5 end},
    crew = crew, crewOk = true,
    cargo = {[{name = "Iron Ore", plural = "Iron Ore", price = 10, size = 1}] = 250},
    cargoCapacity = 1000, cargoFree = 750,
    range = 7.5, canPassRifts = false, cooldown = 12,
    shields = 25000, shieldPct = 1, hp = 90000, hpPct = 0.87,
    energyRequired = 100, energyProduced = 400,
    turretDps = 1200, fighterDps = 300,
    turrets = {[{weaponName = "Mining Laser", category = WeaponCategory.Mining,
                 rarity = {name = "Rare"}, material = {name = "Titanium"}, armed = false,
                 dps = 400, reach = 1.2, slots = 1,
                 stoneRawEfficiency = 0.8, stoneRefinedEfficiency = 0.3,
                 metalRawEfficiency = 0, metalRefinedEfficiency = 0}] = 3},
    systems = {[{script = "data/scripts/systems/miningsystem.lua", name = "Mining System",
                 rarity = {name = "Exotic"}}] = 1},
    planValue = 1250000, reconstructionValue = 90000,
})

Mock.addShip(1, "Little Scout", {x = 2, y = 3, range = 3})
Mock.addShip(1, "Home Base", {type = EntityType.Station, x = 0, y = 0})
Mock.addShip(1, "Wreck", {availability = ShipAvailability.Destroyed, usableError = 1})
Mock.addShip(77, "Alliance Freighter", {x = 10, y = 10})
Mock.addShip(2, "Not Yours", {x = 5, y = 5})

Bridge.initialize()
local key = Auth.createKey(1, "tests")

local seq = 0
local function call(method, path, query, body)
    seq = seq + 1
    local id = "r" .. seq
    local f = assert(io.open(Config.getRequestsDir() .. "/" .. id .. ".json", "wb"))
    f:write(Json.encode{id = id, key = key, method = method, path = path,
                        query = query or {}, body = body or {}})
    f:close()

    Bridge.update(Config.pollInterval)

    local rf = assert(io.open(Config.getResponsesDir() .. "/" .. id .. ".json", "rb"),
                      "no response for " .. method .. " " .. path)
    local res = Json.decode(rf:read("*all")); rf:close()

    return res.status, res.body
end

-- #### LISTING #### --

print("\nGET /ships")

local status, body = call("GET", "/ships")
check(status == 200, "returns 200")
check(body.count == 3, "lists only ships by default, not stations (got " .. tostring(body.count) .. ")")
check(Json.isArray(body.ships), "ships is a JSON array")
check(body.ships[1].name == "Little Scout", "sorted by name")
check(body.ships[1].owner.kind == "player", "carries owner identity")

local _, body = call("GET", "/ships", {type = "station"})
check(body.count == 1 and body.ships[1].name == "Home Base", "type=station filters to stations")

local _, body = call("GET", "/ships", {type = "all"})
check(body.count == 4, "type=all includes stations")

local status = call("GET", "/ships", {type = "nonsense"})
check(status == 400, "an unknown type is a 400")

-- #### OWNER SCOPING #### --

print("\nowner scoping")

local _, body = call("GET", "/ships", {owner = "alliance"})
check(body.count == 1 and body.ships[1].name == "Alliance Freighter", "owner=alliance lists alliance craft")
check(body.ships[1].owner.kind == "alliance", "alliance craft are labelled as such")

local _, body = call("GET", "/ships", {owner = "all"})
check(body.count == 4, "owner=all merges both owners")

local status = call("GET", "/ships", {owner = "bogus"})
check(status == 400, "an unknown owner is a 400")

local status = call("GET", "/ships/Not%20Yours")
check(status == 404, "another player's ship is a 404")

-- a player with no alliance must not get a 500
Mock.addPlayer(3, "Loner")
local otherKey = Auth.createKey(3, "loner")
seq = seq + 1
local id = "r" .. seq
local f = assert(io.open(Config.getRequestsDir() .. "/" .. id .. ".json", "wb"))
f:write(Json.encode{id = id, key = otherKey, method = "GET", path = "/ships", query = {owner = "alliance"}})
f:close()
Bridge.update(Config.pollInterval)
local rf = assert(io.open(Config.getResponsesDir() .. "/" .. id .. ".json", "rb"))
local res = Json.decode(rf:read("*all")); rf:close()
check(res.status == 409 and res.body.error.code == "no_alliance", "no alliance is a clean 409")

-- #### DETAIL #### --

print("\nGET /ships/{name}")

local status, ship = call("GET", "/ships/Ore%20Hound")
check(status == 200, "returns 200")
check(ship.name == "Ore Hound", "name round-trips through percent encoding")
check(ship.position.x == -134 and ship.position.y == 88, "position")
check(ship.availability == "Available", "availability resolves to a name, not an int")
check(ship.type == "Ship", "entity type resolves to a name")

check(ship.captain.displayName == "Vex the Patient", "captain identity")
check(ship.captain.level == 3, "captain level")
check(#ship.captain.classes == 2, "both captain classes listed")
check(ship.captain.classes[1].name == "Miner", "class int maps to its name")
check(#ship.captain.perks == 2, "perks listed")

check(ship.crew.size == 42, "crew size")
check(ship.crew.requirementsFulfilled == true, "crew requirements")
check(#ship.crew.byProfession == 2, "crew broken down by profession")

check(ship.cargo.capacity == 1000 and ship.cargo.free == 750, "cargo capacity and free space")
check(ship.cargo.used == 250, "cargo used is derived")
check(ship.cargo.goods[1].name == "Iron Ore" and ship.cargo.goods[1].amount == 250, "cargo goods flattened")

check(ship.hyperspace.range == 7.5, "jump range")
check(ship.hyperspace.canPassRifts == false, "rift capability")
check(ship.shields.max == 25000, "shields")
check(ship.durability.percentage == 0.87, "hull percentage")
check(ship.energy.sufficient == true, "energy sufficiency is derived")
check(ship.dps.total == 1500, "dps totals turrets and fighters")

check(#ship.turrets == 1 and ship.turrets[1].count == 3, "identical turrets collapse to a count")
check(ship.turrets[1].category == "Mining", "turret category resolves to a name")
check(ship.turrets[1].mining.stoneRaw == 0.8, "turret mining efficiency")
check(#ship.systems == 1 and ship.systems[1].rarity == "Exotic", "subsystems")

check(ship.usable.ok == true, "a healthy ship is usable")

local _, wreck = call("GET", "/ships/Wreck")
check(wreck.usable.ok == false, "a destroyed ship is not usable")
check(wreck.usable.code == "Unavailable", "usable error resolves to a name")
check(wreck.availability == "Destroyed", "destroyed availability")

local _, scout = call("GET", "/ships/Little%20Scout")
check(scout.captain == nil, "a captainless ship reports no captain")
check(Json.isArray(scout.turrets) and #scout.turrets == 0, "empty turret list is still an array")

-- everything must survive an encode/decode round trip
local encoded = Json.encode(ship)
check(encoded ~= nil, "detail response encodes cleanly")
check(Json.decode(encoded) ~= nil, "detail response decodes cleanly")

check(#Mock.errors == 0, "no errors logged")
for _, e in ipairs(Mock.errors) do print("       > " .. e) end

print("")
if failures > 0 then print(failures .. " check(s) failed"); os.exit(1) end
print("all checks passed")
