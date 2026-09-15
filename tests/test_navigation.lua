-- Navigation: planned routes, boss farming and the ship's automation state.
--
-- The planner is this mod's own search, so what matters is that its preferences actually
-- change the route - a rift wall is flown around, faction space is avoided when asked,
-- a gate is taken - and that a plan reaches the ship as one call the ship confirms.
-- What the ship then does with it is tests/test_orderchain.lua's business.

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

Mock.addShip(1, "Pathfinder", {x = 0, y = 0, range = 5,
                               captain = {name = "Vel", level = 2, primaryClass = 6}})
Mock.addShip(1, "Riftrunner", {x = 0, y = 0, range = 5, canPassRifts = true,
                               captain = {name = "Oro", level = 2, primaryClass = 6}})
Mock.addShip(1, "Farmer", {x = 300, y = 0, range = 6, statusText = "[PLAYER]",
                           captain = {name = "Kel", level = 3, primaryClass = 9}})
Mock.addShip(1, "Walker", {x = 300, y = 0, range = 6,
                           captain = {name = "Ann", level = 1, primaryClass = 9}})
Mock.addShip(1, "Commuter", {x = 180, y = 0, range = 6, statusText = "[PLAYER]",
                             captain = {name = "Tam", level = 1, primaryClass = 6}})

Bridge.initialize()
Mock.shipEventSink = Bridge.pushShipEvent

local key = Auth.createKey(1, "tests")
local seq = 0

local function send(method, path, body, query)
    seq = seq + 1
    local id = "n" .. seq

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

-- Sends, then ticks the world until the request is answered or a timeout's worth passes.
-- The route cooldown is stepped over first, since nearly every call here plans something.
local function call(method, path, body, query)
    Mock.advanceClock(Config.routeCooldown + 1)

    local read = send(method, path, body, query)
    for _ = 1, 120 do
        local status, answer = read()
        if status then return status, answer end
        tick(0.25)
    end

    return nil
end

local function kinds(hops)
    local out = {}
    for _, hop in ipairs(hops or {}) do out[#out + 1] = hop.kind end
    return table.concat(out, ",")
end

local function distance(a, b)
    return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2)
end

-- #### THE PLANNER #### --

print("\nGET /galaxy/route with preferences")

local status, body = call("GET", "/galaxy/route", nil,
                          {ship = "Pathfinder", toX = "20", toY = "0",
                           preferUncontrolled = "true"})
check(status == 200, "a preference answers through the planner")
check(body.planner == "automation", "and says which planner answered")
check(body.reachable == true and body.route[1].x == 0 and body.route[#body.route].x == 20,
      "the route runs origin to destination")
check(#body.hops == #body.route - 1, "hops leave the origin out, route keeps it")

local status, body = call("GET", "/galaxy/route", nil, {ship = "Pathfinder", toX = "20", toY = "0"})
check(body.planner == "engine", "without a preference the engine's pathfinder still answers")

-- A rift wall at x = 10, from y = -20 to 20. Nothing may land on it or jump across it.
for y = -20, 20 do Mock.riftSectors["10:" .. y] = true end
Mock.obstruction = function(ax, ay, bx, by)
    if math.min(ax, bx) > 10 or math.max(ax, bx) < 10 or ax == bx then return false end
    local t = (10 - ax) / (bx - ax)
    local y = ay + t * (by - ay)
    return y >= -20.5 and y <= 20.5
end

local status, body = call("GET", "/galaxy/route", nil,
                          {ship = "Pathfinder", toX = "20", toY = "0", avoidRifts = "true"})
check(status == 200 and body.reachable == true, "a rift wall is planned around")
local detour = false
for _, hop in ipairs(body.hops or {}) do
    if math.abs(hop.y) > 20 then detour = true end
end
check(detour, "by going past its end rather than through it")
local within = true
local previous = body.route and body.route[1]
for _, point in ipairs(body.route or {}) do
    if distance(previous, point) > 5 + 1e-9 then within = false end
    previous = point
end
check(within, "and no hop is longer than the ship's jump range")

local status, body = call("GET", "/galaxy/route", nil, {ship = "Riftrunner", toX = "20", toY = "0",
                                                        preferGates = "false"})
check(body.reachable == true and body.jumps == 4,
      "a rift-capable ship that does not avoid rifts flies straight through, 4 jumps")

local status, body = call("GET", "/galaxy/route", nil, {ship = "Riftrunner", toX = "20", toY = "0",
                                                        avoidRifts = "true"})
check(body.reachable == true and body.jumps > 4,
      "the same ship asked to avoid rifts goes around, as a rift-bound one must")
Mock.obstruction = nil
Mock.riftSectors = {}

-- Faction space in a band along the direct line.
for x = 1, 19 do
    for y = -3, 3 do Mock.controlledSectors[x .. ":" .. y] = 7 end
end

local status, plain = call("GET", "/galaxy/route", nil, {ship = "Pathfinder", toX = "20", toY = "0",
                                                         preferGates = "false"})
local status, avoiding = call("GET", "/galaxy/route", nil, {ship = "Pathfinder", toX = "20", toY = "0",
                                                            preferUncontrolled = "true"})
check(plain.controlledSectors > 0, "the direct route lands in faction space")
check(avoiding.controlledSectors < plain.controlledSectors,
      "asking for uncontrolled space lands in less of it")
check(avoiding.hops[1].controlled ~= nil, "each hop says whether it is controlled")
Mock.controlledSectors = {}

-- A known gate out of the origin, far across the barrier's inside.
Mock.addKnownSector(1, 0, 0, {gates = {{x = 0, y = 100}}})

local status, body = call("GET", "/galaxy/route", nil, {ship = "Pathfinder", toX = "3", toY = "103",
                                                        preferGates = "true"})
check(body.reachable == true and body.hops[1].kind == "gate",
      "a known gate is taken")
check(body.gates == 1 and body.jumps == 2, "and counted apart from the jumps")

local status, body = call("GET", "/galaxy/route", nil, {ship = "Pathfinder", toX = "200",
                                                        toY = "0", avoidRifts = "true"})
check(status == 200 and body.reachable == false and body.reason == "barrier",
      "a route across the barrier is refused at once rather than searched to exhaustion")

Mock.riftSectors["30:0"] = true
local status, body = call("GET", "/galaxy/route", nil, {ship = "Pathfinder", toX = "30", toY = "0",
                                                        avoidRifts = "true"})
check(status == 200 and body.reachable == false and body.reason == "destination_in_rift",
      "a destination inside a rift is unreachable, and says why without a full search")
Mock.riftSectors = {}

-- #### POST /ships/{name}/route #### --

print("\nPOST /ships/{name}/route")

local status, body = call("POST", "/ships/Pathfinder/route", {to = {x = 0, y = 0}})
check(status == 422 and body.error.code == "already_there", "the ship's own sector is refused")

local status, body = call("POST", "/ships/Pathfinder/route", {to = {x = 20, y = 0},
                                                              onEnemies = "panic"})
check(status == 400 and body.error.code == "bad_on_enemies", "an unknown onEnemies is a 400")

Mock.setOffline(1)
local status, body = call("POST", "/ships/Pathfinder/route", {to = {x = 20, y = 0}})
check(status == 409 and body.error.code == "owner_offline",
      "an offline owner is refused before any planning is spent")
Mock.setOnline(1)

Mock.entityCalls = {}
local status, body = call("POST", "/ships/Pathfinder/route",
                          {to = {x = 20, y = 0}, dryRun = true, preferUncontrolled = true})
check(status == 200 and body.dryRun == true and #body.hops > 0, "a dry run returns the plan")
check(#Mock.entityCalls == 0, "and sends the ship nothing")

Mock.entityCalls = {}
local status, body = call("POST", "/ships/Pathfinder/route",
                          {to = {x = 20, y = 0}, onEnemies = "hold", attackCivilians = true})
check(status == 200 and body.confirmed == true,
      "a dispatched route is answered 200 once the ship reports it took the plan up")
check(type(body.planId) == "string" and body.automation and body.automation.plan
      and body.automation.plan.id == body.planId,
      "the confirmation is the ship publishing that plan's id")

local names = {}
for _, c in ipairs(Mock.entityCalls) do names[#names + 1] = c.fn end
check(table.concat(names, ",") == "automationApiRunPlan",
      "the whole plan goes over as one call, with no clear or runOrders around it")

local sent = Json.decode(Mock.entityCalls[1].args[1])
check(sent.kind == "route" and sent.onEnemies == "hold" and sent.attackCivilians == true,
      "the plan carries the enemy handling asked for")
check(#sent.hops == #body.hops and sent.hops[#sent.hops].x == 20,
      "and every hop, ending at the destination")

Mock.refusePlan = "needs_captain"
local status, body = call("POST", "/ships/Pathfinder/route", {to = {x = 20, y = 0}})
check(status == 422 and body.error.code == "needs_captain",
      "a plan the ship refuses comes back with the ship's reason")
Mock.refusePlan = "hop 1, (0:0) -> (5:0): jump not possible"
local status, body = call("POST", "/ships/Pathfinder/route", {to = {x = 20, y = 0}})
check(status == 422 and body.error.code == "plan_refused"
      and body.error.message:find("jump not possible", 1, true) ~= nil,
      "including a jump the engine would not allow")
Mock.refusePlan = nil

Mock.noOrderChainExtension = true
local status, body = call("POST", "/ships/Pathfinder/route", {to = {x = 20, y = 0}})
check(status == 202 and body.confirmed == false,
      "with the orderchain extension missing, the dispatch is answered unconfirmed")
Mock.noOrderChainExtension = false

-- #### BOSS FARMING #### --

print("\nPOST /ships/{name}/farm")

local status, body = call("POST", "/ships/Farmer/farm", {boss = "kraken"})
check(status == 400 and body.error.code == "bad_boss", "an unknown boss is a 400")

local status, body = call("POST", "/ships/Walker/farm", {})
check(status == 422 and body.error.code == "needs_pilot",
      "a ship nobody is flying is refused: spawns count the pilot's jumps")

-- the ship's own sector holds stations, so the loop has to be found next to it
Mock.addPredictedSector(300, 0, {regular = true})
Mock.addPredictedSector(301, 0, {offgrid = true})

local status, body = call("POST", "/ships/Walker/farm", {dryRun = true})
check(status == 200 and body.piloted == false,
      "a dry run works unpiloted, and says it is")
check(body.boss == "ai" and body.ring.min == 240 and body.ring.max == 340,
      "the ring the ship sits in is picked")

local a, b = body.loop[1], body.loop[2]
local function inRing(p)
    local d = math.sqrt(p.x * p.x + p.y * p.y)
    return d > 240 and d < 340
end
check(inRing(a) and inRing(b), "both loop sectors are inside the ring")
check(not (a.x == 300 and a.y == 0) and not (b.x == 300 and b.y == 0)
      and not (a.x == 301 and a.y == 0) and not (b.x == 301 and b.y == 0),
      "and neither is a sector with content")
check(distance(a, b) <= 6 and distance(a, b) >= 1, "they are one jump apart")
check(#body.approach == 1 and body.loopFrom == 2 and #body.hops == 3,
      "a loop one jump away is approached, then lapped")

Mock.entityCalls = {}
local status, body = call("POST", "/ships/Farmer/farm", {onEnemies = "fight"})
check(status == 200 and body.confirmed == true, "a piloted ship's farm is dispatched")
local sent = Json.decode(Mock.entityCalls[1].args[1])
check(sent.kind == "farm" and sent.boss == "ai" and sent.loopFrom == body.loopFrom,
      "as a looping farm plan")
check(sent.collectLoot == true and sent.bossCooldown == 1800
      and body.collectLoot == true and body.bossCooldown == 1800,
      "collecting loot and waiting out vanilla's 30 minute cooldown by default")

local status, body = call("POST", "/ships/Farmer/farm", {collectLoot = "yes"})
check(status == 400 and body.error.code == "bad_collect_loot", "collectLoot must be a boolean")

local status, body = call("POST", "/ships/Farmer/farm", {bossCooldown = -5})
check(status == 400 and body.error.code == "bad_boss_cooldown", "a negative cooldown is a 400")

Mock.entityCalls = {}
local status, body = call("POST", "/ships/Farmer/farm", {collectLoot = false, bossCooldown = 0})
local sent = Json.decode(Mock.entityCalls[1].args[1])
check(status == 200 and sent.collectLoot == false and sent.bossCooldown == 0,
      "both can be switched off")
local lapA, lapB = sent.hops[sent.loopFrom], sent.hops[sent.loopFrom + 1]
local last = sent.hops[sent.loopFrom - 1] or {x = 300, y = 0}
check(distance(lapB, last) == 0,
      "the lap starts by leaving the sector the approach arrives in, so it closes")

local status, body = call("POST", "/ships/Commuter/farm", {boss = "ai", dryRun = true})
check(status == 200 and #body.approach > 1,
      "a ship far outside the ring gets a planned approach first")
local d = math.sqrt(body.loop[1].x ^ 2 + body.loop[1].y ^ 2)
check(d > 240 and d < 340, "to the ring it asked for")
check(body.approach[#body.approach].x == body.loop[1].x
      and body.approach[#body.approach].y == body.loop[1].y,
      "ending on the loop")

local status, body = call("POST", "/ships/Commuter/farm", {boss = "swoks", dryRun = true})
local d = math.sqrt(body.loop[1].x ^ 2 + body.loop[1].y ^ 2)
check(body.boss == "swoks" and d > 350 and d < 430, "swoks has its own ring")

-- #### AUTOMATION STATE #### --

print("\n/ships/{name}/automation")

local status, body = call("GET", "/ships/Walker/automation")
check(status == 200 and body.reported == false and body.source == "none",
      "a ship that never published anything says so")

local status, body = call("GET", "/ships/Pathfinder/automation")
check(body.source == "live" and body.automation.plan ~= nil,
      "a ship that took a plan up reports it from the live feed")

Mock.getShip(1, "Walker").orderInfo = Json.encode({chain = {}, currentIndex = 0, finished = false,
    automationApi = {autoAggressive = true, attackCivilians = false}})
local status, body = call("GET", "/ships/Walker/automation")
check(body.source == "database" and body.automation.autoAggressive == true,
      "with no live state, the database's copy is read instead")

local status, body = call("GET", "/ships/Walker")
check(body.orders and body.orders.automation and body.orders.automation.autoAggressive == true,
      "and the ship detail carries it too, rather than dumping it into `extra`")

local status, body = call("POST", "/ships/Pathfinder/automation", {})
check(status == 400 and body.error.code == "no_settings", "no settings is a 400")

local status, body = call("POST", "/ships/Pathfinder/automation", {autoAggressive = "yes"})
check(status == 400 and body.error.code == "bad_setting", "a non-boolean setting is a 400")

Mock.entityCalls = {}
local status, body = call("POST", "/ships/Pathfinder/automation", {autoAggressive = true})
check(status == 200 and body.confirmed == true and body.automation.autoAggressive == true,
      "idle defence is switched on and confirmed from the ship's own report")
check(#Mock.entityCalls == 1 and Mock.entityCalls[1].fn == "automationApiConfigure",
      "without touching the chain the ship is running")

print("\nstanding orders")

local status, body = call("POST", "/ships/Pathfinder/automation", {standing = true})
check(status == 400 and body.error.code == "bad_standing", "standing must be an object")

local status, body = call("POST", "/ships/Pathfinder/automation", {standing = {salvage = {enabled = true}}})
check(status == 400 and body.error.code == "bad_standing" and body.error.details.known ~= nil,
      "an unknown standing order is a 400 that lists the known ones")

local status, body = call("POST", "/ships/Pathfinder/automation", {standing = {loot = {mode = "always"}}})
check(status == 400 and body.error.code == "bad_standing_mode", "so is an unknown mode")

local status, body = call("POST", "/ships/Pathfinder/automation", {standing = {loot = {enabled = 1}}})
check(status == 400 and body.error.code == "bad_standing", "and a non-boolean enabled")

local status, body = call("POST", "/ships/Pathfinder/automation", {standing = {loot = {}}})
check(status == 400 and body.error.code == "bad_standing", "and an order that sets nothing")

local status, body = call("POST", "/ships/Pathfinder/automation",
                          {autoAggressive = false, standing = {enemies = {enabled = true}}})
check(status == 400 and body.error.code == "conflicting_settings",
      "the old field and the enemies order may not disagree")

Mock.entityCalls = {}
local status, body = call("POST", "/ships/Pathfinder/automation",
                          {standing = {loot = {enabled = true, mode = "INTERRUPT"}}})
check(status == 200 and body.confirmed == true
      and body.automation.standing.loot.enabled == true
      and body.automation.standing.loot.mode == "interrupt",
      "a standing order is switched on, its mode normalised, and confirmed by the ship")
check(body.automation.standing.enemies.enabled == true,
      "leaving the other standing order as it was")
check(#Mock.entityCalls == 1 and Json.decode(Mock.entityCalls[1].args[1]).standing.loot.mode
      == "interrupt", "in one call that carries only what was sent")

local status, body = call("POST", "/ships/Pathfinder/automation", {standing = {loot = {enabled = false}}})
check(status == 200 and body.automation.standing.loot.enabled == false
      and body.automation.standing.loot.mode == "interrupt",
      "and switched off again, keeping its mode")

Mock.orderChainFrozen = true
local status, body = call("POST", "/ships/Pathfinder/automation", {standing = {loot = {enabled = true}}})
check(status == 202 and body.confirmed == false,
      "a ship that never reports the new standing orders leaves the answer unconfirmed")
Mock.orderChainFrozen = false

local status, body = call("POST", "/ships/Pathfinder/automation/stop")
check(status == 200 and body.automation.plan == nil, "stop ends the plan")
check(body.automation.autoAggressive == true, "and leaves the settings as they were")

-- #### TRAVEL MISSIONS #### --

print("\nthe travel mission checks its destination wherever it is started from")

-- as in the game, a travel area is the one destination sector
Mock.areaSize = {x = 1, y = 1}
Mock.asyncQueue = {}
local status, body = call("POST", "/ships/Pathfinder/missions/travel/start",
                          {area = {center = {x = 2, y = 0}}})
check(status == 422 and body.error.code == "destination_too_close",
      "the Mission tab's start refuses a destination in jump range")
check(#Mock.asyncQueue == 0, "before any analysis is spent")

check(#Mock.errors == 0, "no errors logged")
for _, e in ipairs(Mock.errors) do print("       > " .. e) end

print("")
if failures > 0 then print(failures .. " check(s) failed"); os.exit(1) end
print("all checks passed")
