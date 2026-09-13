-- Station activity: the trading and factory hooks, and the feeds they fill.
--
-- The hooks run inside the game's own merchant scripts, which are not in this repository,
-- so the fixtures below are small stand-ins with the same method names, the same argument
-- order and the same order of operations as tradingmanager.lua and factory.lua - money
-- first, stock after, a failed trade returning early. That order is what the hooks read
-- the unit count and the counterparty off, so it is the thing worth reproducing exactly.

package.path = "data/scripts/lib/?.lua;tests/?.lua;" .. package.path

local Mock = require("mock_avorion")
Mock.install()
Mock.reset()

local Json = require("automationapi.json")
local Config = require("automationapi.config")
local Auth = require("automationapi.auth")
local Hooks = require("automationapi.stationhooks")

dofile("data/scripts/galaxy/automationapi/bridge.lua")
local Bridge = AutomationApiBridge

local failures = 0
local function check(cond, msg)
    if cond then print("  ok   " .. msg)
    else failures = failures + 1; print("  FAIL " .. msg) end
end

-- #### WORLD #### --

Mock.addPlayer(1, "Rustypredator")
Mock.addAlliance(77, "Rusty Industries", 1, {[AlliancePrivilege.ManageShips] = true})

local function tradingGood(name, price, size)
    return {name = name, plural = name, price = price, size = size, tags = {}}
end

Mock.addShip(1, "Rusty Refinery",
{
    type = EntityType.Station, x = 12, y = -4, usableError = 2,
    cargoCapacity = 12000, cargoFree = 5000,
    scripts = {[1] = "data/scripts/entity/merchants/factory.lua"},
    secured =
    {
        [1] =
        {
            maxNumProductions = 3,
            production =
            {
                factory = "${good} Refinery ${size}",
                ingredients = {{name = "Raw Oil", amount = 10, optional = 0}},
                results = {{name = "Oil", amount = 5}},
                garbages = {},
            },
            tradingData =
            {
                stats = {moneyGainedFromGoods = 0, moneySpentOnGoods = 0, moneyGainedFromTax = 0},
                boughtGoods = {tradingGood("Raw Oil", 66, 2)},
                soldGoods = {tradingGood("Oil", 320, 2)},
            },
        },
    },
})

Mock.addShip(77, "Alliance Exchange", {type = EntityType.Station, x = 30, y = 30, usableError = 2})

Bridge.initialize()
local key = Auth.createKey(1, "tests")

local seq = 0
local function call(method, path, query)
    seq = seq + 1
    local id = "r" .. seq
    local f = assert(io.open(Config.getRequestsDir() .. "/" .. id .. ".json", "wb"))
    f:write(Json.encode{id = id, key = key, method = method, path = path,
                        query = query or {}, body = {}})
    f:close()

    Bridge.update(Config.pollInterval)

    local rf = assert(io.open(Config.getResponsesDir() .. "/" .. id .. ".json", "rb"),
                      "no response for " .. method .. " " .. path)
    local res = Json.decode(rf:read("*all")); rf:close()

    return res.status, res.body
end

-- #### A STATION'S SCRIPT VM #### --

-- What Faction(), Entity() and Sector() answer inside one station's script. Switched per
-- test, since every station runs in its own VM in game.
local factions =
{
    [1] = {index = 1, name = "Rustypredator", isPlayer = true, isAlliance = false},
    [77] = {index = 77, name = "Rusty Industries", isPlayer = false, isAlliance = true},
    [900] = {index = 900, name = "The Xsotan Traders", isPlayer = false, isAlliance = false},
}

local here = {faction = factions[1], name = "Rusty Refinery", x = 12, y = -4}

local crafts =
{
    ["hauler"] = {name = "Oil Barge", factionIndex = 900},
    ["own"] = {name = "Tug", factionIndex = 1},
}

_G.Faction = function(index)
    if index == nil then return here.faction end
    return factions[index]
end

_G.Entity = function(index)
    if index == nil then return {name = here.name} end
    return crafts[index]
end

_G.Sector = function()
    return {getCoordinates = function() return here.x, here.y end}
end

-- tradingmanager.lua, reduced to what the hooks touch, in vanilla's order of operations.
local TradingManager = {}
TradingManager.__index = TradingManager

local function newTrader()
    return setmetatable(
    {
        stock = {},
        room = 1000,
        factionPaymentFactor = 1,
        tax = 0.02,
        useUpGoodsEnabled = false,
        useTimeCounter = 0,
        stats = {moneyGainedFromGoods = 0, moneySpentOnGoods = 0, moneyGainedFromTax = 0},
        prices = {["Raw Oil"] = 70, ["Oil"] = 340},
    }, TradingManager)
end

function TradingManager:getNumGoods(name) return self.stock[name] or 0 end
function TradingManager:getMaxStock(good) return self.room end

function TradingManager:increaseGoods(name, delta)
    self.stock[name] = self:getNumGoods(name) + delta
end

function TradingManager:decreaseGoods(name, amount)
    self.stock[name] = self:getNumGoods(name) - amount
    return true
end

function TradingManager:transferMoney(owner, from, to, price)
    if from.index == to.index then return end
    self.transfers = (self.transfers or 0) + 1
end

function TradingManager:buyFromShip(shipIndex, goodName, amount)
    local ship = Entity(shipIndex)
    local shipFaction = Faction(ship.factionIndex)
    local stationFaction = Faction()

    amount = math.min(amount, self:getMaxStock() - self:getNumGoods(goodName))
    if amount <= 0 then return end

    local price = self.prices[goodName] * amount
    if shipFaction.index == stationFaction.index then price = 0 end

    self:transferMoney(stationFaction, stationFaction, shipFaction, price)
    self:increaseGoods(goodName, amount)
end

function TradingManager:sellToShip(shipIndex, goodName, amount)
    local ship = Entity(shipIndex)
    local shipFaction = Faction(ship.factionIndex)
    local stationFaction = Faction()

    amount = math.min(amount, self:getNumGoods(goodName))
    if amount <= 0 then return end

    local price = self.prices[goodName] * amount
    self:transferMoney(stationFaction, shipFaction, stationFaction, price)
    self:decreaseGoods(goodName, amount)
end

function TradingManager:buyGoods(good, amount, otherFactionIndex, monetaryTransactionOnly)
    local stationFaction = Faction()
    local otherFaction = Faction(otherFactionIndex)

    amount = math.min(self:getMaxStock(good) - self:getNumGoods(good.name), amount)
    if amount <= 0 then return 2 end

    local price = otherFaction.index == stationFaction.index and 0 or self.prices[good.name] * amount
    self:transferMoney(stationFaction, stationFaction, otherFaction, price)

    if not monetaryTransactionOnly then self:increaseGoods(good.name, amount) end

    return 0, price
end

function TradingManager:sellGoods(good, amount, otherFactionIndex)
    local stationFaction = Faction()
    local otherFaction = Faction(otherFactionIndex)

    amount = math.min(self:getNumGoods(good.name), amount)
    if amount <= 0 then return 1 end

    local price = self.prices[good.name] * amount
    self:transferMoney(stationFaction, otherFaction, stationFaction, price)
    self:decreaseGoods(good.name, amount)

    return 0, price
end

function TradingManager:useUpBoughtGoods(timeStep)
    if not self.useUpGoodsEnabled then return end

    self.useTimeCounter = self.useTimeCounter + timeStep
    if self.useTimeCounter < 120 then return end
    self.useTimeCounter = self.useTimeCounter - 120

    local amount = math.min(self:getNumGoods("Oil"), 30)
    if amount == 0 then return end

    self:decreaseGoods("Oil", amount)
    self.stats.moneyGainedFromGoods = self.stats.moneyGainedFromGoods + 400 * amount
end

check(Hooks.trading(TradingManager) == true, "the trading hooks install on a TradingManager")
check(Hooks.trading(TradingManager) == true, "and a second include does not wrap them twice")

-- #### TRADES #### --

print("\ntrades")

local trader = newTrader()

trader:buyFromShip("hauler", "Raw Oil", 200)
trader.stock["Oil"] = 500
trader:sellToShip("hauler", "Oil", 50)

local status, body = call("GET", "/stations/Rusty Refinery/events")
check(status == 200, "a station's feed answers")
check(#body.events == 2, "with one event per trade")

local bought, sold = body.events[1], body.events[2]
check(bought.kind == "trade" and bought.direction == "bought", "a docked ship selling is the station buying")
check(bought.good == "Raw Oil" and bought.units == 200, "with the good and the units taken off the stock change")
check(bought.price == 14000 and bought.unitPrice == 70, "and the price actually paid")
check(bought.tax == 280, "and the transaction tax")
check(bought.counterparty and bought.counterparty.name == "The Xsotan Traders"
      and bought.counterparty.kind == "ai", "and who was on the other side")
check(bought.ship == "Oil Barge" and bought.channel == "docked", "and the ship that docked")
check(bought.sector and bought.sector.x == 12 and bought.sector.y == -4, "and where it happened")
check(sold.direction == "sold" and sold.units == 50 and sold.price == 17000, "a docked ship buying is the station selling")
check(sold.seq > bought.seq, "in the order they happened")
check(body.boot ~= nil and body.now ~= nil, "the feed says which server run and what time it is")

trader:sellToShip("hauler", "Raw Oil", 0)
trader.stock["Oil"] = 0
trader:sellToShip("hauler", "Oil", 10)
_, body = call("GET", "/stations/Rusty Refinery/events")
check(#body.events == 2, "a trade that returned early records nothing")

local ok = pcall(TradingManager.buyFromShip, trader, "nobody", "Raw Oil", 5)
check(not ok, "an error inside vanilla still reaches its caller")
trader:buyFromShip("hauler", "Raw Oil", 10)
_, body = call("GET", "/stations/Rusty Refinery/events")
check(#body.events == 3, "and does not leave the next trade stuck behind it")

print("\nstation to station")

-- Another faction's station buying from ours, the way factory deliveries call it: the
-- partner adds the cargo itself, so no stock moves here.
trader.stock["Oil"] = 100
local code, price = trader:sellGoods(tradingGood("Oil", 320, 2), 40, 900)
check(code == 0 and price == 13600, "the wrapped call returns what vanilla returned")

-- Our own factory delivering to this station, monetary only: nothing changes hands.
trader:buyGoods(tradingGood("Raw Oil", 66, 2), 25, 1, true)

-- And a full bay, which vanilla refuses with 2.
trader.room = 0
check(trader:buyGoods(tradingGood("Raw Oil", 66, 2), 25, 900) == 2, "a refused trade still returns its code")
trader.room = 1000

_, body = call("GET", "/stations/Rusty Refinery/events", {since = tostring(body.events[3].seq)})
check(#body.events == 2, "since pages forward from a cursor")
check(body.events[1].direction == "sold" and body.events[1].channel == "direct"
      and body.events[1].units == 40, "a station buying from ours is a direct sale")
check(body.events[2].internal == true and body.events[2].units == 25 and body.events[2].price == 0,
      "a delivery between our own stations is movement, not a price")

print("\npopulation")

trader.useUpGoodsEnabled = true
trader.stock["Oil"] = 100
trader:useUpBoughtGoods(60)
trader:useUpBoughtGoods(70)
_, body = call("GET", "/stations/Rusty Refinery/events", {limit = "1"})
local consumed = body.events[1]
check(consumed.direction == "consumed" and consumed.units == 30 and consumed.price == 12000,
      "what a population eats is recorded with what it paid")

print("\nnot recorded")

here.faction = factions[900]
here.name = "Xsotan Depot"
newTrader():buyFromShip("hauler", "Raw Oil", 10)
here.faction = factions[1]
here.name = "Rusty Refinery"

_, body = call("GET", "/economy/events", {owner = "all"})
local foreign = false
for _, event in ipairs(body.events) do
    if event.station == "Xsotan Depot" then foreign = true end
end
check(not foreign, "an AI station's trades are not recorded")

-- #### PRODUCTION #### --

print("\nproduction")

local production =
{
    results = {{name = "Oil", amount = 5}},
    ingredients = {{name = "Raw Oil", amount = 10, optional = 0}, {name = "Fuel", amount = 2, optional = 1}},
    garbages = {},
}
local newProductionError = ""
local currentProductions = {}

local factoryStock = trader
local Factory = {maxNumProductions = 3, timeToProduce = 30}

function Factory.startProduction(timeStep, boosted)
    table.insert(currentProductions, {progress = 0, boosted = boosted})
end

function Factory.updateServer(timeStep) return "vanilla", timeStep end

function Factory.getNumGoods(name) return factoryStock:getNumGoods(name) end

function Factory.onRestoredFromDisk(elapsed)
    factoryStock:increaseGoods("Oil", 5 * math.floor(elapsed / 30))
end

check(Hooks.factory(Factory, function()
    return production, newProductionError, currentProductions
end), "the factory hooks install")

Factory.startProduction(1, true)
Factory.startProduction(1, false)
newProductionError = "Factory can't produce because ingredients are missing!"

local a, b = Factory.updateServer(20)
check(a == "vanilla" and b == 20, "the wrapped update returns what vanilla returned")
Factory.updateServer(20)

currentProductions = {}
newProductionError = "Factory can't produce because there is not enough cargo space for products!"
Factory.updateServer(20)

_, body = call("GET", "/stations/Rusty Refinery/events", {limit = "1"})
local window = body.events[1]
check(window.kind == "production", "a minute of production is reported as one window")
check(window.cycles == 2 and window.boosted == 1, "with the cycles started and how many were boosted")
check(window.seconds == 60 and window.slotSeconds == 180, "and the slot time it covers")
check(window.busySlotSeconds == 80, "and how much of it slots were busy")
check(window.starvedSeconds == 40 and window.blockedSeconds == 20,
      "and why the idle slots were idle")
check(math.abs(window.utilization - 80 / 180) < 1e-9, "and the utilisation that makes")
check(window.slots == 3 and window.cycleSeconds == 30, "and the line's real slot count and cycle time")
check(#window.results == 1 and window.ingredients[2].optional == true, "and the recipe it ran")

print("\nreload catch-up")

factoryStock.stock["Oil"] = 0
Factory.onRestoredFromDisk(3600)
_, body = call("GET", "/stations/Rusty Refinery/events", {limit = "1"})
check(body.events[1].kind == "catchup" and body.events[1].cycles == 120
      and body.events[1].seconds == 3600, "the reload catch-up reports the cycles it ran")

-- #### OBSERVED TOTALS #### --

print("\nobserved totals")

local observed = body.observed
check(observed ~= nil, "a station with recorded activity has observed totals")
check(observed.production.cycles == 2 and observed.production.catchupCycles == 120,
      "counting live cycles and catch-up cycles apart")
check(math.abs(observed.production.cyclesPerHour - 122 * 3600 / 3660) < 1e-6,
      "and a rate over running and caught-up time together")

local goods = {}
for _, good in ipairs(observed.goods) do goods[good.name] = good end

check(goods["Oil"].made == 610, "units made come from cycles times the recipe")
check(goods["Raw Oil"].used == 1220, "and so do units used")
check(goods["Fuel"].used == 2, "with an optional ingredient counted only on boosted cycles")
check(goods["Raw Oil"].bought.units == 210 and goods["Raw Oil"].bought.credits == 14700,
      "trades add up per good")
check(goods["Raw Oil"].internalIn == 25, "with internal deliveries counted as movement")
check(goods["Oil"].sold.units == 90 and goods["Oil"].sold.unitPrice == 340, "and an average traded price")
check(goods["Oil"].consumed.units == 30, "and consumption kept apart from sales")

local _, listing = call("GET", "/stations")
check(listing.stations[1].economy.observed ~= nil, "the listing carries observed totals too")

local _, detail = call("GET", "/stations/Rusty Refinery")
check(detail.economy.observed.production.cycles == 2, "and so does the detail")

-- #### THE FACTION FEED #### --

print("\nGET /economy/events")

here.faction = factions[77]
here.name = "Alliance Exchange"
here.x, here.y = 30, 30
newTrader():buyFromShip("hauler", "Raw Oil", 5)

status, body = call("GET", "/economy/events")
local sawAlliance = false
for _, event in ipairs(body.events) do
    if event.station == "Alliance Exchange" then sawAlliance = true end
end
check(status == 200 and not sawAlliance, "defaults to the caller's own stations")

status, body = call("GET", "/economy/events", {owner = "all", since = "0", limit = "3"})
check(#body.events == 3 and body.more == true, "a page cut short says there is more")
check(body.events[1].seq < body.events[3].seq, "oldest first when paging from a cursor")
check(body.cursor == body.events[3].seq, "and hands back the cursor to continue from")
check(body.events[1].owner and body.events[1].owner.kind == "player", "each event names its owner")

local all = {}
local since = "0"
repeat
    _, body = call("GET", "/economy/events", {owner = "all", since = since, limit = "3"})
    for _, event in ipairs(body.events) do all[#all + 1] = event end
    since = tostring(body.cursor)
until not body.more

local last = all[#all]
check(last.station == "Alliance Exchange" and last.owner.kind == "alliance",
      "paging to the end reaches the alliance's stations too")

_, body = call("GET", "/economy/events", {owner = "all", since = since})
check(#body.events == 0 and body.more == false, "and then answers empty")

print("\nthe ring buffer")

Config.stationEventsPerFaction = 4
for index = 1, 10 do newTrader():buyFromShip("hauler", "Raw Oil", index) end

_, body = call("GET", "/economy/events", {owner = "alliance", since = since})
check(body.gap == true, "a cursor older than the buffer says events were lost")
check(#body.events <= 5, "and the buffer stays bounded")

status, body = call("GET", "/economy/events", {since = "-1"})
check(status == 400, "a bad since is refused")

local encoded = Json.encode(body)
check(encoded ~= nil, "feeds encode cleanly")

check(#Mock.errors == 0, "no errors logged")
for _, e in ipairs(Mock.errors) do print("       > " .. e) end

print("")
if failures > 0 then print(failures .. " check(s) failed"); os.exit(1) end
print("all checks passed")
