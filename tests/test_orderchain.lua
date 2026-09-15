-- The orderchain.lua extension: what a ship does with a plan once it has one.
--
-- The engine appends the mod's data/scripts/entity/orderchain.lua onto vanilla's, and
-- vanilla's cannot be shipped here. So this test stands in a small model of the vanilla
-- chain - enchain, clearAllOrders, runOrders, the per-tick advance, loops, aggressive
-- orders finishing when the AI stops being aggressive, secure/restore - written against
-- the vanilla source, and loads the real extension on top of it exactly as the engine
-- would: into the same global namespace, after the vanilla definitions.
--
-- The model is deliberately literal about the two vanilla behaviours the extension leans
-- on: the end of a chain clears it, and an aggressive order that finishes takes the chain
-- with it. Get either wrong here and the extension's fight/resume logic would be tested
-- against a game that does not exist.

package.path = "data/scripts/lib/?.lua;tests/?.lua;" .. package.path

local Json = require("automationapi.json")

local failures = 0
local function check(cond, msg)
    if cond then print("  ok   " .. msg)
    else failures = failures + 1; print("  FAIL " .. msg) end
end

-- #### ENGINE STAND-INS #### --

_G.OrderType = {Jump = 1, Mine = 2, Salvage = 3, Loop = 4, Aggressive = 5, Patrol = 6,
                FlyThroughWormhole = 11}
_G.AlliancePrivilege = {ManageShips = 15}
_G.onServer = function() return true end
_G.onClient = function() return false end
_G.include = function(path) return require((string.gsub(path, "/", "."))) end
_G.printlog = function() end
_G.callable = function(namespace, name) callables[name] = namespace[name] end
_G.callables = {}

local world

local function newWorld()
    world =
    {
        x = 0, y = 0,
        range = 5,
        captain = {name = "Vel"},
        pilots = {},
        enemies = false,
        aiState = "Idle",
        aiCivilians = nil,
        published = {},
        permitted = true,
        blocked = {},   -- "x:y" of sectors no jump may land in
        bosses = {},    -- {script, title, args} of boss entities in the sector
        loot = {},      -- {cargo = bool, collectable = bool}
        cargoPickup = 0,
        transporterBlocks = 0,
        squads = {0, 1},
        squadFighters = {[0] = 3, [1] = 2},
        deployed = 0,
        squadOrders = {},
        collectedAll = false,
    }
    _G.callingPlayer = nil
end

_G.EntityType = {Loot = 8}
_G.ComponentType = {CargoLoot = 71}
_G.FighterOrders = {Return = 3, CollectLoot = 9}
_G.StatsBonuses = {FighterCargoPickup = 48}
_G.BlockType = {Transporter = 55}
_G.Plan = function()
    return
    {
        getNumBlocks = function(_, blockType)
            assert(blockType == BlockType.Transporter, "unexpected block type")
            return world.transporterBlocks
        end,
    }
end
_G.Uuid = function() return "uuid" end

_G.checkEntityInteractionPermissions = function()
    return world.permitted and {index = 1} or nil
end

_G.Entity = function()
    return
    {
        getCaptain = function() return world.captain end,
        getPilotIndices = function() return table.unpack(world.pilots) end,
        isJumpRouteValid = function(_, ax, ay, bx, by) return true end,
        getBoostedValue = function(_, stat, base)
            assert(stat == StatsBonuses.FighterCargoPickup, "unexpected stat")
            return base + world.cargoPickup
        end,
    }
end

-- Script lookups match the way the engine does, on the tail of the path the script was
-- added under, and hand back entities like the engine: several return values, or none.
_G.Sector = function()
    return
    {
        getCoordinates = function() return world.x, world.y end,
        getEntitiesByScript = function(_, script)
            local found = {}
            for _, boss in ipairs(world.bosses) do
                if boss.script:sub(-#script) == script then
                    found[#found + 1] =
                    {
                        title = boss.title,
                        getTitleArguments = function() return boss.args or {} end,
                    }
                end
            end
            return table.unpack(found)
        end,
        getEntitiesByType = function(_, entityType)
            assert(entityType == EntityType.Loot, "only loot is looked for")
            local found = {}
            for _, loot in ipairs(world.loot) do
                found[#found + 1] =
                {
                    isCollectable = function() return loot.collectable ~= false end,
                    hasComponent = function(_, component)
                        return component == ComponentType.CargoLoot and loot.cargo == true
                    end,
                }
            end
            return table.unpack(found)
        end,
    }
end

_G.Hangar = function()
    return
    {
        getSquads = function() return table.unpack(world.squads) end,
        getSquadFighters = function(_, squad) return world.squadFighters[squad] or 0 end,
        collectAllFighters = function() world.deployed = 0; world.collectedAll = true end,
    }
end

_G.FighterController = function()
    return
    {
        getDeployedFighters = function()
            local out = {}
            for i = 1, world.deployed do out[i] = {index = i} end
            return table.unpack(out)
        end,
        setSquadOrders = function(_, squad, orders) world.squadOrders[squad] = orders end,
    }
end

_G.HyperspaceEngine = function()
    return
    {
        isJumpRouteValid = function(_, ax, ay, bx, by)
            if world.blocked[bx .. ":" .. by] then return false, "Jump route is blocked." end
            local d = math.sqrt((bx - ax) ^ 2 + (by - ay) ^ 2)
            if d > world.range then return false, "Jump target is out of range." end
            return true
        end,
    }
end

_G.ShipAI = function()
    return
    {
        isEnemyPresent = function(_, civilians)
            world.aiCivilians = civilians
            return world.enemies
        end,
        setAggressive = function() world.aiState = "Aggressive" end,
        setPassive = function() world.aiState = "Passive" end,
    }
end

-- #### VANILLA ORDERCHAIN, MODELLED #### --

local function loadOrderChain()
    OrderChain = {}
    OrderChain.chain = {}
    OrderChain.activeOrder = 0
    OrderChain.running = false
    OrderChain.finished = false
    OrderChain.executableOrders = 0

    function OrderChain.clear()
        OrderChain.chain = {}
        OrderChain.activeOrder = 0
        OrderChain.executableOrders = 0
        OrderChain.running = false
        OrderChain.finished = false
    end

    function OrderChain.clearAllOrders()
        OrderChain.clear()
        OrderChain.updateChain()
        if world.aiState ~= "Passive" then world.aiState = "Passive" end
    end

    function OrderChain.activateOrder()
        if OrderChain.activeOrder == 0 or not OrderChain.running then return end
        local order = OrderChain.chain[OrderChain.activeOrder]

        if order.action == OrderType.Jump then
            local valid = HyperspaceEngine():isJumpRouteValid(world.x, world.y, order.x, order.y)
            if not valid then OrderChain.clearAllOrders() end
        elseif order.action == OrderType.Loop then
            if OrderChain.activeOrder == order.loopIndex then return end
            OrderChain.activeOrder = order.loopIndex
            OrderChain.activateOrder()
        elseif order.action == OrderType.Aggressive then
            world.aiState = "Aggressive"
            world.aggressive = {civilians = order.attackCivilShips, canFinish = order.canFinish}
        end
    end

    function OrderChain.updateChain()
        if not OrderChain.running and OrderChain.executableOrders > OrderChain.activeOrder then
            OrderChain.running = true
            OrderChain.activeOrder = OrderChain.activeOrder + 1
            OrderChain.activateOrder()
        end
        OrderChain.updateShipOrderInfo()
    end

    function OrderChain.enchain(order)
        if OrderChain.finished then OrderChain.clear() end
        table.insert(OrderChain.chain, order)
        OrderChain.updateChain()
    end

    function OrderChain.runOrders()
        OrderChain.executableOrders = #OrderChain.chain
        OrderChain.updateChain()
    end

    function OrderChain.updateServer(timeStep)
        if not OrderChain.running or OrderChain.activeOrder == 0 then return end

        local current = OrderChain.chain[OrderChain.activeOrder]
        local finished = false

        if current.action == OrderType.Jump or current.action == OrderType.FlyThroughWormhole then
            finished = world.x == current.x and world.y == current.y
        elseif current.action == OrderType.Aggressive then
            finished = world.aiState ~= "Aggressive"
        elseif current.action == OrderType.Loop then
            finished = true
        end

        if finished then
            if OrderChain.executableOrders > OrderChain.activeOrder then
                OrderChain.activeOrder = OrderChain.activeOrder + 1
                OrderChain.activateOrder()
            else
                -- end of chain: vanilla disables the autopilot, which clears everything
                OrderChain.activeOrder = 0
                OrderChain.finished = true
                OrderChain.clearAllOrders()
            end
            OrderChain.updateShipOrderInfo()
        end
    end

    function OrderChain.getOrderInfo()
        local info = {chain = {}, currentIndex = OrderChain.activeOrder,
                      coordinates = {x = world.x, y = world.y}, finished = OrderChain.finished}
        for _, action in ipairs(OrderChain.chain) do
            local entry = {}
            for k, v in pairs(action) do entry[k] = v end
            info.chain[#info.chain + 1] = entry
        end
        return info
    end

    function OrderChain.updateShipOrderInfo()
        world.published[#world.published + 1] = OrderChain.getOrderInfo()
    end

    function OrderChain.secure()
        return {chain = OrderChain.chain, activeOrder = OrderChain.activeOrder,
                finished = OrderChain.finished}
    end

    function OrderChain.restore(data)
        OrderChain.chain = data.chain
        OrderChain.activeOrder = data.activeOrder
        OrderChain.finished = data.finished
        if not data.finished and data.activeOrder > 0 then
            OrderChain.running = true
            OrderChain.executableOrders = #OrderChain.chain
        end
        OrderChain.activateOrder()
    end

    -- the engine's append: the mod file runs after the vanilla definitions, in their scope
    dofile("data/scripts/entity/orderchain.lua")
end

-- #### HELPERS #### --

local function tick(seconds) OrderChain.updateServer(seconds or 1) end

local function jumpTo(x, y)
    world.x, world.y = x, y
    tick()
end

local function state()
    return world.published[#world.published].automationApi
end

local function actions()
    local out = {}
    for _, order in ipairs(OrderChain.chain) do
        local name = ({[1] = "J", [4] = "L", [5] = "A", [11] = "G"})[order.action] or "?"
        if order.action == OrderType.Jump or order.action == OrderType.FlyThroughWormhole then
            name = name .. order.x .. ":" .. order.y
        elseif order.action == OrderType.Loop then
            name = name .. order.loopIndex
        end
        out[#out + 1] = name
    end
    return table.concat(out, " ")
end

local function plan(spec)
    OrderChain.automationApiRunPlan(Json.encode(spec))
end

-- #### ROUTES #### --

print("\na route")

newWorld()
loadOrderChain()

check(callables.automationApiRunPlan and callables.automationApiConfigure
      and callables.automationApiStop, "the three entry points are registered callable")

plan({id = "r1", kind = "route", onEnemies = "fight",
      hops = {{x = 5, y = 0, kind = "jump"}, {x = 10, y = 0, kind = "jump"},
              {x = 12, y = 3, kind = "gate"}}})

check(actions() == "J5:0 J10:0 G12:3", "the hops go on the vanilla chain, the gate as a gate")
check(OrderChain.running and OrderChain.activeOrder == 1, "and the chain is running")
check(state().plan.id == "r1" and state().plan.phase == "running",
      "the ship publishes the plan it took up")

local encoded = pcall(Json.encode, OrderChain.getOrderInfo())
check(encoded, "the published order info still encodes")

jumpTo(5, 0)
check(OrderChain.activeOrder == 2 and state().plan.jumps == 1, "a jump advances it and is counted")

print("\nenemies, onEnemies = fight")

world.enemies = true
tick()
check(actions() == "A", "enemies replace the route with an aggressive order")
check(world.aggressive.canFinish == true, "one that finishes when the sector is clear")
check(state().plan.phase == "fighting" and state().plan.fights == 1, "and the plan says it is fighting")

tick()
check(actions() == "A", "while enemies remain, it keeps fighting")

world.enemies = false
world.aiState = "Idle"
tick()
check(actions() == "J10:0 G12:3",
      "when the fight ends the route picks up at the hop it was interrupted on")
check(state().plan.phase == "running", "and is running again")

jumpTo(10, 0)
jumpTo(12, 3)
check(#OrderChain.chain == 0, "flying the last hop empties the chain, as vanilla does")
tick()
check(state().plan == nil and state().last.outcome == "arrived" and state().last.jumps == 3,
      "the plan ends as arrived, with every hop counted")

print("\nenemies that flicker")

newWorld()
loadOrderChain()
plan({id = "r2", hops = {{x = 5, y = 0, kind = "jump"}, {x = 10, y = 0, kind = "jump"}}})
world.enemies = true
tick()
world.enemies = false
tick(1)
check(actions() == "A", "a sector clear for a second is not treated as over while fighting")
tick(5)
check(actions() == "J5:0 J10:0", "but five seconds clear resumes, fight order or not")

print("\nonEnemies = hold, continue")

newWorld()
loadOrderChain()
plan({id = "h1", onEnemies = "hold", hops = {{x = 5, y = 0, kind = "jump"}}})
world.enemies = true
tick()
check(actions() == "A" and world.aggressive.canFinish == false,
      "hold stays aggressive, with an order that never finishes")
check(state().plan.phase == "holding", "and says so")
world.enemies = false
tick(10)
check(actions() == "A", "clearing the sector does not resume a hold")

OrderChain.clearAllOrders()
OrderChain.enchain({action = OrderType.Jump, x = 1, y = 1})
tick()
check(state().plan == nil and state().last.outcome == "replaced",
      "orders from anywhere else end the plan as replaced")

newWorld()
loadOrderChain()
plan({id = "c1", onEnemies = "continue", hops = {{x = 5, y = 0, kind = "jump"}}})
world.enemies = true
tick()
check(actions() == "J5:0", "continue ignores enemies and keeps the route")

print("\nrefusals")

newWorld()
loadOrderChain()
OrderChain.enchain({action = OrderType.Patrol})
OrderChain.runOrders()
plan({id = "x1", hops = {{x = 5, y = 0, kind = "jump"}, {x = 50, y = 0, kind = "jump"}}})
check(actions() == "?", "a plan with an impossible jump leaves the ship's chain alone")
check(state().last.id == "x1" and state().last.outcome == "refused"
      and state().last.reason:find("hop 2", 1, true) ~= nil,
      "and publishes which hop the engine would refuse")

world.captain = nil
plan({id = "x2", hops = {{x = 5, y = 0, kind = "jump"}}})
check(state().last.id == "x2" and state().last.reason == "needs_captain",
      "a ship with neither captain nor pilot refuses, as addJumpOrder would")

world.captain = {name = "Vel"}
world.permitted = false
_G.callingPlayer = 7
local before = #world.published
plan({id = "x3", hops = {{x = 5, y = 0, kind = "jump"}}})
check(#world.published == before and actions() == "?",
      "a client without permission to manage the ship is ignored")
_G.callingPlayer = nil

print("\nboss farming")

newWorld()
world.x, world.y = 290, 0
world.pilots = {1}
loadOrderChain()

-- at A = (290:0), looping A -> B -> A
plan({id = "f1", kind = "farm", boss = "ai", onEnemies = "fight", loopFrom = 1,
      hops = {{x = 293, y = 2, kind = "jump"}, {x = 290, y = 0, kind = "jump"}}})
check(actions() == "J293:2 J290:0 L1", "a farm is the pair of jumps and a loop back")

jumpTo(293, 2)
jumpTo(290, 0)
tick()
check(OrderChain.activeOrder == 1 and state().plan.jumps == 2,
      "the loop sends it round again, and every jump counts")

jumpTo(293, 2)
world.enemies = true
tick()
check(actions() == "A", "a boss arriving mid-lap is fought")

world.enemies = false
world.aiState = "Idle"
tick()
check(actions() == "J290:0 J293:2 J290:0 L2",
      "the lap resumes from the interrupted hop, then loops the whole pair again")

world.pilots = {}
tick()
check(#OrderChain.chain == 0 and state().last.outcome == "pilot_left",
      "the player leaving stops the farm: their jumps were the point")

newWorld()
world.x, world.y = 290, 0
world.pilots = {1}
world.range = 5
loadOrderChain()
world.blocked["290:0"] = true
plan({id = "f2", kind = "farm", loopFrom = 1,
      hops = {{x = 293, y = 2, kind = "jump"}, {x = 290, y = 0, kind = "jump"}}})
check(state().last.outcome == "refused", "a loop whose lap cannot be flown is refused up front")

print("\nbosses, loot and the cooldown")

local SWOKS = {script = "data/scripts/entity/story/swoks.lua", title = "Boss Swoks ${num}",
               args = {num = "III"}}

local function farmAt290(extra)
    newWorld()
    world.x, world.y = 290, 0
    world.pilots = {1}
    loadOrderChain()

    local spec = {id = "b1", kind = "farm", boss = "swoks", onEnemies = "fight", loopFrom = 1,
                  hops = {{x = 293, y = 2, kind = "jump"}, {x = 290, y = 0, kind = "jump"}}}
    for k, v in pairs(extra or {}) do spec[k] = v end
    plan(spec)
end

farmAt290()
check(state().plan.collectLoot == true and state().plan.bossKills == 0,
      "a farm collects loot unless told otherwise")

-- Swoks spawns friendly to the player he spawned for: no enemies yet, only the boss
world.bosses = {SWOKS}
jumpTo(293, 2)
check(state().plan.bossPresent and state().plan.bossPresent.name == "swoks"
      and state().plan.bossPresent.title == "Boss Swoks III",
      "the boss is recognised by its script, and named with its title filled in")
check(actions() == "A" and state().plan.phase == "fighting",
      "and the loop stops for it even before it turns hostile")

world.aiState = "Idle"
tick()
tick(10)
check(#OrderChain.chain == 0 and state().plan.phase == "fighting",
      "an aggressive order with nobody to fight finishes, and the ship waits by the boss")

world.enemies = true
tick()
check(actions() == "A", "and is ordered in again once there are enemies")

-- the boss dies: gone from a sector the ship never left, drops behind
world.bosses = {}
world.enemies = false
world.aiState = "Idle"
world.loot = {{cargo = false}, {cargo = false}, {cargo = true}, {cargo = false, collectable = false}}
tick()
local p = state().plan
check(p.bossKills == 1 and p.lastKill.name == "swoks" and p.lastKill.title == "Boss Swoks III"
      and p.bossPresent == nil, "a boss gone from the sector is counted as killed")
check(p.cooldown and p.cooldown.left == 1800 and p.cooldown.total == 1800,
      "which starts vanilla's thirty minute cooldown")
check(p.phase == "looting" and #OrderChain.chain == 0, "the fighters go looting first")
check(p.loot.instant == 2 and p.loot.cargo == 1 and p.loot.cargoPickup == false,
      "counting only loot the ship may take, cargo apart")

tick()
check(world.squadOrders[0] == FighterOrders.CollectLoot
      and world.squadOrders[1] == FighterOrders.CollectLoot,
      "every squad is sent to collect loot")
world.deployed = 5

world.loot = {{cargo = false}, {cargo = true}}
tick()
check(state().plan.phase == "looting" and state().plan.loot.instant == 1,
      "while drops it can take remain, it keeps at it")

world.loot = {{cargo = true}}
tick()
check(state().plan.phase == "returning" and state().plan.lootResult == "collected",
      "cargo without transporter software does not keep the fighters out")
check(world.squadOrders[0] == FighterOrders.Return, "they are called back")

tick(5)
check(state().plan.phase == "returning", "and the ship will not leave while they are out")

world.deployed = 0
tick()
check(state().plan.phase == "cooldown" and #OrderChain.chain == 0,
      "landed, it sits out the cooldown with nothing on the chain")

world.enemies = true
tick()
check(actions() == "A" and state().plan.phase == "fighting", "enemies during it are fought")
world.enemies = false
world.aiState = "Idle"
world.loot = {}
tick()
check(state().plan.phase == "cooldown", "and afterwards it goes back to waiting")

world.pilots = {}
tick(600)
check(state().plan and state().plan.phase == "cooldown",
      "leaving the controls during the cooldown does not end the farm")
world.pilots = {1}

tick(1200)
check(actions() == "J290:0 J293:2 J290:0 L2" and state().plan.phase == "running"
      and state().plan.cooldown == nil,
      "once it is over, the loop resumes from the hop the boss interrupted")

print("\nloot variations")

farmAt290()
world.bosses = {SWOKS}
jumpTo(293, 2)
world.bosses = {}
world.cargoPickup = 1
world.loot = {{cargo = true}}
world.aiState = "Idle"
tick()
check(state().plan.phase == "cooldown" and state().plan.loot.cargoPickup == false,
      "transporter software without a transporter block does not make cargo worth a trip")

farmAt290()
world.bosses = {SWOKS}
jumpTo(293, 2)
world.bosses = {}
world.cargoPickup = 1
world.transporterBlocks = 1
world.loot = {{cargo = true}}
world.aiState = "Idle"
tick()
check(state().plan.phase == "looting" and state().plan.loot.cargoPickup == true,
      "with the software and a transporter block, cargo is worth sending fighters for")
tick(21)
tick()
check(state().plan.phase == "cooldown" and state().plan.lootResult == "no_launch",
      "fighters that never leave the hangar end the looting, with nobody to wait for")

farmAt290()
world.bosses = {SWOKS}
jumpTo(293, 2)
world.bosses = {}
world.squadFighters = {}
world.loot = {{cargo = false}}
world.aiState = "Idle"
tick()
check(state().plan.phase == "cooldown" and state().plan.lootResult == "no_fighters",
      "a ship without fighters goes straight to the cooldown")

farmAt290({collectLoot = false, bossCooldown = 0})
world.bosses = {SWOKS}
jumpTo(293, 2)
world.bosses = {}
world.loot = {{cargo = false}}
world.aiState = "Idle"
tick()
check(state().plan.phase == "running" and state().plan.bossKills == 1,
      "with looting off and no cooldown, a kill goes straight back to the loop")

farmAt290({onEnemies = "continue"})
world.bosses = {SWOKS}
jumpTo(293, 2)
check(state().plan.phase == "running", "continue does not stop for a boss either")
world.bosses = {}
jumpTo(290, 0)
tick()
check(state().plan.bossKills == 0 and state().plan.cooldown == nil,
      "and a boss left behind in another sector was not killed")

farmAt290()
world.bosses = {SWOKS}
jumpTo(293, 2)
world.bosses = {}
world.loot = {{cargo = false}}
world.deployed = 2
world.aiState = "Idle"
tick()
tick()
world.loot = {}
tick()
tick(91)
check(world.collectedAll and state().plan.phase == "cooldown"
      and state().plan.lootResult == "collected_recalled",
      "fighters that cannot find their way back are pulled in rather than left behind")

farmAt290()
world.bosses = {SWOKS}
jumpTo(293, 2)
local saved = OrderChain.secure()
world.bosses = {}
loadOrderChain()
OrderChain.restore(saved)
tick()
check(state().plan.bossKills == 0 and state().plan.cooldown == nil,
      "a boss seen before a reload is not counted as killed after it")

print("\nidle defence")

newWorld()
loadOrderChain()
world.enemies = true
tick()
check(#world.published == 0 and world.aiCivilians == nil,
      "a ship with nothing switched on neither looks for enemies nor publishes")
world.enemies = false

OrderChain.automationApiConfigure(Json.encode({autoAggressive = true}))
check(state().autoAggressive == true, "the setting is published")

world.enemies = true
tick()
check(actions() == "A" and OrderChain.chain[1].automationApi == "standing",
      "an idle ship with enemies around turns aggressive")
check(state().standing.enemies.enabled == true and state().standing.enemies.mode == "idle",
      "the old setting is the standing enemies order in idle mode")
check(world.aggressive.canFinish == true, "until the sector is clear")
check(world.aiCivilians == false, "counting civilians only when asked to")
tick()
check(#OrderChain.chain == 1 and state().defenceFights == 1, "and does not stack orders while fighting")

world.enemies = false
world.aiState = "Idle"
tick()
check(#OrderChain.chain == 0, "then goes back to idle")

world.pilots = {1}
world.enemies = true
tick()
check(#OrderChain.chain == 0, "a ship somebody is flying is left to them")

world.pilots = {}
world.captain = nil
tick()
check(#OrderChain.chain == 0, "and a ship with no captain is left alone, as vanilla requires")

world.captain = {name = "Vel"}
OrderChain.enchain({action = OrderType.Patrol})
OrderChain.runOrders()
tick()
check(actions() == "?", "a ship with orders of its own is not idle")

-- #### STANDING ORDERS #### --

local function standing(spec)
    OrderChain.automationApiConfigure(Json.encode({standing = spec}))
end

-- a two-hop chain, flown as far as its second hop
local function busyChain()
    OrderChain.enchain({action = OrderType.Jump, x = 5, y = 0})
    OrderChain.enchain({action = OrderType.Jump, x = 10, y = 0})
    OrderChain.runOrders()
    jumpTo(5, 0)
end

print("\nstanding enemies, interrupt")

newWorld()
loadOrderChain()
standing({enemies = {enabled = true, mode = "interrupt"}})
check(state().standing.enemies.mode == "interrupt" and state().autoAggressive == true,
      "the order and its mode are published, and the old field follows it")

busyChain()
check(OrderChain.activeOrder == 2, "(the ship is flying the second hop)")

world.enemies = true
tick()
check(actions() == "A" and state().reaction and state().reaction.kind == "enemies"
      and state().reaction.resumes == true,
      "enemies interrupt the chain, which is put aside to come back")

world.enemies = false
world.aiState = "Idle"
tick()
check(actions() == "J5:0 J10:0" and OrderChain.activeOrder == 2 and OrderChain.running,
      "when the fight is over the chain comes back at the order it was on")
check(state().reaction == nil and state().lastReaction.outcome == "done"
      and state().lastReaction.resumed == true, "and the reaction says it resumed")

newWorld()
loadOrderChain()
standing({enemies = {enabled = true, mode = "idle"}})
busyChain()
world.enemies = true
tick()
check(actions() == "J5:0 J10:0" and state().reaction == nil,
      "in idle mode a ship with a chain is left to fly it")

newWorld()
loadOrderChain()
standing({enemies = {enabled = true, mode = "interrupt"}})
OrderChain.enchain({action = OrderType.Aggressive, attackCivilShips = false, canFinish = false})
OrderChain.runOrders()
world.enemies = true
tick()
check(state().reaction == nil and OrderChain.chain[1].automationApi == nil,
      "a ship already under an aggressive order is not interrupted to be given another")

print("\nloops survive an interruption")

newWorld()
loadOrderChain()
standing({enemies = {enabled = true, mode = "interrupt"}})
OrderChain.enchain({action = OrderType.Jump, x = 5, y = 0})
OrderChain.enchain({action = OrderType.Jump, x = 0, y = 0})
OrderChain.enchain({action = OrderType.Loop, loopIndex = 1})
OrderChain.runOrders()
jumpTo(5, 0)
world.enemies = true
tick()
world.enemies = false
world.aiState = "Idle"
tick()
check(actions() == "J5:0 J0:0 L1" and OrderChain.activeOrder == 2,
      "the loop comes back with its index intact")
jumpTo(0, 0)
check(OrderChain.activeOrder == 1, "and still loops")

print("\nstanding loot")

newWorld()
loadOrderChain()
standing({loot = {enabled = true, mode = "idle"}})
world.loot = {{cargo = false}, {cargo = false}}
tick()
check(state().reaction and state().reaction.kind == "loot" and state().reaction.phase == "looting",
      "an idle ship with fighters sends them for loot in the sector")
tick()
check(world.squadOrders[0] == FighterOrders.CollectLoot, "the squads are ordered to collect")
check(state().reaction.resumes == false and state().lootRuns == 1,
      "nothing to resume, and the run is counted")

world.deployed = 5
world.loot = {}
tick()
check(state().reaction.phase == "returning" and world.squadOrders[0] == FighterOrders.Return,
      "once it is all picked up the fighters are called back")

world.deployed = 0
tick()
check(state().reaction == nil and state().lastReaction.kind == "loot"
      and state().lastReaction.lootResult == "collected", "and when they have landed it is done")

newWorld()
loadOrderChain()
standing({loot = {enabled = true, mode = "idle"}})
busyChain()
world.loot = {{cargo = false}}
tick(2)
check(state().reaction == nil and actions() == "J5:0 J10:0", "idle mode leaves a busy ship be")

standing({loot = {enabled = true, mode = "interrupt"}})
tick(2)
check(state().reaction and state().reaction.kind == "loot" and #OrderChain.chain == 0,
      "interrupt mode takes the ship off its chain for the loot")
world.loot = {}
tick(2)
tick()
check(actions() == "J5:0 J10:0" and OrderChain.activeOrder == 2,
      "and puts the chain back when the fighters are home")

newWorld()
loadOrderChain()
standing({loot = {enabled = true, mode = "interrupt"}})
world.squadFighters = {}
world.loot = {{cargo = false}}
tick(2)
check(state().reaction == nil, "a ship with no fighters aboard does not react")

newWorld()
loadOrderChain()
standing({loot = {enabled = true, mode = "idle"}})
world.loot = {{cargo = true}}
tick(2)
check(state().reaction == nil, "nor to cargo its fighters cannot pick up")

newWorld()
loadOrderChain()
standing({loot = {enabled = true, mode = "idle"}})
world.loot = {{cargo = false}}
world.enemies = true
tick(2)
check(state().reaction == nil, "nobody loots under fire")

print("\nloot that cannot be taken")

newWorld()
loadOrderChain()
standing({loot = {enabled = true, mode = "idle"}})
world.loot = {{cargo = false}}
tick()
world.deployed = 5
for _ = 1, 46 do tick() end
check(state().reaction.phase == "returning", "a collection that picks nothing up stalls")
world.deployed = 0
tick()
check(state().lastReaction.lootResult == "stalled", "and ends as stalled")
for _ = 1, 30 do tick() end
check(state().reaction == nil, "the same sector's loot is then left alone")
for _ = 1, 100 do tick() end
check(state().reaction and state().reaction.kind == "loot", "for a while, not for ever")

print("\na fight, then the loot")

newWorld()
loadOrderChain()
standing({enemies = {enabled = true, mode = "interrupt"}, loot = {enabled = true, mode = "interrupt"}})
busyChain()
world.enemies = true
tick()
world.loot = {{cargo = false}}
world.enemies = false
world.aiState = "Idle"
tick()
check(state().reaction and state().reaction.kind == "loot" and state().reaction.phase == "looting",
      "a fight that leaves loot goes on to the loot")
world.enemies = true
tick()
check(actions() == "A" and state().reaction.phase == "fighting",
      "enemies arriving while the fighters are out are fought")
world.enemies = false
world.aiState = "Idle"
world.loot = {}
tick()
tick(2)
check(actions() == "J5:0 J10:0" and OrderChain.activeOrder == 2 and state().reaction == nil,
      "and the chain comes back after all of it")

newWorld()
loadOrderChain()
standing({enemies = {enabled = true, mode = "interrupt"}, loot = {enabled = true, mode = "idle"}})
busyChain()
world.enemies = true
tick()
world.loot = {{cargo = false}}
world.enemies = false
world.aiState = "Idle"
tick()
check(actions() == "J5:0 J10:0" and state().reaction == nil,
      "an idle-only loot order does not keep an interrupted chain waiting")

print("\nreactions give way")

newWorld()
loadOrderChain()
standing({loot = {enabled = true, mode = "interrupt"}})
busyChain()
world.loot = {{cargo = false}}
tick(2)
OrderChain.enchain({action = OrderType.Patrol})
OrderChain.runOrders()
tick()
check(actions() == "?" and state().reaction == nil and state().lastReaction.outcome == "replaced",
      "orders given while it loots end the reaction, and the old chain stays gone")

newWorld()
loadOrderChain()
standing({enemies = {enabled = true, mode = "interrupt"}})
busyChain()
world.enemies = true
tick()
standing({enemies = {enabled = false}})
check(actions() == "J5:0 J10:0" and state().lastReaction.outcome == "switched_off"
      and state().standing.enemies.mode == "interrupt",
      "switching the order off mid-fight gives the chain back, and keeps the mode")

newWorld()
loadOrderChain()
standing({enemies = {enabled = true, mode = "interrupt"}})
busyChain()
world.enemies = true
tick()
OrderChain.automationApiStop()
check(#OrderChain.chain == 0 and state().reaction == nil
      and state().lastReaction.outcome == "stopped", "stop ends a reaction and clears the chain")
check(state().standing.enemies.enabled == true, "and leaves the standing order on")

newWorld()
loadOrderChain()
standing({enemies = {enabled = true, mode = "interrupt"}})
busyChain()
world.enemies = true
tick()
world.enemies = false
plan({id = "rp", hops = {{x = 8, y = 0, kind = "jump"}}})
check(actions() == "J8:0" and state().reaction == nil and state().plan.id == "rp",
      "a plan sent during a reaction takes over from it")

standing({enemies = {enabled = true, mode = "bogus"}})
check(state().standing.enemies.mode == "interrupt", "an unknown mode is ignored")

print("\nroutes and the loot order")

newWorld()
loadOrderChain()
standing({loot = {enabled = true, mode = "interrupt"}})
plan({id = "rl", onEnemies = "fight",
      hops = {{x = 5, y = 0, kind = "jump"}, {x = 10, y = 0, kind = "jump"}}})
world.enemies = true
tick()
world.loot = {{cargo = false}}
world.enemies = false
world.aiState = "Idle"
tick()
check(state().plan.phase == "looting", "a route's fight loots when the loot order may interrupt")

newWorld()
loadOrderChain()
standing({loot = {enabled = true, mode = "idle"}})
plan({id = "rn", onEnemies = "fight",
      hops = {{x = 5, y = 0, kind = "jump"}, {x = 10, y = 0, kind = "jump"}}})
world.enemies = true
tick()
world.loot = {{cargo = false}}
world.enemies = false
world.aiState = "Idle"
tick()
check(state().plan.phase == "running" and state().reaction == nil,
      "and flies straight on when it may not")

print("\nsaving and loading")

newWorld()
loadOrderChain()
OrderChain.automationApiConfigure(Json.encode({autoAggressive = true, attackCivilians = true}))
plan({id = "s1", hops = {{x = 5, y = 0, kind = "jump"}, {x = 10, y = 0, kind = "jump"}}})
jumpTo(5, 0)

local saved = OrderChain.secure()
check(type(saved.automationApi) == "table", "the automation state is saved with the chain")

-- a jump to a new sector reloads the ship's scripts from what was saved
loadOrderChain()
OrderChain.restore(saved)
tick()
check(state().plan and state().plan.id == "s1" and state().plan.jumps == 1,
      "the plan survives, jumps and all")
check(state().autoAggressive == true and state().attackCivilians == true,
      "and so do the settings")

loadOrderChain()
OrderChain.restore({chain = {}, activeOrder = 0, finished = false})
tick()
OrderChain.updateShipOrderInfo()
check(state().plan == nil and state().autoAggressive == false,
      "a chain saved before the mod was installed restores cleanly")

loadOrderChain()
OrderChain.restore({chain = {}, activeOrder = 0, finished = false,
                    automationApi = {settings = {autoAggressive = true, attackCivilians = false}}})
OrderChain.updateShipOrderInfo()
check(state().standing.enemies.enabled == true and state().standing.enemies.mode == "idle"
      and state().standing.loot.enabled == false,
      "a ship saved with idle defence comes back with the standing enemies order")

newWorld()
loadOrderChain()
standing({enemies = {enabled = true, mode = "interrupt"}, loot = {enabled = true, mode = "idle"}})
busyChain()
world.enemies = true
tick()
saved = OrderChain.secure()
loadOrderChain()
OrderChain.restore(saved)
OrderChain.updateShipOrderInfo()
check(state().standing.enemies.mode == "interrupt" and state().standing.loot.enabled == true,
      "standing orders survive a reload")
check(state().reaction and state().reaction.resumes == true, "and so does a reaction in progress")
world.enemies = false
world.aiState = "Idle"
tick()
tick()
check(actions() == "J5:0 J10:0" and OrderChain.activeOrder == 2,
      "which still gives the chain back afterwards")

print("\nstopping")

newWorld()
loadOrderChain()
plan({id = "t1", hops = {{x = 5, y = 0, kind = "jump"}}})
OrderChain.automationApiStop()
check(#OrderChain.chain == 0 and state().plan == nil and state().last.outcome == "stopped",
      "stop clears the chain and ends the plan")

print("")
if failures > 0 then print(failures .. " check(s) failed"); os.exit(1) end
print("all checks passed")
