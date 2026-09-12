-- Reads a station's books out of the ship database.
--
-- Every player-foundable station that handles money runs one of the merchant scripts in
-- data/scripts/entity/merchants/, and all of them keep their state in a TradingManager
-- (data/scripts/lib/tradingmanager.lua). That state - the goods bought and sold, the
-- price factors, the trading policies, and a running total of money earned, spent and
-- taken as tax - is written into the craft's database row by the script's secure(), and
-- ShipDatabaseEntry:getSecuredScriptValues() hands it straight back.
--
-- Which is what makes this work at all. The obvious route to a station's books is the
-- Entity, and the Entity only exists while its sector is resident: a player's stations
-- sit in sectors nobody is flying through, so an Entity-based read would answer "sector
-- not loaded" for exactly the stations the owner cares about, and the alternative -
-- Galaxy():loadSector on a timer - would pay for a statistics page in server frame time.
-- The database row costs one read and is there whether or not anyone is logged in, which
-- is the same bargain every other read endpoint in this mod makes.
--
-- ### What that costs
--
-- Secured values are a snapshot, refreshed when the engine calls secure(): on unload, and
-- on the server's regular saves. A station in a sector that has been unloaded for an hour
-- reports exactly what it held at unload, which is also all that has happened to it. A
-- station in a *loaded* sector can be up to one save interval behind the live entity, so
-- `sectorLoaded` is reported alongside and is the flag to read before trusting a number
-- to the second.
--
-- ### What it cannot know
--
-- Actual traded prices. getBuyPrice/getSellPrice multiply the base price by a
-- supply/demand factor that lives in the sector's own economyupdater script and by a
-- relations factor for the counterparty, neither of which is in the database. What is
-- reported here is the base price - good.price times the station's own price factor,
-- which is the same `basePrice` the game's own trade UI shows - and it is named
-- `basePrice` rather than `price` for that reason.

package.path = package.path .. ";data/scripts/lib/?.lua"

local Json = include("automationapi/json")
local Serialize = include("automationapi/serialize")

-- Pure data: goods[name] = {name, plural, price, size, level, tags, ...}. Pulled in so a
-- production chain can be priced, since a production only names its ingredients.
include("goods")

local Economy = {}

-- A database getter can raise for a row the engine considers half-written; one bad field
-- should cost that field rather than the request.
local function safe(fn, default)
    local ok, value = pcall(fn)
    if not ok then return default end
    if value == nil then return default end

    return value
end

local function round(value)
    return math.floor(value + 0.5)
end

-- #### RECOGNISING THE SCRIPTS #### --

local MERCHANTS = "data/scripts/entity/merchants/"

-- The merchant script a station is named after, when it runs more than one. A shipyard
-- carries repairdock.lua and consumer.lua as well, and reporting "consumer" for it would
-- be true and useless.
local PRIMARY =
{
    ["factory.lua"] = "factory",
    ["tradingpost.lua"] = "tradingpost",
    ["resourcetrader.lua"] = "resourcedepot",
    ["shipyard.lua"] = "shipyard",
    ["equipmentdock.lua"] = "equipmentdock",
    ["turretfactory.lua"] = "turretfactory",
    ["fighterfactory.lua"] = "fighterfactory",
    ["researchstation.lua"] = "researchstation",
    ["militaryoutpost.lua"] = "militaryoutpost",
    ["casino.lua"] = "casino",
    ["habitat.lua"] = "habitat",
    ["biotope.lua"] = "biotope",
    ["travelhub.lua"] = "travelhub",
    ["smugglersmarket.lua"] = "smugglersmarket",
    ["repairdock.lua"] = "repairdock",
    ["consumer.lua"] = "consumer",
    ["seller.lua"] = "seller",
}

-- Order in which a station that runs several is labelled. Earlier wins.
local PRIMARY_ORDER =
{
    "factory.lua", "shipyard.lua", "turretfactory.lua", "fighterfactory.lua",
    "resourcetrader.lua", "tradingpost.lua", "equipmentdock.lua", "researchstation.lua",
    "militaryoutpost.lua", "casino.lua", "habitat.lua", "biotope.lua", "travelhub.lua",
    "smugglersmarket.lua", "repairdock.lua", "consumer.lua", "seller.lua",
}

local function basename(path)
    return string.match(tostring(path), "([^/]+)$") or tostring(path)
end

-- TradingManager:secureTradingGoods() always writes these two, which is what makes a
-- secured table recognisable without knowing which script produced it.
local function isTradingData(value)
    return type(value) == "table"
        and type(value.boughtGoods) == "table"
        and type(value.soldGoods) == "table"
end

-- factory.lua nests its trading data under `tradingData`; seller.lua, consumer.lua and
-- tradingpost.lua return the trading table itself with their own fields added to it.
local function tradingIn(values)
    if type(values) ~= "table" then return nil end
    if isTradingData(values) then return values end
    if isTradingData(values.tradingData) then return values.tradingData end

    return nil
end

-- #### GOODS #### --

-- entry:getCargo() is keyed by TradingGood userdata, which is no use for looking a good
-- up by name. Flattened once per station.
local function stockByName(cargos)
    local byName = {}
    if type(cargos) ~= "table" then return byName end

    for good, amount in pairs(cargos) do
        local ok, name = pcall(function() return good.name end)
        if ok and type(name) == "string" then
            byName[name] = (byName[name] or 0) + (tonumber(amount) or 0)
        end
    end

    return byName
end

-- Reproduces TradingManager:getMaxStock, which is what the station itself uses to decide
-- it has no room to produce into. The cargo bay is split evenly between every good the
-- station trades, so the cap on one good moves when another is added.
local function maxStockFor(size, capacity, slots)
    size = tonumber(size) or 0
    if size <= 0 or slots <= 0 then return 0 end

    local space = capacity / slots

    if space / size > 100 then
        return math.min(50000, round(space / size / 100) * 100)
    end

    return math.floor(space / size)
end

local function goodEntry(raw, factor, stock, capacity, slots)
    local described = Serialize.tradingGood(raw)
    if not described then return nil end

    local maxStock = maxStockFor(described.size, capacity, slots)
    local held = stock[described.name] or 0

    described.amount = nil
    described.stock = held
    described.maxStock = maxStock
    -- How full this good's share of the bay is. A sold good pinned at 1 is a station
    -- that has stopped producing for want of room; a bought good at 0 is one starved of
    -- an ingredient. Both are the interesting states and neither is obvious from a count.
    described.fill = maxStock > 0 and math.min(1, held / maxStock) or 0
    described.basePrice = round(Serialize.number(described.price, 0) * (factor or 1))

    return described
end

local function goodsOf(trading, stock, capacity)
    local bought, sold = trading.boughtGoods or {}, trading.soldGoods or {}

    -- The station divides its bay by however many goods it trades, counting both lists.
    local slots = 0
    for _ in pairs(bought) do slots = slots + 1 end
    for _ in pairs(sold) do slots = slots + 1 end

    local buys, sells = Json.array({}), Json.array({})

    for _, raw in pairs(bought) do
        local entry = goodEntry(raw, trading.buyPriceFactor, stock, capacity, slots)
        if entry then buys[#buys + 1] = entry end
    end

    for _, raw in pairs(sold) do
        local entry = goodEntry(raw, trading.sellPriceFactor, stock, capacity, slots)
        if entry then sells[#sells + 1] = entry end
    end

    local byName = function(a, b) return (a.name or "") < (b.name or "") end
    table.sort(buys, byName)
    table.sort(sells, byName)

    return buys, sells
end

-- #### PRODUCTION #### --

-- A production line names its ingredients and results and nothing else, so the goods
-- index supplies the price and volume each one carries.
local function chainSide(list, stock)
    local out = Json.array({})

    for _, item in pairs(list or {}) do
        local name = Serialize.string(item.name)
        local reference = name and goods and goods[name] or nil
        local amount = Serialize.number(item.amount, 0)
        local price = reference and Serialize.number(reference.price, 0) or 0

        out[#out + 1] =
        {
            name = name,
            amount = amount,
            -- ingredients only: the game treats optional as 0/1 rather than a boolean
            optional = item.optional ~= nil and item.optional ~= 0 or nil,
            price = price,
            size = reference and Serialize.number(reference.size, 0) or 0,
            value = price * amount,
            stock = stock[name or ""] or 0,
        }
    end

    return out
end

local function valueOf(side)
    local total = 0
    for _, item in ipairs(side) do total = total + (item.value or 0) end

    return total
end

-- The game builds a factory's station title out of the production's own template and the
-- good the line makes: "${good} Mine ${size}" over Ore is an Ore Mine, and the same
-- factory.lua over Energy Cell is a Solar Power Plant. `kind` is the script and cannot
-- tell those two apart, which is what made every one of them read as "factory".
--
-- This is formatFactoryName() from data/scripts/lib/productions.lua, minus the size
-- suffix: the factory's size is not in the secured data, so it is dropped rather than
-- guessed at.
local function factoryTitle(production, results)
    local template = Serialize.string(production.factory)
    if not template then return nil end

    local first = results[1]
    local reference = first and goods and goods[first.name or ""] or nil

    -- What the game falls back to when the result good is not in the index, which is
    -- what a good from another mod looks like from here.
    if not reference then return "Factory" end

    local good = Serialize.string(reference.name) or ""
    local plural = Serialize.string(reference.plural) or good

    local filled = string.gsub(template, "%${(%w+)}", function(key)
        if key == "good" or key == "prefix" then return good end
        if key == "plural" then return plural end

        return ""
    end)

    return (string.gsub(filled, "^%s*(.-)%s*$", "%1"))
end

-- #### PRODUCTION RATE #### --

-- factory.lua's own constants: no cycle is shorter than 15 seconds, and a plan with less
-- production capacity than 100 counts as 100.
local MINIMUM_TIME_TO_PRODUCE = 15.0
local MINIMUM_CAPACITY = 100

-- "faction:name" -> {blocks, capacity}. Reading a plan's statistics means loading the
-- whole plan out of the database row, which for a large station is thousands of blocks -
-- and /stations is the endpoint the poller calls on every pass. Production capacity only
-- changes when the plan does, so it is kept until the block count moves.
local capacityCache = {}

local function productionCapacityOf(entry)
    local key = tostring(safe(function() return entry.faction end, "")) .. ":"
        .. tostring(safe(function() return entry.name end, ""))
    local blocks = safe(function() return entry.numBlocks end, 0)

    local cached = capacityCache[key]
    if cached and cached.blocks == blocks then return cached.capacity end

    local capacity = safe(function() return entry:getPlan():getStats().productionCapacity end)
    capacity = tonumber(capacity)

    capacityCache[key] = {blocks = blocks, capacity = capacity}

    return capacity
end

-- Factory.refreshProductionTime() from data/scripts/entity/merchants/factory.lua. A cycle
-- takes longer the more its output is worth and the less production capacity the plan
-- has, and runs faster for higher-level goods:
--
--   timeToProduce = max(15, value of results and waste / capacity / (1 + level / 100))
--
-- Every slot runs a cycle of that length in parallel, so what a station can turn over in an
-- hour is slots * 3600 / timeToProduce - with every slot busy, which is the station's
-- ceiling rather than what it is doing right now. A cycle started with an optional
-- ingredient in the bay advances twice as fast, which is `boost`.
local function rateOf(production, slots, capacity)
    local value, level, samples = 0, 0, 0

    for _, side in ipairs({production.results or {}, production.garbages or {}}) do
        for _, item in pairs(side) do
            local reference = goods and goods[item.name or ""] or nil
            if reference then
                value = value + Serialize.number(reference.price, 0) * Serialize.number(item.amount, 0)
                level = level + (tonumber(reference.level) or 0)
                samples = samples + 1
            end
        end
    end

    if samples > 0 then level = level / samples end

    local known = capacity ~= nil
    local effective = math.max(MINIMUM_CAPACITY, capacity or 0)
    local cycle = math.max(MINIMUM_TIME_TO_PRODUCE, value / effective / (1 + level / 100))

    local optional = false
    for _, item in pairs(production.ingredients or {}) do
        if item.optional ~= nil and item.optional ~= 0 then optional = true end
    end

    return
    {
        cycleSeconds = cycle,
        cyclesPerHour = slots * 3600 / cycle,
        productionCapacity = capacity,
        -- False when the plan could not be read, in which case the game's own floor of
        -- 100 stands in for it: the slowest the station could possibly be.
        capacityKnown = known,
        boost = optional and 2 or nil,
    }
end

local function perHour(side, cyclesPerHour)
    local total = 0

    for _, item in ipairs(side) do
        item.perHour = item.amount * cyclesPerHour
        total = total + item.value * cyclesPerHour
    end

    return total
end

local function productionOf(values, stock, capacity)
    local production = values.production
    if type(production) ~= "table" then return nil end

    local ingredients = chainSide(production.ingredients, stock)
    local results = chainSide(production.results, stock)
    local garbage = chainSide(production.garbages, stock)

    -- currentProductions is one entry per cycle in flight, keyed by slot; restore()
    -- rewrites a bare number into {progress = n}, so both shapes reach the database.
    local running = Json.array({})
    for _, cycle in pairs(values.currentProductions or {}) do
        local progress = type(cycle) == "table" and cycle.progress or cycle
        running[#running + 1] = {progress = Serialize.number(progress, 0)}
    end

    local inputValue = valueOf(ingredients)
    local outputValue = valueOf(results) + valueOf(garbage)

    local slots = Serialize.number(values.maxNumProductions, 0)
    local rate = rateOf(production, slots, capacity)

    local inputPerHour = perHour(ingredients, rate.cyclesPerHour)
    local outputPerHour = perHour(results, rate.cyclesPerHour) + perHour(garbage, rate.cyclesPerHour)

    return
    {
        -- The template the game builds the station's title from, e.g. "${good} Mine ${size}",
        -- and that template resolved against the good this line makes.
        factory = Serialize.string(production.factory),
        title = factoryTitle(production, results),
        style = Serialize.string(production.factoryStyle),
        mine = production.mine == true,
        ingredients = ingredients,
        results = results,
        garbage = garbage,
        -- How many cycles the station can have in flight, and how many it does.
        slots = slots,
        running = running,
        active = #running,
        -- Base value in and out of one cycle, at the goods index's own prices. Not what
        -- the station will get for the result - that is a sale, at basePrice and then
        -- supply and demand - but it is what says whether a chain is worth running.
        inputValue = inputValue,
        outputValue = outputValue,
        margin = outputValue - inputValue,
        -- The same at full throughput for an hour, which is what makes two stations
        -- comparable: a cycle's length differs from one line to the next.
        rate = rate,
        inputValuePerHour = inputPerHour,
        outputValuePerHour = outputPerHour,
        marginPerHour = outputPerHour - inputPerHour,
        shuttleVolume = Serialize.number(values.shuttleVolume),
    }
end

-- #### PUBLIC #### --

-- The merchant scripts on a craft, and the books they keep.
--
-- Returns nil for anything that runs none of them - every ship, and the handful of
-- stations that hold no trading manager - so a caller can tell "not a trader" from "a
-- trader with nothing in it".
--
-- `cargos`/`capacity` are entry:getCargo()'s two return values, passed in rather than
-- re-read because ShipData.detail has already paid for them.
function Economy.of(entry, cargos, capacity)
    if not entry then return nil end

    local scripts = safe(function() return entry:getScripts() end, {}) or {}
    local secured = safe(function() return entry:getSecuredScriptValues() end, {}) or {}

    if type(scripts) ~= "table" then return nil end

    local stock = stockByName(cargos)
    capacity = Serialize.number(capacity, 0)

    local attached = Json.array({})
    local byBasename = {}
    local trading, production
    local anySecured = false
    local planCapacity, capacityRead = nil, false

    for index, path in pairs(scripts) do
        local name = basename(path)

        if string.sub(tostring(path), 1, #MERCHANTS) == MERCHANTS then
            attached[#attached + 1] = name
            byBasename[name] = true
        end

        local values = secured[index]

        if type(values) == "table" then
            anySecured = true
            trading = trading or tradingIn(values)
            if not production and type(values.production) == "table" and not capacityRead then
                planCapacity, capacityRead = productionCapacityOf(entry), true
            end
            production = production or productionOf(values, stock, planCapacity)
        end
    end

    if #attached == 0 and not trading then return nil end

    table.sort(attached)

    local kind
    for _, candidate in ipairs(PRIMARY_ORDER) do
        if byBasename[candidate] then
            kind = PRIMARY[candidate]
            break
        end
    end

    local result =
    {
        kind = kind or (trading and "trader" or "station"),
        scripts = attached,
        production = production,

        -- Whether the engine has ever written this craft's scripts to its database row.
        -- False for a station founded since the last save, which otherwise reads exactly
        -- like a factory with no production line and no income - a real state, and not
        -- this one. Everything below is empty rather than wrong when this is false.
        secured = anySecured,
    }

    if not trading then
        -- A merchant script with no trading manager: a repair dock, a casino. Worth
        -- reporting as a station rather than pretending it has books.
        result.goods = {buys = Json.array({}), sells = Json.array({})}
        result.earnings = {fromGoods = 0, spentOnGoods = 0, fromTax = 0, net = 0}

        return result
    end

    local buys, sells = goodsOf(trading, stock, capacity)
    local stats = type(trading.stats) == "table" and trading.stats or {}

    local fromGoods = Serialize.number(stats.moneyGainedFromGoods, 0)
    local spentOnGoods = Serialize.number(stats.moneySpentOnGoods, 0)
    local fromTax = Serialize.number(stats.moneyGainedFromTax, 0)

    result.goods = {buys = buys, sells = sells}

    -- Running totals since the station was founded, not a rate. Two readings and the
    -- time between them is what turns these into "credits per hour", which is the
    -- bridge's job rather than the mod's - see docs/api.md#get-historyeconomysummary.
    result.earnings =
    {
        fromGoods = fromGoods,
        spentOnGoods = spentOnGoods,
        fromTax = fromTax,
        net = fromGoods + fromTax - spentOnGoods,
    }

    result.settings =
    {
        buyPriceFactor = Serialize.number(trading.buyPriceFactor, 1),
        sellPriceFactor = Serialize.number(trading.sellPriceFactor, 1),
        buysFromOthers = trading.buyFromOthers ~= false,
        sellsToOthers = trading.sellToOthers ~= false,
        activelyRequest = trading.activelyRequest == true,
        activelySell = trading.activelySell == true,
        policies = Serialize.value(trading.policies) or {},
    }

    return result
end

-- A faction's own ledger: what it holds now, rather than what its stations have earned.
function Economy.faction(owner)
    local faction = owner.faction

    local resources = Json.array({})

    -- getResources() returns one value per material rather than a table, so it has to be
    -- collected into one - and the list is 1-based while Material() is 0-based.
    local raw = safe(function() return {faction:getResources()} end, {}) or {}
    local materials = safe(function() return NumMaterials() end, 0) or 0

    for value = 0, materials - 1 do
        local material = safe(function() return Material(value) end)

        resources[#resources + 1] =
        {
            material = material and Serialize.string(material.name) or tostring(value),
            value = value,
            amount = Serialize.number(raw[value + 1], 0),
        }
    end

    return
    {
        money = Serialize.number(safe(function() return faction.money end), 0),
        resources = resources,
    }
end

return Economy
