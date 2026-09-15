-- Mission automation: the rule arithmetic, the stored rules, and the loop that sends a
-- ship back out - against the mocked simulation.
--
-- As with test_missions.lua, the vanilla prediction maths is not reproduced. What these
-- pin is the part this mod owns: which configs are tried, how their figures are compared
-- with the limits, which one is chosen, and that the start goes through the same agent
-- handshake a manual start does - for player and alliance craft alike.

package.path = "data/scripts/lib/?.lua;tests/?.lua;" .. package.path

local Mock = require("mock_avorion")
Mock.install()
Mock.reset()

local Json = require("automationapi.json")
local Config = require("automationapi.config")
local Auth = require("automationapi.auth")
local Rules = require("automationapi.missionrules")
local Router = require("automationapi.router")

-- The loop looks once every ten seconds in game; the tests would rather not wait.
Config.missionAutomationInterval = 0.5

dofile("data/scripts/galaxy/automationapi/bridge.lua")
local Bridge = AutomationApiBridge

dofile("data/scripts/player/automationapi/agent.lua")
local Agent = AutomationApiAgent
dofile("data/scripts/player/automationapi/agent.lua")
local AllianceAgent = AutomationApiAgent

local failures = 0
local function check(cond, msg)
    if cond then print("  ok   " .. msg)
    else failures = failures + 1; print("  FAIL " .. msg) end
end

local function raises(fn, code)
    local ok, err = pcall(fn)
    return not ok and Router.isApiError(err) and (code == nil or err.code == code), err
end

-- #### RULE ARITHMETIC #### --

print("\ntrade patience")

check(Rules.expectedTradeFlights(3) == 3, "three flights are always flown")
check(math.abs(Rules.expectedTradeFlights(4) - 3.65) < 1e-9,
      "a fourth flight happens 65% of the time")
check(Rules.tradeCompletionChance(3) == 1, "a three-flight contract always completes")
check(math.abs(Rules.tradeCompletionChance(5) - 0.65 ^ 2) < 1e-9,
      "each flight past three risks the contract")
check(Rules.tradePatience(3) == "safe" and Rules.tradePatience(4) == "small risk"
      and Rules.tradePatience(6) == "real risk" and Rules.tradePatience(11) == "likely lost",
      "patience follows the captain's thresholds")

print("\nmetrics")

local mine = Rules.metrics("mine", {duration = 2},
                           {attackChance = {value = 0.12}, yields = {{from = 100, to = 300}}})
check(mine.duration == 7200, "mine duration is hours in the config, seconds in the metrics")
check(mine.value == 200 and mine.hourly == 100, "yield is the midpoint, hourly follows")

local refine = Rules.metrics("refine", {}, {attackChance = 0, duration = 600, yields = {50, 50}})
check(refine.attackChance == 0 and refine.duration == 600 and refine.value == 100,
      "refine's bare-number prediction fields are read too")

local trade = Rules.metrics("trade", {deposit = 1000},
    {attackChance = {value = 0.1}, flightTime = {value = 1000}, flights = {from = 3, to = 5},
     profitPerFlight = {from = 900, to = 1100}})
check(trade.flights == 5 and trade.cost == 1000 and trade.duration == 5000,
      "trade reads flights, deposit and the whole contract's duration")
check(math.abs(trade.value - 1000 * Rules.expectedTradeFlights(5)) < 1e-6,
      "trade value is what the contract is expected to pay before the customer walks")

print("\nlimits")

local v = Rules.check({maxAttackChance = 0.2}, {attackChance = 0.2}, {})
check(#v == 0, "a chance exactly at the limit passes")

v = Rules.check({maxAttackChance = 0.1, maxFlights = 3, minCreditsLeft = 500},
                {attackChance = 0.15, flights = 4, cost = 800}, {money = 1000, canStart = true})
check(#v == 3, "every broken limit is reported (got " .. #v .. ")")

v = Rules.check({}, {attackChance = 0}, {canStart = false, gameError = "No captain"})
check(#v == 1 and v[1].limit == "game" and v[1].message == "No captain",
      "the game's own refusal counts as a violation")

print("\nranking")

local ranked = Rules.rank(
{
    {metrics = {attackChance = 0.3, hourly = 900, value = 100}, violations = {{}}},
    {metrics = {attackChance = 0.2, hourly = 500, value = 300}, violations = {}},
    {metrics = {attackChance = 0.1, hourly = 700, value = 200}, violations = {}},
}, "hourly")
check(ranked[1].metrics.hourly == 700 and ranked[3].metrics.hourly == 900,
      "passing candidates rank ahead, best hourly first")

ranked = Rules.rank(
{
    {metrics = {attackChance = 0.2, hourly = 500, value = 300}, violations = {}},
    {metrics = {attackChance = 0.1, hourly = 700, value = 200}, violations = {}},
}, "total")
check(ranked[1].metrics.value == 300, "total ranks by value")

ranked = Rules.rank(
{
    {metrics = {attackChance = 0.2, hourly = 500}, violations = {}},
    {metrics = {attackChance = 0.1, hourly = 100}, violations = {}},
}, "safest")
check(ranked[1].metrics.attackChance == 0.1, "safest ranks by ambush chance")

print("\ncandidates")

local durations = Rules.candidates("mine", {limits = {maxDuration = 5400}}, {},
                                   {configurable = {duration = {from = 0.5, to = 3}}})
check(#durations == 3 and durations[3].duration == 1.5,
      "mine tries every half hour the limits allow (got " .. #durations .. ")")

durations = Rules.candidates("mine", {limits = {maxDuration = 600}}, {},
                             {configurable = {duration = {from = 0.5, to = 3}}})
check(#durations == 1 and durations[1].duration == 0.5,
      "when nothing fits, the nearest miss is still tried so it can be reported")

durations = Rules.candidates("expedition", {limits = {}}, {},
                             {configurable = {duration = {from = 30, to = 120}}})
check(#durations == 4, "expedition steps by the order window's half hour")

print("\nvalidation")

check(raises(function() Rules.normalize({mission = "travel"}) end, "not_automatable"),
      "travel cannot be automated")
check(raises(function() Rules.normalize({mission = "mine", limits = {maxAmbush = 1}}) end,
             "bad_rule"), "an unknown limit is refused")
check(raises(function() Rules.normalize({mission = "mine", limits = {maxAttackChance = 5}}) end,
             "bad_rule"), "an attack chance above 1 is refused")

local stored = Rules.normalize({mission = "mine", limits = {maxAttackChance = 0.2}})
check(stored.enabled == true and stored.objective == "hourly" and stored.area.mode == "ship",
      "defaults: enabled, hourly, following the ship")

local toggled = Rules.normalize({enabled = false}, stored)
check(toggled.enabled == false and toggled.limits.maxAttackChance == 0.2
      and toggled.mission == "mine", "a partial body only changes what it names")

local tradeRule = Rules.normalize({mission = "trade", config = {goodName = "Oil", deposit = 5}})
check(tradeRule.config.goodName == nil and tradeRule.config.deposit == nil,
      "trade route and deposit are the automation's to choose, never stored")

-- #### ENDPOINTS AND LOOP #### --

Mock.addPlayer(1, "Rustypredator")
Mock.addPlayer(2, "Wingmate")
Mock.player(1).money = 5000000

local captain = {name = "Pritteggi", level = 3, tier = 3, primaryClass = 4}
Mock.addShip(1, "Prospector", {x = -316, y = 319, range = 4.1, cargoFree = 768, captain = captain})

Bridge.initialize()
local key = Auth.createKey(1, "tests")
local wingKey = Auth.createKey(2, "tests")

local seq = 0

local function send(method, path, body, query, asKey)
    seq = seq + 1
    local id = "a" .. seq

    local f = assert(io.open(Config.getRequestsDir() .. "/" .. id .. ".json", "wb"))
    f:write(Json.encode{id = id, key = asKey or key, method = method, path = path,
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

local function call(method, path, body, query, asKey)
    return send(method, path, body, query, asKey)()
end

local withAlliance = false

local function tick(seconds)
    Mock.advanceClock(seconds)
    Mock.asPlayerAgent(1, function() Agent.update(seconds) end)
    if withAlliance then
        Mock.asAllianceAgent(77, function() AllianceAgent.update(seconds) end)
    end
    Bridge.update(seconds)
end

local function run(seconds, results)
    local steps = math.ceil(seconds / 0.5)
    for _ = 1, steps do
        tick(0.5)
        if #Mock.asyncQueue > 0 then Mock.flushAsync(results) end
    end
end

local function stateOf(ship, query, asKey)
    local _, body = call("GET", "/ships/" .. ship .. "/mission/automation", nil, query, asKey)
    return body and body.state or {}, body
end

-- A mining yield grows with the time spent, plus MineCommand's half a percent per hour, so
-- the longest run the limits allow is also the best per hour - as it is in game.
Mock.predictionFor = function(config)
    local hours = config.duration or 1
    local amount = 1000 * hours * (1 + 0.005 * hours)
    return {attackChance = {value = 0.12}, yields = {{from = amount, to = amount}}}
end

print("\nsaving a rule")

local status, saved = call("POST", "/ships/Prospector/mission/automation",
                           {mission = "mine", enabled = false,
                            limits = {maxAttackChance = 0.2, maxDuration = 5400},
                            materials = {"Iron"}})
check(status == 200, "a rule is saved (got " .. tostring(status) .. ")")
check(saved.rule.revision == 1 and saved.rule.updatedBy.name == "Rustypredator",
      "it records its revision and who saved it")

local status = call("POST", "/ships/Prospector/mission/automation",
                    {mission = "mine", materials = {"Unobtainium"}})
check(status == 400, "a misspelt material is refused when saving, not at dispatch")

local status = call("POST", "/ships/Prospector/mission/automation", {mission = "travel"})
check(status == 422, "an unautomatable mission is refused")

local _, listed = call("GET", "/automation/missions")
check(#listed.automations == 1 and listed.automations[1].ship == "Prospector",
      "the rule is listed")

run(3)
check(stateOf("Prospector").phase == "disabled" and #Mock.simulationCalls == 0,
      "a disabled rule does nothing")

print("\ndispatch")

local status = call("POST", "/ships/Prospector/mission/automation", {enabled = true, ifRevision = 1})
check(status == 200, "switched on with a matching revision")

local status, conflict = call("POST", "/ships/Prospector/mission/automation",
                              {enabled = false, ifRevision = 1})
check(status == 409 and conflict.error.code == "rule_changed",
      "a stale revision is refused rather than overwriting")

run(1)
check(#Mock.asyncQueue == 0, "the analysis was run")

run(6)

local state = stateOf("Prospector")
check(state.phase == "running", "the ship was sent out (phase " .. tostring(state.phase)
      .. ": " .. tostring(state.message) .. ")")
check(state.dispatches == 1, "one dispatch counted")
check(Mock.getShip(1, "Prospector").availability == ShipAvailability.InBackground,
      "and is out in the background simulation")

local startCall
for _, c in ipairs(Mock.simulationCalls) do
    if c.fn == "startCommand" then startCall = c end
end
check(startCall and startCall.args[3].duration == 1.5,
      "the longest duration inside maxDuration was chosen for profit per hour")
check(startCall and startCall.args[3].collected and startCall.args[3].collected[0] == true
      and startCall.args[3].collected[1] == nil, "with the rule's materials")

local evaluation = state.lastEvaluation
check(evaluation and evaluation.tried == 3 and evaluation.passing == 3,
      "the evaluation is kept for the console")

print("\nwaiting for the ship to return")

Mock.simulationCalls = {}
run(40)
check(#Mock.simulationCalls == 0, "nothing is tried while the ship is out")

Mock.getShip(1, "Prospector").availability = ShipAvailability.Available
Mock.getShip(1, "Prospector").analyzedType = nil
run(40)
check(stateOf("Prospector").dispatches == 2, "and it goes out again once back")

print("\nlimits block a dispatch")

Mock.getShip(1, "Prospector").availability = ShipAvailability.Available
Mock.getShip(1, "Prospector").analyzedType = nil

call("POST", "/ships/Prospector/mission/automation", {limits = {maxAttackChance = 0.1}})
Mock.simulationCalls = {}
run(8)

local blocked = stateOf("Prospector")
check(blocked.phase == "blocked", "the ship is held back (phase " .. tostring(blocked.phase) .. ")")
check(blocked.message and string.find(blocked.message, "ambush chance 12%", 1, true) ~= nil,
      "and the message says which limit and by how much")
check(Mock.getShip(1, "Prospector").availability == ShipAvailability.Available,
      "nothing was started")

local analyses = #Mock.asyncQueue
run(30)
check(#Mock.asyncQueue == analyses, "a blocked rule does not spend an analysis on every pass")

print("\noffline")

call("POST", "/ships/Prospector/mission/automation", {limits = {maxAttackChance = 0.5}})
Mock.setOffline(1)
run(4)
check(stateOf("Prospector").phase == "offline", "an offline owner is waited for")
check(#Mock.asyncQueue == 0, "without running an analysis")
Mock.setOnline(1)

print("\ndry run")

local read = send("POST", "/ships/Prospector/mission/automation/evaluate",
                  {limits = {maxAttackChance = 0.05}})
Mock.flushAsync()
Bridge.update(Config.pollInterval)
local status, dry = read()
check(status == 200 and dry.wouldStart == false, "a dry run reports it would not start")
check(dry.evaluation.candidates[1].violations[1].limit == "maxAttackChance",
      "and why, per candidate")
check(#dry.assessment > 0, "with the captain's assessment of the nearest candidate")

local _, unchanged = call("GET", "/ships/Prospector/mission/automation")
check(unchanged.rule.limits.maxAttackChance == 0.5, "without saving the tried limits")

Mock.predictionFor = nil

print("\ntrade")

-- The sweep a trade rule exists for: more deposit, fewer flights, higher ambush chance.
local tradeAnalysis =
{
    sectors = 289, reachable = 280, unreachable = 9,
    sectorsByFaction = {[0] = 120}, reachableCoordinates = {}, biggestFactionInArea = 0,
    routes =
    {
        {name = "Oil", lowest = -0.2, highest = 0.15, profit = 112,
         from = {x = -310, y = 318}, to = {x = -300, y = 322}},
        {name = "Ore", lowest = -0.1, highest = 0.2, profit = 9,
         from = {x = -312, y = 320}, to = {x = -305, y = 311}},
    },
}

Mock.predictionFor = function(config)
    local prediction = {attackChance = {value = 0}, flightTime = {value = 1200},
                        flights = {from = 0, to = 0}, profitPerFlight = {from = 0, to = 0},
                        maxAvailable = {value = 0}, transportedPerFlight = 0}

    local route
    for _, r in ipairs(tradeAnalysis.routes) do
        if r.name == config.goodName then route = r end
    end
    if not route then prediction.error = "No route selected."; return prediction end

    local good = goods[route.name]
    local available = route.name == "Oil" and 400 or 1000
    local buyPrice = math.floor(good.price * (1 + route.lowest))
    local perFlight = math.min(math.floor(768 / good.size), math.floor(config.deposit / buyPrice),
                               available)
    if perFlight == 0 then prediction.error = "Not enough cargo space!"; return prediction end

    local flights = math.ceil(available / perFlight)
    prediction.maxAvailable.value = available
    prediction.transportedPerFlight = perFlight
    prediction.flights = {from = math.min(3, flights), to = flights}
    prediction.profitPerFlight = {from = perFlight * route.profit, to = perFlight * route.profit}
    prediction.attackChance.value = math.min(1, 0.04 + math.min(config.deposit, 1e9) / 1e6)
    return prediction
end

Mock.addShip(1, "Trader", {x = -316, y = 319, range = 4.1, cargoFree = 768, captain = captain})

local read = send("POST", "/ships/Trader/mission/automation/evaluate",
                  {mission = "trade", limits = {maxFlights = 3, maxAttackChance = 0.08}})
Mock.flushAsync(tradeAnalysis)
Bridge.update(Config.pollInterval)
local status, tradeDry = read()

local chosen = tradeDry and tradeDry.evaluation and tradeDry.evaluation.chosen
check(status == 200 and chosen ~= nil, "a trade route inside the limits is found")
check(chosen and chosen.config.goodName == "Oil", "the more profitable route wins")
check(chosen and chosen.metrics.flights == 3 and chosen.config.deposit == 134 * 256,
      "at the smallest deposit that flies it in three flights")
check(chosen and chosen.metrics.attackChance <= 0.08, "keeping under the ambush ceiling")
check(chosen and chosen.route and chosen.route.from.x == -310, "and names the route")

Mock.predictionFor = nil

print("\nalliance")

local privileges = {[AlliancePrivilege.ManageShips] = true,
                    [AlliancePrivilege.SpendResources] = true}
Mock.addAlliance(77, "Rusty Industries", 1, privileges, {1, 2})
Mock.addShip(77, "Alliance Miner", {x = 0, y = 0, captain = captain})
withAlliance = true

local status = call("POST", "/ships/Alliance Miner/mission/automation",
                    {mission = "mine", limits = {maxAttackChance = 0.5}},
                    {owner = "alliance"}, wingKey)
check(status == 403, "a member without ManageShips cannot automate alliance craft")

local status = call("POST", "/ships/Alliance Miner/mission/automation",
                    {mission = "mine", limits = {maxAttackChance = 0.5}}, {owner = "alliance"})
check(status == 200, "a member with ManageShips can")

local _, seen = call("GET", "/ships/Alliance Miner/mission/automation",
                     nil, {owner = "alliance"}, wingKey)
check(seen.rule and seen.rule.updatedBy.name == "Rustypredator",
      "every member reads the same rule")

local _, wingList = call("GET", "/automation/missions", nil, nil, wingKey)
local alliedEntry
for _, entry in ipairs(wingList.automations) do
    if entry.ship == "Alliance Miner" then alliedEntry = entry end
end
check(alliedEntry and alliedEntry.owner.kind == "alliance",
      "and the fleet-wide list carries it for them too")

Mock.simulationCalls = {}
run(10)

local allianceState = stateOf("Alliance Miner", {owner = "alliance"}, wingKey)
check(allianceState.phase == "running" and allianceState.dispatches == 1,
      "the alliance's agent sends it out, and every member sees that (phase "
      .. tostring(allianceState.phase) .. ": " .. tostring(allianceState.message) .. ")")
check(Mock.getShip(77, "Alliance Miner").availability == ShipAvailability.InBackground,
      "the alliance craft is out")

-- The member who saved the rule is demoted: the rule stops, and says why.
Mock.getShip(77, "Alliance Miner").availability = ShipAvailability.Available
Mock.getShip(77, "Alliance Miner").analyzedType = nil
privileges[AlliancePrivilege.ManageShips] = false
run(40)
local demoted = stateOf("Alliance Miner", {owner = "alliance"})
check(demoted.phase == "blocked" and demoted.dispatches == 1,
      "a demoted author's rule stops dispatching")
privileges[AlliancePrivilege.ManageShips] = true

print("\ndelete")

local status, deleted = call("POST", "/ships/Prospector/mission/automation/delete")
check(status == 200 and deleted.deleted == true, "a rule is removed")
local _, gone = call("GET", "/ships/Prospector/mission/automation")
check(gone.rule == nil, "and is gone")

check(#Mock.errors == 0, "no errors logged")
for _, e in ipairs(Mock.errors) do print("       > " .. e) end

print("")
if failures > 0 then print(failures .. " check(s) failed"); os.exit(1) end
print("all checks passed")
