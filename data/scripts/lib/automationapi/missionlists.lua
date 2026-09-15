-- Missions whose configuration is a list: goods to procure, goods to sell, supply routes,
-- and the torpedoes, fighters and crew bought on maintenance.
--
-- None of this is described by getConfigurableValues. Procure lists five placeholder
-- slots the command never reads, sell and maintenance hand back an empty table with no
-- default, and supply returns nothing at all. A caller working from the catalog therefore
-- sends nothing, or a number, and the vanilla command raises on pairs() over it
-- ("bad argument #1 to 'pairs' (table expected, got nil)"). The shapes the commands
-- actually read are the ones their order windows build in ui.buildConfig. They are built
-- here from a request a caller can write by hand, and echoed back the same way.
--
-- Supply is the odd one out: a route names two stations, but the command needs to know
-- which goods and which trade scripts connect them, and that only exists in the area
-- analysis. So supply routes are completed at assessment time (MissionLists.complete),
-- against the analysis, exactly as the order window does after its own analysis.

local Json = include("automationapi/json")
local Router = include("automationapi/router")
local Serialize = include("automationapi/serialize")

include("goods")

local MissionLists = {}

-- The order windows show at most this many lines. The commands would take more, but
-- nothing in vanilla has ever produced such a config, so none is accepted either.
local MAX_PROCURE = 5
local MAX_ROUTES = 5
-- torpedo lines are free-form in the window; ten covers every warhead type
local MAX_TORPEDOES = 10
-- hangars have ten squads, 0-9, and the window has one fighter line per squad
local MAX_SQUAD = 9
local MAX_FIGHTERS_PER_SQUAD = 12

-- #### SHARED #### --

local function fail(code, message)
    Router.fail(400, code, message)
end

-- Libraries that only exist in the game (and in whatever the tests stub). Loaded on
-- first use, so a missing one costs a feature rather than the whole module.
local function library(path)
    local ok, lib = pcall(include, path)
    if ok then return lib end
    return nil
end

local function listOf(value, field, code, maximum)
    if value == nil then return {} end

    if type(value) ~= "table" then
        fail(code, "'" .. field .. "' must be an array.")
    end

    -- An object, or an array with a null punched into it, has no order to keep and no
    -- line numbers to report problems against.
    local count = 0
    for _ in pairs(value) do count = count + 1 end
    if count ~= #value then
        fail(code, "'" .. field .. "' must be an array.")
    end

    if maximum and #value > maximum then
        fail(code, "'" .. field .. "' takes at most " .. maximum .. " entries.")
    end

    return value
end

local function entryOf(item, label, code)
    if type(item) ~= "table" then fail(code, label .. " must be an object.") end
    return item
end

local function numberIn(value, label, code, low, high, whole)
    if type(value) ~= "number" or value ~= value then
        fail(code, label .. " must be a number.")
    end

    if whole and value ~= math.floor(value) then
        fail(code, label .. " must be a whole number.")
    end

    if (low and value < low) or (high and value > high) then
        fail(code, label .. " must be between " .. tostring(low) .. " and " .. tostring(high) .. ".")
    end

    return value
end

-- Accepts the good's index name in any case, and answers with the exact spelling the
-- goods table (and so the command) uses.
local function goodName(value, label, code)
    if type(value) ~= "string" or value == "" then
        fail(code, label .. " needs a good 'name'.")
    end

    if type(goods) ~= "table" then return value end
    if goods[value] then return value end

    local wanted = string.lower(value)
    for name, _ in pairs(goods) do
        if string.lower(name) == wanted then return name end
    end

    fail(code, label .. ": unknown good '" .. value .. "'.")
end

-- Vanilla reads illegal/dangerous off a TradingGood, which goods[name]:good() builds.
-- The index entry carries the same flags, so that is the fallback.
local function goodFlags(name)
    local reference = type(goods) == "table" and goods[name] or nil
    if not reference then return {} end

    local ok, good = pcall(function() return reference:good() end)
    if ok and good then return good end

    return reference
end

local function tradeable(name)
    local reference = type(goods) == "table" and goods[name] or nil
    if not reference then return false end

    local tags = reference.tags or {}
    return not (tags.ore or tags.scrap)
end

local function sortedKeys(t)
    local keys = {}
    for k, _ in pairs(t or {}) do
        if type(k) == "number" then keys[#keys + 1] = k end
    end
    table.sort(keys)

    return keys
end

local function captainClasses(entry)
    local classes = {merchant = false, smuggler = false}
    if not entry then return classes end

    local CaptainUtility = library("captainutility")
    if not CaptainUtility or not CaptainUtility.ClassType then return classes end

    pcall(function()
        local captain = entry:getCaptain()
        if not captain then return end
        classes.merchant = captain:hasClass(CaptainUtility.ClassType.Merchant) == true
        classes.smuggler = captain:hasClass(CaptainUtility.ClassType.Smuggler) == true
    end)

    return classes
end

-- RarityType is an engine enum and cannot be iterated (see enums.lua). The values are
-- fixed: the maintenance window adds Rarity(0..3) for torpedoes, and Common followed by
-- Rarity(1..3) for fighters, which only works because Common is 0.
local rarityNames =
{
    [-1] = "Petty", [0] = "Common", [1] = "Uncommon", [2] = "Rare",
    [3] = "Exceptional", [4] = "Exotic", [5] = "Legendary",
}

local function rarityId(value, label, code)
    if value == nil then return 0 end

    if type(value) == "string" then
        local wanted = string.lower(value)
        for id, name in pairs(rarityNames) do
            if string.lower(name) == wanted then value = id end
        end

        if type(value) == "string" then
            fail(code, label .. ": unknown rarity '" .. value .. "'.")
        end
    end

    -- maintenance buys Common to Exceptional, the window offers nothing else
    return numberIn(value, label .. " rarity", code, 0, 3, true)
end

local function rarityList()
    local result = Json.array({})
    for id = 0, 3 do result[#result + 1] = {id = id, name = rarityNames[id]} end

    return result
end

-- Names are the enum keys ("Nuclear", "ChainGun"), not the display names: those carry
-- translator hints and could change with a locale, the keys cannot.
local function enumName(enum, id)
    for name, value in pairs(enum or {}) do
        if value == id then return name end
    end

    return nil
end

local function enumId(enum, value, label, code, what)
    if type(value) == "number" then
        if enum and not enumName(enum, value) then
            fail(code, label .. ": unknown " .. what .. " " .. tostring(value) .. ".")
        end
        return value
    end

    if type(value) == "string" and enum then
        local wanted = string.lower(value)
        for name, id in pairs(enum) do
            if string.lower(name) == wanted then return id end
        end
    end

    fail(code, label .. ": unknown " .. what .. " '" .. tostring(value) .. "'.")
end

local function warheadTypes()
    local TorpedoUtility = library("torpedoutility")
    return TorpedoUtility and TorpedoUtility.WarheadType or nil
end

-- lib/weapontype.lua defines WeaponType as a global rather than returning it.
local function weaponTypes()
    if type(WeaponType) ~= "table" then library("weapontype") end
    return type(WeaponType) == "table" and WeaponType or nil
end

-- #### CONFIG BUILDERS #### --

-- Each takes the stripped request config and rewrites it in place into what the command
-- reads. The request fields are removed, so nothing the command does not expect is left
-- lying around in a config the game will persist.
local builders = {}

-- {"goods": [{"name": "Energy Cell", "amount": 500, "stolen": false}]}
function builders.procure(config)
    local list = listOf(config.goods, "goods", "bad_goods", MAX_PROCURE)

    local toBuy = {}
    for i, raw in ipairs(list) do
        local label = "goods[" .. i .. "]"
        local item = entryOf(raw, label, "bad_goods")

        toBuy[i] =
        {
            name = goodName(item.name, label, "bad_goods"),
            amount = numberIn(item.amount, label .. " amount", "bad_goods", 0, nil, true),
            stolen = item.stolen == true,
            -- the order window line it came from; only the window reads it back
            slot = i,
        }
    end

    config.goodsToBuy = toBuy
    -- what ProcureCommand's ui.buildConfig writes alongside
    config.goods = {}
    config.numSelectableGoods = MAX_PROCURE
end

-- {"goods": [{"name": "Energy Cell", "amount": 500, "stolen": false}]}
function builders.sell(config)
    local list = listOf(config.goods, "goods", "bad_goods", nil)

    local toSell = {}
    for i, raw in ipairs(list) do
        local label = "goods[" .. i .. "]"
        local item = entryOf(raw, label, "bad_goods")

        toSell[i] =
        {
            goodName = goodName(item.name, label, "bad_goods"),
            amount = numberIn(item.amount, label .. " amount", "bad_goods", 0, nil, true),
            stolen = item.stolen == true,
        }
    end

    config.goodsToSell = toSell
    config.goods = nil
end

-- {"routes": [{"from": "Solar Plant", "to": "Oil Refinery", "goods": ["Energy Cell"]}]}
-- goods is optional and narrows what is carried; the goods themselves come from the
-- analysis, see MissionLists.complete.
function builders.supply(config)
    local list = listOf(config.routes, "routes", "bad_routes", MAX_ROUTES)

    local routes = {}
    for i, raw in ipairs(list) do
        local label = "routes[" .. i .. "]"
        local item = entryOf(raw, label, "bad_routes")

        if type(item.from) ~= "string" or item.from == "" then
            fail("bad_routes", label .. " needs 'from', the name of the station to load at.")
        end
        if type(item.to) ~= "string" or item.to == "" then
            fail("bad_routes", label .. " needs 'to', the name of the station to deliver to.")
        end
        if item.from == item.to then
            fail("bad_routes", label .. " starts and ends at the same station.")
        end

        local wanted
        if item.goods ~= nil then
            wanted = {}
            for j, name in ipairs(listOf(item.goods, label .. ".goods", "bad_routes", nil)) do
                wanted[j] = goodName(name, label .. ".goods[" .. j .. "]", "bad_routes")
            end
        end

        -- transportable is never taken from the caller: it names the trade scripts the
        -- ship buys and sells through, and is always derived from the analysis
        routes[i] = {from = item.from, to = item.to, goods = wanted}
    end

    config.routes = routes
end

local crewActions = {none = false, required = 1, maximum = 2}
local crewNames = {[1] = "required", [2] = "maximum"}

-- {"crew": "required",
--  "torpedoes": [{"warhead": "Neutron", "rarity": "Rare", "percentage": 50}],
--  "fighters": [{"squad": 0, "weaponType": "ChainGun", "rarity": 2, "amount": 12}]}
-- percentage is the share of free torpedo storage to fill; squad is the hangar squad
-- index (0-9); weaponType "shuttle" buys boarding shuttles.
function builders.maintenance(config)
    local crew = config.crew
    config.crew = nil
    config.crewAction = nil

    if crew ~= nil then
        local action = crewActions[string.lower(tostring(crew))]
        if action == nil then
            fail("bad_crew", "'crew' must be one of none, required, maximum.")
        end
        config.crewAction = action or nil
    end

    local torpedoes = listOf(config.torpedoes, "torpedoes", "bad_torpedoes", MAX_TORPEDOES)
    config.torpedoes = nil

    local torpedoOrders = {}
    for i, raw in ipairs(torpedoes) do
        local label = "torpedoes[" .. i .. "]"
        local item = entryOf(raw, label, "bad_torpedoes")

        local warhead = enumId(warheadTypes(), item.warhead, label, "bad_torpedoes", "warhead")
        local rarity = rarityId(item.rarity, label, "bad_torpedoes")
        local percentage = numberIn(item.percentage, label .. " percentage", "bad_torpedoes", 0, 100)

        -- the window leaves a line at 0% out of the config altogether
        if percentage > 0 then
            torpedoOrders[#torpedoOrders + 1] = {warhead = warhead, rarity = rarity, percentage = percentage}
        end
    end

    config.torpedoesToBuy = torpedoOrders

    local fighters = listOf(config.fighters, "fighters", "bad_fighters", MAX_SQUAD + 1)
    config.fighters = nil

    -- Keyed by squad index + 1, because MaintenanceCommand reads hangar[i - 1] off the
    -- key. The table is sparse on purpose; the agent restores the keys after JSON.
    local fighterOrders = {}
    for i, raw in ipairs(fighters) do
        local label = "fighters[" .. i .. "]"
        local item = entryOf(raw, label, "bad_fighters")

        local squad = numberIn(item.squad, label .. " squad", "bad_fighters", 0, MAX_SQUAD, true)
        if fighterOrders[squad + 1] then
            fail("bad_fighters", label .. ": squad " .. squad .. " is already listed.")
        end

        local weaponType
        local rarity
        if type(item.weaponType) == "string" and string.lower(item.weaponType) == "shuttle" then
            -- the window only offers Common for shuttles; there are no others
            weaponType = "shuttle"
            rarity = 0
        else
            weaponType = enumId(weaponTypes(), item.weaponType, label, "bad_fighters", "weapon type")
            rarity = rarityId(item.rarity, label, "bad_fighters")
        end

        local amount = numberIn(item.amount, label .. " amount", "bad_fighters",
                                0, MAX_FIGHTERS_PER_SQUAD, true)

        if amount > 0 then
            fighterOrders[squad + 1] = {weaponType = weaponType, rarity = rarity, amount = amount}
        end
    end

    config.fightersToBuy = fighterOrders
end

function MissionLists.handles(key)
    return builders[key] ~= nil
end

function MissionLists.build(key, config)
    local builder = builders[key]
    if builder then builder(config) end
end

-- #### COMPLETION #### --

local completers = {}

local function stationsByName(analysis)
    local result = {}
    if type(analysis) ~= "table" or type(analysis.stations) ~= "table" then return result end

    for _, station in pairs(analysis.stations) do
        if type(station) == "table" and station.name then result[station.name] = station end
    end

    return result
end

-- Fills each route's transportable list from the analysis, the way the order window's
-- refreshComboBoxes does, and explains the first route that cannot be flown. Vanilla
-- quietly skips such a route and only then complains that nothing can be flown at all,
-- which leaves a caller guessing which of five routes is wrong.
function completers.supply(command, owner, shipName, area)
    local analysis = area.analysis
    local stations = stationsByName(analysis)
    local ship = ShipDatabaseEntry(owner.index, shipName)

    local problem
    local function report(text)
        problem = problem or text
    end

    for i, route in ipairs(command.config.routes or {}) do
        route.transportable = {}

        local label = "Route " .. i
        local from, to = stations[route.from], stations[route.to]

        if not from then
            report(label .. ": '" .. route.from .. "' is not one of your stations that trades goods.")
        elseif not to then
            report(label .. ": '" .. route.to .. "' is not one of your stations that trades goods.")
        else
            local fromEntry = ShipDatabaseEntry(owner.index, route.from)
            local toEntry = ShipDatabaseEntry(owner.index, route.to)
            local fx, fy = fromEntry:getCoordinates()
            local tx, ty = toEntry:getCoordinates()

            local match
            for _, deliverable in pairs(command:detectDeliverableStations(owner.index, from, analysis)) do
                if deliverable.station.name == route.to then match = deliverable end
            end

            if fx == tx and fy == ty then
                report(label .. ": both stations are in the same sector.")
            elseif not match then
                report(label .. ": '" .. route.to .. "' buys nothing '" .. route.from .. "' sells.")
            else
                for _, transportable in pairs(match.transportable) do
                    local chosen = route.goods == nil
                    for _, name in ipairs(route.goods or {}) do
                        if name == transportable.name then chosen = true end
                    end

                    if chosen then route.transportable[#route.transportable + 1] = transportable end
                end

                if #route.transportable == 0 then
                    report(label .. ": none of the chosen goods go from '" .. route.from
                           .. "' to '" .. route.to .. "'.")
                elseif ship and (command:blockedByRing(ship, fromEntry) or command:blockedByRing(ship, toEntry)) then
                    report(label .. ": the ship cannot cross the rift to reach both stations.")
                end
            end
        end
    end

    return problem
end

-- Returns a plain error string, or nil when the config is complete.
function MissionLists.complete(key, command, owner, shipName, area)
    local completer = completers[key]
    if not completer then return nil end

    local ok, problem = pcall(completer, command, owner, shipName, area)
    if not ok then
        return "The routes could not be matched against the area analysis: " .. tostring(problem)
    end

    return problem
end

-- #### DESCRIPTION #### --

local describers = {}

function describers.procure(config, result)
    local list = Json.array({})

    for _, index in ipairs(sortedKeys(config.goodsToBuy)) do
        local item = config.goodsToBuy[index]
        if type(item) == "table" then
            list[#list + 1] =
            {
                name = Serialize.string(item.name),
                amount = Serialize.number(item.amount, 0),
                stolen = item.stolen == true,
            }
        end
    end

    result.goods = list
    result.goodsToBuy = nil
    result.numSelectableGoods = nil
end

function describers.sell(config, result)
    local list = Json.array({})

    for _, index in ipairs(sortedKeys(config.goodsToSell)) do
        local item = config.goodsToSell[index]
        if type(item) == "table" then
            list[#list + 1] =
            {
                name = Serialize.string(item.goodName),
                amount = Serialize.number(item.amount, 0),
                stolen = item.stolen == true,
            }
        end
    end

    result.goods = list
    result.goodsToSell = nil
end

function describers.supply(config, result)
    local list = Json.array({})

    for _, index in ipairs(sortedKeys(config.routes)) do
        local route = config.routes[index]
        if type(route) == "table" then
            local carried = Json.array({})
            for _, transportable in ipairs(route.transportable or {}) do
                carried[#carried + 1] = Serialize.string(transportable.name)
            end

            list[#list + 1] =
            {
                from = Serialize.string(route.from),
                to = Serialize.string(route.to),
                goods = route.goods and Json.array(Serialize.value(route.goods)) or nil,
                -- what the ship will actually carry, once matched against the analysis
                carried = carried,
            }
        end
    end

    result.routes = list
end

function describers.maintenance(config, result)
    result.crew = crewNames[config.crewAction] or "none"
    result.crewAction = nil

    local warheads = warheadTypes()
    local torpedoes = Json.array({})
    for _, index in ipairs(sortedKeys(config.torpedoesToBuy)) do
        local order = config.torpedoesToBuy[index]
        if type(order) == "table" then
            torpedoes[#torpedoes + 1] =
            {
                warhead = Serialize.number(order.warhead),
                warheadName = enumName(warheads, order.warhead),
                rarity = Serialize.number(order.rarity),
                rarityName = rarityNames[order.rarity],
                percentage = Serialize.number(order.percentage, 0),
            }
        end
    end
    result.torpedoes = torpedoes
    result.torpedoesToBuy = nil

    local weapons = weaponTypes()
    local fighters = Json.array({})
    for _, index in ipairs(sortedKeys(config.fightersToBuy)) do
        local order = config.fightersToBuy[index]
        if type(order) == "table" then
            local shuttle = order.weaponType == "shuttle"
            fighters[#fighters + 1] =
            {
                squad = index - 1,
                weaponType = shuttle and "shuttle" or Serialize.number(order.weaponType),
                weaponTypeName = shuttle and "shuttle" or enumName(weapons, order.weaponType),
                rarity = Serialize.number(order.rarity),
                rarityName = rarityNames[order.rarity],
                amount = Serialize.number(order.amount, 0),
            }
        end
    end
    result.fighters = fighters
    result.fightersToBuy = nil
end

-- Rewrites the generic echo in `result` into the request shape.
function MissionLists.describe(key, config, result)
    local describer = describers[key]
    if describer then describer(config or {}, result) end
end

-- #### OPTIONS #### --

-- What a caller may put in the lists, as the order window would offer it: the goods on
-- sale in the area, the cargo that would sell, the station pairs that trade. All of it
-- depends on the ship, its captain or the analysis, so it rides along with a preview.
local optionBuilders = {}

-- The window's good combo boxes, ProcureCommand ui.refresh: a normal captain picks from
-- the legal, non-dangerous goods sold in the area; a smuggler from everything sold there
-- plus goods only obtainable illegally; a merchant from anything legal, at double the
-- price for goods the area does not sell.
function optionBuilders.procure(command, owner, shipName, area)
    local analysis = area.analysis or {}
    local classes = captainClasses(ShipDatabaseEntry(owner.index, shipName))

    local list = Json.array({})
    local seen = {}

    local function add(name, availability)
        if seen[name] then return end
        seen[name] = true
        list[#list + 1] = {name = name, availability = availability}
    end

    local inArea = {}
    for name, _ in pairs(analysis.goodsInArea or {}) do inArea[#inArea + 1] = name end
    table.sort(inArea)

    for _, name in ipairs(inArea) do
        local flags = goodFlags(name)
        if classes.smuggler and not classes.merchant then
            add(name, "area")
        elseif classes.merchant then
            if not flags.illegal then add(name, "area") end
        elseif not flags.illegal and not flags.dangerous then
            add(name, "area")
        end
    end

    if classes.merchant then
        local others = {}
        for name, _ in pairs(goods or {}) do
            if not seen[name] and tradeable(name) and not goodFlags(name).illegal then
                others[#others + 1] = name
            end
        end
        table.sort(others)
        -- the captain can get these anyway, for double the usual price
        for _, name in ipairs(others) do add(name, "elsewhere") end
    elseif classes.smuggler then
        local others = {}
        for name, _ in pairs(analysis.smugglerGoodsInArea or {}) do
            if not seen[name] then others[#others + 1] = name end
        end
        table.sort(others)
        -- only obtainable illegally, and flagged stolen
        for _, name in ipairs(others) do add(name, "stolen") end
    end

    return
    {
        goods = list,
        maxGoods = MAX_PROCURE,
        -- the window only shows the "procure illegally" checkbox to smugglers
        stolenAllowed = classes.smuggler,
        captain = classes,
    }
end

-- SellCommand's cargo list: every sellable good on board, and whether this captain can
-- sell it in this area.
function optionBuilders.sell(command, owner, shipName, area)
    local analysis = area.analysis or {}
    local entry = ShipDatabaseEntry(owner.index, shipName)
    local classes = captainClasses(entry)

    local cargo = entry and entry:getCargo() or {}
    local demand = analysis.goodsInDemand or {}
    local supply = analysis.goodsInSupply or {}

    local list = Json.array({})
    for good, amount in pairs(cargo) do
        local name = good.name
        if type(name) == "string" and tradeable(name) then
            local special = good.stolen or good.illegal or good.dangerous or good.suspicious
            local sellable = false

            if classes.merchant and not good.stolen and not good.illegal then
                sellable = true
            elseif demand[name] and not special then
                sellable = true
            elseif classes.smuggler and (demand[name] or supply[name]) then
                -- smugglers also sell special cargo into demand, and anything into supply
                sellable = true
            end

            local described = Serialize.tradingGood(good, amount)
            described.name = name
            described.sellable = sellable
            list[#list + 1] = described
        end
    end

    table.sort(list, function(a, b) return a.name < b.name end)

    return {cargo = list, captain = classes}
end

-- The window's from/to combo boxes: every station of the owner that trades, and for each
-- the stations it can deliver to, with the goods that would go along.
function optionBuilders.supply(command, owner, shipName, area)
    local analysis = area.analysis or {}
    local ship = ShipDatabaseEntry(owner.index, shipName)

    local list = Json.array({})
    for _, station in pairs(analysis.stations or {}) do
        local entry = ShipDatabaseEntry(owner.index, station.name)

        if entry then
            local x, y = entry:getCoordinates()
            local deliveries = Json.array({})

            for _, deliverable in pairs(command:detectDeliverableStations(owner.index, station, analysis)) do
                local target = ShipDatabaseEntry(owner.index, deliverable.station.name)

                local carried = Json.array({})
                local seen = {}
                for _, transportable in pairs(deliverable.transportable) do
                    if not seen[transportable.name] then
                        seen[transportable.name] = true
                        carried[#carried + 1] = transportable.name
                    end
                end
                table.sort(carried)

                deliveries[#deliveries + 1] =
                {
                    to = deliverable.station.name,
                    goods = carried,
                    -- the window greys these out: without rift passage the ship cannot
                    -- reach both sides of the ring
                    blocked = ship ~= nil and target ~= nil
                              and (command:blockedByRing(ship, entry) or command:blockedByRing(ship, target)),
                }
            end

            table.sort(deliveries, function(a, b) return a.to < b.to end)

            list[#list + 1] =
            {
                name = station.name,
                title = Serialize.displayName(entry:getTitle()),
                position = Serialize.vec2(x, y),
                deliveries = deliveries,
            }
        end
    end

    table.sort(list, function(a, b) return a.name < b.name end)

    return {stations = list, maxRoutes = MAX_ROUTES}
end

-- MaintenanceCommand's torpedo and fighter lines: the warheads sold around the ship, and
-- per hangar squad what could be bought for it.
function optionBuilders.maintenance(command, owner, shipName, area)
    local entry = ShipDatabaseEntry(owner.index, shipName)
    local x, y = entry:getCoordinates()

    local warheadEnum = warheadTypes() or {}
    local warheads = Json.array({})
    local offered

    pcall(function()
        local TorpedoGenerator = library("torpedogenerator")
        local captain = entry:getCaptain()
        local generator = TorpedoGenerator(Seed(captain.name .. tostring(x) .. tostring(y) .. tostring(GameSeed())))
        offered = generator:getWarheadProbability(x, y)
    end)

    for name, id in pairs(warheadEnum) do
        if not offered or offered[id] then warheads[#warheads + 1] = {id = id, name = name} end
    end
    table.sort(warheads, function(a, b) return a.id < b.id end)

    local weaponEnum = weaponTypes() or {}
    local weapons = Json.array({})
    pcall(function()
        for id, probability in pairs(Balancing_GetWeaponProbability(x, y)) do
            local name = enumName(weaponEnum, id)
            if probability > 0 and name then weapons[#weapons + 1] = {id = id, name = name} end
        end
    end)
    table.sort(weapons, function(a, b) return a.id < b.id end)

    local squads = Json.array({})
    local hangar = {}
    pcall(function() hangar = entry:getLightweightHangar() or {} end)

    for index = 0, MAX_SQUAD do
        local squad = hangar[index]
        if squad then
            -- what the squad already flies decides what the window offers for it
            local example
            pcall(function() example = squad:getBlueprint() or squad:getFighter(0) end)

            local fighterType = example and example.type
            local types = FighterType or {}
            local armed = not example or fighterType == types.Fighter
            local shuttles = not example or fighterType == types.CrewShuttle

            local count = Serialize.number(squad.numFighters, 0)

            squads[#squads + 1] =
            {
                squad = index,
                name = Serialize.string(squad.name),
                fighters = count,
                buyable = math.max(0, MAX_FIGHTERS_PER_SQUAD - count),
                weaponTypes = armed and weapons or Json.array({}),
                shuttles = shuttles,
            }
        end
    end

    return
    {
        crew = Json.array({"none", "required", "maximum"}),
        rarities = rarityList(),
        warheads = warheads,
        squads = squads,
    }
end

-- Returns the options table, or nil for missions that have none. Never raises: a
-- preview is still worth having without them.
function MissionLists.options(key, command, owner, shipName, area)
    local builder = optionBuilders[key]
    if not builder then return nil end

    local ok, options = pcall(builder, command, owner, shipName, area)
    if not ok then
        return {error = "The choices for this mission could not be read: " .. tostring(options)}
    end

    return options
end

return MissionLists
