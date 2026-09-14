
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

-- Vanilla's no-spawn timer after a boss dies (player/story/spawnrandombosses.lua sets
-- noSpawnTimer = 30 * 60 for Swoks and for the AI alike). It is one timer per player, shared
-- by both bosses, and while it runs onSectorEntered returns before the jump counter is even
-- touched - so jumps during it are fuel spent for nothing, not progress towards a spawn.
local AUTOMATION_API_BOSS_COOLDOWN = 30 * 60

-- The scripts vanilla puts on each boss. Nothing else carries them, which makes them a
-- surer test than titles (translated, numbered) or factions (Swoks flies for the pirates).
local AUTOMATION_API_BOSSES =
{
    {name = "swoks", script = "entity/story/swoks.lua"},
    {name = "ai", script = "entity/story/aibehaviour.lua"},
}

-- How often a farm looks at the sector for bosses and loot. The enemy check stays per tick.
local AUTOMATION_API_SCAN_INTERVAL = 1

-- Looting limits. Fighters are re-ordered periodically, as vanilla's harvest AI does every
-- three seconds, because a squad that finds nothing within reach drifts back on its own.
local AUTOMATION_API_LOOT_MAX = 300        -- the whole collection, at most
local AUTOMATION_API_LOOT_STALL = 45       -- no drop picked up for this long ends it
local AUTOMATION_API_LOOT_LAUNCH = 20      -- no fighter out after this long ends it
local AUTOMATION_API_RETURN_MAX = 90       -- waiting for fighters to land before jumping
local AUTOMATION_API_ORDER_REPEAT = 5

-- A cooldown republishes its remaining time this often. Every publish is an event in the
-- ship's feed, so once a minute is enough for a client to keep an honest countdown.
local AUTOMATION_API_COOLDOWN_PUBLISH = 60

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

-- #### SECTOR SCANS #### --

-- "Boss Swoks ${num}" and friends: the title is a template and its arguments come apart.
local function automationApiTitleOf(entity)
    local ok, title = pcall(function() return entity.title end)
    if not ok or type(title) ~= "string" or title == "" then return nil end

    local okArgs, args = pcall(function() return entity:getTitleArguments() end)
    if okArgs and type(args) == "table" then
        title = string.gsub(title, "%${([%w_]+)}", function(key)
            return args[key] ~= nil and tostring(args[key]) or nil
        end)
    end

    return title
end

local function automationApiFindBoss()
    for _, boss in ipairs(AUTOMATION_API_BOSSES) do
        local ok, entity = pcall(function() return Sector():getEntitiesByScript(boss.script) end)
        if ok and entity then
            return {name = boss.name, title = automationApiTitleOf(entity)}
        end
    end

    return nil
end

-- Whether fighters of this ship may pick up cargo drops. That takes two things, both checked
-- in the engine with the boss lab (lib/automationapi/devsetup.lua): the FighterCargoPickup
-- stat, which Transporter Software of rare or better adds when permanently installed (see
-- systems/transportersoftware.lua), and a transporter block. Either one alone and the
-- fighters leave every cargo drop where it is.
--
-- Loot:isCollectable does not answer this: it is true for cargo on any ship with hold space,
-- fighters able to carry it or not. And every ship has a Transporter component, block or
-- not, so the block is counted in the plan.
local function automationApiCargoPickup(ship)
    local okStat, value = pcall(function()
        return ship:getBoostedValue(StatsBonuses.FighterCargoPickup, 0)
    end)
    if not okStat or (tonumber(value) or 0) <= 0 then return false end

    local okBlocks, blocks = pcall(function()
        return Plan(ship):getNumBlocks(BlockType.Transporter)
    end)

    return okBlocks and (tonumber(blocks) or 0) > 0
end

-- Loot in the sector this ship is allowed to pick up, split the way fighters see it: cargo
-- drops need the pickup stat above, everything else (money, resources, turrets, subsystems,
-- inventory items) is collected on contact. Loot reserved for somebody else is not counted.
local function automationApiLootIn(ship)
    local found = {instant = 0, cargo = 0}

    local ok, loots = pcall(function() return {Sector():getEntitiesByType(EntityType.Loot)} end)
    if not ok then return found end

    for _, loot in ipairs(loots) do
        local okCollectable, collectable = pcall(function() return loot:isCollectable(ship) end)

        if okCollectable and collectable then
            local okCargo, cargo = pcall(function()
                return loot:hasComponent(ComponentType.CargoLoot)
            end)

            if okCargo and cargo then
                found.cargo = found.cargo + 1
            else
                found.instant = found.instant + 1
            end
        end
    end

    return found
end

-- Fighters the ship has at all, how many of them are out, and the squad indices.
local function automationApiFighters()
    local total, deployed, squads = 0, 0, {}

    pcall(function()
        local hangar = Hangar()
        squads = {hangar:getSquads()}
        for _, squad in ipairs(squads) do
            total = total + (tonumber(hangar:getSquadFighters(squad)) or 0)
        end
    end)

    pcall(function()
        deployed = #{FighterController():getDeployedFighters()}
    end)

    return math.max(total, deployed), deployed, squads
end

local function automationApiOrderSquads(orders)
    local _, _, squads = automationApiFighters()

    pcall(function()
        local controller = FighterController()
        for _, squad in ipairs(squads) do
            controller:setSquadOrders(squad, orders, Uuid())
        end
    end)
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
        bossPresent = plan.bossHere and {name = plan.bossHere.name, title = plan.bossHere.title}
                      or nil,
        -- nil on routes, which have no bosses to count or loot to collect
        bossKills = plan.bossKills,
        lastKill = plan.lastKill,
        collectLoot = plan.collectLoot,
        loot = plan.loot,
        lootResult = plan.lootResult,
        cooldown = (plan.cooldownLeft or 0) > 0
                   and {left = math.ceil(plan.cooldownLeft), total = plan.bossCooldown} or nil,
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

local function automationApiAggressive(plan)
    local hold = plan.onEnemies == "hold"

    automationApiReplaceChain({{
        action = OrderType.Aggressive,
        attackCivilShips = plan.attackCivilians == true,
        -- holding means staying aggressive after the sector is clear, which is an order
        -- that never finishes
        canFinish = not hold,
        automationApi = plan.id,
    }})
end

local function automationApiStartFight(plan)
    -- the hop the ship was on has not happened yet, so it is where the route picks up. A
    -- fight that breaks into looting or a cooldown has no hop on the chain, and keeps the
    -- one the first fight saved.
    if plan.phase == "running" then
        local current = OrderChain.chain[OrderChain.activeOrder]

        if current and current.hop then
            plan.resumeAt = current.hop
        elseif plan.loopFrom then
            plan.resumeAt = plan.loopFrom
        else
            plan.resumeAt = plan.resumeAt or 1
        end
    end

    automationApiAggressive(plan)

    plan.phase = plan.onEnemies == "hold" and "holding" or "fighting"
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
    plan.loot = nil

    automationApiReplaceChain(orders)
    automationApiPublish()
end

-- #### BOSSES #### --

-- Watches a farm's sector for a boss, and counts its cooldown down. A boss that was in the
-- sector and is gone while the ship is still there has been killed: vanilla gives a boss no
-- other way out with a player in the sector (deleteonplayersleft needs them gone, and Swoks
-- only flies off after being paid through his dialog). The AI's own cooldown is started by
-- exactly this test in lib/story/ai.lua checkForDrop.
--
-- The cooldown runs on the ship's clock, which is the pilot's: the ship's sector is
-- simulated because they are in it, as the player script holding vanilla's timer is.
local function automationApiWatchBoss(plan, timeStep, moved)
    if (plan.cooldownLeft or 0) > 0 then
        plan.cooldownLeft = math.max(0, plan.cooldownLeft - timeStep)
    end

    plan.scanIn = (plan.scanIn or 0) - timeStep
    if plan.scanIn > 0 and not moved then return end
    plan.scanIn = AUTOMATION_API_SCAN_INTERVAL

    local x, y = Sector():getCoordinates()
    local boss = automationApiFindBoss()

    if boss then
        if not plan.bossHere then
            plan.bossHere = {name = boss.name, title = boss.title, x = x, y = y}
            automationApiPublish()
        end
        return
    end

    local seen = plan.bossHere
    if not seen then return end

    plan.bossHere = nil

    if seen.x == x and seen.y == y then
        plan.bossKills = (plan.bossKills or 0) + 1
        plan.lastKill = {name = seen.name, title = seen.title, sector = {x = x, y = y}}

        if (plan.bossCooldown or 0) > 0 then
            plan.cooldownLeft = plan.bossCooldown
        end
    end

    automationApiPublish()
end

-- #### LOOTING #### --

local function automationApiAfterLoot(plan)
    if (plan.cooldownLeft or 0) > 0 then
        -- nothing may be on the chain while the ship waits
        OrderChain.clearAllOrders()
        plan.phase = "cooldown"
        plan.publishIn = AUTOMATION_API_COOLDOWN_PUBLISH
        automationApiPublish()
        return
    end

    automationApiResume(plan)
end

local function automationApiLootWanted(ship)
    local loot = automationApiLootIn(ship)
    local cargoPickup = automationApiCargoPickup(ship)
    local fighters, deployed = automationApiFighters()

    loot.cargoPickup = cargoPickup
    loot.fighters = fighters
    loot.deployed = deployed

    return loot.instant + (cargoPickup and loot.cargo or 0), loot
end

-- Sends the fighters out for what the fight left behind, if there is any the ship's
-- fighters can take. Returns whether looting started.
local function automationApiStartLooting(plan)
    local wanted, loot = automationApiLootWanted(Entity())

    plan.loot = (loot.instant + loot.cargo) > 0 and loot or nil

    if wanted == 0 then return false end

    if loot.fighters == 0 then
        plan.lootResult = "no_fighters"
        return false
    end

    OrderChain.clearAllOrders()

    plan.phase = "looting"
    plan.phaseFor = 0
    plan.stallFor = 0
    plan.lootLeft = wanted
    plan.orderIn = 0
    plan.lootScanIn = AUTOMATION_API_SCAN_INTERVAL

    automationApiPublish()
    return true
end

local function automationApiFinishLooting(plan, result)
    plan.lootResult = result
    plan.phase = "returning"
    plan.phaseFor = 0
    plan.orderIn = AUTOMATION_API_ORDER_REPEAT

    automationApiOrderSquads(FighterOrders.Return)
    automationApiPublish()
end

local function automationApiAfterFight(plan)
    if plan.collectLoot and automationApiStartLooting(plan) then return end
    automationApiAfterLoot(plan)
end

local function automationApiTickLooting(plan, timeStep)
    plan.phaseFor = plan.phaseFor + timeStep
    plan.stallFor = plan.stallFor + timeStep

    plan.orderIn = plan.orderIn - timeStep
    if plan.orderIn <= 0 then
        plan.orderIn = AUTOMATION_API_ORDER_REPEAT
        automationApiOrderSquads(FighterOrders.CollectLoot)
    end

    plan.lootScanIn = plan.lootScanIn - timeStep
    if plan.lootScanIn > 0 then return end
    plan.lootScanIn = AUTOMATION_API_SCAN_INTERVAL

    local wanted, loot = automationApiLootWanted(Entity())

    if wanted < plan.lootLeft then plan.stallFor = 0 end

    local changed = not plan.loot or plan.loot.instant ~= loot.instant
                    or plan.loot.cargo ~= loot.cargo or plan.loot.deployed ~= loot.deployed
    plan.lootLeft = wanted
    plan.loot = loot
    if changed then automationApiPublish() end

    if wanted == 0 then
        automationApiFinishLooting(plan, "collected")
    elseif loot.deployed == 0 and plan.phaseFor >= AUTOMATION_API_LOOT_LAUNCH then
        -- no pilots, or squads the hangar will not start
        automationApiFinishLooting(plan, "no_launch")
    elseif plan.stallFor >= AUTOMATION_API_LOOT_STALL then
        automationApiFinishLooting(plan, "stalled")
    elseif plan.phaseFor >= AUTOMATION_API_LOOT_MAX then
        automationApiFinishLooting(plan, "timeout")
    end
end

-- A jump leaves fighters that are out behind, so the ship waits for them to land.
local function automationApiTickReturning(plan, timeStep)
    plan.phaseFor = plan.phaseFor + timeStep

    local _, deployed = automationApiFighters()

    if deployed == 0 then
        automationApiAfterLoot(plan)
        return
    end

    if plan.phaseFor >= AUTOMATION_API_RETURN_MAX then
        -- Stragglers that cannot find their way back (out of reach, stuck) are pulled in
        -- rather than abandoned, then the plan moves on regardless.
        pcall(function() Hangar():collectAllFighters() end)
        plan.lootResult = (plan.lootResult or "collected") .. "_recalled"
        automationApiAfterLoot(plan)
        return
    end

    plan.orderIn = plan.orderIn - timeStep
    if plan.orderIn <= 0 then
        plan.orderIn = AUTOMATION_API_ORDER_REPEAT
        automationApiOrderSquads(FighterOrders.Return)
    end
end

local function automationApiTickCooldown(plan, timeStep)
    if (plan.cooldownLeft or 0) <= 0 then
        automationApiResume(plan)
        return
    end

    plan.publishIn = (plan.publishIn or 0) - timeStep
    if plan.publishIn <= 0 then
        plan.publishIn = AUTOMATION_API_COOLDOWN_PUBLISH
        automationApiPublish()
    end
end

-- #### TICK #### --

local function automationApiTickPlan(plan, timeStep, enemies)
    local x, y = Sector():getCoordinates()

    local moved = plan.sector.x ~= x or plan.sector.y ~= y

    if moved then
        plan.sector = {x = x, y = y}
        plan.jumps = plan.jumps + 1
        -- a boss left behind in another sector was not killed
        plan.bossHere = nil
        automationApiPublish()
    end

    -- Farms treat a boss as a reason to stay even before it turns hostile: Swoks arrives
    -- registered as a friend of the player it spawned for, and jumping away from him loses
    -- the fight the whole loop was for.
    local hostile = enemies

    if plan.kind == "farm" then
        automationApiWatchBoss(plan, timeStep, moved)
        hostile = hostile or plan.bossHere ~= nil
    end

    local fights = hostile and plan.onEnemies ~= "continue"

    -- A boss spawn counts the jumps of the player aboard, not of the ship. With nobody at
    -- the controls the loop is jumps for nothing, so it stops rather than burn fuel. Only a
    -- ship about to jump is stopped: a fight, fighters out collecting or a cooldown carry on
    -- without a pilot, and the check comes round again once the loop resumes.
    if plan.kind == "farm" and plan.phase == "running" and not automationApiPiloted() then
        OrderChain.clearAllOrders()
        automationApiEndPlan("pilot_left",
                             "Nobody is aboard any more, and boss spawns only count the "
                             .. "jumps of a player on the ship.")
        return
    end

    -- Looting, returning and cooldown keep the chain empty, so anything on it is somebody
    -- else's orders.
    if plan.phase == "looting" or plan.phase == "returning" or plan.phase == "cooldown" then
        if #OrderChain.chain > 0 then
            automationApiEndPlan("replaced", "Other orders replaced the " .. plan.phase .. ".")
            return
        end

        if fights then
            automationApiStartFight(plan)
        elseif plan.phase == "looting" then
            automationApiTickLooting(plan, timeStep)
        elseif plan.phase == "returning" then
            automationApiTickReturning(plan, timeStep)
        else
            automationApiTickCooldown(plan, timeStep)
        end

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

        if fights then
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

        if hostile then
            plan.clearFor = 0

            -- An aggressive order finishes when the AI sees nobody to fight, which a boss
            -- that has not turned hostile yet allows. The ship waits by it, and is ordered
            -- in again the moment there are enemies.
            if enemies and #OrderChain.chain == 0 then automationApiAggressive(plan) end
            return
        end

        plan.clearFor = (plan.clearFor or 0) + timeStep

        if plan.clearFor >= AUTOMATION_API_CLEAR_GRACE or #OrderChain.chain == 0 then
            automationApiAfterFight(plan)
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

    if plan.kind == "farm" then
        plan.bossKills = 0
        plan.collectLoot = spec.collectLoot ~= false
        plan.bossCooldown = math.max(0, tonumber(spec.bossCooldown) or AUTOMATION_API_BOSS_COOLDOWN)
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
        -- A boss seen before a reload is not proof of a kill after it: a restart sends every
        -- boss away with the sector, and resets vanilla's own cooldown with the player script.
        if automationApi.plan then automationApi.plan.bossHere = nil end
        automationApi.last = type(saved.last) == "table" and saved.last or nil
        automationApi.defenceFights = tonumber(saved.defenceFights) or 0
    end

    automationApiVanillaRestore(data)
end

end
