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
    }
    _G.callingPlayer = nil
end

_G.checkEntityInteractionPermissions = function()
    return world.permitted and {index = 1} or nil
end

_G.Entity = function()
    return
    {
        getCaptain = function() return world.captain end,
        getPilotIndices = function() return table.unpack(world.pilots) end,
        isJumpRouteValid = function(_, ax, ay, bx, by) return true end,
    }
end

_G.Sector = function()
    return {getCoordinates = function() return world.x, world.y end}
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
check(actions() == "A" and OrderChain.chain[1].automationApi == "defence",
      "an idle ship with enemies around turns aggressive")
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
