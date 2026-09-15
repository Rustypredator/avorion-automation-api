-- Order programs: the step vocabulary, and the runner working a craft through its steps -
-- against the mocked world, with the real endpoints carrying each step out.

package.path = "data/scripts/lib/?.lua;tests/?.lua;" .. package.path

local Mock = require("mock_avorion")
Mock.install()
Mock.reset()

local Json = require("automationapi.json")
local Config = require("automationapi.config")
local Auth = require("automationapi.auth")
local Router = require("automationapi.router")
local Rules = require("automationapi.programrules")

-- The runner looks every two seconds in game; the tests would rather not wait.
Config.programInterval = 0.5
Config.programRetry = 5
Config.programOrdersGrace = 1
Config.missionAutomationInterval = 0.5

dofile("data/scripts/galaxy/automationapi/bridge.lua")
local Bridge = AutomationApiBridge

dofile("data/scripts/player/automationapi/agent.lua")
local Agent = AutomationApiAgent

local Programs = require("automationapi.handlers.programs")

local failures = 0
local function check(cond, msg)
    if cond then print("  ok   " .. msg)
    else failures = failures + 1; print("  FAIL " .. msg) end
end

local function raises(fn, code)
    local ok, err = pcall(fn)
    return not ok and Router.isApiError(err) and (code == nil or err.code == code), err
end

-- #### THE VOCABULARY #### --

print("\nvalidation")

local route = {action = {type = "route", to = {x = 4, y = 0}}}

check(raises(function() Rules.normalize({}) end, "bad_program"), "a program needs steps")
check(raises(function() Rules.normalize({steps = {{action = {type = "dance"}}}}) end, "bad_program"),
      "an unknown action is refused")
check(raises(function() Rules.normalize({steps = {{action = {type = "farm"}}}}) end, "bad_program"),
      "a farm, which never ends by itself, needs conditions")
check(raises(function() Rules.normalize({steps = {{action = {type = "wait"}}}}) end, "bad_program"),
      "and so does a wait")
check(raises(function()
    Rules.normalize({steps = {{action = {type = "wait"}, ["until"] = {conditions = {{type = "cargo", percent = 150}}}}}})
end, "bad_program"), "a cargo percentage above 100 is refused")
check(raises(function()
    Rules.normalize({steps = {{action = {type = "wait"}, ["until"] = {conditions = {{type = "weather"}}}}}})
end, "bad_program"), "an unknown condition is refused")
check(raises(function()
    Rules.normalize({steps = {route, {action = {type = "wait"}, ["until"] = {conditions = {{type = "elapsed", seconds = 5}}},
                              ["then"] = {["goto"] = 3}}}})
end, "bad_program"), "a goto to a step that does not exist is refused")
check(raises(function() Rules.normalize({steps = {{action = {type = "route", to = {x = 4, y = 0}}, ["repeat"] = true}}}) end,
             "bad_program"), "repeat without conditions is refused")
check(raises(function() Rules.normalize({steps = {{action = {type = "mission", rule = {mission = "travel"}}}}}) end,
             "not_automatable"), "a mission step's own rule is checked like any rule")

local program = Rules.normalize({name = "Loop", steps =
{
    route,
    {action = {type = "wait"}, ["until"] = {match = "all", conditions =
        {{type = "cargo", op = ">=", percent = 50}, {type = "elapsed", seconds = 10}}},
     ["then"] = {["goto"] = 1}},
}})
check(program.enabled == true and #program.steps == 2 and program.steps[2]["then"] == "goto"
      and program.steps[2]["goto"] == 1, "a valid program is stored with its defaults")

local renamed = Rules.normalize({name = "Renamed"}, program)
check(renamed.name == "Renamed" and #renamed.steps == 2, "a partial body keeps the steps")

print("\nevaluation")

local wait = program.steps[2]
check(Rules.evaluate(wait, {cargo = {capacity = 100, used = 60}, elapsed = 3}).done == false,
      "all: one condition met is not enough")
check(Rules.evaluate(wait, {cargo = {capacity = 100, used = 60}, elapsed = 12}).done == true,
      "all: both met is")
local anyStep = Rules.normalize({steps = {{action = {type = "wait"}, ["until"] = {conditions =
    {{type = "good", name = "Iron", amount = 10}, {type = "enemies", present = false}}}}}}).steps[1]
local r = Rules.evaluate(anyStep, {cargo = {capacity = 10, used = 5, goods = {{name = "Iron", amount = 12}}}})
check(r.done == true and r.met[1] == true and r.met[2] == false,
      "any: one is enough, and unknown facts count as not met")
check(Rules.evaluate(program.steps[1], {naturalEnd = true}).done == true,
      "a step without conditions is done at its action's end")
check(Rules.evaluate(program.steps[1], {cargo = {capacity = 0, used = 0}}).done == false,
      "and not before")
check(Rules.nextStep(program, 1) == 2 and Rules.nextStep(program, 2) == 1,
      "next and goto lead where they say")
check(raises(function()
    Rules.normalize({steps = {route, {action = {type = "wait"}, ["until"] = {conditions = {{type = "elapsed", seconds = 5}}},
                              ["then"] = "goto"}}})
end, "bad_program"), "then goto without a step is refused")
local restart = Rules.normalize({steps = {route, {action = {type = "wait"},
    ["until"] = {conditions = {{type = "elapsed", seconds = 5}}}, ["then"] = "start"}}})
check(restart.steps[2]["then"] == "start" and restart.steps[2]["goto"] == nil and Rules.nextStep(restart, 2) == 1,
      "then start goes back to step 1 without a number")

-- #### THE RUNNER #### --

Mock.addPlayer(1, "Rustypredator")
Mock.player(1).money = 5000000

local captain = {name = "Vel", level = 3, tier = 3, primaryClass = 4}
Mock.addShip(1, "Hauler", {x = 0, y = 0, range = 5, captain = captain,
                           cargoCapacity = 100, cargoFree = 100})
Mock.addShip(1, "Miner", {x = -316, y = 319, range = 4.1, cargoCapacity = 100, cargoFree = 100,
                          captain = captain})

Bridge.initialize()
Mock.shipEventSink = Bridge.pushShipEvent

local key = Auth.createKey(1, "tests")
local seq = 0

local function send(method, path, body, query)
    seq = seq + 1
    local id = "p" .. seq

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

local function run(seconds)
    for _ = 1, math.ceil(seconds / 0.25) do
        tick(0.25)
        if #Mock.asyncQueue > 0 then Mock.flushAsync() end
    end
end

local function stateOf(ship)
    local _, body = call("GET", "/ships/" .. ship .. "/program")
    return body and body.state or {}, body
end

local function called(fn)
    local n = 0
    for _, c in ipairs(Mock.entityCalls) do if c.fn == fn then n = n + 1 end end
    return n
end

-- The ship reports that the plan it was flying has ended where it is now.
local function arrive(ship, x, y, outcome)
    local s = Mock.getShip(1, ship)
    local plan = s.automation.plan
    s.x, s.y = x, y
    s.automation.last = {id = plan.id, kind = plan.kind, outcome = outcome or "arrived"}
    s.automation.plan = nil
    s.chain = {}
    Bridge.pushShipEvent(1, ship, "order", {chain = {}, activeIndex = 0, finished = false,
                                           x = x, y = y, automation = Json.encode(s.automation)})
end

print("\nsaving a program")

local status, body = call("POST", "/ships/Hauler/program", {steps = {{action = {type = "farm"}}}})
check(status == 400 and body.error.code == "bad_program", "an invalid program is refused")

Mock.entityCalls = {}
status, body = call("POST", "/ships/Hauler/program", {name = "Shuttle", steps =
{
    {name = "loot on", action = {type = "standing", standing = {loot = {enabled = true, mode = "interrupt"}}}},
    {name = "out", action = {type = "route", to = {x = 4, y = 0}}},
    {name = "fill up", action = {type = "wait"}, ["until"] = {conditions = {{type = "cargo", op = ">=", percent = 50}}}},
    {name = "home", action = {type = "route", to = {x = 0, y = 0}}, ["then"] = {["goto"] = 2}},
}})
check(status == 200 and body.program.revision == 1 and body.program.updatedBy.name == "Rustypredator",
      "a program is saved with its revision and author")
check(body.state and body.state.step == 1, "it starts at step 1")

local _, listed = call("GET", "/automation/programs")
check(#listed.programs == 1 and listed.programs[1].ship == "Hauler"
      and #listed.actions > 0 and #listed.conditions > 0,
      "it is listed, with the vocabulary")

print("\nworking through the steps")

run(4)
local state = stateOf("Hauler")
check(called("automationApiConfigure") == 1, "the standing step goes to the ship as the automation endpoint would send it")
check(Mock.getShip(1, "Hauler").automation.standing.loot.mode == "interrupt", "and the ship holds it")
check(called("automationApiRunPlan") == 1 and state.step == 2 and state.status == "running",
      "a standing step is over at once, and the route is flown next (step " .. tostring(state.step)
      .. ", " .. tostring(state.status) .. ": " .. tostring(state.message) .. ")")
check(type(state.planId) == "string", "the runner knows which plan is its own")

run(4)
check(stateOf("Hauler").step == 2, "the route step waits while the plan flies")

arrive("Hauler", 4, 0)
run(2)
state = stateOf("Hauler")
check(state.step == 3 and state.conditions[1].text == "cargo >= 50%" and state.conditions[1].met == false,
      "arriving ends the route, and the wait shows its condition unmet")

run(4)
check(stateOf("Hauler").step == 3, "nothing moves while the condition is not met")

Mock.getShip(1, "Hauler").cargoFree = 40
run(3)
state = stateOf("Hauler")
check(state.step == 4 and called("automationApiRunPlan") == 2, "cargo past 50% moves on to the flight home")

arrive("Hauler", 0, 0)
run(3)
state = stateOf("Hauler")
check(state.step == 2 and called("automationApiRunPlan") == 3, "and home goes back to step 2: the program loops")

local logged = false
for _, line in ipairs(state.log) do
    if line.message:find("step 4 (home) done", 1, true) then logged = true end
end
check(logged, "each finished step is logged")

print("\nmoving a program by hand")

status, body = call("POST", "/ships/Hauler/program/control", {action = "goto", step = 9})
check(status == 400 and body.error.code == "bad_step", "a step that does not exist is refused")

status, body = call("POST", "/ships/Hauler/program/control", {action = "goto", step = 3})
check(status == 200 and body.state.step == 3, "goto moves it")

print("\nsurviving a restart")

Programs.resetState()
state = stateOf("Hauler")
check(state.step == 3, "the step a program had got to survives a restart")

print("\nswitching off")

status, body = call("POST", "/ships/Hauler/program", {enabled = false, ifRevision = 1})
check(status == 200 and body.program.enabled == false and body.state.step == 3,
      "switching off keeps its place")
status, body = call("POST", "/ships/Hauler/program", {enabled = true, ifRevision = 1})
check(status == 409 and body.error.code == "program_changed", "a stale revision is refused")

Mock.entityCalls = {}
run(3)
check(#Mock.entityCalls == 0 and stateOf("Hauler").status == "disabled", "a switched-off program does nothing")

print("\na step that ends while its plan still flies")

Mock.getShip(1, "Hauler").cargoFree = 100
Mock.entityCalls = {}
status = call("POST", "/ships/Hauler/program", {enabled = true, steps =
{
    {action = {type = "route", to = {x = 20, y = 0}}, ["until"] = {conditions = {{type = "elapsed", seconds = 6}}},
     ["then"] = "stop"},
}})
check(status == 200, "(saved)")
check(stateOf("Hauler").step == 1, "new steps start the program over")
run(3)
check(called("automationApiRunPlan") == 1, "the route goes out")
run(6)
state = stateOf("Hauler")
check(called("automationApiStop") == 1, "when the time is up the plan still flying is stopped")
check(state.status == "finished", "and 'stop' ends the program (" .. tostring(state.status) .. ")")
run(3)
check(called("automationApiRunPlan") == 1, "a finished program sends nothing more")

print("\nrefusals are retried")

Mock.entityCalls = {}
call("POST", "/ships/Hauler/program", {steps =
{
    {action = {type = "route", to = {x = 0, y = 0}}},
}})
run(2)
state = stateOf("Hauler")
check(state.status == "retrying" and state.message:find("already_there", 1, true) ~= nil,
      "a step the endpoint refuses says why (" .. tostring(state.message) .. ")")

Mock.setOffline(1)
run(8)
check(stateOf("Hauler").status == "waiting", "an offline owner is waited for")
Mock.setOnline(1)

call("POST", "/ships/Hauler/program/delete")
local _, gone = call("GET", "/ships/Hauler/program")
check(gone.program == nil, "a deleted program is gone")

-- #### MISSION STEPS #### --

print("\nmission steps")

Mock.predictionFor = function(config)
    local hours = config.duration or 1
    local amount = 1000 * hours
    return {attackChance = {value = 0.12}, yields = {{from = amount, to = amount}}}
end

call("POST", "/ships/Miner/program", {name = "Mine till full", steps =
{
    {action = {type = "mission"}, ["repeat"] = true,
     ["until"] = {conditions = {{type = "cargo", op = ">=", percent = 90}}}, ["then"] = "stop"},
}})
run(2)
state = stateOf("Miner")
check(state.status == "retrying" and state.message:find("no_mission_rule", 1, true) ~= nil,
      "a mission step with no rule to fly says so")

call("POST", "/ships/Miner/mission/automation",
     {mission = "mine", limits = {maxAttackChance = 0.2, maxDuration = 3600}, materials = {"Iron"}})

run(8)
local _, rule = call("GET", "/ships/Miner/mission/automation")
check(rule.state.phase == "program", "mission automation stands aside for the program ("
      .. tostring(rule.state.phase) .. ")")

state = stateOf("Miner")
check(Mock.getShip(1, "Miner").availability == ShipAvailability.InBackground
      and state.status == "running",
      "the step sends the ship out under the craft's rule (" .. tostring(state.message) .. ")")

local ship = Mock.getShip(1, "Miner")
ship.availability = ShipAvailability.Available
ship.analyzedType = nil
ship.cargoFree = 50
run(8)
check(ship.availability == ShipAvailability.InBackground, "back half full, it is sent out again: repeat")

ship.availability = ShipAvailability.Available
ship.analyzedType = nil
ship.cargoFree = 5
run(4)
state = stateOf("Miner")
check(state.status == "finished", "back full, the condition is met and the program ends")

_, rule = call("GET", "/ships/Miner/mission/automation")
check(rule.state.phase ~= "program" and rule.state.dispatches == 1,
      "and the craft's own enabled rule takes it back, sending it out by itself ("
      .. tostring(rule.state.phase) .. ")")

-- #### THE MISSION LIBRARY #### --

print("\nthe mission library")

-- Without the craft's own rule, which would otherwise send it out between the steps here.
call("POST", "/ships/Miner/mission/automation/delete")
ship.availability = ShipAvailability.Available
ship.analyzedType = nil

status, body = call("POST", "/automation/missions/library/Mine%20safe",
                    {mission = "mine", limits = {maxAttackChance = 0.2, maxDuration = 3600}, materials = {"Unobtainium"}})
check(status == 400, "a library mission is checked like a rule: an unknown material is refused ("
      .. tostring(status) .. ")")

status, body = call("POST", "/automation/missions/library/Mine%20safe",
                    {mission = "mine", limits = {maxAttackChance = 0.2, maxDuration = 3600}, materials = {"Iron"}})
check(status == 200 and body.name == "Mine safe" and body.revision == 1 and body.rule.mission == "mine"
      and body.rule.enabled == nil, "a library mission is saved under its name, with no on or off")
status, body = call("POST", "/automation/missions/library/Mine%20safe", {objective = "total", ifRevision = 0})
check(status == 409 and body.error.code == "library_changed", "a stale revision is refused")
status, body = call("POST", "/automation/missions/library/Mine%20safe", {objective = "total", ifRevision = 1})
check(status == 200 and body.rule.objective == "total" and body.rule.limits.maxAttackChance == 0.2,
      "an update merges over the stored mission")

status, body = call("POST", "/ships/Miner/program", {steps = {{action = {type = "mission", library = "Nope"}}}})
check(status == 400 and body.error.code == "bad_program", "a step naming a mission the library lacks is refused")

status, body = call("POST", "/ships/Miner/program", {name = "Library", enabled = false, steps =
{
    {action = {type = "mission", library = "Mine safe"}, ["then"] = "stop"},
}})
check(status == 200 and body.program.steps[1].action.library == "Mine safe", "a step names a library mission")

local _, library = call("GET", "/automation/missions/library")
check(#library.missions == 1 and library.missions[1].usedBy[1] == "Miner", "the library says which craft use it")

status, body = call("POST", "/automation/missions/library/Mine%20safe/delete")
check(status == 409 and body.error.code == "mission_in_use", "a mission a program flies cannot be deleted")

status, body = call("POST", "/automation/missions/library/Mine%20safe", {rename = "Mine carefully"})
check(status == 200 and body.name == "Mine carefully", "a library mission can be renamed")
local _, renamed = call("GET", "/ships/Miner/program")
check(renamed.program.steps[1].action.library == "Mine carefully" and renamed.program.revision == 2,
      "and the programs naming it follow, keeping their revision")

-- Every option predicts a 12% ambush, so a 10% ceiling refuses them all.
call("POST", "/automation/missions/library/Mine%20carefully", {limits = {maxAttackChance = 0.1}})
check(ship.availability == ShipAvailability.Available, "(the program was saved switched off, so nothing left yet)")
call("POST", "/ships/Miner/program", {enabled = true})
run(4)
state = stateOf("Miner")
check(state.status == "retrying" and state.message:find("nothing_within_limits", 1, true) ~= nil,
      "the step flies the library mission as it is when the step starts (" .. tostring(state.message) .. ")")

call("POST", "/automation/missions/library/Mine%20carefully", {limits = {maxAttackChance = 0.2, maxDuration = 3600}})
run(8)
state = stateOf("Miner")
check(ship.availability == ShipAvailability.InBackground and state.message:find("Mine carefully", 1, true) ~= nil,
      "and once it allows a start, the ship goes out on it (" .. tostring(state.message) .. ")")

call("POST", "/ships/Miner/program/delete")
status, body = call("POST", "/automation/missions/library/Mine%20carefully/delete")
check(status == 200 and body.deleted == true, "unused, it can be deleted")

-- #### TRAVEL STEPS #### --

print("\ntravel steps")

check(raises(function() Rules.normalize({steps = {{action = {type = "travel", to = {x = 60, y = 0}, swiftness = 5}}}}) end,
             "bad_program"), "swiftness is 0 to 3")

Mock.addShip(1, "Courier", {x = 0, y = 0, range = 5, captain = captain, cargoCapacity = 100, cargoFree = 100})
Mock.simulationCalls = {}
status = call("POST", "/ships/Courier/program", {name = "Run", steps =
{
    {action = {type = "travel", to = {x = 60, y = 0}, swiftness = 1}},
    {action = {type = "wait"}, ["until"] = {conditions = {{type = "elapsed", seconds = 3}}}, ["then"] = "stop"},
}})
check(status == 200, "(saved)")

for _ = 1, 8 do
    tick(0.25)
    Mock.flushAsync({route = {{x = 0, y = 0}, {x = 30, y = 0}, {x = 60, y = 0}},
                     sectors = 1, reachableCoordinates = {}})
end
run(3)

local courier = Mock.getShip(1, "Courier")
local travelled
for _, c in ipairs(Mock.simulationCalls) do
    if c.fn == "startAreaAnalysis" and c.args[2] == Mock.commandTypes.Travel then travelled = true end
end
state = stateOf("Courier")
check(travelled and courier.availability == ShipAvailability.InBackground and state.step == 1
      and state.status == "running", "a travel step starts a Travel mission (" .. tostring(state.message) .. ")")

courier.availability = ShipAvailability.Available
courier.x, courier.y = 60, 0
run(2)
check(stateOf("Courier").step == 2, "and ends once the craft is back, at the other end")

print("")
if failures > 0 then print(failures .. " check(s) failed"); os.exit(1) end
print("all checks passed")
