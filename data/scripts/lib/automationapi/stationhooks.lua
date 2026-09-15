-- Station activity, recorded where it happens.
--
-- The game narrates every trade a station makes into its owner's economy log: Faction:pay
-- and Faction:receive take a description, and the engine files it. Nothing reads that log
-- back - there is no getter and no callback - so the API cannot open it. What it can do is
-- sit in front of the same calls. Every one of those log entries is written by Lua that a
-- mod is allowed to extend, and this module is that extension:
--
--   data/scripts/lib/tradingmanager.lua        TradingManager, behind every merchant script
--   data/scripts/entity/merchants/factory.lua  the production loop itself
--
-- Both of those files in this mod are appended to the game's copy - Avorion inserts a
-- mod's file ahead of the vanilla file's final `return` - and do nothing but hand the
-- vanilla locals to the functions below.
--
-- What comes out is better than the log would have been. The log is prose for a human;
-- this is the good, the units, the price actually paid after supply, demand and relations,
-- the counterparty, and - which the log never says at all - how many production cycles a
-- factory really ran and why its idle slots were idle.
--
-- ### Where it runs, and what that rules out
--
-- Inside station scripts: one VM per station, on whichever thread the station's sector is
-- updated by. So this module must never touch anything but its own station and the bridge,
-- must never raise into vanilla code, and must never make a trade fail. Every wrapper calls
-- the original unconditionally and records around it inside pcall.
--
-- Events go to the galaxy bridge with Galaxy():invokeFunction, the same call the player
-- agent uses for ship events.
--
-- ### What it does not see
--
-- Nothing runs in an unloaded sector. That costs no money: a player station trades with
-- nothing while unloaded, and the game's only catch-up on reload is production, which
-- Factory.onRestoredFromDisk runs in one step and this reports as a `catchup` event.
-- AI stations top their stock up on reload too, but AI stations are not recorded.

local StationHooks = {}

local BRIDGE_SCRIPT = "data/scripts/galaxy/automationapi/bridge.lua"

-- Production is counted continuously but reported in windows. A factory starts a cycle every
-- few seconds, and one cross-VM call per cycle would cost the server more than the
-- information is worth.
StationHooks.productionWindow = 60

-- `unpack` moved between Lua versions; the game's own scripts use the global.
local unpack = table.unpack or unpack

-- Tables already wrapped, so a script VM that includes a file twice does not record twice.
-- Kept here rather than as a field on the table: a Factory is a script namespace the
-- engine resolves names in, and has no business carrying a flag of ours.
local hooked = setmetatable({}, {__mode = "k"})

local function pack(...)
    return {n = select("#", ...), ...}
end

local function logError(format, ...)
    pcall(eprint, "AutomationAPI: " .. format, ...)
end

local function safe(fn, default)
    local ok, value = pcall(fn)
    if not ok or value == nil then return default end

    return value
end

-- #### IDENTITY #### --

local function factionKind(faction)
    if safe(function() return faction.isPlayer end, false) then return "player" end
    if safe(function() return faction.isAlliance end, false) then return "alliance" end

    return "ai"
end

-- The station this script is attached to, or nil if it is not one worth recording.
--
-- Asked at the moment of recording rather than cached: stations change hands, and an AI
-- station a player has just bought should start reporting on its next trade.
local function station()
    local faction = safe(function() return Faction() end)
    if not faction or factionKind(faction) == "ai" then return nil end

    local entity = safe(function() return Entity() end)
    if not entity then return nil end

    local name = safe(function() return entity.name end)
    if type(name) ~= "string" or name == "" then return nil end

    local ok, x, y = pcall(function() return Sector():getCoordinates() end)

    return
    {
        index = safe(function() return faction.index end),
        name = name,
        x = ok and tonumber(x) or nil,
        y = ok and tonumber(y) or nil,
    }
end

local function describeFaction(faction)
    if not faction then return nil end

    return
    {
        index = safe(function() return faction.index end),
        name = safe(function() return faction.name end),
        kind = factionKind(faction),
    }
end

-- Fire and forget. The payload crosses a VM boundary, so it is plain tables only.
local function push(identity, kind, payload)
    payload.x = identity.x
    payload.y = identity.y

    local ok, err = pcall(function()
        Galaxy():invokeFunction(BRIDGE_SCRIPT, "pushStationEvent",
                                identity.index, identity.name, kind, payload)
    end)

    if not ok then logError("station event for %s failed: %s", tostring(identity.name), tostring(err)) end
end

-- #### TRADES #### --

-- The trade being recorded in this VM, or nil. A VM runs one call at a time, so one slot
-- is enough; a trade entry point reached from inside another (a vanilla change, or another
-- mod) simply belongs to the outer one.
local open

local function settleTrade(ctx)
    if not ctx.units or ctx.units <= 0 then return end

    local identity = station()
    if not identity then return end

    local price = ctx.price or 0

    push(identity, "trade",
    {
        direction = ctx.direction,
        channel = ctx.channel,
        good = ctx.good,
        units = ctx.units,
        -- What the counterparty paid or was paid, which is the price the trade happened at.
        price = price,
        -- What actually moved through the owner's account. Differs from `price` only for
        -- stations with a faction payment factor, which is how consumers take goods in.
        ownerAmount = ctx.ownerAmount or 0,
        tax = ctx.tax or 0,
        -- Goods moved between a faction's own craft, or to a member of its alliance, change
        -- hands for nothing. Counted as movement, never as a price.
        internal = ctx.internal == true,
        counterparty = ctx.counterparty,
        ship = ctx.ship,
    })
end

-- Wraps one trade entry point.
--
-- `prepare` runs before the original with its arguments; `settle` after, with its return
-- values. Both are optional and both run under pcall - a failure in either loses the event,
-- never the trade.
local function recordedTrade(original, direction, channel, prepare, settle)
    return function(self, ...)
        if open then return original(self, ...) end

        local ctx = {direction = direction, channel = channel}
        if prepare then pcall(prepare, ctx, self, ...) end

        open = ctx
        local results = pack(pcall(original, self, ...))
        open = nil

        if not results[1] then error(results[2], 0) end

        pcall(function()
            if settle then settle(ctx, self, results) end
            settleTrade(ctx)
        end)

        return unpack(results, 2, results.n)
    end
end

local function shipName(shipIndex)
    return safe(function()
        local ship = Entity(shipIndex)
        return ship and ship.name or nil
    end)
end

-- A good is either the TradingGood userdata or a name, depending on the caller.
local function goodName(good)
    if type(good) == "string" then return good end

    return safe(function() return good.name end)
end

function StationHooks.trading(TradingManager)
    if type(TradingManager) ~= "table" then return false end
    if hooked[TradingManager] then return true end
    hooked[TradingManager] = true

    -- Every trade with another faction goes through here, and it is the only place that
    -- knows who is on the other side and what the money was.
    local transferMoney = TradingManager.transferMoney
    if type(transferMoney) == "function" then
        TradingManager.transferMoney = function(self, owner, from, to, price, ...)
            local ctx = open

            if ctx and not ctx.transferred then
                pcall(function()
                    ctx.transferred = true
                    ctx.price = tonumber(price) or 0

                    local stationPays = owner.index == from.index
                    -- Price zero is the game's own marker for goods moving inside one faction
                    -- or to a member of its alliance (getBuyPrice returns 0 for both), which
                    -- are different factions and so would otherwise read as a free sale.
                    ctx.internal = from.index == to.index or ctx.price == 0
                    ctx.counterparty = describeFaction(stationPays and to or from)

                    if not ctx.internal then
                        local factor = tonumber(self.factionPaymentFactor) or 1
                        ctx.ownerAmount = ctx.price * factor
                        ctx.tax = math.floor(ctx.price * (tonumber(self.tax) or 0) + 0.5)
                    end
                end)
            end

            return transferMoney(self, owner, from, to, price, ...)
        end
    end

    -- The unit count, taken from the stock change the trade itself makes. Only the first
    -- good touched inside a trade counts: a trade is one good.
    local function counted(original)
        return function(self, name, amount, ...)
            local ctx = open

            if ctx and (ctx.good == nil or ctx.good == name) then
                pcall(function()
                    ctx.good = name
                    ctx.units = (ctx.units or 0) + (tonumber(amount) or 0)
                end)
            end

            return original(self, name, amount, ...)
        end
    end

    if type(TradingManager.increaseGoods) == "function" then
        TradingManager.increaseGoods = counted(TradingManager.increaseGoods)
    end
    if type(TradingManager.decreaseGoods) == "function" then
        TradingManager.decreaseGoods = counted(TradingManager.decreaseGoods)
    end

    -- A docked ship selling to the station, and buying from it. Nothing is returned; a trade
    -- happened if money was transferred.
    local function docked(ctx, self, shipIndex)
        ctx.ship = shipName(shipIndex)
    end

    local function onlyIfTransferred(ctx)
        if not ctx.transferred then ctx.units = nil end
    end

    if type(TradingManager.buyFromShip) == "function" then
        TradingManager.buyFromShip = recordedTrade(TradingManager.buyFromShip, "bought", "docked",
                                                   docked, onlyIfTransferred)
    end
    if type(TradingManager.sellToShip) == "function" then
        TradingManager.sellToShip = recordedTrade(TradingManager.sellToShip, "sold", "docked",
                                                  docked, onlyIfTransferred)
    end

    -- Station to station: another station's shuttles, and traders that never dock. These
    -- return 0 on success, and with monetaryTransactionOnly they move no stock at all - the
    -- caller adds the cargo itself - so the unit count is the one the function clips to.
    if type(TradingManager.buyGoods) == "function" then
        TradingManager.buyGoods = recordedTrade(TradingManager.buyGoods, "bought", "direct",
            function(ctx, self, good, amount)
                local name = goodName(good)
                local room = self:getMaxStock(good) - self:getNumGoods(name)
                ctx.clipped = math.min(room, tonumber(amount) or 0)
                ctx.clippedGood = name
            end,
            function(ctx, self, results)
                if results[2] ~= 0 then ctx.units = nil return end
                if not ctx.units then ctx.good, ctx.units = ctx.clippedGood, ctx.clipped end
            end)
    end
    if type(TradingManager.sellGoods) == "function" then
        TradingManager.sellGoods = recordedTrade(TradingManager.sellGoods, "sold", "direct",
            function(ctx, self, good, amount)
                local name = goodName(good)
                ctx.clipped = math.min(self:getNumGoods(name), tonumber(amount) or 0)
                ctx.clippedGood = name
            end,
            function(ctx, self, results)
                if results[2] ~= 0 then ctx.units = nil return end
                if not ctx.units then ctx.good, ctx.units = ctx.clippedGood, ctx.clipped end
            end)
    end

    -- A population eating what a habitat or trading post bought, and paying for it. No
    -- transferMoney here: the game credits the owner directly, and the trading stats are
    -- the only record of how much.
    local useUpBoughtGoods = TradingManager.useUpBoughtGoods
    if type(useUpBoughtGoods) == "function" then
        local consume = recordedTrade(useUpBoughtGoods, "consumed", "population",
            function(ctx, self)
                ctx.before = tonumber(self.stats and self.stats.moneyGainedFromGoods) or 0
            end,
            function(ctx, self)
                local after = tonumber(self.stats and self.stats.moneyGainedFromGoods) or 0
                ctx.price = math.max(0, after - ctx.before)
                ctx.ownerAmount = ctx.price
            end)

        -- Called every tick and does something every two minutes, so skip the wrapper
        -- entirely where it cannot do anything.
        TradingManager.useUpBoughtGoods = function(self, ...)
            if not self.useUpGoodsEnabled then return useUpBoughtGoods(self, ...) end
            return consume(self, ...)
        end
    end

    return true
end

-- #### PRODUCTION #### --

local function freshWindow()
    return
    {
        seconds = 0,
        slotSeconds = 0,
        busySlotSeconds = 0,
        starvedSeconds = 0,
        blockedSeconds = 0,
        idleSeconds = 0,
        cycles = 0,
        boosted = 0,
    }
end

-- factory.lua explains an idle slot with one of two sentences. Matched on a word rather
-- than the whole text, which is a translation template and has changed wording before.
local function idleReason(text)
    if type(text) ~= "string" or text == "" then return "idle" end
    if string.find(text, "ingredient", 1, true) then return "starved" end
    if string.find(text, "space", 1, true) then return "blocked" end

    return "idle"
end

-- A production's goods lists, flattened for the trip across the VM boundary. Sent with
-- every window so a stored window stays accurate after the station is rebuilt into
-- something else.
local function recipe(production)
    local function side(list)
        local out = {}
        for _, item in pairs(list or {}) do
            out[#out + 1] =
            {
                name = tostring(item.name or ""),
                amount = tonumber(item.amount) or 0,
                optional = item.optional ~= nil and item.optional ~= 0 or nil,
            }
        end
        return out
    end

    return side(production.results), side(production.ingredients), side(production.garbages)
end

-- `locals` returns factory.lua's own file-local state, which only code appended to that
-- file can reach: production, newProductionError, currentProductions.
function StationHooks.factory(Factory, locals)
    if type(Factory) ~= "table" or type(locals) ~= "function" then return false end
    if hooked[Factory] then return true end
    hooked[Factory] = true

    local window = freshWindow()

    local function flush()
        local finished = window
        window = freshWindow()

        if finished.seconds <= 0 then return end

        local identity = station()
        if not identity then return end

        local production = locals()
        if type(production) ~= "table" then return end

        local results, ingredients, garbage = recipe(production)

        finished.slots = tonumber(Factory.maxNumProductions) or 0
        finished.cycleSeconds = tonumber(Factory.timeToProduce) or 0
        finished.results = results
        finished.ingredients = ingredients
        finished.garbage = garbage

        push(identity, "production", finished)
    end

    -- Cycles started, which is when the ingredients are taken. Runs in the parallel update,
    -- where touching anything but this VM's own tables is off limits; it does not.
    local startProduction = Factory.startProduction
    if type(startProduction) == "function" then
        Factory.startProduction = function(timeStep, boosted, ...)
            if onServer() then
                window.cycles = window.cycles + 1
                if boosted then window.boosted = window.boosted + 1 end
            end

            return startProduction(timeStep, boosted, ...)
        end
    end

    -- Slot time, sampled on the main thread after each server update. Busy slots are
    -- counted directly; an idle one is charged to the reason the last production attempt
    -- gave, which is what the station's own UI shows as its error.
    local updateServer = Factory.updateServer
    if type(updateServer) == "function" then
        Factory.updateServer = function(timeStep, ...)
            local results = pack(updateServer(timeStep, ...))

            pcall(function()
                local production, errorText, running = locals()
                local dt = tonumber(timeStep) or 0
                if type(production) ~= "table" or dt <= 0 then return end

                local slots = tonumber(Factory.maxNumProductions) or 0
                local busy = 0
                for _ in pairs(running or {}) do busy = busy + 1 end
                busy = math.min(busy, slots)

                window.seconds = window.seconds + dt
                window.slotSeconds = window.slotSeconds + slots * dt
                window.busySlotSeconds = window.busySlotSeconds + busy * dt

                if busy < slots then
                    local key = idleReason(errorText) .. "Seconds"
                    window[key] = window[key] + dt
                end

                if window.seconds >= StationHooks.productionWindow then flush() end
            end)

            return unpack(results, 1, results.n)
        end
    end

    -- The reload catch-up: everything the factory would have made while unloaded, run in
    -- one step. Counted from the first result's stock, since the cycle count is a local of
    -- the vanilla function.
    local onRestoredFromDisk = Factory.onRestoredFromDisk
    if type(onRestoredFromDisk) == "function" then
        Factory.onRestoredFromDisk = function(elapsed, ...)
            local before, first

            pcall(function()
                local production = locals()
                first = production and production.results and production.results[1]
                if first then before = Factory.getNumGoods(first.name) end
            end)

            local results = pack(onRestoredFromDisk(elapsed, ...))

            pcall(function()
                if not before or not first or (tonumber(first.amount) or 0) <= 0 then return end

                local identity = station()
                if not identity then return end

                local produced = Factory.getNumGoods(first.name) - before
                local cycles = math.max(0, math.floor(produced / first.amount))

                local production = locals()
                local resultList, ingredients, garbage = recipe(production)

                push(identity, "catchup",
                {
                    seconds = tonumber(elapsed) or 0,
                    cycles = cycles,
                    results = resultList,
                    ingredients = ingredients,
                    garbage = garbage,
                })
            end)

            return unpack(results, 1, results.n)
        end
    end

    return true
end

return StationHooks
