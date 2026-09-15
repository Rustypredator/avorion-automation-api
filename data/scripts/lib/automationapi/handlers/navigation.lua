-- Planned routes, boss farming and standing orders: order chains the ship flies by itself.
--
-- These are the /orders half of movement grown up. A route is planned here, with the
-- preferences calculateJumpPath cannot take, and handed to the ship as one plan. The ship
-- side is this mod's extension of orderchain.lua (data/scripts/entity/orderchain.lua),
-- which puts the hops on the vanilla chain - so the Orders view, the galaxy map and the
-- event log all show them as ordinary jumps - and watches the sector while it flies:
--
--   onEnemies = "fight"     clear the chain, fight, then pick the route up where it left
--               "hold"      clear the chain and stay aggressive where it is
--               "continue"  ignore them and keep jumping
--
-- The same watch drives the standing orders, which a ship keeps without a plan: fight
-- enemies in its sector, send fighters for loot in it. Each is allowed to take the ship
-- only while it is idle, or to interrupt its chain and put it back afterwards.
--
-- Nothing on the ship can answer a call. What it does publish is its automation state,
-- alongside the chain in the order info the engine already pushes to the owner, and the
-- player agent forwards that like any other order event. So a dispatch here is confirmed
-- the way /orders confirms one: held open until the ship reports the plan it took up, or
-- the reason it refused.
--
-- A player-owned ship in a sector nobody is in stops being simulated, and a plan waits
-- with it; the engine gives an order chain no way around that.

local Json = include("automationapi/json")
local Router = include("automationapi/router")
local Serialize = include("automationapi/serialize")
local Owner = include("automationapi/owner")
local Routes = include("automationapi/routes")
local ShipData = include("automationapi/shipdata")
local ShipEvents = include("automationapi/shipevents")
local RoutePlanner = include("automationapi/routeplanner")
local Missions = include("automationapi/handlers/missions")
local Movement = include("automationapi/handlers/movement")

local Navigation = {}

local ON_ENEMIES = {fight = true, hold = true, continue = true}

-- player/story/spawnrandombosses.lua: noSpawnTimer = 30 * 60 after either boss dies
local BOSS_COOLDOWN = 30 * 60
local BOSS_COOLDOWN_MAX = 4 * 3600

-- A plan's id is how its confirmation is recognised in the event feed, so it only has to
-- be unique among the plans one ship could report at once.
local nextPlanId = 0

local function planId()
    nextPlanId = nextPlanId + 1

    local ok, runtime = pcall(function() return Server().unpausedRuntime end)
    return string.format("p%d-%d", nextPlanId, math.floor(ok and runtime or 0))
end

-- #### REQUEST PARSING #### --

local function onEnemiesOf(body, default)
    local value = body.onEnemies
    if value == nil then return default end

    value = string.lower(tostring(value))
    if not ON_ENEMIES[value] then
        Router.fail(400, "bad_on_enemies",
                    "'onEnemies' is one of fight, hold or continue.",
                    {known = Json.array({"fight", "hold", "continue"})})
    end

    return value
end

-- Standing orders: {enemies = {enabled, mode}, loot = {enabled, mode}}, every part
-- optional. What is left out stays as the ship has it.
local STANDING_ORDERS = {"enemies", "loot"}
local STANDING_MODES = {idle = true, interrupt = true}

local function standingOf(value)
    if type(value) ~= "table" then
        Router.fail(400, "bad_standing", "'standing' is an object of standing orders.",
                    {known = Json.array(STANDING_ORDERS)})
    end

    local known = {}
    for _, name in ipairs(STANDING_ORDERS) do known[name] = true end

    for name, _ in pairs(value) do
        if not known[name] then
            Router.fail(400, "bad_standing", "Unknown standing order '" .. tostring(name) .. "'.",
                        {known = Json.array(STANDING_ORDERS)})
        end
    end

    local standing = {}

    for _, name in ipairs(STANDING_ORDERS) do
        local order = value[name]

        if order ~= nil then
            if type(order) ~= "table" then
                Router.fail(400, "bad_standing",
                            "'standing." .. name .. "' is an object with 'enabled' and/or 'mode'.")
            end

            local parsed = {}

            if order.enabled ~= nil then
                if type(order.enabled) ~= "boolean" then
                    Router.fail(400, "bad_standing",
                                "'standing." .. name .. ".enabled' must be true or false.")
                end
                parsed.enabled = order.enabled
            end

            if order.mode ~= nil then
                local mode = string.lower(tostring(order.mode))
                if not STANDING_MODES[mode] then
                    Router.fail(400, "bad_standing_mode",
                                "'standing." .. name .. ".mode' is idle or interrupt.",
                                {known = Json.array({"idle", "interrupt"})})
                end
                parsed.mode = mode
            end

            if next(parsed) == nil then
                Router.fail(400, "bad_standing",
                            "'standing." .. name .. "' needs 'enabled' and/or 'mode'.")
            end

            standing[name] = parsed
        end
    end

    if next(standing) == nil then
        Router.fail(400, "bad_standing", "'standing' names no standing order.",
                    {known = Json.array(STANDING_ORDERS)})
    end

    return standing
end

-- Whether the ship's published state holds the standing orders that were sent. A ship on a
-- mod version from before standing orders publishes none, and never confirms.
local function standingReported(automation, requested)
    local reported = automation.standing
    if type(reported) ~= "table" then return false end

    for name, order in pairs(requested) do
        local actual = reported[name]
        if type(actual) ~= "table" then return false end

        for key, value in pairs(order) do
            if actual[key] ~= value then return false end
        end
    end

    return true
end

local function shipEntry(owner, shipName)
    local entry = ShipDatabaseEntry(owner.index, shipName)
    if not entry then
        Router.fail(404, "no_ship_data", "No database entry for '" .. shipName .. "'.")
    end

    local x, y = entry:getCoordinates()
    local range, canPassRifts = entry:getHyperspaceProperties()

    return {x = x, y = y, range = range or 0, canPassRifts = canPassRifts == true}
end

-- #### DISPATCH #### --

local function automationOf(event)
    return type(event) == "table" and type(event.automation) == "table" and event.automation
           or nil
end

-- Sends a plan to the ship and answers once the ship reports it took it up - or refused
-- it, which it reports as the outcome of a plan it never started.
local function dispatchPlan(ctx, owner, shipName, sector, plan, body)
    local payload = Json.encode(plan)

    body.planId = plan.id

    return Missions.enqueue
    {
        kind = "orders",
        owner = owner,
        playerIndex = ctx.playerIndex,
        shipName = shipName,
        sector = sector,
        clear = false,
        run = false,
        calls = {{fn = "automationApiRunPlan", args = {payload}}},
        complete = ctx.complete,
        onResult = function()
            Movement.awaitConfirmation
            {
                owner = owner,
                shipName = shipName,
                body = body,
                complete = ctx.complete,
                check = function(event)
                    local automation = automationOf(event)
                    if not automation then return nil end

                    if type(automation.plan) == "table" and automation.plan.id == plan.id then
                        return 200
                    end

                    local last = automation.last
                    if type(last) == "table" and last.id == plan.id then
                        if last.outcome == "refused" then
                            body.error =
                            {
                                code = last.reason == "needs_captain" and "needs_captain"
                                       or "plan_refused",
                                message = "The ship refused the plan: "
                                          .. tostring(last.reason or "no reason given"),
                            }
                            return 422
                        end

                        -- taken up and already over - a one-hop route can be flown inside
                        -- the confirmation window
                        return 200
                    end

                    return nil
                end,
            }
        end,
    }
end

-- A settings change or a stop: no plan to recognise, so the check is on the state itself.
local function dispatchCall(ctx, owner, shipName, sector, fn, payload, body, satisfied)
    return Missions.enqueue
    {
        kind = "orders",
        owner = owner,
        playerIndex = ctx.playerIndex,
        shipName = shipName,
        sector = sector,
        clear = false,
        run = false,
        calls = {{fn = fn, args = payload and {payload} or {}}},
        complete = ctx.complete,
        onResult = function()
            Movement.awaitConfirmation
            {
                owner = owner,
                shipName = shipName,
                body = body,
                complete = ctx.complete,
                check = function(event)
                    local automation = automationOf(event)
                    if automation and satisfied(automation) then return 200 end
                    return nil
                end,
            }
        end,
    }
end

-- #### ENDPOINTS #### --

function Navigation.register(router)

    -- Plans a route with preferences and flies it as an order chain.
    router:post("/ships/{name}/route", function(ctx, params)
        local body = ctx.body
        local owner = Owner.findShip(ctx, params.name)

        local toX, toY = Routes.destination(body)
        local onEnemies = onEnemiesOf(body, "fight")
        local preferences = Routes.preferences(body)
            or {preferGates = false, avoidRifts = false, preferUncontrolled = false}
        local dryRun = body.dryRun == true

        local ship = shipEntry(owner, params.name)

        if ship.x == toX and ship.y == toY then
            Router.fail(422, "already_there",
                        string.format("'%s' is already in (%d:%d).", params.name, toX, toY))
        end

        -- The world is checked before the plan is spent, so a ship that cannot be ordered
        -- is refused at once rather than after seconds of searching.
        local sector
        if not dryRun then
            local x, y = Movement.requireOrderable(ctx, owner, params.name,
                                                   {{name = "jump", rule = "unless_piloted"}})
            sector = {x = x, y = y}
        end

        Routes.throttle(ctx.playerIndex)

        RoutePlanner.run(
        {
            owner = owner,
            from = {x = ship.x, y = ship.y},
            to = {x = toX, y = toY},
            range = ship.range,
            canPassRifts = ship.canPassRifts,
            preferGates = preferences.preferGates,
            avoidRifts = preferences.avoidRifts,
            preferUncontrolled = preferences.preferUncontrolled,
        },
        function(result)
            local response = Routes.describePlan(result, ship.x, ship.y, toX, toY,
                                                 ship.range, ship.canPassRifts, preferences)
            response.ship = params.name
            response.owner = Owner.describe(owner)
            response.onEnemies = onEnemies
            response.attackCivilians = body.attackCivilians == true
            response.dryRun = dryRun

            if not result.reachable then
                response.error =
                {
                    code = "no_route",
                    message = "No route found: " .. tostring(result.reason),
                }
                ctx.complete(422, response)
                return
            end

            if dryRun then
                ctx.complete(200, response)
                return
            end

            local hops = {}
            for index, hop in ipairs(result.hops) do
                hops[index] = {x = hop.x, y = hop.y, kind = hop.kind}
            end

            dispatchPlan(ctx, owner, params.name, sector,
            {
                id = planId(),
                kind = "route",
                hops = hops,
                onEnemies = onEnemies,
                attackCivilians = body.attackCivilians == true,
            }, response)
        end,
        ctx.complete)

        return Router.DEFERRED
    end)

    -- Jumps back and forth between two empty sectors in a boss ring, with a player aboard,
    -- until a boss turns up - and then deals with it the way onEnemies says.
    router:post("/ships/{name}/farm", function(ctx, params)
        local body = ctx.body
        local owner = Owner.findShip(ctx, params.name)

        local boss = string.lower(tostring(body.boss or "auto"))
        if boss ~= "auto" and not RoutePlanner.bossRings[boss] then
            Router.fail(400, "bad_boss", "'boss' is one of auto, ai or swoks.",
                        {known = Json.array({"auto", "ai", "swoks"})})
        end

        local onEnemies = onEnemiesOf(body, "fight")
        local dryRun = body.dryRun == true

        local collectLoot = true
        if body.collectLoot ~= nil then
            if type(body.collectLoot) ~= "boolean" then
                Router.fail(400, "bad_collect_loot", "'collectLoot' must be true or false.")
            end
            collectLoot = body.collectLoot
        end

        -- Seconds the loop waits after a kill. Vanilla's is 30 minutes for both bosses; the
        -- knob exists for servers whose mods change it, and 0 keeps jumping regardless.
        local bossCooldown = BOSS_COOLDOWN
        if body.bossCooldown ~= nil then
            bossCooldown = tonumber(body.bossCooldown)
            if type(body.bossCooldown) ~= "number" or bossCooldown < 0
               or bossCooldown > BOSS_COOLDOWN_MAX then
                Router.fail(400, "bad_boss_cooldown",
                            string.format("'bossCooldown' is seconds, 0 to %d.", BOSS_COOLDOWN_MAX))
            end
            bossCooldown = math.floor(bossCooldown)
        end

        local ship = shipEntry(owner, params.name)

        -- The jump counter belongs to the player aboard, not to the ship. A captain flying
        -- this loop alone would jump for ever and never spawn anything.
        local piloted = Movement.isPilotedByPlayer(owner, params.name)

        local sector
        if not dryRun then
            if not piloted then
                Router.fail(422, "needs_pilot",
                            "Boss spawns count the jumps of the player on the ship, not the "
                            .. "ship's own. Board '" .. params.name .. "' and take the "
                            .. "controls first.",
                            {piloted = false})
            end

            local x, y = Movement.requireOrderable(ctx, owner, params.name,
                                                   {{name = "jump", rule = "unless_piloted"}})
            sector = {x = x, y = y}
        end

        if ship.range < 1 then
            Router.fail(422, "no_hyperspace", "'" .. params.name .. "' cannot jump.")
        end

        Routes.throttle(ctx.playerIndex)

        local loop, reason = RoutePlanner.farmLoop(ship.x, ship.y, ship.range,
                                                   ship.canPassRifts, boss)
        if not loop then
            Router.fail(422, "no_farm_loop", "No loop for boss farming: " .. reason)
        end

        local ring = RoutePlanner.bossRings[loop.ring]

        local function respond(approach)
            local hops = {}
            for _, hop in ipairs(approach) do
                hops[#hops + 1] = {x = hop.x, y = hop.y, kind = hop.kind or "jump"}
            end

            -- Start the lap from whichever of the pair the ship will be sitting on.
            local last = hops[#hops] or {x = ship.x, y = ship.y}
            local first, second = loop.b, loop.a
            if last.x == loop.b.x and last.y == loop.b.y then first, second = loop.a, loop.b end

            local loopFrom = #hops + 1
            hops[#hops + 1] = {x = first.x, y = first.y, kind = "jump"}
            hops[#hops + 1] = {x = second.x, y = second.y, kind = "jump"}

            local response =
            {
                ship = params.name,
                owner = Owner.describe(owner),
                boss = loop.ring,
                ring = {min = ring.min, max = ring.max},
                loop = Json.array({Serialize.vec2(loop.a.x, loop.a.y),
                                   Serialize.vec2(loop.b.x, loop.b.y)}),
                approach = Json.array(RoutePlanner.describeHops(approach,
                                                                {x = ship.x, y = ship.y})),
                hops = Json.array(hops),
                loopFrom = loopFrom,
                piloted = piloted,
                onEnemies = onEnemies,
                attackCivilians = body.attackCivilians == true,
                collectLoot = collectLoot,
                bossCooldown = bossCooldown,
                dryRun = dryRun,
                -- the map draws this like any other route
                route = Json.array((function()
                    local points = {{x = ship.x, y = ship.y}}
                    for _, hop in ipairs(hops) do points[#points + 1] = {x = hop.x, y = hop.y} end
                    return points
                end)()),
                reachable = true,
            }

            if dryRun then
                ctx.complete(200, response)
                return
            end

            dispatchPlan(ctx, owner, params.name, sector,
            {
                id = planId(),
                kind = "farm",
                boss = loop.ring,
                hops = hops,
                loopFrom = loopFrom,
                onEnemies = onEnemies,
                attackCivilians = body.attackCivilians == true,
                collectLoot = collectLoot,
                bossCooldown = bossCooldown,
            }, response)
        end

        local atA = ship.x == loop.a.x and ship.y == loop.a.y
        local atB = ship.x == loop.b.x and ship.y == loop.b.y

        if atA or atB then
            respond({})
            return Router.DEFERRED
        end

        RoutePlanner.run(
        {
            owner = owner,
            from = {x = ship.x, y = ship.y},
            to = loop.a,
            range = ship.range,
            canPassRifts = ship.canPassRifts,
        },
        function(result)
            if not result.reachable then
                ctx.complete(422, {error =
                {
                    code = "no_route",
                    message = string.format("No route to the loop at (%d:%d): %s",
                                            loop.a.x, loop.a.y, tostring(result.reason)),
                }})
                return
            end

            respond(result.hops)
        end,
        ctx.complete)

        return Router.DEFERRED
    end)

    -- What the ship's automation is doing. The live event feed when the owner's agent has
    -- recorded one, else the ship database's copy, which is as fresh as the last save.
    router:get("/ships/{name}/automation", function(ctx, params)
        local owner = Owner.findShip(ctx, params.name)

        local automation = ShipEvents.latestAutomation(owner.index, params.name)
        local source = automation and "live" or nil

        if not automation then
            local entry = ShipDatabaseEntry(owner.index, params.name)
            if entry then
                local ok, raw = pcall(function() return entry:getOrderInfo() end)
                local orders = ok and ShipData.ordersOf(raw) or nil
                if orders and orders.automation then
                    automation = orders.automation
                    source = "database"
                end
            end
        end

        return
        {
            ship = params.name,
            owner = Owner.describe(owner),
            source = source or "none",
            -- false until the ship has published anything: a ship whose sector has not
            -- loaded since the mod was installed, or one another mod's orderchain.lua
            -- replaced outright
            reported = automation ~= nil,
            automation = automation,
        }
    end)

    -- The ship's settings: its standing orders, and whether civilians count as enemies.
    router:post("/ships/{name}/automation", function(ctx, params)
        local body = ctx.body
        local owner = Owner.findShip(ctx, params.name)

        local settings = {}
        for _, name in ipairs({"autoAggressive", "attackCivilians"}) do
            if body[name] ~= nil then
                if type(body[name]) ~= "boolean" then
                    Router.fail(400, "bad_setting", "'" .. name .. "' must be true or false.")
                end
                settings[name] = body[name]
            end
        end

        if body.standing ~= nil then
            settings.standing = standingOf(body.standing)
        end

        if body.autoAggressive ~= nil and settings.standing and settings.standing.enemies
           and settings.standing.enemies.enabled ~= nil
           and settings.standing.enemies.enabled ~= body.autoAggressive then
            Router.fail(400, "conflicting_settings",
                        "'autoAggressive' is the standing enemies order; the two disagree.")
        end

        if next(settings) == nil then
            Router.fail(400, "no_settings",
                        "Provide 'standing', 'autoAggressive' and/or 'attackCivilians'.")
        end

        -- A setting gives the ship no order, so only the world has to allow the call.
        local x, y = Movement.requireOrderable(ctx, owner, params.name, nil,
                                               {skipCaptain = true})

        return dispatchCall(ctx, owner, params.name, {x = x, y = y},
                            "automationApiConfigure", Json.encode(settings),
                            {ship = params.name, owner = Owner.describe(owner),
                             requested = settings},
                            function(automation)
                                for name, value in pairs(settings) do
                                    if name == "standing" then
                                        if not standingReported(automation, value) then
                                            return false
                                        end
                                    elseif automation[name] ~= value then
                                        return false
                                    end
                                end
                                return true
                            end)
    end)

    router:post("/ships/{name}/automation/stop", function(ctx, params)
        local owner = Owner.findShip(ctx, params.name)

        local x, y = Movement.requireOrderable(ctx, owner, params.name, nil,
                                               {skipCaptain = true})

        return dispatchCall(ctx, owner, params.name, {x = x, y = y},
                            "automationApiStop", nil,
                            {ship = params.name, owner = Owner.describe(owner)},
                            function(automation)
                                return automation.plan == nil and automation.reaction == nil
                            end)
    end)

end

function Navigation.tick()
    RoutePlanner.tick()
end

return Navigation
