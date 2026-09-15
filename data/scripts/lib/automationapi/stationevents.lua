-- What player and alliance stations actually did: trades, production and reload catch-up.
--
-- Populated from inside the stations themselves - automationapi/stationhooks.lua wraps the
-- game's TradingManager and factory loop and pushes here through the bridge - so it records
-- with every player logged out, for as long as a station's sector is loaded. See that file
-- for what is captured and why it is the useful half of the game's economy log.
--
-- Two things are kept, and they answer different questions:
--
--   * A feed per owning faction, a ring buffer of events in the order they happened. It is
--     what the bridge's poller collects into Postgres, so it only has to hold what arrives
--     between two polls. One buffer per faction rather than per station, because a caller
--     reads a whole faction's industry in one call with one cursor.
--   * Running totals per station since the server started: cycles, slot time, and units and
--     credits per good. These are what /stations reports as `observed`, so a caller with no
--     history store still gets real rates rather than the theoretical ceiling.
--
-- Both live in memory and start empty after a restart. Every read carries `boot`, which
-- changes when that happens, so a collector can tell a restart from a quiet station.

local Json = include("automationapi/json")
local Config = include("automationapi/config")
local Serialize = include("automationapi/serialize")

local StationEvents = {}

-- factionIndex -> {events = {}, evicted = highest seq dropped from this buffer}
local feeds = {}

-- "<factionIndex>/<station>" -> running totals, see totalsFor
local totals = {}

-- Global, so one cursor covers the player and their alliance together.
local nextSeq = 0

-- Identifies this run of the server. Sequence numbers restart at zero with it, and a
-- collector keys what it stores by the pair.
local boot = (function()
    local ok, stamp = pcall(os.time)
    if ok and type(stamp) == "number" then return tostring(stamp) end

    return tostring(math.random(1, 2147483647))
end)()

local function keyOf(factionIndex, name)
    return tostring(factionIndex) .. "/" .. tostring(name)
end

local function now()
    local ok, runtime = pcall(function() return Server().unpausedRuntime end)
    return ok and tonumber(runtime) or 0
end

local function number(value)
    return Serialize.number(value, 0)
end

-- #### NORMALISING #### --

-- Payloads arrive from another VM as plain tables built by stationhooks.lua. Nothing in them
-- is trusted to be the right type, since a different mod version could be on the other end.
local function recipeOf(list)
    local out = Json.array({})

    for _, item in ipairs(type(list) == "table" and list or {}) do
        if type(item) == "table" and type(item.name) == "string" then
            out[#out + 1] =
            {
                name = item.name,
                amount = number(item.amount),
                optional = item.optional == true or nil,
            }
        end
    end

    return out
end

local DIRECTIONS = {sold = true, bought = true, consumed = true}

local normalise = {}

function normalise.trade(payload)
    if not DIRECTIONS[payload.direction] then return nil end
    if type(payload.good) ~= "string" or payload.good == "" then return nil end

    local units = number(payload.units)
    if units <= 0 then return nil end

    local price = number(payload.price)
    local event =
    {
        direction = payload.direction,
        channel = Serialize.string(payload.channel),
        good = payload.good,
        units = units,
        price = price,
        unitPrice = price / units,
        ownerAmount = number(payload.ownerAmount),
        tax = number(payload.tax),
        internal = payload.internal == true,
        ship = Serialize.string(payload.ship),
    }

    local counterparty = payload.counterparty
    if type(counterparty) == "table" then
        event.counterparty =
        {
            index = Serialize.number(counterparty.index),
            name = Serialize.string(counterparty.name),
            kind = Serialize.string(counterparty.kind),
        }
    end

    return event
end

local PRODUCTION_FIELDS =
{
    "seconds", "slotSeconds", "busySlotSeconds", "starvedSeconds", "blockedSeconds",
    "idleSeconds", "cycles", "boosted", "slots", "cycleSeconds",
}

function normalise.production(payload)
    local event = {}
    for _, field in ipairs(PRODUCTION_FIELDS) do event[field] = number(payload[field]) end

    if event.seconds <= 0 then return nil end

    event.utilization = event.slotSeconds > 0 and event.busySlotSeconds / event.slotSeconds or 0
    event.results = recipeOf(payload.results)
    event.ingredients = recipeOf(payload.ingredients)
    event.garbage = recipeOf(payload.garbage)

    return event
end

function normalise.catchup(payload)
    local event =
    {
        seconds = number(payload.seconds),
        cycles = number(payload.cycles),
        results = recipeOf(payload.results),
        ingredients = recipeOf(payload.ingredients),
        garbage = recipeOf(payload.garbage),
    }

    if event.seconds <= 0 then return nil end

    return event
end

-- #### RUNNING TOTALS #### --

local function totalsFor(factionIndex, name, at)
    local key = keyOf(factionIndex, name)
    local entry = totals[key]

    if not entry then
        entry =
        {
            since = at,
            production =
            {
                seconds = 0, slotSeconds = 0, busySlotSeconds = 0, starvedSeconds = 0,
                blockedSeconds = 0, idleSeconds = 0, cycles = 0, boosted = 0,
                catchupSeconds = 0, catchupCycles = 0,
            },
            goods = {},
            windows = 0,
            trades = 0,
        }
        totals[key] = entry
    end

    entry.last = at

    return entry
end

local function goodTotals(entry, name)
    local good = entry.goods[name]

    if not good then
        good =
        {
            made = 0, used = 0,
            sold = {units = 0, credits = 0, trades = 0},
            bought = {units = 0, credits = 0, trades = 0},
            consumed = {units = 0, credits = 0, trades = 0},
            internalIn = 0, internalOut = 0,
        }
        entry.goods[name] = good
    end

    return good
end

-- Units a number of cycles made and used, per good, from the recipe carried with them.
-- Optional ingredients only go in on a boosted cycle.
local function countRecipe(entry, event, cycles, boosted)
    for _, item in ipairs(event.results) do
        local good = goodTotals(entry, item.name)
        good.made = good.made + item.amount * cycles
    end

    for _, item in ipairs(event.garbage) do
        local good = goodTotals(entry, item.name)
        good.made = good.made + item.amount * cycles
    end

    for _, item in ipairs(event.ingredients) do
        local good = goodTotals(entry, item.name)
        good.used = good.used + item.amount * (item.optional and boosted or cycles)
    end
end

local absorb = {}

function absorb.trade(entry, event)
    local good = goodTotals(entry, event.good)
    entry.trades = entry.trades + 1

    if event.internal then
        if event.direction == "bought" then
            good.internalIn = good.internalIn + event.units
        else
            good.internalOut = good.internalOut + event.units
        end
        return
    end

    local bucket = good[event.direction]
    bucket.units = bucket.units + event.units
    bucket.credits = bucket.credits + event.price
    bucket.trades = bucket.trades + 1
end

function absorb.production(entry, event)
    local production = entry.production
    entry.windows = entry.windows + 1

    for _, field in ipairs(PRODUCTION_FIELDS) do
        if production[field] ~= nil then production[field] = production[field] + event[field] end
    end

    -- Latest wins: a station's line and slot count are a description, not a sum.
    production.slots = event.slots
    production.cycleSeconds = event.cycleSeconds

    countRecipe(entry, event, event.cycles, event.boosted)
end

function absorb.catchup(entry, event)
    local production = entry.production
    production.catchupSeconds = production.catchupSeconds + event.seconds
    production.catchupCycles = production.catchupCycles + event.cycles

    -- The catch-up takes no optional ingredients.
    countRecipe(entry, event, event.cycles, 0)
end

-- #### PUBLIC #### --

-- Called from the bridge, which is called from inside a station's own script. Returns true
-- when the event was stored.
function StationEvents.push(factionIndex, stationName, kind, payload)
    if type(stationName) ~= "string" or stationName == "" then return false end
    if tonumber(factionIndex) == nil then return false end
    if type(payload) ~= "table" or not normalise[kind] then return false end

    local event = normalise[kind](payload)
    if not event then return false end

    nextSeq = nextSeq + 1

    event.seq = nextSeq
    event.at = now()
    event.kind = kind
    event.station = stationName

    factionIndex = tonumber(factionIndex)
    event.faction = factionIndex

    if payload.x and payload.y then event.sector = Serialize.vec2(payload.x, payload.y) end

    local feed = feeds[factionIndex]
    if not feed then
        feed = {events = {}, evicted = 0}
        feeds[factionIndex] = feed
    end

    feed.events[#feed.events + 1] = event

    -- Trimmed in batches rather than one at a time, so a busy faction does not copy its
    -- whole buffer on every event.
    local cap = Config.stationEventsPerFaction
    if #feed.events > cap + math.floor(cap / 4) then
        local keep = {}
        local drop = #feed.events - cap

        feed.evicted = feed.events[drop].seq
        for index = drop + 1, #feed.events do keep[#keep + 1] = feed.events[index] end
        feed.events = keep
    end

    absorb[kind](totalsFor(factionIndex, stationName, event.at), event)

    return true
end

-- Events for the given factions, optionally one station, oldest first.
--
-- With `since`, the page starts after it and runs forward: a collector catching up wants
-- the oldest it has not seen, and `more` says to ask again from the returned cursor.
-- Without it, the newest `limit` - what a person opening a station wants to see.
--
-- `gap` means events after `since` were already evicted before anyone collected them.
function StationEvents.read(factionIndices, stationName, since, limit)
    local matched = {}
    local gap = false

    for _, factionIndex in ipairs(factionIndices) do
        local feed = feeds[tonumber(factionIndex)]

        if feed then
            if since ~= nil and since < feed.evicted then gap = true end

            for _, event in ipairs(feed.events) do
                if (since == nil or event.seq > since)
                    and (stationName == nil or event.station == stationName) then
                    matched[#matched + 1] = event
                end
            end
        end
    end

    table.sort(matched, function(a, b) return a.seq < b.seq end)

    local out = Json.array({})
    local more = false

    if since ~= nil then
        for index = 1, math.min(limit, #matched) do out[#out + 1] = matched[index] end
        more = #matched > limit
    else
        for index = math.max(1, #matched - limit + 1), #matched do out[#out + 1] = matched[index] end
    end

    -- Where to pick up. The last event handed out when the page was cut short; otherwise
    -- the global counter, which also skips everything other factions generated meanwhile.
    local cursor = nextSeq
    if more and #out > 0 then cursor = out[#out].seq end

    return out, {cursor = cursor, more = more, gap = gap}
end

-- A station's running totals since the server started, shaped for a response, or nil when
-- nothing has been recorded for it.
function StationEvents.observed(factionIndex, stationName)
    local entry = totals[keyOf(factionIndex, stationName)]
    if not entry then return nil end

    local production = {}
    for field, value in pairs(entry.production) do production[field] = value end

    production.utilization = production.slotSeconds > 0
        and production.busySlotSeconds / production.slotSeconds or nil

    -- Cycles per hour of time the station was either running or being caught up for, which
    -- is its real rate. Loaded time alone would overstate a station that is usually unloaded
    -- by exactly the share of time it spends that way.
    local span = production.seconds + production.catchupSeconds
    production.cyclesPerHour = span > 0
        and (production.cycles + production.catchupCycles) * 3600 / span or nil

    local goods = Json.array({})
    local names = {}
    for name in pairs(entry.goods) do names[#names + 1] = name end
    table.sort(names)

    for _, name in ipairs(names) do
        local good = entry.goods[name]
        local out =
        {
            name = name,
            made = good.made,
            used = good.used,
            madePerHour = span > 0 and good.made * 3600 / span or nil,
            usedPerHour = span > 0 and good.used * 3600 / span or nil,
            internalIn = good.internalIn,
            internalOut = good.internalOut,
        }

        for _, direction in ipairs({"sold", "bought", "consumed"}) do
            local bucket = good[direction]
            out[direction] =
            {
                units = bucket.units,
                credits = bucket.credits,
                trades = bucket.trades,
                -- The average price the trades actually happened at, which is what the base
                -- price in the station's books cannot say.
                unitPrice = bucket.units > 0 and bucket.credits / bucket.units or nil,
            }
        end

        goods[#goods + 1] = out
    end

    return
    {
        since = entry.since,
        last = entry.last,
        production = (entry.windows > 0 or production.catchupSeconds > 0) and production or nil,
        trades = entry.trades,
        goods = goods,
    }
end

function StationEvents.cursor()
    return nextSeq
end

function StationEvents.boot()
    return boot
end

function StationEvents.reset()
    feeds, totals, nextSeq = {}, {}, 0
end

return StationEvents
