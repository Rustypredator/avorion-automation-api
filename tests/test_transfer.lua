-- Cargo transfers: the request vocabulary, the read of every hold a ship could transfer
-- with, and a transfer reaching the ship as one call the ship confirms. What the ship then
-- does with the two holds is tests/test_orderchain.lua's business.

package.path = "data/scripts/lib/?.lua;tests/?.lua;" .. package.path

local Mock = require("mock_avorion")
Mock.install()
Mock.reset()

local Json = require("automationapi.json")
local Config = require("automationapi.config")
local Auth = require("automationapi.auth")
local Rules = require("automationapi.transferrules")

dofile("data/scripts/galaxy/automationapi/bridge.lua")
local Bridge = AutomationApiBridge

dofile("data/scripts/player/automationapi/agent.lua")
local Agent = AutomationApiAgent

local failures = 0
local function check(cond, msg)
    if cond then print("  ok   " .. msg)
    else failures = failures + 1; print("  FAIL " .. msg) end
end

-- #### THE VOCABULARY #### --

print("\nvalidation")

local function refused(spec)
    local code
    local ok = pcall(function()
        Rules.normalize(spec, function(c) code = c; error("refused") end)
    end)
    return not ok and code or nil
end

check(refused({}) == "no_goods", "goods, or all, are required")
check(refused({goods = {{name = ""}}}) == "bad_goods", "a good needs a name")
check(refused({goods = {{name = "Iron", amount = 0}}}) == "bad_goods", "an amount is at least 1")
check(refused({goods = {{name = "Iron", amount = 2.5}}}) == "bad_goods", "and whole")
check(refused({goods = {"Iron"}, direction = "throw"}) == "bad_direction", "direction is give or take")
check(refused({all = true, goods = {"Iron"}}) == "conflicting_goods", "all and goods are not both given")
check(refused({all = true, approach = "yes"}) == "bad_approach", "approach is a boolean")

local parsed = Rules.normalize({goods = {"Iron", {name = " Steel ", amount = 5, stolen = true},
                                         {name = "Oil", amount = Json.null}}},
                               function() error("unexpected") end)
check(parsed.direction == "give" and parsed.approach == true and parsed.all == false,
      "give, approaching, is the default")
check(parsed.goods[1].name == "Iron" and parsed.goods[1].amount == nil
      and parsed.goods[2].name == "Steel" and parsed.goods[2].amount == 5 and parsed.goods[2].stolen == true
      and parsed.goods[3].amount == nil,
      "a bare name, a null amount and a missing one all mean all of that good")
check(Rules.describe(parsed, "Hub") == "give all Iron, 5 stolen Steel, all Oil to Hub", "and it reads back")

-- #### WORLD #### --

Mock.addPlayer(1, "Rustypredator")
Mock.addPlayer(2, "Someone Else")
Mock.addAlliance(9, "Rusty Co", 1, {[AlliancePrivilege.ManageShips] = true})

local function good(name, price, size) return {name = name, plural = name, price = price, size = size} end

local captain = {name = "Vel", level = 2, primaryClass = 3}
Mock.addShip(1, "Hauler", {x = 5, y = 5, captain = captain, cargoCapacity = 500, cargoFree = 200,
                           cargo = {[good("Iron", 10, 1)] = 300}})
Mock.addShip(1, "Scout", {x = 5, y = 5, cargoCapacity = 50, cargoFree = 50})
Mock.addShip(1, "Faraway", {x = 40, y = 40, cargoCapacity = 50, cargoFree = 50})
Mock.addShip(1, "Hub", {x = 5, y = 5, type = EntityType.Station, cargoCapacity = 10000, cargoFree = 9000,
                        cargo = {[good("Steel", 40, 2)] = 500}})
Mock.addShip(9, "Alliance Depot", {x = 5, y = 5, type = EntityType.Station, cargoCapacity = 2000, cargoFree = 2000})
Mock.addShip(1, "Missioner", {x = 5, y = 5, availability = ShipAvailability.InBackground})
Mock.addShip(2, "Stranger", {x = 5, y = 5, cargoCapacity = 50, cargoFree = 50})

Bridge.initialize()
Mock.shipEventSink = Bridge.pushShipEvent

local key = Auth.createKey(1, "tests")
local seq = 0

local function send(method, path, body, query)
    seq = seq + 1
    local id = "t" .. seq

    local f = assert(io.open(Config.getRequestsDir() .. "/" .. id .. ".json", "wb"))
    f:write(Json.encode{id = id, key = key, method = method, path = path,
                        body = body or {}, query = query or {}})
    f:close()

    Bridge.update(Config.pollInterval)

    return function()
        local rf = io.open(Config.getResponsesDir() .. "/" .. id .. ".json", "rb")
        if not rf then return nil end
        local res = Json.decode(rf:read("*all")); rf:close()
        return res.status, res.body
    end
end

local function tick(seconds)
    Mock.advanceClock(seconds)
    Mock.asPlayerAgent(1, function() Agent.update(seconds) end)
    Bridge.update(seconds)
end

local function call(method, path, body, query)
    local read = send(method, path, body, query)
    for _ = 1, 120 do
        local status, answer = read()
        if status then return status, answer end
        tick(0.25)
    end
    return nil
end

local function named(list, name)
    for _, entry in ipairs(list or {}) do if entry.name == name then return entry end end
    return nil
end

-- #### GET /ships/{name}/transfer #### --

print("\nGET /ships/{name}/transfer")

local status, body = call("GET", "/ships/Hauler/transfer")
check(status == 200 and body.ship.name == "Hauler" and body.ship.sector.x == 5,
      "the ship and its sector")
check(body.ship.cargo.goods[1].name == "Iron" and body.ship.cargo.goods[1].amount == 300
      and body.ship.cargo.free == 200,
      "with its hold")
check(named(body.targets, "Hauler") == nil, "the ship is not its own target")
check(named(body.targets, "Stranger") == nil, "another player's craft is not offered")

local hub = named(body.targets, "Hub")
check(hub and hub.sameSector == true and hub.type == "Station" and hub.cargo.goods[1].name == "Steel"
      and hub.cargo.goods[1].amount == 500,
      "a station in the same sector is offered with its hold")
local depot = named(body.targets, "Alliance Depot")
check(depot and depot.owner.kind == "alliance" and depot.sameSector == true,
      "and so is an alliance craft")
check(named(body.targets, "Faraway").sameSector == false, "a craft elsewhere is listed, marked as elsewhere")
check(body.targets[#body.targets].name == "Faraway", "after everything in reach")

status, body = call("GET", "/ships/Hauler/transfer", nil, {sameSector = "true"})
check(named(body.targets, "Faraway") == nil and named(body.targets, "Hub") ~= nil,
      "sameSector=true leaves the rest out")

-- #### POST /ships/{name}/transfer #### --

print("\nPOST /ships/{name}/transfer")

status, body = call("POST", "/ships/Hauler/transfer", {goods = {"Iron"}})
check(status == 400 and body.error.code == "no_target", "a transfer names its target")

status, body = call("POST", "/ships/Hauler/transfer", {target = "Hub"})
check(status == 400 and body.error.code == "no_goods", "and what to move")

status, body = call("POST", "/ships/Hauler/transfer", {target = "Stranger", all = true})
check(status == 404 and body.error.code == "no_such_target", "another player's craft cannot be named")

status, body = call("POST", "/ships/Hauler/transfer", {target = "Hauler", all = true})
check(status == 422 and body.error.code == "same_craft", "nor the ship itself")

status, body = call("POST", "/ships/Hauler/transfer", {target = "Faraway", all = true})
check(status == 422 and body.error.code == "not_same_sector" and body.error.details.target.x == 40,
      "a craft in another sector is refused, saying where it is")

status, body = call("POST", "/ships/Hauler/transfer", {target = "Missioner", all = true})
check(status == 409 and body.error.code == "target_in_background", "a target out on a mission is refused")

Mock.getShip(1, "Hauler").availability = ShipAvailability.InBackground
status, body = call("POST", "/ships/Hauler/transfer", {target = "Hub", all = true})
check(status == 409 and body.error.code == "ship_in_background", "so is a ship out on one")
Mock.getShip(1, "Hauler").availability = ShipAvailability.Available

Mock.loadedSectors = {}
status, body = call("POST", "/ships/Hauler/transfer", {target = "Hub", all = true})
check(status == 409 and body.error.code == "sector_not_loaded", "and one whose sector is not loaded")
Mock.loadedSectors = nil

Mock.setOffline(1)
status, body = call("POST", "/ships/Hauler/transfer", {target = "Hub", all = true})
check(status == 409 and body.error.code == "owner_offline", "an offline owner cannot give the order")
Mock.setOnline(1)

Mock.entityCalls = {}
status, body = call("POST", "/ships/Scout/transfer", {target = "Hub", direction = "take",
                                                     goods = {{name = "Steel", amount = 20}}})
check(status == 200 and body.confirmed == true and body.done == true,
      "a transfer in reach is answered once the ship reports it done, even without a captain")
check(body.result and body.result.outcome == "done" and body.result.moved[1].name == "Steel"
      and body.result.moved[1].amount == 20,
      "with what was moved")
check(body.summary == "take 20 Steel from Hub", "and a line saying what was asked")
check(#Mock.entityCalls == 1 and Mock.entityCalls[1].fn == "automationApiTransfer",
      "the whole transfer goes over as one call, with nothing around it")

local sent = Json.decode(Mock.entityCalls[1].args[1])
check(sent.id == body.transferId and sent.target.faction == 1 and sent.target.name == "Hub"
      and sent.direction == "take" and sent.approach == true and sent.goods[1].amount == 20,
      "naming the target by owner and name")

Mock.entityCalls = {}
status, body = call("POST", "/ships/Hauler/transfer", {target = "Alliance Depot", all = true})
sent = Json.decode(Mock.entityCalls[1].args[1])
check(status == 200 and sent.target.faction == 9 and sent.all == true and body.target.owner.kind == "alliance",
      "an alliance craft is named by the alliance")

Mock.entityCalls = {}
status, body = call("POST", "/ships/Hub/transfer", {target = "Hauler", goods = {{name = "Steel", amount = 7}}})
sent = Json.decode(Mock.entityCalls[1].args[1])
check(status == 200 and Mock.entityCalls[1].target.name == "Hauler" and sent.target.name == "Hub"
      and sent.direction == "take" and body.carriedOutBy.name == "Hauler",
      "a station that gives is carried out by the ship, taking")

status, body = call("POST", "/ships/Hub/transfer", {target = "Alliance Depot", all = true})
check(status == 422 and body.error.code == "no_ship", "two stations cannot transfer between themselves")

Mock.transferApproach = true
status, body = call("POST", "/ships/Hauler/transfer", {target = "Hub", goods = {"Iron"}})
check(status == 200 and body.done == false and body.phase == "docking",
      "a target out of reach answers once the ship is on its way")
check(body.automation and body.automation.transfer and body.automation.transfer.id == body.transferId,
      "and the ship's state carries the transfer")
Mock.transferApproach = nil

status, body = call("POST", "/ships/Hauler/automation/stop")
check(status == 200 and body.automation.transfer == nil, "stopping the automation ends a transfer on its way")

Mock.refuseTransfer = "out_of_range"
status, body = call("POST", "/ships/Hauler/transfer", {target = "Hub", goods = {"Iron"}, approach = false})
check(status == 422 and body.error.code == "out_of_range" and body.result.outcome == "refused",
      "a transfer the ship refuses comes back with the ship's reason")
Mock.refuseTransfer = nil

Mock.noOrderChainExtension = true
status, body = call("POST", "/ships/Hauler/transfer", {target = "Hub", goods = {"Iron"}})
check(status == 202 and body.confirmed == false, "a ship without the extension leaves it unconfirmed")
Mock.noOrderChainExtension = false

-- #### ALLIANCE PRIVILEGES #### --

print("\nalliance privileges")

Mock.reset()
Mock.addPlayer(1, "Rustypredator")
Mock.addAlliance(9, "Rusty Co", 1, {})
Mock.addShip(1, "Hauler", {x = 5, y = 5, captain = captain, cargoCapacity = 500, cargoFree = 200})
Mock.addShip(9, "Alliance Depot", {x = 5, y = 5, type = EntityType.Station})
Bridge.initialize()
Mock.shipEventSink = Bridge.pushShipEvent
key = Auth.createKey(1, "tests")

status, body = call("POST", "/ships/Hauler/transfer", {target = "Alliance Depot", all = true})
check(status == 403 and body.error.code == "missing_privilege",
      "a member without ManageShips cannot move cargo into alliance craft")

status, body = call("GET", "/ships/Hauler/transfer")
check(status == 200 and named(body.targets, "Alliance Depot") == nil, "and is not offered them")

print("")
if failures > 0 then print(failures .. " check(s) failed"); os.exit(1) end
print("all checks passed")
