-- Movement: travel gating, in-sector orders and route planning.
--
-- The travel gates are the interesting part. Vanilla only checks them on the client, so
-- without them the API accepts a destination, spends an area analysis on it, and is then
-- refused by the game with nothing useful to report.

package.path = "data/scripts/lib/?.lua;tests/?.lua;" .. package.path

local Mock = require("mock_avorion")
Mock.install()
Mock.reset()

local Json = require("automationapi.json")
local Config = require("automationapi.config")
local Auth = require("automationapi.auth")

dofile("data/scripts/galaxy/automationapi/bridge.lua")
local Bridge = AutomationApiBridge

dofile("data/scripts/player/automationapi/agent.lua")
local Agent = AutomationApiAgent

local failures = 0
local function check(cond, msg)
    if cond then print("  ok   " .. msg)
    else failures = failures + 1; print("  FAIL " .. msg) end
end

-- #### WORLD #### --

Mock.addPlayer(1, "Rustypredator")
Mock.addShip(1, "Prospector",
{
    x = 0, y = 0, range = 5, cargoFree = 768,
    captain = {name = "Pritteggi", level = 3, tier = 3, primaryClass = 4},
})
Mock.addShip(1, "Deep Runner", {x = 200, y = 200, range = 5,
                                captain = {name = "Odd", level = 2, primaryClass = 6}})

-- a gate out of the Prospector's sector, which makes its far end one hop away
Mock.addKnownSector(1, 0, 0, {gates = {{x = 400, y = 400}}})

Bridge.initialize()

-- stand in for the player agent, which forwards ShipInfo callbacks to the bridge
Mock.shipEventSink = Bridge.pushShipEvent
local key = Auth.createKey(1, "tests")

-- Travel areas are a single sector, unlike the 15x15 default the other missions use.
Mock.areaSize = {x = 1, y = 1}

local seq = 0

local function send(method, path, body, query)
    seq = seq + 1
    local id = "v" .. seq

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

local function call(method, path, body, query)
    return send(method, path, body, query)()
end

local function tick(seconds)
    Mock.advanceClock(seconds)
    Mock.asPlayerAgent(1, function() Agent.update(seconds) end)
    Bridge.update(seconds)
end

-- #### TRAVEL GATES #### --

print("\nPOST /ships/{name}/travel - destination gates")

local status, body = call("POST", "/ships/Prospector/travel", {})
check(status == 400 and body.error.code == "no_destination", "a missing destination is a 400")

local status, body = call("POST", "/ships/Prospector/travel", {to = {x = 1.5, y = 2}})
check(status == 400 and body.error.code == "bad_coordinates",
      "a fractional coordinate is rejected rather than quietly floored")

local status, body = call("POST", "/ships/Prospector/travel", {to = {x = 0, y = 0}})
check(status == 422 and body.error.code == "already_there",
      "travelling to the ship's own sector is refused")

local status, body = call("POST", "/ships/Prospector/travel", {to = {x = 3, y = 0}})
check(status == 422 and body.error.code == "destination_too_close",
      "a destination inside jump range is refused, as the game would refuse it")
check(#Mock.asyncQueue == 0, "and no area analysis was spent finding that out")

local status, body = call("POST", "/ships/Prospector/travel", {to = {x = 400, y = 400}})
check(status == 422 and body.error.code == "destination_too_close",
      "a destination on the far side of a gate is refused too")

Mock.jumpUnobstructed = false
local read = send("POST", "/ships/Prospector/travel", {to = {x = 3, y = 0}})
check(read() == nil, "a rift between the two makes the same destination legal again")
Mock.jumpUnobstructed = true
Mock.flushAsync()
Bridge.update(Config.pollInterval)
for _ = 1, 8 do tick(0.6) end

-- #### ROUTE LENGTH #### --

print("\nthe route-too-short check preview used to miss")

local read = send("POST", "/ships/Prospector/missions/travel/preview", {to = {x = 60, y = 0}})
Mock.flushAsync({route = {{x = 0, y = 0}, {x = 60, y = 0}}, sectors = 1,
                 reachableCoordinates = {}})
Bridge.update(Config.pollInterval)

local status, preview = read()
check(status == 200, "preview still answers")
check(preview.canStart == false,
      "a two-sector route is reported as unstartable, which is what the game does")
check(preview.errors.start ~= nil
      and preview.errors.start.text == "This route is too short.",
      "and carries the game's own wording")

local read = send("POST", "/ships/Prospector/missions/travel/preview", {to = {x = 60, y = 0}})
Mock.flushAsync({route = {{x = 0, y = 0}, {x = 30, y = 0}, {x = 60, y = 0}},
                 sectors = 1, reachableCoordinates = {}})
Bridge.update(Config.pollInterval)

local _, preview = read()
check(preview.canStart == true, "a three-sector route is startable")
check(preview.errors.start == nil, "with no start error")

-- #### TRAVEL START #### --

print("\nPOST /ships/{name}/travel - dispatch")

Mock.simulationCalls = {}
local read = send("POST", "/ships/Prospector/travel", {to = {x = 60, y = 0}, swiftness = 3})
Mock.flushAsync({route = {{x = 0, y = 0}, {x = 30, y = 0}, {x = 60, y = 0}},
                 sectors = 1, reachableCoordinates = {}})
Bridge.update(Config.pollInterval)

for _ = 1, 8 do tick(0.6) end

local status, travelled = read()
check(status == 200, "travel returns 200")
check(travelled.started == true, "and reports the mission started")
check(travelled.mission == "travel", "as a travel mission")
check(travelled.config.swiftness == 3, "carrying the swiftness it was given")

local dispatched
for _, c in ipairs(Mock.simulationCalls) do
    if c.fn == "startAreaAnalysis" then dispatched = dispatched or c end
end
check(dispatched ~= nil and dispatched.args[2] == Mock.commandTypes.Travel,
      "the Travel command type was used")

local status, body = call("POST", "/ships/Prospector/travel",
                          {to = {x = 90, y = 0}, swiftness = 9})
check(status == 400 and body.error.code == "bad_swiftness", "swiftness is range checked")

-- #### ORDERS #### --

print("\nPOST /ships/{name}/orders")

Mock.entityCalls = {}
Mock.loadedSectors = {["200:200"] = true}

Mock.addShip(1, "Tug", {x = 5, y = 5, range = 3})
local status, body = call("POST", "/ships/Tug/orders", {orders = {{type = "patrol"}}})
check(status == 409 and body.error.code == "sector_not_loaded",
      "orders into an unloaded sector are refused rather than silently dropped")

local status, body = call("POST", "/ships/Deep Runner/orders", {orders = {}})
check(status == 400 and body.error.code == "no_orders", "an empty order list is a 400")

local status, body = call("POST", "/ships/Deep Runner/orders",
                          {orders = {{type = "teleport"}}})
check(status == 400 and body.error.code == "bad_order", "an unknown order type is a 400")

-- a caller debugging its payload should hear about the payload, not about the world
Mock.setOffline(1)
local status, body = call("POST", "/ships/Deep Runner/orders",
                          {orders = {{type = "teleport"}}})
check(status == 400 and body.error.code == "bad_order",
      "the payload is checked before the online gate")
local status, body = call("POST", "/ships/Deep Runner/orders", {orders = {{type = "patrol"}}})
check(status == 409 and body.error.code == "owner_offline",
      "a valid payload from an offline owner is a 409")
Mock.setOnline(1)

local status, body = call("POST", "/ships/Deep Runner/orders",
                          {orders = {{type = "patrol"}, {type = "repair"}}})
check(status == 422 and body.error.code == "order_after_terminal",
      "the chain's refusal to enqueue past a patrol is enforced here, not discovered later")

-- mine, salvage and refine exist in the engine only as wrappers that clear the chain,
-- add one order and run it. They cannot be enchained onto anything, and asking for it
-- used to produce a 202 and then nothing at all, because addMineOrder is not callable().
local status, body = call("POST", "/ships/Deep Runner/orders",
                          {orders = {{type = "jump", to = {x = 201, y = 200}},
                                     {type = "mine"}}})
check(status == 422 and body.error.code == "order_not_chainable",
      "a one-shot order cannot be enchained after another")

Mock.entityCalls = {}
local read = send("POST", "/ships/Deep Runner/orders",
{
    orders =
    {
        {type = "jump", to = {x = 201, y = 200}},
        {type = "patrol"},
    },
})
tick(0.3)

local status, orders = read()
check(status == 200, "a dispatch whose chain is read back is answered 200, not blind")
check(orders.confirmed == true, "and is marked confirmed")
local chainNames = {}
for _, o in ipairs(orders.chain) do chainNames[#chainNames + 1] = o.name end
check(table.concat(chainNames, ",") == "Jump,Patrol",
      "the response carries the chain the ship actually ended up with")
check(orders.activeIndex == 1, "and which order is running")
check(orders.cleared == true, "the existing chain is cleared by default")
check(#orders.dispatched == 2, "both orders are reported as dispatched")

local names = {}
for _, c in ipairs(Mock.entityCalls) do names[#names + 1] = c.fn end
check(table.concat(names, ",") == "clearAllOrders,addJumpOrder,addPatrolOrder,runOrders",
      "clear, the orders, then runOrders - which is what actually starts the chain")

local jump
for _, c in ipairs(Mock.entityCalls) do if c.fn == "addJumpOrder" then jump = c end end
check(jump ~= nil and jump.args[1] == 201 and jump.args[2] == 200,
      "the jump order carries the destination")
check(jump.target.faction == 1 and jump.target.name == "Deep Runner",
      "addressed by faction and ship name, so no entity id is needed")
check(jump.x == 200 and jump.y == 200, "dispatched into the sector the ship is in")

-- every one of these three used to dispatch a function the engine does not expose
Mock.entityCalls = {}
local read = send("POST", "/ships/Deep Runner/orders", {orders = {{type = "mine"}}})
tick(0.3)
local status, orders = read()
check(status == 200, "a one-shot order on its own is accepted")
check(orders.oneShot == true, "and is reported as one-shot")

local names = {}
for _, c in ipairs(Mock.entityCalls) do names[#names + 1] = c.fn end
check(table.concat(names, ",") == "onUserMineOrder,runOrders",
      "dispatched through the wrapper the engine actually marks callable")
check(orders.cleared == true, "the wrapper clears the chain itself, so cleared is still true")

for _, case in ipairs({{"mine", "onUserMineOrder"},
                       {"salvage", "onUserSalvageOrder"},
                       {"refine", "onUserRefineOresOrder"}}) do
    Mock.entityCalls = {}
    local read = send("POST", "/ships/Deep Runner/orders", {orders = {{type = case[1]}}})
    tick(0.3)
    read()
    check(Mock.entityCalls[1] and Mock.entityCalls[1].fn == case[2],
          case[1] .. " goes to " .. case[2] .. ", which is callable()")
end

Mock.entityCalls = {}
local read = send("POST", "/ships/Deep Runner/orders",
                  {clear = false, orders = {{type = "aggressive"}}})
tick(0.3)
local status = read()
check(status == 200, "clear=false is accepted")
check(Mock.entityCalls[1].fn == "addAggressiveOrder", "and skips the clear")

-- Re-issuing an order the ship is already running leaves the chain byte-identical. A
-- confirmation that asked "did the chain change?" called that a failed dispatch, even
-- though the ship was patrolling exactly as asked.
Mock.entityCalls = {}
local read = send("POST", "/ships/Deep Runner/orders", {orders = {{type = "patrol"}}})
tick(0.3)
local status, orders = read()
check(status == 200, "the first patrol is confirmed")

local read = send("POST", "/ships/Deep Runner/orders", {orders = {{type = "patrol"}}})
tick(0.3)
local status, orders = read()
check(status == 200 and orders.confirmed == true,
      "and so is re-issuing it onto an identical chain")

-- The case the confirmation exists for: the engine takes the call and refuses the order
-- without a word, which before this was indistinguishable from success.
-- Note the flip side of matching rather than diffing: an order the ship already holds
-- cannot be told apart from a refusal, so this uses one it does not.
Mock.orderChainFrozen = true
Mock.entityCalls = {}
local read = send("POST", "/ships/Deep Runner/orders", {orders = {{type = "repair"}}})
tick(0.3)
tick(Config.orderConfirmWindow + 0.5)
local status, orders = read()
check(status == 202, "a dispatch the chain never reflects falls back to 202")
check(orders.confirmed == false, "and says so rather than claiming success")
check(orders.note ~= nil and string.find(orders.note, "did not report") ~= nil,
      "with a note explaining what could not be established")
Mock.orderChainFrozen = false

-- #### THE CAPTAIN GATES #### --
--
-- orderchain.lua refuses these itself and says so only by chat message to a calling
-- player, so without checking here the caller gets a 202 and a ship that never moves.
print("\nPOST /ships/{name}/orders - captain requirements")

Mock.addShip(1, "Drifter", {x = 200, y = 200, range = 5, statusText = "Idle"})

Mock.player(1).sectorX, Mock.player(1).sectorY = 200, 200

local status, body = call("POST", "/ships/Drifter/orders", {orders = {{type = "mine"}}})
check(status == 422 and body.error.code == "needs_captain",
      "a mine order on a captainless ship is refused up front")
check(body.error.details and body.error.details.order == "mine",
      "and names the order that needs the captain")

local status, body = call("POST", "/ships/Drifter/orders",
                          {orders = {{type = "jump", to = {x = 201, y = 200}}}})
check(status == 422 and body.error.code == "needs_captain",
      "so is a jump, which changes sector")

Mock.entityCalls = {}
local read = send("POST", "/ships/Drifter/orders", {orders = {{type = "patrol"}}})
tick(0.3)
local status = read()
check(status == 200,
      "but a patrol is fine while the owner shares the sector, as canReceivePlayerOrder says")

-- a player flying the ship counts in place of a captain, but only for the jump
Mock.getShip(1, "Drifter").statusText = "[PLAYER] /* ship AI status*/"
Mock.entityCalls = {}
local read = send("POST", "/ships/Drifter/orders",
                  {orders = {{type = "jump", to = {x = 201, y = 200}}}})
tick(0.3)
local status = read()
check(status == 200, "a player at the controls satisfies the jump order's requirement")
check(Mock.entityCalls[2] and Mock.entityCalls[2].fn == "addJumpOrder",
      "and the jump is dispatched")

local status, body = call("POST", "/ships/Drifter/orders", {orders = {{type = "mine"}}})
check(status == 422 and body.error.code == "needs_captain",
      "but a mine order still needs a captain - a pilot is no substitute")

-- out of the sector and with no captain, nothing is accepted at all
Mock.getShip(1, "Drifter").statusText = "Idle"
Mock.player(1).sectorX, Mock.player(1).sectorY = 0, 0
local status, body = call("POST", "/ships/Drifter/orders", {orders = {{type = "patrol"}}})
check(status == 422 and body.error.code == "needs_captain",
      "a captainless ship in another sector cannot be ordered at all")

Mock.player(1).sectorX, Mock.player(1).sectorY = 200, 200

-- a ship out on a captain mission has no order chain to talk to
Mock.addShip(1, "Away", {x = 200, y = 200, availability = ShipAvailability.InBackground})
local status, body = call("POST", "/ships/Away/orders", {orders = {{type = "patrol"}}})
check(status == 409 and body.error.code == "ship_in_background",
      "a ship in background simulation is refused with a reason")

-- #### ROUTES #### --

print("\nGET /galaxy/route")

local status, body = call("GET", "/galaxy/route", nil, {ship = "Prospector", toX = "60", toY = "0"})
check(status == 200, "returns 200")
check(body.reachable == true, "reports the destination as reached")
check(body.jumps == 12, "hop count is route length minus one")
check(body.route[1].x == 0 and body.route[#body.route].x == 60, "route runs origin to destination")
check(body.jumpRange == 5, "the ship's own jump range was used")

local status, body = call("GET", "/galaxy/route", nil, {ship = "Prospector", toX = "60", toY = "0"})
check(status == 429 and body.error.code == "route_busy",
      "a second route inside the cooldown is refused")

Mock.advanceClock(Config.routeCooldown + 1)
local status = call("GET", "/galaxy/route", nil, {fromX = "0", fromY = "0", toX = "10",
                                                  toY = "0", range = "5"})
check(status == 200, "explicit coordinates and range work without a ship")

Mock.advanceClock(Config.routeCooldown + 1)
local status, body = call("GET", "/galaxy/route", nil, {fromX = "0", fromY = "0", toX = "10", toY = "0"})
check(status == 400 and body.error.code == "no_range", "a missing range is a 400")

Mock.advanceClock(Config.routeCooldown + 1)
Mock.routeResult = {{x = 0, y = 0}, {x = 5, y = 0}}
local status, body = call("GET", "/galaxy/route", nil,
                          {fromX = "0", fromY = "0", toX = "99", toY = "0", range = "5"})
check(status == 200 and body.reachable == false,
      "a path that stops short is reported as unreachable rather than as an arrival")
Mock.routeResult = nil

check(#Mock.errors == 0, "no errors logged")
for _, e in ipairs(Mock.errors) do print("       > " .. e) end

print("")
if failures > 0 then print(failures .. " check(s) failed"); os.exit(1) end
print("all checks passed")
