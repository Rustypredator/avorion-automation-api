-- Stations, and what they have earned.
--
-- Everything here reads the ship database, like the rest of the read side, so it works
-- for stations in unloaded sectors and with every player logged out - which is the normal
-- state of a player's own stations. See economy.lua for where the numbers come from and
-- what a database snapshot can and cannot say.
--
-- The earnings reported are running totals since the station was founded. Turning two of
-- those into a rate is deliberately not done here: the mod holds no history, and building
-- one on the game server's tick is the thing this whole design exists to avoid. The bridge
-- keeps the samples and does the arithmetic - see docs/api.md#bridge-local-endpoints.

local Json = include("automationapi/json")
local Router = include("automationapi/router")
local Owner = include("automationapi/owner")
local Serialize = include("automationapi/serialize")
local ShipData = include("automationapi/shipdata")
local EconomyData = include("automationapi/economy")

local Economy = {}

-- Passes several return values through, which getCargo() needs: it answers with the
-- manifest and the bay's capacity, and a wrapper that kept only the first silently
-- capped every station's per-good stock at zero.
local function safe(fn, default)
    local ok, a, b = pcall(fn)
    if not ok then return default end
    if a == nil then return default end

    return a, b
end

local function ownersFor(ctx)
    if ctx.query.owner == "all" then return Owner.all(ctx) end

    return {Owner.resolve(ctx)}
end

-- Whether the station's sector is resident right now.
--
-- Worth reporting because it is exactly the condition under which the numbers below can
-- lag: secured values are rewritten when the engine saves or unloads a craft, so an
-- unloaded station's row is precisely what it held when it went quiet, while a loaded
-- one can be up to one save interval behind its live entity.
local function sectorLoaded(x, y)
    return safe(function() return Galaxy():sectorLoaded(x, y) end, false) == true
end

-- good name -> units held, across everything the station trades.
--
-- Keyed by name rather than a list of pairs, because the only thing that reads it is
-- differencing two samples good by good. An unmarked table is the right shape here: the
-- encoder's heuristic makes it an object, and an empty one encodes as {} rather than [].
local function stockMapOf(goods)
    local stock = {}
    if type(goods) ~= "table" then return stock end

    for _, side in ipairs({goods.buys or {}, goods.sells or {}}) do
        for _, entry in ipairs(side) do
            if entry.name then stock[entry.name] = entry.stock or 0 end
        end
    end

    return stock
end

-- One station, database row and books together.
local function stationOf(owner, name, full)
    local entry = ShipDatabaseEntry(owner.index, name)
    if not entry or not safe(function() return entry:exists() end, false) then return nil end

    local result = full and ShipData.detail(owner, name) or ShipData.summary(owner, name)
    if not result then return nil end

    local cargos, capacity = safe(function() return entry:getCargo() end)
    result.economy = EconomyData.of(entry, cargos, capacity)

    if result.position then
        result.sectorLoaded = sectorLoaded(result.position.x, result.position.y)
    end

    if not full then
        -- The listing is polled, so the priced goods lists and the full manifest belong
        -- to the detail call. What stays is the one thing a time series needs from every
        -- station on every pass: how many units of each good it is holding. That is what
        -- turns two samples into "this line produced 400 Oil and sold 380 of it", which
        -- the earnings totals alone cannot say - they are one number for the station.
        if result.economy then
            result.economy.stock = stockMapOf(result.economy.goods)
            result.economy.goods = nil
        end

        result.cargo =
        {
            capacity = Serialize.number(capacity, 0),
            free = Serialize.number(safe(function() return entry:getFreeCargoSpace() end), 0),
        }
        result.cargo.used = result.cargo.capacity - result.cargo.free
    end

    return result
end

-- Rolls the per-station totals up into one set of numbers for a faction.
local function totalsOf(stations)
    local totals = {fromGoods = 0, spentOnGoods = 0, fromTax = 0, net = 0}

    for _, station in ipairs(stations) do
        local earnings = station.economy and station.economy.earnings
        if earnings then
            totals.fromGoods = totals.fromGoods + (earnings.fromGoods or 0)
            totals.spentOnGoods = totals.spentOnGoods + (earnings.spentOnGoods or 0)
            totals.fromTax = totals.fromTax + (earnings.fromTax or 0)
            totals.net = totals.net + (earnings.net or 0)
        end
    end

    return totals
end

local function stationsOf(owner)
    local result = {}

    for _, name in ipairs({owner.faction:getShipNames()}) do
        -- getShipNames() returns ships and stations together. Asked first because this
        -- is the endpoint the poller calls every pass over the whole fleet, and the
        -- reads below - the script list, the secured values, the cargo bay - are three
        -- database reads that a hauler was never going to answer anything with.
        local entityType = safe(function() return owner.faction:getShipType(name) end)

        if entityType == EntityType.Station then
            local station = stationOf(owner, name, false)

            -- And a station that runs no merchant script keeps no books - a defence
            -- platform, a shipyard with nothing but a repair dock - so it is not in a
            -- listing about earnings either.
            if station and station.economy then result[#result + 1] = station end
        end
    end

    table.sort(result, function(a, b) return a.name < b.name end)

    return result
end

function Economy.register(router)

    -- Every station the caller owns, each with its books.
    --
    -- One call per key per pass is all the bridge's economy history needs, which is why
    -- the goods lists are not in it - see GET /stations/{name} for those.
    router:get("/stations", function(ctx)
        local result = Json.array({})

        for _, owner in ipairs(ownersFor(ctx)) do
            for _, station in ipairs(stationsOf(owner)) do
                result[#result + 1] = station
            end
        end

        return {stations = result, count = #result}
    end)

    -- One station in full: the database detail every craft has, plus the production
    -- chain, the goods it trades with their stock and base prices, and its earnings.
    router:get("/stations/{name}", function(ctx, params)
        local owner = Owner.findShip(ctx, params.name)

        local station = stationOf(owner, params.name, true)
        if not station then
            Router.fail(404, "no_ship_data",
                        "No database entry for '" .. params.name .. "'.")
        end

        if not station.economy then
            Router.fail(409, "not_a_station",
                        "'" .. params.name .. "' runs no merchant script, so it keeps no "
                        .. "books. Read it at /ships/" .. params.name .. " instead.")
        end

        return station
    end)

    -- The faction ledger: what the caller holds, and what their stations have made.
    --
    -- Defaults to the calling player like every other endpoint. Pass ?owner=all for the
    -- player and their alliance together, which is usually what you want here - an
    -- alliance station's earnings land in the alliance's account, not the founder's.
    router:get("/economy", function(ctx)
        local factions = Json.array({})

        for _, owner in ipairs(ownersFor(ctx)) do
            local stations = stationsOf(owner)
            local faction = EconomyData.faction(owner)

            faction.owner = Owner.describe(owner)
            faction.stations = {count = #stations, earnings = totalsOf(stations)}

            factions[#factions + 1] = faction
        end

        return {factions = factions, count = #factions}
    end)

end

return Economy
