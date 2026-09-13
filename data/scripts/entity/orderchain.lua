
-- Automation API: route plans, enemy handling and idle defence, run by the ship itself.
--
-- The engine appends a mod file at a vanilla path onto the vanilla script, so everything
-- below lives inside OrderChain's own namespace, on every craft that has an order chain.
-- That placement is forced rather than chosen:
--
--   * Only a script running in the ship's sector can see what is in it. Nothing in the
--     galaxy or player context can ask "are there enemies around this ship", so an
--     automation that reacts to enemies has to live on the ship.
--   * addJumpOrder only falls back to a gate or wormhole when a client made the call
--     (it needs callingPlayer), which an API dispatch never is. Enchaining the gate hop
--     from inside the chain is the only way to put one on it.
--   * Extending the chain rather than attaching a new script to the craft means nothing
--     new is written into the save: the state rides along in OrderChain.secure(), and a
--     vanilla restore() simply ignores the extra key if the mod is ever removed.
--
-- The mod is server-side only, so clients never load this half. Everything is guarded
-- accordingly, and every callable checks the caller's permission the way vanilla does,
-- because callable() also opens a function to invokeServerFunction from a client.
--
-- What it reports back rides on the order info the chain already publishes to its owner
-- (getOrderInfo -> setShipOrderInfo), which the player agent already forwards to the
-- bridge. See handlers/navigation.lua for the other end.

if onServer() then

local AutomationApiJson = include("automationapi/json")

-- How long a sector has to stay free of enemies before a fight counts as over. The AI's
-- enemy check flickers while a ship is mid-jump into the sector or cloaked, and resuming a
-- route into the middle of a fight that has not really ended is worse than waiting.
local AUTOMATION_API_CLEAR_GRACE = 5

local automationApi =
{
    settings = {autoAggressive = false, attackCivilians = false},
    -- the plan currently driving the chain, or nil
    plan = nil,
    -- how the previous plan ended, so a caller polling after the fact can tell
    last = nil,
    -- fights started by idle defence, over the life of the ship
    defenceFights = 0,
    enemies = false,
}

local function automationApiLog(format, ...)
    printlog("AutomationAPI orderchain: " .. format, ...)
end

-- Same gate as every vanilla order function: nothing from a client that may not manage
-- the craft. An API dispatch arrives without a calling player and passes.
local function automationApiPermitted()
    if not callingPlayer then return true end

    local owner = checkEntityInteractionPermissions(Entity(), AlliancePrivilege.ManageShips)
    return owner ~= nil
end

local function automationApiPiloted()
    local pilots = {Entity():getPilotIndices()}
    return #pilots > 0
end

local function automationApiEnemiesPresent()
    local ok, present = pcall(function()
        return ShipAI():isEnemyPresent(automationApi.settings.attackCivilians == true)
    end)

    return ok and present == true
end

local function automationApiJumpValid(fromX, fromY, toX, toY)
    local ok, valid, reason = pcall(function()
        return HyperspaceEngine():isJumpRouteValid(fromX, fromY, toX, toY)
    end)

    if not ok then
        ok, valid, reason = pcall(function()
            return Entity():isJumpRouteValid(fromX, fromY, toX, toY)
        end)
    end

    if not ok then return false, tostring(valid) end
    return valid == true, reason
end

-- #### PUBLISHING #### --

local function automationApiDescribePlan(plan)
    local current = OrderChain.chain[OrderChain.activeOrder]
    local target = plan.hops[#plan.hops]

    return
    {
        id = plan.id,
        kind = plan.kind,
        phase = plan.phase,
        onEnemies = plan.onEnemies,
        attackCivilians = plan.attackCivilians == true,
        hops = #plan.hops,
        hop = current and current.hop or plan.resumeAt or 0,
        loopFrom = plan.loopFrom or 0,
        jumps = plan.jumps,
        fights = plan.fights,
        target = target and {x = target.x, y = target.y} or nil,
        boss = plan.boss,
    }
end

local function automationApiDescribe()
    local x, y = Sector():getCoordinates()

    return
    {
        version = 1,
        autoAggressive = automationApi.settings.autoAggressive == true,
        attackCivilians = automationApi.settings.attackCivilians == true,
        defenceFights = automationApi.defenceFights,
        enemies = automationApi.enemies == true,
        sector = {x = x, y = y},
        plan = automationApi.plan and automationApiDescribePlan(automationApi.plan) or nil,
        last = automationApi.last,
    }
end

local function automationApiPublish()
    OrderChain.updateShipOrderInfo()
end

-- #### CHAIN BUILDING #### --

local function automationApiHopOrder(plan, index)
    local hop = plan.hops[index]

    if hop.gate then
        return {action = OrderType.FlyThroughWormhole, x = hop.x, y = hop.y,
                gate = hop.kind ~= "wormhole", automationApi = plan.id, hop = index}
    end

    return {action = OrderType.Jump, x = hop.x, y = hop.y,
            automationApi = plan.id, hop = index}
end

-- The chain that flies `plan` from hop `from` onwards, validated the way addJumpOrder
-- validates each jump: from wherever the previous order leaves the ship. Returns the
-- orders, or nil and a reason.
local function automationApiBuildChain(plan, from)
    local x, y = Sector():getCoordinates()
    local orders = {}

    local function add(index)
        local hop = plan.hops[index]

        if not hop.gate then
            local valid, reason = automationApiJumpValid(x, y, hop.x, hop.y)
            if not valid then
                return string.format("hop %d, (%d:%d) -> (%d:%d): %s", index, x, y,
                                     hop.x, hop.y, tostring(reason or "jump not possible"))
            end
        end

        orders[#orders + 1] = automationApiHopOrder(plan, index)
        x, y = hop.x, hop.y
    end

    for index = from, #plan.hops do
        local failure = add(index)
        if failure then return nil, failure end
    end

    if plan.loopFrom then
        local loopStart

        if from > plan.loopFrom then
            -- resuming partway round: finish this lap, then fly the whole loop again and
            -- repeat that part
            loopStart = #orders + 1
            for index = plan.loopFrom, #plan.hops do
                local failure = add(index)
                if failure then return nil, failure end
            end
        else
            loopStart = plan.loopFrom - from + 1
        end

        -- the lap has to close: the last hop leads back to the first of the loop
        local first = plan.hops[plan.loopFrom]
        if not first.gate then
            local valid, reason = automationApiJumpValid(x, y, first.x, first.y)
            if not valid then
                return nil, string.format("the loop does not close, (%d:%d) -> (%d:%d): %s",
                                          x, y, first.x, first.y,
                                          tostring(reason or "jump not possible"))
            end
        end

        orders[#orders + 1] = {action = OrderType.Loop, loopIndex = loopStart,
                               automationApi = plan.id}
    end

    return orders
end

local function automationApiReplaceChain(orders)
    OrderChain.clearAllOrders()

    for _, order in ipairs(orders) do
        OrderChain.enchain(order)
    end

    OrderChain.runOrders()
end

local function automationApiOwnsChain(plan)
    local chain = OrderChain.chain
    if #chain == 0 then return false end

    for _, order in ipairs(chain) do
        if order.automationApi ~= plan.id then return false end
    end

    return true
end

local function automationApiEndPlan(outcome, reason)
    local plan = automationApi.plan
    if not plan then return end

    local x, y = Sector():getCoordinates()

    automationApi.last =
    {
        id = plan.id,
        kind = plan.kind,
        outcome = outcome,
        reason = reason,
        jumps = plan.jumps,
        fights = plan.fights,
        sector = {x = x, y = y},
    }

    automationApi.plan = nil
    automationApiPublish()
end

-- #### FIGHTING #### --

local function automationApiStartFight(plan)
    local current = OrderChain.chain[OrderChain.activeOrder]

    -- the hop the ship was on has not happened yet, so it is where the route picks up
    if current and current.hop then
        plan.resumeAt = current.hop
    elseif plan.loopFrom then
        plan.resumeAt = plan.loopFrom
    else
        plan.resumeAt = plan.resumeAt or 1
    end

    local hold = plan.onEnemies == "hold"

    automationApiReplaceChain({{
        action = OrderType.Aggressive,
        attackCivilShips = plan.attackCivilians == true,
        -- holding means staying aggressive after the sector is clear, which is an order
        -- that never finishes
        canFinish = not hold,
        automationApi = plan.id,
    }})

    plan.phase = hold and "holding" or "fighting"
    plan.fights = plan.fights + 1
    plan.clearFor = 0

    automationApiPublish()
end

local function automationApiResume(plan)
    local orders, failure = automationApiBuildChain(plan, plan.resumeAt or 1)

    if not orders then
        automationApiEndPlan("resume_failed", failure)
        return
    end

    plan.phase = "running"
    plan.clearFor = 0

    automationApiReplaceChain(orders)
    automationApiPublish()
end

-- #### TICK #### --

local function automationApiTickPlan(plan, timeStep, enemies)
    local x, y = Sector():getCoordinates()

    if plan.sector.x ~= x or plan.sector.y ~= y then
        plan.sector = {x = x, y = y}
        plan.jumps = plan.jumps + 1
        automationApiPublish()
    end

    -- A boss spawn counts the jumps of the player aboard, not of the ship. With nobody at
    -- the controls the loop is jumps for nothing, so it stops rather than burn fuel.
    if plan.kind == "farm" and not automationApiPiloted() then
        OrderChain.clearAllOrders()
        automationApiEndPlan("pilot_left",
                             "Nobody is aboard any more, and boss spawns only count the "
                             .. "jumps of a player on the ship.")
        return
    end

    if plan.phase == "running" then
        if #OrderChain.chain == 0 then
            local target = plan.hops[#plan.hops]
            if not plan.loopFrom and target and target.x == x and target.y == y then
                automationApiEndPlan("arrived")
            else
                automationApiEndPlan("stopped",
                                     "The chain emptied before the route was flown - a "
                                     .. "jump the game refused, or orders cleared in game.")
            end
            return
        end

        if not automationApiOwnsChain(plan) then
            automationApiEndPlan("replaced", "Other orders replaced the route.")
            return
        end

        if enemies and plan.onEnemies ~= "continue" then
            automationApiStartFight(plan)
        end

        return
    end

    if plan.phase == "fighting" then
        -- an aggressive order that finished takes the chain with it, so an empty chain is
        -- the fight ending as well as someone clearing it
        if #OrderChain.chain > 0 and not automationApiOwnsChain(plan) then
            automationApiEndPlan("replaced", "Other orders replaced the fight.")
            return
        end

        if enemies then
            plan.clearFor = 0
            return
        end

        plan.clearFor = (plan.clearFor or 0) + timeStep

        if plan.clearFor >= AUTOMATION_API_CLEAR_GRACE or #OrderChain.chain == 0 then
            automationApiResume(plan)
        end

        return
    end

    if plan.phase == "holding" then
        if not automationApiOwnsChain(plan) then
            automationApiEndPlan("replaced", "Other orders replaced the hold.")
        end
    end
end

-- Idle defence: a ship with nothing to do, and enemies in its sector, fights them. The
-- order finishes on its own when the sector is clear, and the ship goes back to idle.
--
-- A captain is required, as vanilla requires one for any order a player gives a ship
-- they are not standing next to. A piloted ship is left alone: whoever is flying it is
-- the one deciding what it does.
local function automationApiTickIdle(enemies)
    if not automationApi.settings.autoAggressive or not enemies then return end

    local chain = OrderChain.chain
    if #chain > 0 and not OrderChain.finished then return end

    local entity = Entity()
    if automationApiPiloted() or not entity:getCaptain() then return end

    automationApiReplaceChain({{
        action = OrderType.Aggressive,
        attackCivilShips = automationApi.settings.attackCivilians == true,
        canFinish = true,
        automationApi = "defence",
    }})

    automationApi.defenceFights = automationApi.defenceFights + 1
    automationApiPublish()
end

local function automationApiTick(timeStep)
    -- Every craft with an order chain runs this, most of them with nothing switched on.
    -- Those look at nothing and publish nothing, so a fleet sitting near a fight does not
    -- fill every ship's event log with enemies coming and going.
    if not automationApi.plan and not automationApi.settings.autoAggressive then
        automationApi.enemies = false
        return
    end

    local enemies = automationApiEnemiesPresent()

    if enemies ~= automationApi.enemies then
        automationApi.enemies = enemies
        automationApiPublish()
    end

    if automationApi.plan then
        automationApiTickPlan(automationApi.plan, timeStep, enemies)
    else
        automationApiTickIdle(enemies)
    end
end

-- #### CALLABLES #### --

-- Replaces the chain with a route. `payload` is JSON rather than a table because it
-- crosses invokeEntityFunction, and only plain values are known to survive that.
function OrderChain.automationApiRunPlan(payload)
    if not automationApiPermitted() then return end

    local ok, spec = pcall(AutomationApiJson.decode, payload)
    if not ok or type(spec) ~= "table" or type(spec.hops) ~= "table" or #spec.hops == 0 then
        automationApiLog("rejected a malformed plan")
        return
    end

    local x, y = Sector():getCoordinates()

    local plan =
    {
        id = tostring(spec.id or "plan"),
        kind = spec.kind == "farm" and "farm" or "route",
        hops = {},
        loopFrom = tonumber(spec.loopFrom),
        onEnemies = spec.onEnemies,
        attackCivilians = spec.attackCivilians == true,
        boss = spec.boss,
        phase = "running",
        jumps = 0,
        fights = 0,
        sector = {x = x, y = y},
    }

    if plan.onEnemies ~= "hold" and plan.onEnemies ~= "continue" then
        plan.onEnemies = "fight"
    end

    for index, hop in ipairs(spec.hops) do
        plan.hops[index] =
        {
            x = math.floor(tonumber(hop.x) or 0),
            y = math.floor(tonumber(hop.y) or 0),
            gate = hop.kind == "gate" or hop.kind == "wormhole",
            kind = hop.kind,
        }
    end

    if plan.loopFrom and (plan.loopFrom < 1 or plan.loopFrom > #plan.hops) then
        plan.loopFrom = nil
    end

    -- the same rule addJumpOrder applies: changing sector takes a captain or a pilot
    if not Entity():getCaptain() and not automationApiPiloted() then
        automationApi.last = {id = plan.id, kind = plan.kind, outcome = "refused",
                              reason = "needs_captain", jumps = 0, fights = 0,
                              sector = {x = x, y = y}}
        automationApiPublish()
        return
    end

    local orders, failure = automationApiBuildChain(plan, 1)
    if not orders then
        automationApi.last = {id = plan.id, kind = plan.kind, outcome = "refused",
                              reason = failure, jumps = 0, fights = 0,
                              sector = {x = x, y = y}}
        automationApiPublish()
        return
    end

    -- a plan replacing a plan still says how the previous one ended
    if automationApi.plan then automationApiEndPlan("replaced", "A new plan was sent.") end

    automationApi.plan = plan
    automationApiReplaceChain(orders)
    automationApiPublish()
end
callable(OrderChain, "automationApiRunPlan")

function OrderChain.automationApiConfigure(payload)
    if not automationApiPermitted() then return end

    local ok, spec = pcall(AutomationApiJson.decode, payload)
    if not ok or type(spec) ~= "table" then return end

    if spec.autoAggressive ~= nil then
        automationApi.settings.autoAggressive = spec.autoAggressive == true
    end
    if spec.attackCivilians ~= nil then
        automationApi.settings.attackCivilians = spec.attackCivilians == true
    end

    automationApiPublish()
end
callable(OrderChain, "automationApiConfigure")

-- Stops a plan and clears the chain. Idle defence is a setting and stays as it was.
function OrderChain.automationApiStop()
    if not automationApiPermitted() then return end

    if automationApi.plan then
        OrderChain.clearAllOrders()
        automationApiEndPlan("stopped", "Stopped through the API.")
    else
        automationApiPublish()
    end
end
callable(OrderChain, "automationApiStop")

-- #### VANILLA HOOKS #### --

local automationApiVanillaUpdateServer = OrderChain.updateServer
function OrderChain.updateServer(timeStep)
    automationApiVanillaUpdateServer(timeStep)

    -- nothing here may take the ship's own order chain down with it
    local ok, err = pcall(automationApiTick, timeStep)
    if not ok then automationApiLog("tick failed: %s", tostring(err)) end
end

local automationApiVanillaGetOrderInfo = OrderChain.getOrderInfo
function OrderChain.getOrderInfo()
    local info = automationApiVanillaGetOrderInfo()

    local ok, described = pcall(automationApiDescribe)
    if ok then info.automationApi = described end

    return info
end

local automationApiVanillaSecure = OrderChain.secure
function OrderChain.secure()
    local data = automationApiVanillaSecure()

    data.automationApi =
    {
        settings = automationApi.settings,
        plan = automationApi.plan,
        last = automationApi.last,
        defenceFights = automationApi.defenceFights,
    }

    return data
end

local automationApiVanillaRestore = OrderChain.restore
function OrderChain.restore(data)
    local saved = type(data) == "table" and data.automationApi or nil

    if type(saved) == "table" then
        if type(saved.settings) == "table" then
            automationApi.settings.autoAggressive = saved.settings.autoAggressive == true
            automationApi.settings.attackCivilians = saved.settings.attackCivilians == true
        end
        automationApi.plan = type(saved.plan) == "table" and saved.plan or nil
        automationApi.last = type(saved.last) == "table" and saved.last or nil
        automationApi.defenceFights = tonumber(saved.defenceFights) or 0
    end

    automationApiVanillaRestore(data)
end

end
