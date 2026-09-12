-- Station books: /stations, /stations/{name} and /economy.
--
-- The interesting half of this file is the fixtures rather than the assertions. They
-- reproduce the exact shape the game writes into a craft's database row - a per-script
-- table of whatever that script's secure() returned - including the two awkward parts:
-- factory.lua nests its trading data one level down while every other merchant script
-- returns the trading table itself, and neither the script list nor the secured list is a
-- sequence, because both are keyed by script index.

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
Mock.addAlliance(77, "Rusty Industries", 1, {[AlliancePrivilege.ManageShips] = true})

Mock.player(1).money = 12500000
Mock.player(1).resources = {[0] = 40000, [1] = 9000}
Mock.alliances[77].money = 800000

local function good(name, price, size)
    return {name = name, plural = name, price = price, size = size,
            illegal = false, stolen = false, dangerous = false, suspicious = false,
            tags = {}}
end

-- An oil refinery: buys Energy Cells and Raw Oil, sells Oil.
Mock.addShip(1, "Rusty Refinery",
{
    type = EntityType.Station, x = 12, y = -4,
    usableError = 2, -- NotAShip, which is what the game answers for any station
    cargoCapacity = 12000, cargoFree = 5000,
    cargo =
    {
        [good("Oil", 320, 2)] = 900,
        [good("Raw Oil", 66, 2)] = 40,
        [good("Energy Cell", 61, 1)] = 1200,
    },
    -- Keyed by script index, and deliberately not 1..n: the game hands these back with
    -- whatever indices the engine assigned, and a reader that assumes a sequence sees
    -- nothing at all.
    scripts =
    {
        [3] = "data/scripts/entity/merchants/factory.lua",
        [7] = "data/scripts/entity/stationambientsound.lua",
    },
    secured =
    {
        [3] =
        {
            maxNumProductions = 3,
            shuttleVolume = 20,
            production =
            {
                factory = "${good} Refinery ${size}",
                factoryStyle = "Factory",
                ingredients = {{name = "Energy Cell", amount = 5, optional = 0},
                               {name = "Raw Oil", amount = 10, optional = 0}},
                results = {{name = "Oil", amount = 5}},
                garbages = {},
            },
            currentProductions = {[1] = {progress = 0.25}, [2] = 0.8},
            tradingData =
            {
                buyPriceFactor = 0.9,
                sellPriceFactor = 1.1,
                buyFromOthers = true,
                sellToOthers = false,
                activelyRequest = true,
                activelySell = false,
                policies = {sellsIllegal = false, buysIllegal = false},
                stats = {moneyGainedFromGoods = 4000000, moneySpentOnGoods = 1500000,
                         moneyGainedFromTax = 25000},
                boughtGoods = {good("Energy Cell", 61, 1), good("Raw Oil", 66, 2)},
                soldGoods = {good("Oil", 320, 2)},
            },
        },
    },
})

-- A trading post, which returns the trading table itself rather than nesting it.
Mock.addShip(77, "Alliance Exchange",
{
    type = EntityType.Station, x = 30, y = 30, usableError = 2,
    cargoCapacity = 4000, cargoFree = 1000,
    cargo = {[good("Ore", 30, 1)] = 500},
    scripts = {[1] = "data/scripts/entity/merchants/tradingpost.lua"},
    secured =
    {
        [1] =
        {
            buyingConfigured = true,
            buyPriceFactor = 1.0,
            sellPriceFactor = 1.2,
            policies = {},
            stats = {moneyGainedFromGoods = 90000, moneySpentOnGoods = 30000,
                     moneyGainedFromTax = 0},
            boughtGoods = {good("Ore", 30, 1)},
            soldGoods = {},
        },
    },
})

-- A ship, which the listing skips on entity type before it reads anything else.
Mock.addShip(1, "Ore Hound", {x = 12, y = -4, cargoCapacity = 500, cargoFree = 500})

-- A station with no merchant script at all: a defence platform.
Mock.addShip(1, "Gun Platform", {type = EntityType.Station, x = 1, y = 1, usableError = 2})

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

print("\nGET /stations")

local status, body = call("GET", "/stations")
check(status == 200, "returns 200")
check(Json.isArray(body.stations), "stations is a JSON array")
check(body.count == 1, "lists only stations that keep books (got " .. tostring(body.count) .. ")")
check(body.stations[1].name == "Rusty Refinery", "found the refinery")
check(body.stations[1].economy.kind == "factory", "labelled by its primary merchant script")
check(body.stations[1].economy.earnings.fromGoods == 4000000, "carries earnings in the listing")
check(body.stations[1].economy.earnings.net == 4000000 + 25000 - 1500000, "net is gained + tax - spent")
check(body.stations[1].economy.goods == nil, "the listing leaves the priced goods lists out")
check(body.stations[1].economy.stock["Oil"] == 900, "but carries units held per good, which is what a series needs")
check(body.stations[1].economy.stock["Raw Oil"] == 40, "for bought goods too")
check(body.stations[1].cargo.used == 7000, "the listing carries a cargo total")

local _, body = call("GET", "/stations", {owner = "all"})
check(body.count == 2, "owner=all merges player and alliance stations")

local _, body = call("GET", "/stations", {owner = "alliance"})
check(body.count == 1 and body.stations[1].name == "Alliance Exchange",
      "owner=alliance scopes to the alliance")
check(body.stations[1].economy.kind == "tradingpost",
      "a flat trading table is recognised too")

-- #### DETAIL #### --

print("\nGET /stations/{name}")

local status, refinery = call("GET", "/stations/Rusty%20Refinery")
check(status == 200, "returns 200")

local production = refinery.economy.production
check(production ~= nil, "reports a production line")
check(production.style == "Factory", "carries the factory style")
check(production.title == "Oil Refinery",
      "the factory template is resolved against the good the line makes")
check(#production.ingredients == 2, "two ingredients")
check(#production.results == 1, "one result")
check(production.slots == 3, "reports the production slot count")
check(production.active == 2, "counts cycles in flight, whichever shape they were stored in")
check(production.ingredients[1].price == 61, "ingredients are priced from the goods index")
check(production.inputValue == 5 * 61 + 10 * 66, "input value is price times amount")
check(production.outputValue == 5 * 320, "output value likewise")
check(production.margin == production.outputValue - production.inputValue, "margin is the difference")
check(production.results[1].stock == 900, "a chain entry carries what is in the bay")

local goods = refinery.economy.goods
check(#goods.buys == 2 and #goods.sells == 1, "goods split into bought and sold")
check(goods.sells[1].name == "Oil", "sells Oil")
check(goods.sells[1].stock == 900, "stock comes from the cargo bay")
check(goods.sells[1].basePrice == 352, "base price is the good's price times the sell factor")
check(goods.buys[1].basePrice == 55, "and the buy factor for a bought good (61 * 0.9 rounds to 55)")

-- Three goods share a 12000 bay: 4000 each. Oil is size 2, so 2000 units, and
-- 2000/100 = 20 rounds to 2000.
check(goods.sells[1].maxStock == 2000, "max stock splits the bay between every traded good")
check(math.abs(goods.sells[1].fill - 0.45) < 1e-9, "fill is stock over max stock")

local settings = refinery.economy.settings
check(settings.sellsToOthers == false, "a false setting survives rather than defaulting true")
check(settings.activelyRequest == true, "and a true one")
check(settings.buyPriceFactor == 0.9, "price factors are reported")

check(refinery.captain == nil, "detail is the full ship detail, so captainless reads as nil")
check(refinery.cargo ~= nil and #refinery.cargo.goods == 3, "and carries the full manifest")
check(refinery.sectorLoaded ~= nil, "says whether the sector is resident")

check(refinery.economy.secured == true, "says the database row has been written")

local status, body = call("GET", "/stations/Gun%20Platform")
check(status == 409 and body.error.code == "not_a_station",
      "a station with no merchant script is a 409, not an empty 200")

local status = call("GET", "/stations/Ore%20Hound")
check(status == 409, "so is a ship")

local status = call("GET", "/stations/Nothing%20Here")
check(status == 404, "an unowned name is a 404")

-- #### FACTION LEDGER #### --

print("\nGET /economy")

local status, body = call("GET", "/economy")
check(status == 200, "returns 200")
check(body.count == 1, "defaults to the calling player")
check(body.factions[1].money == 12500000, "reports the player's money")
check(body.factions[1].resources[1].material == "Iron", "resources are named by material")
check(body.factions[1].resources[1].amount == 40000, "and carry an amount")
check(body.factions[1].stations.count == 1, "counts the stations it rolled up")
check(body.factions[1].stations.earnings.fromGoods == 4000000, "and totals their earnings")

local _, body = call("GET", "/economy", {owner = "all"})
check(body.count == 2, "owner=all reports both ledgers")
check(body.factions[2].owner.kind == "alliance", "the second is the alliance")
check(body.factions[2].stations.earnings.fromGoods == 90000, "with its own station totals")

-- #### A STATION THE GAME HAS NOT SAVED YET #### --
--
-- Added last on purpose: it is a station, so it would change the counts above.

print("\na station founded since the last save")

-- A station founded since the last save has scripts and no secured values at all, which
-- otherwise reads exactly like a factory with no production line and no income.
Mock.addShip(1, "Brand New Mine",
{
    type = EntityType.Station, x = 4, y = 4, usableError = 2,
    cargoCapacity = 1000, cargoFree = 1000,
    scripts = {[1] = "data/scripts/entity/merchants/factory.lua"},
    secured = {},
})

local status, fresh = call("GET", "/stations/Brand%20New%20Mine")
check(status == 200, "an unsaved station is still a station")
check(fresh.economy.secured == false, "and says its row has not been written yet")
check(fresh.economy.production == nil, "with no production line to report")

-- everything must survive an encode/decode round trip
local encoded = Json.encode(refinery)
check(encoded ~= nil, "station detail encodes cleanly")
check(Json.decode(encoded) ~= nil, "station detail decodes cleanly")

check(#Mock.errors == 0, "no errors logged")
for _, e in ipairs(Mock.errors) do print("       > " .. e) end

print("")
if failures > 0 then print(failures .. " check(s) failed"); os.exit(1) end
print("all checks passed")
