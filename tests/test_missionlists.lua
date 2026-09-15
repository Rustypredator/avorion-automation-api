-- List-shaped mission configs: procure and sell goods, supply routes, and the crew,
-- torpedoes and fighters bought on maintenance.
--
-- Vanilla reads these as tables its order windows build, and raised on pairs() when the
-- API handed it nothing or a number. What is covered here is the translation from the
-- request shape into what the commands read, the echo back, the supply route matching
-- against the analysis, and the options a preview offers.

package.path = "data/scripts/lib/?.lua;tests/?.lua;" .. package.path

local Mock = require("mock_avorion")
Mock.install()
Mock.reset()

local Json = require("automationapi.json")
local Config = require("automationapi.config")
local Auth = require("automationapi.auth")

-- The libraries maintenance names come from. Enum keys are the game's own.
Mock.stubs.torpedoutility = {WarheadType = {Nuclear = 1, Neutron = 2, Fusion = 3}}
Mock.stubs.captainutility = {ClassType = {Merchant = 7, Smuggler = 8}}
_G.WeaponType = {ChainGun = 0, Laser = 3, MiningLaser = 4}
_G.FighterType = {Invalid = 0, Fighter = 1, CrewShuttle = 2}
_G.Balancing_GetWeaponProbability = function() return {[0] = 1, [3] = 0.5, [4] = 0} end

dofile("data/scripts/galaxy/automationapi/bridge.lua")
local Bridge = AutomationApiBridge

local failures = 0
local function check(cond, msg)
    if cond then print("  ok   " .. msg)
    else failures = failures + 1; print("  FAIL " .. msg) end
end

local function captain(classes)
    return
    {
        name = "Pritteggi", level = 3, tier = 3, primaryClass = 4,
        hasClass = function(_, class) return classes[class] == true end,
    }
end

Mock.addPlayer(1, "Rustypredator")
local trader = Mock.addShip(1, "Trader",
{
    x = 10, y = 10, range = 6, cargoFree = 800,
    captain = captain({}),
    cargo =
    {
        [{name = "Energy Cell", price = 61, size = 1}] = 300,
        [{name = "Oil", price = 320, size = 2, stolen = true}] = 20,
    },
    hangar =
    {
        [0] = {name = "Alpha", numFighters = 4,
               getBlueprint = function() return {type = FighterType.Fighter} end},
        [2] = {name = "Boarders", numFighters = 12,
               getBlueprint = function() return {type = FighterType.CrewShuttle} end},
    },
})
Bridge.initialize()
local key = Auth.createKey(1, "tests")

local seq = 0

local function send(method, path, body)
    seq = seq + 1
    local id = "l" .. seq

    local f = assert(io.open(Config.getRequestsDir() .. "/" .. id .. ".json", "wb"))
    f:write(Json.encode{id = id, key = key, method = method, path = path, body = body or {}, query = {}})
    f:close()

    Bridge.update(Config.pollInterval)

    return function()
        local rf = io.open(Config.getResponsesDir() .. "/" .. id .. ".json", "rb")
        if not rf then return nil end
        local res = Json.decode(rf:read("*all")); rf:close()
        return res.status, res.body
    end
end

-- Previews against a chosen analysis, and returns the config the command was predicted with.
local predicted
Mock.predictionFor = function(config)
    predicted = config
    return {attackChance = {value = 0}}
end

local function preview(mission, body, analysis)
    predicted = nil
    local read = send("POST", "/ships/Trader/missions/" .. mission .. "/preview", body)
    Mock.flushAsync(analysis)
    Bridge.update(Config.pollInterval)
    local status, response = read()
    return status, response, predicted
end

local function baseAnalysis(extra)
    local analysis = {sectors = 225, reachable = 225, unreachable = 0, sectorsByFaction = {},
                      reachableCoordinates = {}, biggestFactionInArea = 0}
    for k, v in pairs(extra or {}) do analysis[k] = v end
    return analysis
end

-- #### CATALOG #### --

print("\ncatalog")

-- ProcureCommand:getConfigurableValues, verbatim in shape: two lists of five slots that
-- the command never reads. Rendered as fields they sent numbers the command raised on.
Mock.configurableFor = function(missionType)
    if missionType == Mock.commandTypes.Procure then
        local values = {goods = {}, amounts = {}}
        for i = 1, 5 do
            values.goods[i] = {displayName = "Good to procure", default = ""}
            values.amounts[i] = {displayName = "Amount of good", from = 0, to = 100, default = 0}
        end
        return values
    end
    if missionType == Mock.commandTypes.Maintenance then return {torpedoesToBuy = {}} end
    return {duration = {from = 0.5, to = 2, default = 1, displayName = "Duration"}}
end

local read = send("GET", "/ships/Trader/missions")
local _, catalog = read()
local byKey = {}
for _, m in ipairs(catalog.missions) do byKey[m.mission] = m end
check(next(byKey.procure.configurable) == nil, "procure's placeholder slots are not offered as fields")
check(next(byKey.maintenance.configurable) == nil, "nor maintenance's empty legacy table")
check(byKey.mine.configurable.duration ~= nil, "single values still are")

-- #### PROCURE #### --

print("\nprocure")

local procureAnalysis = baseAnalysis({goodsInArea = {["Energy Cell"] = 3, ["Oil"] = 1},
                                      smugglerGoodsInArea = {["Raw Oil"] = true}})

local status, body, config = preview("procure",
    {config = {goods = {{name = "energy cell", amount = 500}, {name = "Oil", amount = 10, stolen = true}}}},
    procureAnalysis)
check(status == 200, "a procure preview with goods answers (got " .. tostring(status) .. ")")
check(config and type(config.goodsToBuy) == "table" and #config.goodsToBuy == 2,
      "goods reach the command as goodsToBuy")
check(config.goodsToBuy[1].name == "Energy Cell" and config.goodsToBuy[1].amount == 500
      and config.goodsToBuy[1].stolen == false and config.goodsToBuy[1].slot == 1,
      "each with the good's exact name, amount, stolen flag and window slot")
check(config.goodsToBuy[2].stolen == true, "stolen is passed through")
check(Json.isArray(body.config.goods) and body.config.goods[1].name == "Energy Cell"
      and body.config.goodsToBuy == nil,
      "the echo speaks the request shape")
check(body.errors.config == nil, "and has no config error")

local names = {}
for _, g in ipairs(body.options.goods) do names[g.name] = g.availability end
check(names["Energy Cell"] == "area" and names["Raw Oil"] == nil,
      "a plain captain is offered what the area sells, nothing smuggled")
check(body.options.stolenAllowed == false, "and cannot procure illegally")

trader.captain = captain({[8] = true})
local _, smuggled = preview("procure", {config = {goods = {}}}, procureAnalysis)
names = {}
for _, g in ipairs(smuggled.options.goods) do names[g.name] = g.availability end
check(names["Raw Oil"] == "stolen" and smuggled.options.stolenAllowed == true,
      "a smuggler is offered goods only obtainable illegally")
trader.captain = captain({})

local status, _, config = preview("procure", {}, procureAnalysis)
check(status == 200 and config and type(config.goodsToBuy) == "table" and next(config.goodsToBuy) == nil,
      "no goods at all still hands the command a table, never nil")

local function refused(mission, body, code, what)
    local read = send("POST", "/ships/Trader/missions/" .. mission .. "/preview", body)
    local status, response = read()
    check(status == 400 and response.error.code == code,
          what .. " (got " .. tostring(status) .. " " .. tostring(response and response.error
          and response.error.code) .. ")")
end

refused("procure", {config = {goods = {{name = "Unobtainium", amount = 1}}}}, "bad_goods", "an unknown good is refused")
refused("procure", {config = {goods = {{name = "Oil"}}}}, "bad_goods", "a good without an amount is refused")
refused("procure", {config = {goods = 5}}, "bad_goods", "goods that are not a list are refused")
refused("procure", {config = {goods = {{name = "Oil", amount = 1}, {name = "Oil", amount = 1},
    {name = "Oil", amount = 1}, {name = "Oil", amount = 1}, {name = "Oil", amount = 1},
    {name = "Oil", amount = 1}}}}, "bad_goods", "more lines than the window has are refused")

-- #### SELL #### --

print("\nsell")

local sellAnalysis = baseAnalysis({goodsInDemand = {["Energy Cell"] = true, ["Oil"] = true},
                                   goodsInSupply = {}})

local status, body, config = preview("sell", {config = {goods = {{name = "Energy Cell", amount = 300}}}},
                                     sellAnalysis)
check(status == 200 and config and #config.goodsToSell == 1, "goods reach the command as goodsToSell")
check(config.goodsToSell[1].goodName == "Energy Cell" and config.goodsToSell[1].amount == 300
      and config.goodsToSell[1].stolen == false, "keyed by goodName, as SellCommand reads them")
check(config.goods == nil and body.config.goods[1].name == "Energy Cell", "echoed as goods")

local cargo = {}
for _, c in ipairs(body.options.cargo) do cargo[c.name] = c end
check(cargo["Energy Cell"].amount == 300 and cargo["Energy Cell"].sellable == true,
      "cargo in demand is offered as sellable")
check(cargo["Oil"].stolen == true and cargo["Oil"].sellable == false,
      "stolen cargo is not, for a captain who is no smuggler")

-- #### SUPPLY #### --

print("\nsupply")

Mock.addShip(1, "Solar Plant", {x = 12, y = 10, type = EntityType.Station, title = "Solar Power Plant"})
Mock.addShip(1, "Refinery", {x = 20, y = 14, type = EntityType.Station, title = "Oil Refinery"})
Mock.addShip(1, "Neighbour", {x = 12, y = 10, type = EntityType.Station})

local supplyAnalysis = baseAnalysis(
{
    stations =
    {
        {name = "Solar Plant", opportunities = {{script = "factory.lua", sold = {"Energy Cell"}, bought = {}}}},
        {name = "Refinery", opportunities = {{script = "factory.lua", sold = {"Oil"},
                                              bought = {"Energy Cell", "Raw Oil"}}}},
        {name = "Neighbour", opportunities = {{script = "factory.lua", sold = {}, bought = {"Energy Cell"}}}},
    },
})

local status, body, config = preview("supply",
    {config = {routes = {{from = "Solar Plant", to = "Refinery"}}}}, supplyAnalysis)
check(status == 200 and config and #config.routes == 1, "routes reach the command")
local route = config.routes[1]
check(route.from == "Solar Plant" and route.to == "Refinery" and #route.transportable == 1
      and route.transportable[1].name == "Energy Cell" and route.transportable[1].toScript == "factory.lua",
      "and are completed with what the analysis says the stations trade")
check(body.errors.config == nil and body.config.routes[1].carried[1] == "Energy Cell",
      "the echo shows what will be carried")

local stations = {}
for _, s in ipairs(body.options.stations) do stations[s.name] = s end
check(stations["Solar Plant"] and #stations["Solar Plant"].deliveries == 1
      and stations["Solar Plant"].deliveries[1].to == "Refinery",
      "options list each station's deliveries, not the one in its own sector")
check(stations["Solar Plant"].title == "Solar Power Plant", "with the station's title")

local _, body = preview("supply", {config = {routes = {{from = "Solar Plant", to = "Neighbour"}}}}, supplyAnalysis)
check(body.canStart == false and body.errors.config.text:find("same sector") ~= nil,
      "a route inside one sector is explained")

local _, body = preview("supply", {config = {routes = {{from = "Refinery", to = "Solar Plant"}}}}, supplyAnalysis)
check(body.errors.config and body.errors.config.text:find("buys nothing") ~= nil,
      "a route whose ends do not trade is explained")

local _, body = preview("supply", {config = {routes = {{from = "Nowhere", to = "Refinery"}}}}, supplyAnalysis)
check(body.errors.config and body.errors.config.text:find("Nowhere") ~= nil, "an unknown station is named")

local _, body, config = preview("supply",
    {config = {routes = {{from = "Solar Plant", to = "Refinery", goods = {"Oil"}}}}}, supplyAnalysis)
check(#config.routes[1].transportable == 0 and body.errors.config ~= nil,
      "a goods filter that matches nothing is an error, not a silent empty route")

refused("supply", {config = {routes = {{from = "Refinery"}}}}, "bad_routes", "a route without 'to' is refused")
refused("supply", {config = {routes = {{from = "Refinery", to = "Refinery"}}}}, "bad_routes",
        "a route from a station to itself is refused")

-- #### MAINTENANCE #### --

print("\nmaintenance")

local status, body, config = preview("maintenance",
{
    config =
    {
        crew = "maximum",
        torpedoes = {{warhead = "neutron", rarity = "Rare", percentage = 60}, {warhead = 1, percentage = 0}},
        fighters = {{squad = 2, weaponType = "shuttle", amount = 3},
                    {squad = 0, weaponType = "Laser", rarity = 2, amount = 8}},
    },
}, baseAnalysis())
check(status == 200 and config, "a maintenance preview with purchases answers (got " .. tostring(status) .. ")")
check(config.crewAction == 2, "crew 'maximum' becomes crewAction 2")
check(#config.torpedoesToBuy == 1 and config.torpedoesToBuy[1].warhead == 2
      and config.torpedoesToBuy[1].rarity == 2 and config.torpedoesToBuy[1].percentage == 60,
      "torpedo lines are resolved to ids, and a 0% line is left out as the window does")
check(config.fightersToBuy[3] and config.fightersToBuy[3].weaponType == "shuttle"
      and config.fightersToBuy[3].rarity == 0,
      "fighters are keyed by squad index + 1; shuttles are always Common")
check(config.fightersToBuy[1] and config.fightersToBuy[1].weaponType == 3 and config.fightersToBuy[1].amount == 8,
      "armed fighters carry their weapon type id")
check(body.config.crew == "maximum" and body.config.torpedoes[1].warheadName == "Neutron"
      and body.config.fighters[1].squad == 0 and body.config.fighters[2].weaponType == "shuttle",
      "the echo speaks the request shape, ordered by squad")

check(#body.options.squads == 2 and body.options.squads[1].buyable == 8
      and #body.options.squads[1].weaponTypes == 2 and body.options.squads[2].shuttles == true
      and #body.options.squads[2].weaponTypes == 0,
      "options describe each squad and what it can take")
check(#body.options.warheads == 3, "and the warheads on offer")

-- What the console used to send: a number where the table goes.
local status, _, config = preview("maintenance", {config = {torpedoesToBuy = 0}}, baseAnalysis())
check(status == 200 and type(config.torpedoesToBuy) == "table" and type(config.fightersToBuy) == "table"
      and config.crewAction == nil,
      "a stray number is replaced with the tables the command iterates")

refused("maintenance", {config = {crew = "everyone"}}, "bad_crew", "an unknown crew action is refused")
refused("maintenance", {config = {torpedoes = {{warhead = "Photon", percentage = 10}}}}, "bad_torpedoes",
        "an unknown warhead is refused")
refused("maintenance", {config = {fighters = {{squad = 1, weaponType = 0, amount = 1},
                                              {squad = 1, weaponType = 0, amount = 2}}}},
        "bad_fighters", "the same squad twice is refused")
refused("maintenance", {config = {fighters = {{squad = 0, weaponType = 0, amount = 13}}}},
        "bad_fighters", "more fighters than a squad holds are refused")

-- #### START #### --

print("\nstart")

-- The config crosses to the agent as JSON. A sparse fighter table becomes an object with
-- string keys, and MaintenanceCommand reads hangar[key - 1], so the keys must come back
-- as numbers.
dofile("data/scripts/player/automationapi/agent.lua")
local Agent = AutomationApiAgent

local function tick(seconds)
    Mock.advanceClock(seconds)
    Mock.asPlayerAgent(1, function() Agent.update(seconds) end)
    Bridge.update(seconds)
end

Mock.simulationCalls = {}
local read = send("POST", "/ships/Trader/missions/maintenance/start",
                  {config = {fighters = {{squad = 2, weaponType = "shuttle", amount = 3}}}})
Mock.flushAsync(baseAnalysis())
Bridge.update(Config.pollInterval)
for _ = 1, 6 do tick(0.6) end

local startCall
for _, c in ipairs(Mock.simulationCalls) do
    if c.fn == "startCommand" then startCall = startCall or c end
end
check(startCall ~= nil, "the maintenance start reaches startCommand (status " .. tostring(read()) .. ")")
check(startCall and startCall.args[3].fightersToBuy[3] and startCall.args[3].fightersToBuy[3].amount == 3,
      "with the fighter order still keyed by number")

check(#Mock.errors == 0, "no errors logged")
for _, e in ipairs(Mock.errors) do print("       > " .. e) end

print("")
if failures > 0 then print(failures .. " check(s) failed"); os.exit(1) end
print("all checks passed")
