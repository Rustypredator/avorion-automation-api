
-- Automation API: route plans, enemy handling and standing orders, run by the ship itself.
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

-- A standing loot order that could not take everything (a stall, fighters that would not
-- launch) leaves that sector's loot alone for this long. Without it the same unreachable
-- drop would send the fighters out again the moment they landed, for ever.
local AUTOMATION_API_LOOT_RETRY = 120

-- The orders a ship keeps without being told again, and when each one may take the ship:
-- "idle" only while it has nothing to do, "interrupt" whatever it is doing, after which
-- the chain it was flying is put back.
local AUTOMATION_API_STANDING = {"enemies", "loot"}
local AUTOMATION_API_STANDING_MODES = {idle = true, interrupt = true}

-- Cargo transfers. The reach is vanilla's (entity/transfercrewgoods.lua,
-- checkPermissionsAndDistance): the nearest points of the two craft at most 20 apart, or
-- as far as the longer transporter reaches.
local AUTOMATION_API_TRANSFER_REACH = 20
local AUTOMATION_API_APPROACH_MAX = 300     -- docking or flying alongside, at most
local AUTOMATION_API_APPROACH_REPEAT = 3    -- the fly target is renewed, as the target moves

local function automationApiDefaultStanding()
    return
    {
        enemies = {enabled = false, mode = "idle"},
        loot = {enabled = false, mode = "idle"},
    }
end

local automationApi =
{
    settings = {attackCivilians = false, standing = automationApiDefaultStanding()},
    -- a standing order currently holding the ship, or nil. Never alongside a plan: a plan
    -- brings its own enemy handling, and a plan being sent ends the reaction.
    reaction = nil,
    lastReaction = nil,
    -- times a standing loot order sent the fighters out, over the life of the ship
    lootRuns = 0,
    -- {x, y, left}: the sector whose loot is being left alone, see AUTOMATION_API_LOOT_RETRY
    lootBackoff = nil,
    lootScanIn = 0,
    -- the plan currently driving the chain, or nil
    plan = nil,
    -- how the previous plan ended, so a caller polling after the fact can tell
    last = nil,
    -- fights started by the standing enemies order, over the life of the ship. The name
    -- is from when that order was the only one and was called idle defence.
    defenceFights = 0,
    enemies = false,
    -- a cargo transfer waiting for the ship to come into reach, or nil; and how the
    -- previous one ended
    transfer = nil,
    lastTransfer = nil,
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

-- Orders the fighters that are already out, one by one.
--
-- A squad order is what the hangar launches on, but it does not take a fighter off an order
-- of its own, and a fight gives every fighter one: the engine's combat AI assigns targets
-- per fighter (FighterAI:setOrders, the way vanilla's behemoth does in
-- entity/background/behemothbehavior.lua). That is why loot collection after a fight found
-- the squads flying home and nothing collected - the fighters were still flying what the
-- fight left them, and the squad's CollectLoot only applied to whatever launched next.
--
-- A fighter on Attack is left alone. It has something to shoot, and the engine sends it
-- home by itself once the sector is clear, so taking it off its target to chase a drop
-- would leave the ship fighting without its fighters. Everything else - above all the
-- Return the end of a fight leaves behind - is overwritten.
local function automationApiOrderDeployed(orders)
    local ok, deployed = pcall(function()
        return {FighterController():getDeployedFighters()}
    end)
    if not ok then return end

    for _, fighter in ipairs(deployed) do
        pcall(function()
            local ai = FighterAI(fighter)
            local current = ai.orders

            if current ~= orders and current ~= FighterOrders.Attack then
                ai:setOrders(orders, Uuid())
            end
        end)
    end
end

local function automationApiOrderSquads(orders)
    local _, _, squads = automationApiFighters()

    pcall(function()
        local controller = FighterController()
        for _, squad in ipairs(squads) do
            controller:setSquadOrders(squad, orders, Uuid())
        end
    end)

    automationApiOrderDeployed(orders)
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

local function automationApiDescribeReaction(reaction)
    return
    {
        kind = reaction.kind,
        mode = reaction.mode,
        phase = reaction.phase,
        -- whether a chain was put aside and comes back when this is over
        resumes = reaction.saved ~= nil,
        loot = reaction.loot,
        lootResult = reaction.lootResult,
    }
end

local function automationApiDescribeTransfer(transfer)
    return
    {
        id = transfer.id,
        target = transfer.target.name,
        direction = transfer.direction,
        all = transfer.all,
        -- an empty table would cross as an object
        goods = #transfer.goods > 0 and transfer.goods or nil,
        phase = transfer.phase,
    }
end

local function automationApiDescribe()
    local x, y = Sector():getCoordinates()
    local standing = automationApi.settings.standing

    local described = {}
    for _, name in ipairs(AUTOMATION_API_STANDING) do
        described[name] = {enabled = standing[name].enabled == true, mode = standing[name].mode}
    end

    return
    {
        version = 1,
        -- kept for clients from before standing orders: the enemies order, in any mode
        autoAggressive = standing.enemies.enabled == true,
        attackCivilians = automationApi.settings.attackCivilians == true,
        standing = described,
        defenceFights = automationApi.defenceFights,
        lootRuns = automationApi.lootRuns,
        enemies = automationApi.enemies == true,
        sector = {x = x, y = y},
        plan = automationApi.plan and automationApiDescribePlan(automationApi.plan) or nil,
        last = automationApi.last,
        reaction = automationApi.reaction and automationApiDescribeReaction(automationApi.reaction)
                   or nil,
        lastReaction = automationApi.lastReaction,
        transfer = automationApi.transfer and automationApiDescribeTransfer(automationApi.transfer)
                   or nil,
        lastTransfer = automationApi.lastTransfer,
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

-- Whether every order on the chain carries `tag`: a plan's id, or "standing".
local function automationApiChainTagged(tag)
    local chain = OrderChain.chain
    if #chain == 0 then return false end

    for _, order in ipairs(chain) do
        if order.automationApi ~= tag then return false end
    end

    return true
end

local function automationApiOwnsChain(plan)
    return automationApiChainTagged(plan.id)
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
--
-- The looting phases work on whichever table holds them - a farm plan, or a standing
-- order's reaction - and are handed what to do once the fighters are back.
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

-- A farm says whether it loots. A route has no say of its own, and loots when the ship
-- has a standing loot order allowed to interrupt: the route is what it would interrupt.
local function automationApiAfterFight(plan)
    local loot = automationApi.settings.standing.loot
    local collect = plan.collectLoot
    if collect == nil then collect = loot.enabled and loot.mode == "interrupt" end

    if collect and automationApiStartLooting(plan) then return end
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
local function automationApiTickReturning(plan, timeStep, done)
    plan.phaseFor = plan.phaseFor + timeStep

    local _, deployed = automationApiFighters()

    if deployed == 0 then
        done(plan)
        return
    end

    if plan.phaseFor >= AUTOMATION_API_RETURN_MAX then
        -- Stragglers that cannot find their way back (out of reach, stuck) are pulled in
        -- rather than abandoned, then the plan moves on regardless.
        pcall(function() Hangar():collectAllFighters() end)
        plan.lootResult = (plan.lootResult or "collected") .. "_recalled"
        done(plan)
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
            automationApiTickReturning(plan, timeStep, automationApiAfterLoot)
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

-- #### STANDING ORDERS #### --
--
-- Orders a ship keeps without a plan: fight enemies that turn up in its sector, and send
-- its fighters for loot lying in it. Each one is allowed either only while the ship is
-- idle, or to interrupt whatever chain it is flying. What either does while it holds the
-- ship is a reaction:
--
--   enemies   an aggressive order until the sector has been clear for a moment, then
--             the loot, if the loot order applies to what the ship was doing
--   loot      fighters out collecting, then waiting for them to land
--
-- An interrupted chain is put aside whole - orders, active index and how much of it was
-- executable - and put back the way vanilla's own restore() puts back a saved chain, so
-- loops keep their indices and the interrupted order simply starts again.
--
-- A captain is required, as vanilla requires one for any order a player gives a ship
-- they are not standing next to. A piloted ship is left alone: whoever is flying it is
-- the one deciding what it does.

local function automationApiMayAct()
    return not automationApiPiloted() and Entity():getCaptain() ~= nil
end

local function automationApiIdle()
    return #OrderChain.chain == 0 or OrderChain.finished
end

local function automationApiSaveChain()
    if automationApiIdle() or OrderChain.activeOrder == 0 then return nil end

    local orders = {}
    for index, order in ipairs(OrderChain.chain) do
        local copy = {}
        for key, value in pairs(order) do copy[key] = value end
        orders[index] = copy
    end

    return
    {
        chain = orders,
        activeOrder = OrderChain.activeOrder,
        executableOrders = OrderChain.executableOrders,
    }
end

-- Clears whatever the reaction left on the chain and puts `saved` back, if there is one.
local function automationApiRestoreChain(saved)
    OrderChain.clearAllOrders()
    if not saved or #saved.chain == 0 then return end

    OrderChain.chain = saved.chain
    OrderChain.activeOrder = math.max(0, saved.activeOrder - 1)
    OrderChain.executableOrders = math.max(saved.executableOrders or #saved.chain,
                                           saved.activeOrder)
    OrderChain.running = false
    OrderChain.finished = false

    -- activates the order after activeOrder, which is the interrupted one
    OrderChain.updateChain()
end

local function automationApiEndReaction(outcome, restore)
    local reaction = automationApi.reaction
    if not reaction then return end

    local x, y = Sector():getCoordinates()

    automationApi.reaction = nil
    automationApi.lastReaction =
    {
        kind = reaction.kind,
        outcome = outcome,
        lootResult = reaction.lootResult,
        resumed = restore == true and reaction.saved ~= nil,
        sector = {x = x, y = y},
    }

    -- Loot the fighters could not finish is left alone for a while, or the ship would
    -- keep launching at it.
    if reaction.lootResult and reaction.lootResult ~= "collected" then
        automationApi.lootBackoff = {x = x, y = y, left = AUTOMATION_API_LOOT_RETRY}
    end

    if restore then automationApiRestoreChain(reaction.saved) end

    automationApiPublish()
end

local function automationApiReactionFight(reaction)
    automationApiReplaceChain({{
        action = OrderType.Aggressive,
        attackCivilShips = automationApi.settings.attackCivilians == true,
        canFinish = true,
        automationApi = "standing",
    }})

    reaction.phase = "fighting"
    reaction.clearFor = 0

    automationApi.defenceFights = automationApi.defenceFights + 1
    automationApiPublish()
end

local function automationApiReactionLoot(reaction)
    if not automationApiStartLooting(reaction) then return false end

    automationApi.lootRuns = automationApi.lootRuns + 1
    automationApiPublish()
    return true
end

-- The fighters are back: the ship returns to what it was doing.
local function automationApiReactionLooted()
    automationApiEndReaction("done", true)
end

local function automationApiReact(kind, mode)
    local x, y = Sector():getCoordinates()

    local reaction =
    {
        kind = kind,
        mode = mode,
        saved = automationApiSaveChain(),
        sector = {x = x, y = y},
    }

    automationApi.reaction = reaction

    if kind == "enemies" then
        automationApiReactionFight(reaction)
    elseif not automationApiReactionLoot(reaction) then
        -- the loot went between the scan and now; nothing was touched
        automationApi.reaction = nil
    end
end

local function automationApiTickReaction(reaction, timeStep, enemies)
    local standing = automationApi.settings.standing

    if reaction.phase == "fighting" then
        -- an aggressive order that finished takes the chain with it, so an empty chain is
        -- the fight ending as well as someone clearing it
        if #OrderChain.chain > 0 and not automationApiChainTagged("standing") then
            automationApiEndReaction("replaced", false)
            return
        end

        if enemies then
            reaction.clearFor = 0
            if #OrderChain.chain == 0 then automationApiReactionFight(reaction) end
            return
        end

        reaction.clearFor = (reaction.clearFor or 0) + timeStep
        if reaction.clearFor < AUTOMATION_API_CLEAR_GRACE and #OrderChain.chain > 0 then return end

        -- The loot comes next if the loot order may take the ship from what it was doing:
        -- always when it was idle, only in interrupt mode when a chain is waiting.
        local loot = standing.loot
        if loot.enabled and (reaction.saved == nil or loot.mode == "interrupt") then
            if automationApiReactionLoot(reaction) then
                reaction.kind = "loot"
                automationApiPublish()
                return
            end
        end

        automationApiEndReaction("done", true)
        return
    end

    -- looting and returning keep the chain empty, so anything on it is somebody's orders
    if #OrderChain.chain > 0 then
        automationApiEndReaction("replaced", false)
        return
    end

    if enemies and standing.enemies.enabled then
        -- the ship is already taken from its chain, so the enemies order's mode is moot
        automationApiReactionFight(reaction)
        return
    end

    if reaction.phase == "looting" then
        automationApiTickLooting(reaction, timeStep)
    elseif reaction.phase == "returning" then
        automationApiTickReturning(reaction, timeStep, automationApiReactionLooted)
    end
end

local function automationApiTickStanding(timeStep, enemies)
    local standing = automationApi.settings.standing

    local backoff = automationApi.lootBackoff
    if backoff then
        backoff.left = backoff.left - timeStep
        if backoff.left <= 0 then automationApi.lootBackoff = nil end
    end

    if not automationApiMayAct() then return end

    local idle = automationApiIdle()

    local function applies(order)
        return order.enabled and (idle or order.mode == "interrupt")
    end

    if enemies then
        if not applies(standing.enemies) then return end

        -- an aggressive order the ship was given already does the job
        local current = OrderChain.chain[OrderChain.activeOrder]
        if not idle and current and current.action == OrderType.Aggressive then return end

        automationApiReact("enemies", standing.enemies.mode)
        return
    end

    -- nobody loots under fire
    if not applies(standing.loot) then return end

    automationApi.lootScanIn = (automationApi.lootScanIn or 0) - timeStep
    if automationApi.lootScanIn > 0 then return end
    automationApi.lootScanIn = AUTOMATION_API_SCAN_INTERVAL

    backoff = automationApi.lootBackoff
    if backoff then
        local x, y = Sector():getCoordinates()
        if backoff.x == x and backoff.y == y then return end
    end

    local wanted, loot = automationApiLootWanted(Entity())
    if wanted > 0 and loot.fighters > 0 then
        automationApiReact("loot", standing.loot.mode)
    end
end

-- #### CARGO TRANSFER #### --
--
-- Moving goods between this ship and another craft of the same player, or of the player
-- and their alliance. Vanilla's transfer window does it in a handful of server calls
-- (transfercrewgoods.lua: transferCargo, transferAllCargo) behind a check for who may and
-- how close the two are - and every one of those functions needs a calling player, so it
-- cannot be driven from the API and is done again here, with the same checks.
--
-- A target in reach is served at once, and the ship's own orders are not touched. One out
-- of reach is approached first, when the transfer allows it: a station with vanilla's own
-- dock order, a ship by flying alongside it (vanilla's FlyToPosition order exists but its
-- update is commented out, so the ship's AI is flown directly). That takes the ship like
-- any order does, so it needs a captain and nobody at the controls, and ends a plan or a
-- standing order holding the ship.

-- Engine names can carry translator hints ("Iron /* good */"); the API names goods without.
local function automationApiGoodName(good)
    local ok, name = pcall(function() return good.name end)
    if not ok or type(name) ~= "string" then return "" end

    name = string.gsub(name, "/%*.-%*/", "")
    return (string.gsub(name, "^%s*(.-)%s*$", "%1"))
end

-- A craft in this sector by owner and name, which is how the API names craft.
local function automationApiFindCraft(factionIndex, name)
    local sector = Sector()

    local ok, found = pcall(function() return {sector:getEntitiesByFaction(factionIndex)} end)
    if not ok then
        found = {}
        for _, entityType in ipairs({EntityType.Ship, EntityType.Station}) do
            local okType, list = pcall(function() return {sector:getEntitiesByType(entityType)} end)
            if okType then
                for _, entity in ipairs(list) do found[#found + 1] = entity end
            end
        end
    end

    for _, entity in ipairs(found) do
        local okName, entityName = pcall(function() return entity.name end)
        local okFaction, faction = pcall(function() return entity.factionIndex end)
        if okName and okFaction and entityName == name and faction == factionIndex then
            return entity
        end
    end

    return nil
end

-- The same player, or a player and their own alliance. The bridge only ever names craft of
-- the caller and the caller's alliance; this holds the ship to the same rule for anything
-- else that reaches the callable without a calling player.
local function automationApiSameOwner(ship, target)
    local a, b = ship.factionIndex, target.factionIndex
    if a == b then return true end

    -- The galaxy knows players who are not online, which Player(index) may not; and a
    -- property an alliance does not have raises in the engine rather than reading nil, so
    -- only a player is asked for its alliance.
    local function allianceOf(index)
        local ok, alliance = pcall(function()
            local faction = Galaxy():findFaction(index)
            if faction and faction.isPlayer then return faction.allianceIndex end
            return nil
        end)
        if ok then return alliance end

        ok, alliance = pcall(function()
            local player = Player(index)
            return player and player.allianceIndex or nil
        end)
        return ok and alliance or nil
    end

    return allianceOf(a) == b or allianceOf(b) == a
end

-- How far apart the two craft are, and how far the transfer reaches. A ship in a station's
-- docking area counts as touching it: that is where vanilla's dock order stops
-- (entity/ai/dock.lua, isInDockingArea) and what vanilla trading calls docked
-- (lib/player.lua CheckShipDocked), but the area reaches well past the 20 of hull distance,
-- so a docked ship measured by distance alone would never be in reach.
local function automationApiReach(ship, target)
    local okDocked, docked = pcall(function()
        return target:hasComponent(ComponentType.DockingPositions) and target:isInDockingArea(ship)
    end)
    if okDocked and docked then return 0, AUTOMATION_API_TRANSFER_REACH end

    local ok, distance = pcall(function() return ship:getNearestDistance(target) end)
    local reach = AUTOMATION_API_TRANSFER_REACH

    for _, craft in ipairs({ship, target}) do
        local okRange, range = pcall(function() return craft.transporterRange end)
        if okRange and tonumber(range) then reach = math.max(reach, tonumber(range)) end
    end

    return ok and tonumber(distance) or math.huge, reach
end

-- Moves what `transfer` asks for from sender to receiver, as much as there is and as much
-- as fits. Returns the outcome and what was moved and what was not.
local function automationApiMoveGoods(sender, receiver, transfer)
    local okCargo, cargos = pcall(function() return sender:getCargos() end)

    -- In a fixed order, clean goods before stolen ones of the same name, so a request that
    -- does not say which gets the ones a customs scan will not care about.
    local held = {}
    for good, amount in pairs(okCargo and type(cargos) == "table" and cargos or {}) do
        local okStolen, stolen = pcall(function() return good.stolen end)
        held[#held + 1] = {good = good, amount = tonumber(amount) or 0,
                           name = automationApiGoodName(good), stolen = okStolen and stolen == true}
    end
    table.sort(held, function(a, b)
        if a.name ~= b.name then return a.name < b.name end
        return not a.stolen and b.stolen
    end)

    local moved, movedBy, short = {}, {}, {}
    local total = 0

    local function free()
        local okFree, space = pcall(function() return receiver.freeCargoSpace end)
        return okFree and tonumber(space) or 0
    end

    local function record(item, amount)
        local key = item.name .. (item.stolen and "|stolen" or "")
        local entry = movedBy[key]
        if not entry then
            entry = {name = item.name, amount = 0, stolen = item.stolen or nil}
            movedBy[key] = entry
            moved[#moved + 1] = entry
        end
        entry.amount = entry.amount + amount
        total = total + amount
    end

    local wants = transfer.all and {{}} or transfer.goods

    for _, want in ipairs(wants) do
        local remaining = want.amount or math.huge
        local found, took = 0, 0
        local noSpace = false

        for _, item in ipairs(held) do
            local matches = transfer.all
                            or (item.name == want.name and (want.stolen == nil or want.stolen == item.stolen))

            if matches and item.amount > 0 and remaining > 0 then
                found = found + item.amount

                local amount = math.min(item.amount, remaining)
                local okSize, size = pcall(function() return item.good.size end)
                size = okSize and tonumber(size) or 0
                if size > 0 then amount = math.min(amount, math.floor(free() / size + 1e-6)) end

                if amount > 0 then
                    local removed = pcall(function() sender:removeCargo(item.good, amount) end)
                    if removed then
                        local added = pcall(function() receiver:addCargo(item.good, amount) end)
                        if added then
                            item.amount = item.amount - amount
                            remaining = remaining - amount
                            took = took + amount
                            record(item, amount)
                        else
                            -- nothing may be lost between the two holds
                            pcall(function() sender:addCargo(item.good, amount) end)
                        end
                    end
                end

                if item.amount > 0 and remaining > 0 then noSpace = true end
            end
        end

        if not transfer.all then
            local wanted = want.amount or found
            if found == 0 then
                short[#short + 1] = {name = want.name, wanted = want.amount, moved = 0, reason = "not_held"}
            elseif took < wanted then
                short[#short + 1] = {name = want.name, wanted = want.amount, moved = took,
                                     reason = noSpace and "no_space" or "not_enough"}
            end
        elseif noSpace then
            short[#short + 1] = {reason = "no_space"}
        end
    end

    local outcome = "done"
    if total == 0 then
        outcome = "nothing_moved"
    elseif #short > 0 then
        outcome = "partial"
    end

    return
    {
        outcome = outcome,
        total = total,
        moved = #moved > 0 and moved or nil,
        short = #short > 0 and short or nil,
        empty = transfer.all and #held == 0 or nil,
    }
end

local function automationApiEndTransfer(outcome, reason, result)
    local transfer = automationApi.transfer
    if not transfer then return end

    local x, y = Sector():getCoordinates()

    automationApi.transfer = nil
    automationApi.lastTransfer =
    {
        id = transfer.id,
        target = transfer.target.name,
        direction = transfer.direction,
        outcome = outcome,
        reason = reason,
        approached = transfer.phase ~= nil,
        moved = result and result.moved,
        short = result and result.short,
        total = result and result.total or 0,
        sector = {x = x, y = y},
    }

    automationApiPublish()
end

local function automationApiRunTransfer(target)
    local transfer = automationApi.transfer
    local ship = Entity()

    local sender, receiver = ship, target
    if transfer.direction == "take" then sender, receiver = target, ship end

    local result = automationApiMoveGoods(sender, receiver, transfer)
    automationApiEndTransfer(result.outcome, result.empty and "empty_hold" or nil, result)
end

local function automationApiStopApproach(transfer)
    if transfer.phase == "approaching" then
        pcall(function() ShipAI():setPassive() end)
    elseif transfer.phase == "docking" and automationApiChainTagged("transfer") then
        OrderChain.clearAllOrders()
    end
end

local function automationApiStartApproach(transfer, target)
    OrderChain.clearAllOrders()

    local okStation, station = pcall(function() return target.isStation end)

    if okStation and station then
        OrderChain.enchain({action = OrderType.DockToStation, targetId = target.id.string,
                            automationApi = "transfer"})
        OrderChain.runOrders()
        transfer.phase = "docking"
    else
        transfer.phase = "approaching"
        transfer.flyIn = 0
    end

    transfer.phaseFor = 0
end

local function automationApiTickTransfer(transfer, timeStep)
    transfer.phaseFor = (transfer.phaseFor or 0) + timeStep

    local target = automationApiFindCraft(transfer.target.faction, transfer.target.name)
    if not target then
        automationApiStopApproach(transfer)
        automationApiEndTransfer("refused", "target_gone")
        return
    end

    local distance, reach = automationApiReach(Entity(), target)

    if distance <= reach then
        -- A dock order that brought the ship this close is left to finish; the ship
        -- ends up docked, which is what the player would have done by hand.
        if transfer.phase == "approaching" then automationApiStopApproach(transfer) end
        automationApiRunTransfer(target)
        return
    end

    if transfer.phase == "docking" then
        -- The dock script ends with orderCompleted, which only stops the chain: the order
        -- stays on it and `finished` is never set. A stopped chain here means the ship
        -- arrived and is still not in reach, so waiting for the timeout would change nothing.
        if #OrderChain.chain == 0 or OrderChain.finished or not OrderChain.running then
            automationApiEndTransfer("refused", "out_of_range")
            return
        end
        if not automationApiChainTagged("transfer") then
            automationApiEndTransfer("replaced", "Other orders replaced the docking.")
            return
        end
    else
        if #OrderChain.chain > 0 and not OrderChain.finished then
            automationApiEndTransfer("replaced", "Other orders replaced the approach.")
            return
        end

        transfer.flyIn = (transfer.flyIn or 0) - timeStep
        if transfer.flyIn <= 0 then
            transfer.flyIn = AUTOMATION_API_APPROACH_REPEAT
            pcall(function()
                local ship = Entity()
                ShipAI():setFly(target.translationf, (tonumber(target.radius) or 0)
                                                     + (tonumber(ship.radius) or 0))
            end)
        end
    end

    if transfer.phaseFor >= AUTOMATION_API_APPROACH_MAX then
        automationApiStopApproach(transfer)
        automationApiEndTransfer("refused", "timeout")
    end
end

local function automationApiWatching()
    local standing = automationApi.settings.standing
    return automationApi.plan ~= nil or automationApi.reaction ~= nil
           or automationApi.transfer ~= nil
           or standing.enemies.enabled or standing.loot.enabled
end

local function automationApiTick(timeStep)
    -- Every craft with an order chain runs this, most of them with nothing switched on.
    -- Those look at nothing and publish nothing, so a fleet sitting near a fight does not
    -- fill every ship's event log with enemies coming and going.
    if not automationApiWatching() then
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
    elseif automationApi.reaction then
        automationApiTickReaction(automationApi.reaction, timeStep, enemies)
    elseif automationApi.transfer then
        -- the approach has the ship; standing orders wait until it is over
        automationApiTickTransfer(automationApi.transfer, timeStep)
    else
        automationApiTickStanding(timeStep, enemies)
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

    -- and a standing order holding the ship lets go; the chain it put aside is not wanted
    if automationApi.reaction then automationApiEndReaction("replaced", false) end

    -- as does a transfer still on its way to the target
    if automationApi.transfer then
        automationApiStopApproach(automationApi.transfer)
        automationApiEndTransfer("replaced", "A plan was sent.")
    end

    automationApi.plan = plan
    automationApiReplaceChain(orders)
    automationApiPublish()
end
callable(OrderChain, "automationApiRunPlan")

function OrderChain.automationApiConfigure(payload)
    if not automationApiPermitted() then return end

    local ok, spec = pcall(AutomationApiJson.decode, payload)
    if not ok or type(spec) ~= "table" then return end

    local standing = automationApi.settings.standing

    -- the setting from before standing orders: the enemies order, leaving its mode be
    if spec.autoAggressive ~= nil then
        standing.enemies.enabled = spec.autoAggressive == true
    end
    if spec.attackCivilians ~= nil then
        automationApi.settings.attackCivilians = spec.attackCivilians == true
    end

    if type(spec.standing) == "table" then
        for _, name in ipairs(AUTOMATION_API_STANDING) do
            local order = spec.standing[name]
            if type(order) == "table" then
                if order.enabled ~= nil then standing[name].enabled = order.enabled == true end
                if AUTOMATION_API_STANDING_MODES[order.mode] then standing[name].mode = order.mode end
            end
        end
    end

    -- A reaction whose order was just switched off stops, and the ship goes back to what
    -- it was doing. One whose order is still on carries on under the new settings.
    local reaction = automationApi.reaction
    if reaction then
        local order = standing[reaction.kind]
        if not order.enabled then automationApiEndReaction("switched_off", true) end
    end

    automationApiPublish()
end
callable(OrderChain, "automationApiConfigure")

-- Moves cargo between this ship and another craft in its sector. `payload` is JSON:
--
--   id          how the outcome is recognised in the published state
--   target      {faction, name} of the other craft
--   direction   give (ship to target) or take (target to ship)
--   all         the whole hold, or
--   goods       [{name, amount?, stolen?}], amount left out for all of that good
--   approach    whether to dock with or fly to a target out of reach first
--
-- The bridge checks the request before it gets here; the ship checks the world, and says
-- how it went in lastTransfer, or that it is on its way in transfer.
function OrderChain.automationApiTransfer(payload)
    if not automationApiPermitted() then return end

    local ok, spec = pcall(AutomationApiJson.decode, payload)
    if not ok or type(spec) ~= "table" or type(spec.target) ~= "table" then
        automationApiLog("rejected a malformed transfer")
        return
    end

    local x, y = Sector():getCoordinates()

    local transfer =
    {
        id = tostring(spec.id or "transfer"),
        target = {faction = tonumber(spec.target.faction) or -1, name = tostring(spec.target.name or "")},
        direction = spec.direction == "take" and "take" or "give",
        all = spec.all == true,
        goods = {},
        approach = spec.approach ~= false,
    }

    for _, good in ipairs(type(spec.goods) == "table" and spec.goods or {}) do
        if type(good) == "table" and type(good.name) == "string" then
            local amount = tonumber(good.amount)
            transfer.goods[#transfer.goods + 1] =
            {
                name = good.name,
                amount = amount and amount >= 1 and math.floor(amount) or nil,
            }
            -- false is an answer too: only goods that are not stolen
            if type(good.stolen) == "boolean" then transfer.goods[#transfer.goods].stolen = good.stolen end
        end
    end

    local function refuse(reason, message)
        automationApi.lastTransfer = {id = transfer.id, target = transfer.target.name,
                                      direction = transfer.direction, outcome = "refused",
                                      reason = reason, message = message, total = 0,
                                      sector = {x = x, y = y}}
        automationApiPublish()
    end

    if not transfer.all and #transfer.goods == 0 then
        refuse("no_goods")
        return
    end

    local ship = Entity()
    local target = automationApiFindCraft(transfer.target.faction, transfer.target.name)

    if not target then
        refuse("target_not_here", string.format("No craft called '%s' of that owner is in (%d:%d).",
                                                transfer.target.name, x, y))
        return
    end

    if target.index == ship.index then
        refuse("same_craft")
        return
    end

    local allowed
    if callingPlayer then
        allowed = checkEntityInteractionPermissions(target, AlliancePrivilege.ManageShips) ~= nil
    else
        allowed = automationApiSameOwner(ship, target)
    end
    if not allowed then
        refuse("not_permitted", "Cargo only moves between craft of the same player, or a player and their alliance.")
        return
    end

    local distance, reach = automationApiReach(ship, target)
    local inReach = distance <= reach

    if not inReach then
        if not transfer.approach then
            refuse("out_of_range", string.format("The craft are %d apart and the transfer reaches %d.",
                                                 math.floor(distance), math.floor(reach)))
            return
        end
        if automationApiPiloted() then
            refuse("piloted", "Someone is at the controls; the ship will not fly itself to the target.")
            return
        end
        if not ship:getCaptain() then
            refuse("needs_captain", "Flying to the target is an order, and orders need a captain.")
            return
        end
    end

    -- a transfer still on its way somewhere is superseded
    if automationApi.transfer then
        automationApiStopApproach(automationApi.transfer)
        automationApiEndTransfer("replaced", "Another transfer was sent.")
    end

    automationApi.transfer = transfer

    if inReach then
        -- nothing the ship is doing is touched
        automationApiRunTransfer(target)
        return
    end

    if automationApi.plan then
        automationApiEndPlan("replaced", "A cargo transfer took the ship.")
    end
    if automationApi.reaction then automationApiEndReaction("replaced", false) end

    automationApiStartApproach(transfer, target)
    automationApiPublish()
end
callable(OrderChain, "automationApiTransfer")

-- Stops a plan, a standing order holding the ship, or a transfer on its way, and clears
-- the chain. The standing orders are settings and stay as they were.
function OrderChain.automationApiStop()
    if not automationApiPermitted() then return end

    if automationApi.transfer then
        automationApiStopApproach(automationApi.transfer)
        automationApiEndTransfer("stopped", "Stopped through the API.")
        if not automationApi.plan and not automationApi.reaction then return end
    end

    if automationApi.plan then
        OrderChain.clearAllOrders()
        automationApiEndPlan("stopped", "Stopped through the API.")
    elseif automationApi.reaction then
        automationApiEndReaction("stopped", false)
        OrderChain.clearAllOrders()
        automationApiPublish()
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
        reaction = automationApi.reaction,
        lastReaction = automationApi.lastReaction,
        defenceFights = automationApi.defenceFights,
        lootRuns = automationApi.lootRuns,
        transfer = automationApi.transfer,
        lastTransfer = automationApi.lastTransfer,
    }

    return data
end

local automationApiVanillaRestore = OrderChain.restore
function OrderChain.restore(data)
    local saved = type(data) == "table" and data.automationApi or nil

    if type(saved) == "table" then
        local settings = saved.settings
        if type(settings) == "table" then
            automationApi.settings.attackCivilians = settings.attackCivilians == true

            local standing = automationApiDefaultStanding()
            local stored = type(settings.standing) == "table" and settings.standing or {}

            for _, name in ipairs(AUTOMATION_API_STANDING) do
                local order = stored[name]
                if type(order) == "table" then
                    standing[name].enabled = order.enabled == true
                    if AUTOMATION_API_STANDING_MODES[order.mode] then
                        standing[name].mode = order.mode
                    end
                end
            end

            -- a ship saved before standing orders had idle defence, which is this
            if stored.enemies == nil and settings.autoAggressive == true then
                standing.enemies.enabled = true
            end

            automationApi.settings.standing = standing
        end
        automationApi.reaction = type(saved.reaction) == "table" and saved.reaction or nil
        automationApi.lastReaction = type(saved.lastReaction) == "table" and saved.lastReaction
                                     or nil
        automationApi.lootRuns = tonumber(saved.lootRuns) or 0
        automationApi.plan = type(saved.plan) == "table" and saved.plan or nil
        -- A boss seen before a reload is not proof of a kill after it: a restart sends every
        -- boss away with the sector, and resets vanilla's own cooldown with the player script.
        if automationApi.plan then automationApi.plan.bossHere = nil end
        automationApi.last = type(saved.last) == "table" and saved.last or nil
        automationApi.defenceFights = tonumber(saved.defenceFights) or 0
        automationApi.lastTransfer = type(saved.lastTransfer) == "table" and saved.lastTransfer or nil
        -- A transfer caught mid-approach picks up again: the dock order is restored with
        -- the chain, and a ship flying alongside is simply sent again.
        local transfer = saved.transfer
        if type(transfer) == "table" and type(transfer.target) == "table" then
            transfer.flyIn = 0
            automationApi.transfer = transfer
        else
            automationApi.transfer = nil
        end
    end

    automationApiVanillaRestore(data)
end

end
