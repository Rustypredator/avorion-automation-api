-- Moving ships around: the two ways the game offers, and route planning.
--
-- The two are genuinely different and the difference matters to a planner:
--
--   /travel   starts a Travel captain mission - an alias of missions/travel/start.
--             Galaxy-wide, loads no sectors, survives the ship being anywhere, and
--             reports a real prediction first.
--   /orders   enqueues in-sector orders on the ship's own order chain. Only works while
--             the sector is loaded, and the engine's dispatch returns nothing, so the
--             answer is held until the ship reports its chain back.
--
-- Planned routes, boss farming and idle defence build on /orders' half; they live in
-- handlers/navigation.lua. Every write needs the owning player online.

local Json = include("automationapi/json")
local Router = include("automationapi/router")
local Serialize = include("automationapi/serialize")
local Owner = include("automationapi/owner")
local Routes = include("automationapi/routes")
local ShipData = include("automationapi/shipdata")
local Config = include("automationapi/config")
local ShipEvents = include("automationapi/shipevents")
local RoutePlanner = include("automationapi/routeplanner")

-- Defines the global OrderType, which is how the published order info identifies each
-- order. Matching on it rather than on the display name keeps this independent of
-- localization.
include("ordertypes")
local Missions = include("automationapi/handlers/missions")

local Movement = {}

-- #### ORDERS #### --

-- The order-chain entry points worth exposing, and the engine facts that govern them.
--
-- Two constraints shape this table, both learned the hard way - the engine enforces them
-- silently, so getting either wrong produces a 202 and nothing else at all.
--
-- 1. Only functions registered with callable() in orderchain.lua can be reached by
--    invokeEntityFunction. addMineOrder, addSalvageOrder and addRefineOresOrder are NOT
--    registered, so they must be driven through their onUser* wrappers instead.
-- 2. Those wrappers are not enchainable: each one does clearAllOrders() + add + runOrders()
--    internally, so it replaces the whole chain. They are marked oneShot and have to stand
--    alone in a request.
--
-- The chainable four are exactly what vanilla's own galaxy-map order UI enqueues
-- (mapcommands.lua:2351-2384) - the closest analogue to this endpoint.
--
-- Orders needing an entity id (attack, board, dock, escort) are left out: the caller would
-- have to know ids from a loaded sector, which this API does not hand out.
local orderTypes =
{
    jump =
    {
        fn = "addJumpOrder",
        action = OrderType.Jump,
        terminal = false,
        -- addJumpOrder takes a captain OR a player aboard, since it changes sector
        captain = "unless_piloted",
        build = function(spec)
            local x, y = Routes.coordinates(spec.to or spec, "to")
            return {x, y}
        end,
    },
    patrol      = {fn = "addPatrolOrder", action = OrderType.Patrol,
                   terminal = true,  build = function() return {} end},
    repair      = {fn = "addRepairOrder", action = OrderType.Repair,
                   terminal = false, build = function() return {} end},
    aggressive =
    {
        fn = "addAggressiveOrder",
        action = OrderType.Aggressive,
        terminal = false,
        build = function(spec)
            return {spec.attackCivilians == true, spec.canFinish == true}
        end,
    },

    -- one-shot wrappers: these replace the chain rather than extending it
    mine =
    {
        fn = "onUserMineOrder",
        action = OrderType.Mine,
        oneShot = true,
        -- the wrapper needs a captain whenever it is given no target entity, and this API
        -- never has one to give
        captain = true,
        build = function() return {} end,
    },
    salvage =
    {
        fn = "onUserSalvageOrder",
        action = OrderType.Salvage,
        oneShot = true,
        captain = true,
        build = function() return {} end,
    },
    refine =
    {
        fn = "onUserRefineOresOrder",
        action = OrderType.RefineOres,
        oneShot = true,
        build = function() return {} end,
    },
}

local function orderTypeNames()
    local names = {}
    for name, _ in pairs(orderTypes) do names[#names + 1] = name end
    table.sort(names)

    return names
end

local function oneShotNames()
    local names = {}
    for name, order in pairs(orderTypes) do
        if order.oneShot then names[#names + 1] = name end
    end
    table.sort(names)

    return names
end

local function isTerminal(order, spec)
    if type(order.terminal) == "function" then return order.terminal(spec) end
    return order.terminal == true
end

-- Turns the request body into the flat call list the agent replays onto the order chain.
-- Only numbers, strings and booleans come out, because this crosses a script boundary.
local function buildOrders(body)
    local specs = body.orders

    if type(specs) ~= "table" or #specs == 0 then
        Router.fail(400, "no_orders",
                    "Provide 'orders' as a non-empty array of {type, ...}.",
                    {known = Json.array(orderTypeNames())})
    end

    local calls = {}
    local needsCaptain = {}
    local terminatedBy
    local oneShot = false

    for index, spec in ipairs(specs) do
        if type(spec) == "string" then spec = {type = spec} end

        if type(spec) ~= "table" then
            Router.fail(400, "bad_order",
                        "Order " .. index .. " must be an object or a type name.")
        end

        local name = string.lower(tostring(spec.type or ""))
        local order = orderTypes[name]

        if not order then
            Router.fail(400, "bad_order",
                        "Unknown order type '" .. tostring(spec.type) .. "'.",
                        {known = Json.array(orderTypeNames())})
        end

        if terminatedBy then
            Router.fail(422, "order_after_terminal",
                        "Nothing can follow a '" .. terminatedBy .. "' order; the game "
                        .. "refuses to enchain past it.")
        end

        if order.oneShot then
            if #specs > 1 then
                Router.fail(422, "order_not_chainable",
                            "'" .. name .. "' is not an enchainable order: the game "
                            .. "implements it as a wrapper that clears the chain, adds the "
                            .. "order and runs it, so it has to be the only order in the "
                            .. "request.",
                            {oneShot = Json.array(oneShotNames())})
            end

            oneShot = true
        end

        calls[#calls + 1] = {order = name, fn = order.fn, args = order.build(spec),
                             action = order.action}

        if order.captain then
            needsCaptain[#needsCaptain + 1] = {name = name, rule = order.captain}
        end

        if isTerminal(order, spec) then terminatedBy = name end
    end

    return calls, needsCaptain, oneShot
end

-- Whether a player is flying the ship right now. There is no database field for this -
-- ShipDatabaseEntry describes the craft, not who is sitting in it - but the engine's own
-- AI status string is "[PLAYER]" exactly when a player holds the controls, so that is
-- what vanilla's UI reads too.
local function isPilotedByPlayer(owner, shipName)
    local ok, status = pcall(function() return owner.faction:getShipStatus(shipName) end)
    if not ok or type(status) ~= "string" then return false end

    return string.find(status, "%[PLAYER%]") ~= nil
end

-- The other half of canReceivePlayerOrder(): the calling player standing in the ship's
-- sector. Note this is the player, not the owning faction - an alliance ship is ordered by
-- whichever member is calling.
local function playerInSector(ctx, x, y)
    local ok, px, py = pcall(function() return ctx.player:getSectorCoordinates() end)
    if not ok or type(px) ~= "number" then return false end

    return px == x and py == y
end

-- #### CONFIRMING A DISPATCH #### --
--
-- invokeEntityFunction cannot return anything, so a dispatch used to be answered blind.
-- It does not have to be: the order chain publishes its state back to the owning faction
-- on every change (orderchain.lua:1340 calls owner:setShipOrderInfo), and that is readable
-- from here with getShipOrderInfo. So instead of answering immediately, the request is
-- held for a moment and answered with the chain the ship actually ended up with.
--
-- Read back rather than pushed: the matching onShipOrderInfoUpdated callback would have to
-- live in the player agent and be correlated back across the script boundary, which buys
-- nothing for a single request. It is the right tool for a persistent per-ship log.
local pendingConfirms = {}

-- Whether the chain the ship is actually holding is the one we asked for.
--
-- Two wrong answers were tried first, and both are worth remembering:
--
--   * "Did the chain change?" - wrong because re-issuing an order a ship is already
--     running produces an identical chain, which then reads as a failed dispatch.
--   * Reading getShipOrderInfo back off the owner handle the request captured - wrong
--     because that handle serves a cached ShipInfo and keeps returning the state it held
--     when the request arrived, so the chain never appears to move at all.
--
-- So the resulting chain comes from the pushed event feed, which is live, and is matched
-- against the orders we sent. A cleared chain has to match exactly; an appended one only
-- has to end with our orders, since what the ship already held stays in front of them.
local function chainMatches(event, calls, replaced)
    if type(event) ~= "table" or type(event.chain) ~= "table" then return false end

    local actual = event.chain
    local offset = #actual - #calls
    if offset < 0 then return false end
    if replaced and offset ~= 0 then return false end

    for index, call in ipairs(calls) do
        local entry = actual[offset + index]
        if type(entry) ~= "table" then return false end
        if math.floor(tonumber(entry.action) or -1) ~= call.action then return false end
    end

    return true
end

Movement.chainMatches = chainMatches

-- Holds a dispatched request open until the ship's own event feed shows it took effect.
--
--   spec.owner, spec.shipName  whose feed to watch
--   spec.check(event)          nil to keep waiting, or the status to answer with; called
--                              with the newest order event, which may be nil
--   spec.body                  the response, filled in with the resulting chain
--   spec.complete              the request's completion
function Movement.awaitConfirmation(spec)
    spec.waited = 0
    pendingConfirms[#pendingConfirms + 1] = spec
end

function Movement.tick(elapsed)
    if #pendingConfirms == 0 then return end

    local remaining = {}

    for _, confirm in ipairs(pendingConfirms) do
        confirm.waited = confirm.waited + (elapsed or 0)

        local event = ShipEvents.latestOrder(confirm.owner.index, confirm.shipName)
        local status = confirm.check(event)
        local expired = confirm.waited >= Config.orderConfirmWindow

        if status or expired then
            local body = confirm.body
            body.chain = (event or {}).chain or Json.array({})
            body.activeIndex = Serialize.number((event or {}).activeIndex, 0)
            body.finished = (event or {}).finished == true
            body.confirmed = status == 200

            if event and event.automation then body.automation = event.automation end

            if status then
                -- 200: the ship reported back a state holding what we sent. Anything else
                -- is the ship reporting that it refused, which the check has explained.
                confirm.complete(status, body)
            else
                -- 202: dispatched, but no event showed these orders. Not proof of failure -
                -- a one-shot order that completes instantly can land and clear again inside
                -- the window - so it is reported as unconfirmed rather than as an error.
                body.note = "Dispatched, but the ship did not report a chain holding these "
                            .. "orders within " .. Config.orderConfirmWindow .. "s. They "
                            .. "may have been refused, or may have completed already. "
                            .. "GET /ships/" .. confirm.shipName
                            .. "/events shows what the ship actually did."
                confirm.complete(202, body)
            end
        else
            remaining[#remaining + 1] = confirm
        end
    end

    pendingConfirms = remaining
end

Movement.isPilotedByPlayer = isPilotedByPlayer

-- Everything that has to be true of the world before anything is put on a ship's order
-- chain: the owner online, the ship out of the background simulation, its sector loaded,
-- and the captain gates. Returns the ship's sector.
--
-- needsCaptain lists {name, rule} for orders stricter than the universal gate; rule is
-- true (a captain, always) or "unless_piloted" (a captain or a player aboard). Pass
-- {skipCaptain = true} in options for calls that give the ship no order at all.
function Movement.requireOrderable(ctx, owner, shipName, needsCaptain, options)
    options = options or {}

    Missions.requireOnline(owner)

    local availability = owner.faction:getShipAvailability(shipName)
    if availability == ShipAvailability.InBackground then
        Router.fail(409, "ship_in_background",
                    "'" .. shipName .. "' is out on a captain mission and has no "
                    .. "order chain to talk to. Recall it first.")
    end

    local x, y = owner.faction:getShipPosition(shipName)
    if type(x) ~= "number" or type(y) ~= "number" then
        Router.fail(404, "no_ship_position",
                    "The game does not report a position for '" .. shipName .. "'.")
    end

    local loaded = false
    local ok, result = pcall(function() return Galaxy():sectorLoaded(x, y) end)
    if ok then loaded = result == true end

    if not loaded then
        Router.fail(409, "sector_not_loaded",
                    string.format("(%d:%d) is not loaded, so the ship's scripts are "
                                  .. "not running and orders would be dropped without "
                                  .. "a trace. A Travel captain mission "
                                  .. "(POST /ships/%s/missions/travel/start) moves a ship "
                                  .. "wherever it is.", x, y, shipName))
    end

    if options.skipCaptain then return x, y end

    -- The captain gates. orderchain.lua checks these itself, but reports a refusal
    -- only by chat message to a calling player - which an API caller is not - so the
    -- order would otherwise vanish into a 202 with nothing to show for it.
    --
    -- canReceivePlayerOrder() (orderchain.lua:811) is the universal one: any order from
    -- a player needs the craft to have a captain, or the player to be in its sector.
    -- Individual orders then add a stricter check of their own.
    local hasCaptain = ShipData.hasCaptain(owner.index, shipName)

    if not hasCaptain then
        local piloted = isPilotedByPlayer(owner, shipName)

        if not piloted and not playerInSector(ctx, x, y) then
            Router.fail(422, "needs_captain",
                        "'" .. shipName .. "' has no captain, and the game only "
                        .. "accepts orders for a captainless ship while its owner is "
                        .. "in the same sector.",
                        {captain = false, sector = {x = x, y = y}})
        end

        for _, need in ipairs(needsCaptain or {}) do
            if need.rule == "unless_piloted" then
                if not piloted then
                    Router.fail(422, "needs_captain",
                                "A '" .. need.name .. "' order changes sector, so the "
                                .. "game requires either a captain or a player aboard. "
                                .. "'" .. shipName .. "' has neither.",
                                {captain = false, order = need.name})
                end
            else
                Router.fail(422, "needs_captain",
                            "A '" .. need.name .. "' order is carried out by a captain, "
                            .. "and '" .. shipName .. "' has none. Vanilla says: "
                            .. "\"Your ship needs a captain for that!\"",
                            {captain = false, order = need.name})
            end
        end
    end

    return x, y
end

-- #### ENDPOINTS #### --

function Movement.register(router)

    -- A Travel mission by another name, kept so existing callers keep working. The start
    -- itself - destination checks included - is POST /ships/{name}/missions/travel/start;
    -- all this adds is `swiftness` at the top level of the body.
    router:post("/ships/{name}/travel", function(ctx, params)
        local toX, toY = Routes.destination(ctx.body)

        -- rewritten into the shape the travel mission's area builder expects
        ctx.body.to = {x = toX, y = toY}
        ctx.body.config = ctx.body.config or {}

        if ctx.body.swiftness ~= nil then
            local swiftness = Routes.integer(ctx.body.swiftness)
            if swiftness == nil or swiftness < 0 or swiftness > 3 then
                Router.fail(400, "bad_swiftness",
                            "'swiftness' is 0 (careful) to 3 (reckless).")
            end
            ctx.body.config.swiftness = swiftness
        end

        return Missions.startHandler(ctx, {name = params.name, key = "travel"})
    end)

    -- In-sector orders. Fire-and-forget by the engine's own design: invokeEntityFunction
    -- runs on the target's next update tick, cannot return anything, and silently does
    -- nothing if the sector is not resident. So this answers 202 and never 200, and the
    -- honest way to see the result is GET /ships/{name}.
    router:post("/ships/{name}/orders", function(ctx, params)
        local owner = Owner.findShip(ctx, params.name)

        -- Validate the request before checking the world: a caller working on its payload
        -- should be told what is wrong with it, not that nobody is logged in.
        local calls, needsCaptain, oneShot = buildOrders(ctx.body)

        local x, y = Movement.requireOrderable(ctx, owner, params.name, needsCaptain)

        -- clear defaults to true: enqueueing onto whatever the ship was already doing is
        -- rarely what an external planner means, and vanilla's map UI clears too. A
        -- one-shot order clears the chain itself, so asking for it again would be a second
        -- redundant call across the script boundary.
        local clear = not oneShot and ctx.body.clear ~= false

        local dispatched = Json.array({})
        for _, call in ipairs(calls) do dispatched[#dispatched + 1] = call.order end

        return Missions.enqueue
        {
            kind = "orders",
            owner = owner,
            playerIndex = ctx.playerIndex,
            shipName = params.name,
            sector = {x = x, y = y},
            clear = clear,
            calls = calls,
            complete = ctx.complete,
            onResult = function(result)
                local body =
                {
                    ship = params.name,
                    owner = Owner.describe(owner),
                    sector = Serialize.vec2(x, y),
                    cleared = clear or oneShot,
                    oneShot = oneShot,
                    dispatched = dispatched,
                    accepted = (result.data or {}).accepted or #calls,
                }

                -- Hold the answer open until the chain actually moves, so the caller is
                -- told what happened rather than only that we asked.
                local replaced = clear or oneShot

                Movement.awaitConfirmation
                {
                    owner = owner,
                    shipName = params.name,
                    check = function(event)
                        if chainMatches(event, calls, replaced) then return 200 end
                        return nil
                    end,
                    body = body,
                    complete = ctx.complete,
                }
            end,
        }
    end)

    -- Explicitly expensive: calculateJumpPath is documented as slow and runs on the
    -- server tick, so it is rate limited per player.
    router:get("/galaxy/route", function(ctx)
        local query = ctx.query

        local fromX, fromY, jumpRange, canPassRifts
        local owner

        if query.ship then
            owner = Owner.findShip(ctx, query.ship)
            local entry = ShipDatabaseEntry(owner.index, query.ship)

            if not entry then
                Router.fail(404, "no_ship_data",
                            "No database entry for '" .. tostring(query.ship) .. "'.")
            end

            fromX, fromY = entry:getCoordinates()
            jumpRange, canPassRifts = entry:getHyperspaceProperties()
        else
            fromX = Routes.integer(query.fromX)
            fromY = Routes.integer(query.fromY)

            if fromX == nil or fromY == nil then
                Router.fail(400, "no_origin",
                            "Provide 'ship', or 'fromX' and 'fromY'.")
            end

            jumpRange = tonumber(query.range)
            if jumpRange == nil then
                Router.fail(400, "no_range",
                            "Provide 'range', the jump range in sectors, when not using "
                            .. "'ship'.")
            end

            canPassRifts = query.rifts == "true" or query.rifts == true
        end

        local toX, toY = Routes.integer(query.toX), Routes.integer(query.toY)
        if toX == nil or toY == nil then
            Router.fail(400, "no_destination", "Provide 'toX' and 'toY'.")
        end

        owner = owner or Owner.resolve(ctx)

        -- Any preference means this mod's own planner, since calculateJumpPath takes
        -- none. It is sliced across ticks, so the answer is deferred.
        local preferences = Routes.preferences(query)

        Routes.throttle(ctx.playerIndex)

        if preferences then
            RoutePlanner.run(
            {
                owner = owner,
                from = {x = fromX, y = fromY},
                to = {x = toX, y = toY},
                range = jumpRange,
                canPassRifts = canPassRifts,
                preferGates = preferences.preferGates,
                avoidRifts = preferences.avoidRifts,
                preferUncontrolled = preferences.preferUncontrolled,
            },
            function(result)
                ctx.complete(200, Routes.describePlan(result, fromX, fromY, toX, toY,
                                                      jumpRange, canPassRifts, preferences))
            end,
            ctx.complete)

            return Router.DEFERRED
        end

        local route = Routes.calculate(owner, fromX, fromY, toX, toY,
                                       jumpRange, canPassRifts)

        if not route then
            return
            {
                from = Serialize.vec2(fromX, fromY),
                to = Serialize.vec2(toX, toY),
                reachable = false,
                route = Json.array({}),
                jumps = 0,
                distance = 0,
            }
        end

        local described = Routes.describe(route)
        local last = route[#route]

        return
        {
            from = Serialize.vec2(fromX, fromY),
            to = Serialize.vec2(toX, toY),
            -- a path that stops short means the pathfinder gave up; say so rather than
            -- letting the caller assume the last sector is the destination
            reachable = last.x == toX and last.y == toY,
            route = described.sectors,
            jumps = described.jumps,
            distance = Serialize.number(described.distance, 0),
            jumpRange = Serialize.number(jumpRange, 0),
            canPassRifts = canPassRifts == true,
            planner = "engine",
        }
    end)

end

return Movement
