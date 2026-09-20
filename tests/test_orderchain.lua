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
                FlyThroughWormhole = 11, DockToStation = 19}
_G.AlliancePrivilege = {ManageShips = 15}
_G.onServer = function() return true end
_G.onClient = function() return false end
_G.include = function(path) return require((string.gsub(path, "/", "."))) end
_G.printlog = function() end
_G.callable = function(namespace, name) callables[name] = namespace[name] end
_G.callables = {}

local world

-- A craft with a cargo bay that behaves like the engine's: getCargos() hands out the goods
-- as keys, removeCargo wants one of those, addCargo merges into a good of the same kind,
-- and the free space follows what is in the hold.
local function craft(spec)
    local c =
    {
        name = spec.name, factionIndex = spec.faction or 1, index = spec.name,
        capacity = spec.capacity or 1000, transporterRange = spec.transporter or 0,
        isStation = spec.station == true, radius = 40,
        id = {string = "id-" .. spec.name}, translationf = {name = spec.name},
        hold = {},
    }

    for _, entry in ipairs(spec.goods or {}) do
        c.hold[#c.hold + 1] = {good = entry[1], amount = entry[2]}
    end

    function c:getCargos()
        local out = {}
        for _, entry in ipairs(self.hold) do out[entry.good] = entry.amount end
        return out
    end

    function c:removeCargo(good, amount)
        for index, entry in ipairs(self.hold) do
            if entry.good == good then
                assert(entry.amount >= amount, "removed more than held")
                entry.amount = entry.amount - amount
                if entry.amount == 0 then table.remove(self.hold, index) end
                return
            end
        end
        error("removeCargo: not a good in this hold")
    end

    function c:addCargo(good, amount)
        assert(self.freeCargoSpace >= good.size * amount, "added more than fits")
        for _, entry in ipairs(self.hold) do
            if entry.good.name == good.name and (entry.good.stolen == true) == (good.stolen == true) then
                entry.amount = entry.amount + amount
                return
            end
        end
        self.hold[#self.hold + 1] = {good = good, amount = amount}
    end

    function c:held(name, stolen)
        for _, entry in ipairs(self.hold) do
            if entry.good.name == name and (stolen == nil or (entry.good.stolen == true) == stolen) then
                return entry.amount
            end
        end
        return 0
    end

    -- Only stations have docks, and which ship sits in the docking area is up to the test.
    -- The area reaches past the transfer's 20 of hull distance, which is the point.
    function c:hasComponent(component)
        return component == ComponentType.DockingPositions and self.isStation
    end

    function c:isInDockingArea(ship)
        assert(self.isStation, "isInDockingArea on a craft without docks")
        return world.docked[self.name] == true
    end

    function c:getNearestDistance(other)
        local d = world.distance[other.name] or world.distance[self.name]
        return d or 0
    end

    return setmetatable(c, {__index = function(t, key)
        if key == "freeCargoSpace" then
            local used = 0
            for _, entry in ipairs(rawget(t, "hold")) do used = used + entry.good.size * entry.amount end
            return rawget(t, "capacity") - used
        end
    end})
end

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
        -- what each deployed fighter is flying, by its index; a fight leaves fighters on
        -- orders of their own, which a squad order does not take them off
        fighterOrders = {},
        collectedAll = false,
        crafts = {},     -- other craft in the sector, see craft()
        distance = {},   -- craft name -> nearest distance from the ship
        players = {[1] = {allianceIndex = 9}},
        flyTo = nil,     -- the last setFly: {target, distance}
        flyCalls = 0,
        dockDone = false,
        docked = {},     -- station name -> the ship is in its docking area
        hull = 1,        -- fractions of the ship's own maximum; nil for "the engine will
        shield = 1,      -- not say", which is what a craft without shields looks like
        known = {},      -- faction index -> list of {x, y} that faction has been to
        controlled = {}, -- "x:y" -> faction index holding that sector
        relations = {},  -- faction index -> relation level towards the ship's owner
        fleet = {},      -- faction index -> {name = {x, y, station}}
        values = {},     -- Server values, which is where the location library lives
        randoms = nil,   -- a fixed sequence for math.random, so a pick is testable
    }
    world.ship = craft({name = "Self", faction = 1, capacity = 100})
    _G.callingPlayer = nil
end

_G.EntityType = {Loot = 8, Ship = 1, Station = 2}
_G.ComponentType = {CargoLoot = 71, DockingPositions = 30}
_G.FighterOrders = {Attack = 1, Return = 3, CollectLoot = 9}
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

-- A Player or Alliance handle, as the flee order reads one: what that faction has seen,
-- what it owns and, for a player, which alliance it is in.
local function factionHandle(index)
    return
    {
        index = index,
        isPlayer = world.players[index] ~= nil,
        isAlliance = world.players[index] == nil,
        allianceIndex = (world.players[index] or {}).allianceIndex,
        getKnownSectors = function()
            return table.unpack(world.known[index] or {})
        end,
        getShipNames = function()
            local names = {}
            for name in pairs(world.fleet[index] or {}) do names[#names + 1] = name end
            table.sort(names)
            return table.unpack(names)
        end,
        getShipPosition = function(_, name)
            local craftSpec = (world.fleet[index] or {})[name]
            if not craftSpec then error("no such craft") end
            return craftSpec.x, craftSpec.y
        end,
        getShipType = function(_, name)
            local craftSpec = (world.fleet[index] or {})[name]
            return craftSpec and craftSpec.station and EntityType.Station or EntityType.Ship
        end,
        -- as the engine answers it: a level, from the other faction's point of view
        getRelations = function(_, other) return world.relations[index] end,
    }
end

_G.Galaxy = function()
    return
    {
        findFaction = function(_, index) return factionHandle(index) end,
        getControllingFaction = function(_, x, y)
            local index = world.controlled[x .. ":" .. y]
            return index and factionHandle(index) or nil
        end,
    }
end

_G.Faction = function(index) return factionHandle(index) end

_G.Server = function()
    return
    {
        getValue = function(_, key) return world.values[key] end,
        setValue = function(_, key, value) world.values[key] = value end,
    }
end

-- math.random with a script, so "a random known sector" is a sector this test chose.
local automationApiRealRandom = math.random
math.random = function(a, b)
    if world and world.randoms and #world.randoms > 0 then
        return table.remove(world.randoms, 1)
    end
    if a == nil then return automationApiRealRandom() end
    return automationApiRealRandom(a, b)
end

_G.Entity = function()
    local ship = world.ship
    -- The engine reports absolutes; the extension turns them into fractions itself, so
    -- the model keeps a maximum of 100 and scales the test's fraction onto it.
    ship.maxDurability = world.hull ~= nil and 100 or 0
    ship.durability = (world.hull or 0) * 100
    ship.shieldMaxDurability = world.shield ~= nil and 100 or 0
    ship.shieldDurability = (world.shield or 0) * 100
    ship.getCaptain = function() return world.captain end
    ship.getPilotIndices = function() return table.unpack(world.pilots) end
    ship.isJumpRouteValid = function(_, ax, ay, bx, by) return true end
    ship.getBoostedValue = function(_, stat, base)
        assert(stat == StatsBonuses.FighterCargoPickup, "unexpected stat")
        return base + world.cargoPickup
    end
    return ship
end

_G.Player = function(index) return world.players[index] end

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
        getEntitiesByFaction = function(_, faction)
            local found = {}
            for _, other in ipairs(world.crafts) do
                if other.factionIndex == faction then found[#found + 1] = other end
            end
            if world.ship.factionIndex == faction then found[#found + 1] = world.ship end
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
        -- as in the engine: the squad's order is what launches fighters still in the
        -- hangar, and leaves the ones already out flying whatever they were given
        setSquadOrders = function(_, squad, orders) world.squadOrders[squad] = orders end,
    }
end

_G.FighterAI = function(fighter)
    local index = fighter.index

    return
    {
        orders = world.fighterOrders[index],
        setOrders = function(_, orders) world.fighterOrders[index] = orders end,
    }
end

_G.HyperspaceEngine = function()
    return
    {
        reach = world.range,
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
        setFly = function(_, target, distance)
            world.flyTo = {target = target, distance = distance}
            world.flyCalls = world.flyCalls + 1
        end,
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
        elseif current.action == OrderType.DockToStation then
            finished = world.dockDone
        end

        -- The dock script ends itself with orderCompleted, which only stops the chain:
        -- the order stays on it and `finished` is never set.
        if finished and current.action == OrderType.DockToStation
           and OrderChain.executableOrders <= OrderChain.activeOrder then
            OrderChain.running = false
            OrderChain.updateShipOrderInfo()
            return
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

-- the boss dies: gone from a sector the ship never left, drops behind. The fight left its
-- fighters out on orders of their own - most of them already flying home, one still on a
-- target.
world.bosses = {}
world.enemies = false
world.aiState = "Idle"
world.deployed = 5
world.fighterOrders = {FighterOrders.Return, FighterOrders.Return, FighterOrders.Attack,
                       FighterOrders.Return, FighterOrders.Return}
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
check(world.fighterOrders[1] == FighterOrders.CollectLoot
      and world.fighterOrders[4] == FighterOrders.CollectLoot,
      "and the fighters already out are turned round one by one, or they would land instead")
check(world.fighterOrders[3] == FighterOrders.Attack,
      "except one still attacking, which the engine sends home when the sector is clear")

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
-- the fight is over and its fighters are heading home on the orders it gave them
world.deployed = 3
world.fighterOrders = {FighterOrders.Return, FighterOrders.Return, FighterOrders.Return}
tick()
check(state().reaction and state().reaction.kind == "loot" and state().reaction.phase == "looting",
      "a fight that leaves loot goes on to the loot")
tick()
check(world.fighterOrders[1] == FighterOrders.CollectLoot
      and world.fighterOrders[2] == FighterOrders.CollectLoot
      and world.fighterOrders[3] == FighterOrders.CollectLoot,
      "fighters coming back from the fight are sent for the loot instead of landing")
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

-- #### CARGO TRANSFER #### --

local IRON = {name = "Iron", size = 1}
local STOLEN_IRON = {name = "Iron", size = 1, stolen = true}
local STEEL = {name = "Steel /* good */", size = 2}

local function transfer(spec)
    spec.id = spec.id or "t1"
    spec.target = spec.target or {faction = 1, name = "Hub"}
    OrderChain.automationApiTransfer(Json.encode(spec))
end

local function withHub(hub)
    hub = hub or {}
    hub.name = hub.name or "Hub"
    hub.station = hub.station ~= false
    local c = craft(hub)
    world.crafts[#world.crafts + 1] = c
    return c
end

print("\ncargo transfer in reach")

newWorld()
loadOrderChain()
world.ship = craft({name = "Self", capacity = 200, goods = {{STOLEN_IRON, 20}, {IRON, 100}, {STEEL, 10}}})
local hub = withHub({capacity = 1000})
busyChain()
local chainBefore = actions()

transfer({goods = {{name = "Iron", amount = 110}}})
local last = state().lastTransfer
check(last and last.id == "t1" and last.outcome == "done" and last.total == 110,
      "goods in reach are moved at once, and the ship says so")
check(world.ship:held("Iron", false) == 0 and world.ship:held("Iron", true) == 10
      and hub:held("Iron", false) == 100 and hub:held("Iron", true) == 10,
      "clean goods go before stolen ones of the same name")
check(#last.moved == 2 and last.moved[1].amount == 100 and last.moved[1].stolen == nil
      and last.moved[2].amount == 10 and last.moved[2].stolen == true,
      "and the report keeps the two apart")
check(actions() == chainBefore and state().transfer == nil,
      "nothing the ship was doing is touched")

transfer({id = "t2", goods = {{name = "Steel"}}})
check(state().lastTransfer.outcome == "done" and hub:held("Steel /* good */") == 10,
      "a good is named without the engine's translator hint, and no amount takes all of it")

transfer({id = "t3", goods = {{name = "Iron", stolen = false}}})
check(state().lastTransfer.outcome == "nothing_moved" and state().lastTransfer.short[1].reason == "not_held",
      "an entry that asks for clean goods leaves the stolen ones")

transfer({id = "t4", goods = {{name = "Gold"}, {name = "Iron"}}})
last = state().lastTransfer
check(last.outcome == "partial" and last.short[1].name == "Gold" and last.short[1].reason == "not_held"
      and hub:held("Iron", true) == 20,
      "what the hold does not have is reported, and the rest still moves")

print("\ncargo transfer, taking, limited by space")

newWorld()
loadOrderChain()
world.ship = craft({name = "Self", capacity = 25, goods = {{IRON, 5}}})
hub = withHub({goods = {{IRON, 50}, {STEEL, 30}}})

transfer({direction = "take", all = true})
last = state().lastTransfer
check(last.outcome == "partial" and world.ship.freeCargoSpace == 0 and last.short[1].reason == "no_space",
      "taking everything fills the hold and says the rest did not fit")
check(world.ship:held("Iron") == 25 and hub:held("Iron") == 30 and hub:held("Steel /* good */") == 30,
      "nothing is lost or made up between the two holds")

transfer({id = "t2", direction = "take", goods = {{name = "Steel", amount = 3}}})
check(state().lastTransfer.outcome == "nothing_moved" and state().lastTransfer.short[1].reason == "no_space",
      "a good that does not fit at all moves nothing")

print("\ncargo transfer, who with")

newWorld()
loadOrderChain()
world.ship = craft({name = "Self", goods = {{IRON, 10}}})
withHub({name = "Stranger", faction = 2})
withHub({name = "Depot", faction = 9})

transfer({target = {faction = 1, name = "Nowhere"}, all = true})
check(state().lastTransfer.outcome == "refused" and state().lastTransfer.reason == "target_not_here",
      "a target not in the sector is refused")
transfer({target = {faction = 2, name = "Stranger"}, all = true})
check(state().lastTransfer.reason == "not_permitted", "another player's craft is refused")
transfer({target = {faction = 1, name = "Self"}, all = true})
check(state().lastTransfer.reason == "same_craft", "the ship itself is refused")
transfer({target = {faction = 9, name = "Depot"}, all = true})
check(state().lastTransfer.outcome == "done", "the owner's alliance's craft is allowed")

world.ship = craft({name = "Self", goods = {{IRON, 10}}})
world.permitted = false
_G.callingPlayer = 1
transfer({target = {faction = 9, name = "Depot"}, all = true, id = "client"})
check(state().lastTransfer.id ~= "client", "a client without ManageShips gets nowhere")
_G.callingPlayer = nil
world.permitted = true

print("\ncargo transfer out of reach")

newWorld()
loadOrderChain()
world.ship = craft({name = "Self", goods = {{IRON, 10}}})
hub = withHub()
world.distance.Hub = 500

transfer({all = true, approach = false})
check(state().lastTransfer.reason == "out_of_range", "without approach, a target out of reach is refused")

world.distance.Hub = 25
hub.transporterRange = 30
transfer({id = "t2", all = true, approach = false})
check(state().lastTransfer.outcome == "done", "a transporter reaching further counts, as in vanilla")

world.ship = craft({name = "Self", goods = {{IRON, 10}}})
hub.hold = {}
world.distance.Hub = 500
world.captain = nil
transfer({id = "t3", all = true})
check(state().lastTransfer.reason == "needs_captain", "approaching needs a captain")
world.captain = {name = "Vel"}
world.pilots = {1}
transfer({id = "t4", all = true})
check(state().lastTransfer.reason == "piloted", "and nobody at the controls")
world.pilots = {}

plan({id = "route", hops = {{x = 5, y = 0, kind = "jump"}}})
transfer({id = "t5", all = true})
check(state().transfer and state().transfer.phase == "docking" and actions() == "?",
      "a station out of reach is docked with, with vanilla's dock order")
check(OrderChain.chain[1].action == OrderType.DockToStation and OrderChain.chain[1].targetId == "id-Hub",
      "naming the station")
check(state().plan == nil and state().last.outcome == "replaced", "which ends the plan the ship was flying")

tick()
check(state().transfer and hub:held("Iron") == 0, "nothing moves while the ship is still out of reach")

world.distance.Hub = 0
tick()
check(state().transfer == nil and state().lastTransfer.id == "t5" and state().lastTransfer.outcome == "done"
      and state().lastTransfer.approached == true and hub:held("Iron") == 10,
      "and once it is close, the cargo moves")

world.ship = craft({name = "Self", goods = {{IRON, 10}}})
world.distance.Hub = 500
transfer({id = "t6", all = true})
world.dockDone = true
tick()
check(state().transfer == nil and state().lastTransfer.reason == "out_of_range",
      "docking that ends out of reach is reported rather than waited on")
world.dockDone = false

-- what the local server showed: the dock order stops in the docking area, 60 from the hull
world.ship = craft({name = "Self", goods = {{IRON, 10}}})
hub.hold = {}
world.distance.Hub = 500
transfer({id = "t7", all = true})
world.distance.Hub = 60
world.docked.Hub = true
world.dockDone = true
tick()
check(state().transfer == nil and state().lastTransfer.id == "t7" and state().lastTransfer.outcome == "done"
      and hub:held("Iron") == 10,
      "a ship in the station's docking area is in reach, however far the hull is")
check(#OrderChain.chain == 1 and not OrderChain.running, "and the finished dock order is left as vanilla leaves it")
world.dockDone = false
world.docked.Hub = nil

world.ship = craft({name = "Self", goods = {{IRON, 10}}})
hub.hold = {}
world.distance.Hub = 60
world.docked.Hub = true
transfer({id = "t8", all = true, approach = false})
check(state().lastTransfer.outcome == "done", "already docked counts as in reach without approaching too")
world.docked.Hub = nil

print("\ncargo transfer flying alongside a ship")

newWorld()
loadOrderChain()
world.ship = craft({name = "Self", goods = {{IRON, 10}}})
local freighter = withHub({name = "Freighter", station = false})
world.distance.Freighter = 800

transfer({target = {faction = 1, name = "Freighter"}, all = true})
check(state().transfer.phase == "approaching" and #OrderChain.chain == 0, "a ship is flown to, not docked with")
tick()
check(world.flyCalls == 1 and world.flyTo.target == freighter.translationf and world.flyTo.distance == 80,
      "right up to it")
tick() tick() tick()
check(world.flyCalls == 2, "renewing the course as the target moves")

standing({enemies = {enabled = true, mode = "idle"}})
world.enemies = true
tick()
check(state().reaction == nil and state().transfer ~= nil, "a standing order waits for the approach")
world.enemies = false

for _ = 1, 300 do tick() end
check(state().transfer == nil and state().lastTransfer.reason == "timeout" and world.aiState == "Passive",
      "a target never reached is given up on")

transfer({id = "t2", target = {faction = 1, name = "Freighter"}, all = true})
OrderChain.enchain({action = OrderType.Patrol})
OrderChain.runOrders()
tick()
check(state().transfer == nil and state().lastTransfer.outcome == "replaced", "other orders take over from it")
OrderChain.clearAllOrders()

transfer({id = "t3", target = {faction = 1, name = "Freighter"}, all = true})
local saved = OrderChain.secure()
loadOrderChain()
OrderChain.restore(saved)
OrderChain.updateShipOrderInfo()
check(state().transfer and state().transfer.id == "t3", "a transfer on its way survives a reload")
world.distance.Freighter = 10
tick()
check(state().lastTransfer.id == "t3" and state().lastTransfer.outcome == "done" and freighter:held("Iron") == 10,
      "and finishes after it")

transfer({id = "t4", target = {faction = 1, name = "Freighter"}, direction = "take", all = true})
world.distance.Freighter = 900
world.ship = craft({name = "Self"})
transfer({id = "t5", target = {faction = 1, name = "Freighter"}, all = true})
OrderChain.automationApiStop()
check(state().transfer == nil and state().lastTransfer.outcome == "stopped", "stop ends a transfer on its way")

print("\nstopping")

newWorld()
loadOrderChain()
plan({id = "t1", hops = {{x = 5, y = 0, kind = "jump"}}})
OrderChain.automationApiStop()
check(#OrderChain.chain == 0 and state().plan == nil and state().last.outcome == "stopped",
      "stop clears the chain and ends the plan")


-- #### FLEEING #### --

print("\nfleeing: thresholds")

newWorld()
loadOrderChain()
world.known[1] = {{x = 3, y = 0}}

standing({flee = {enabled = true, hull = 0.5}})
check(state().standing.flee.enabled == true and state().standing.flee.hull == 0.5
      and state().standing.flee.to.kind == "known",
      "the flee order is published with its thresholds and destination")

world.hull = 0.6
tick()
check(state().flee == nil, "a healthy ship does not run")

world.hull = 0.4
tick()
check(state().flee == nil, "nor does a hurt one with nobody shooting at it")

world.enemies = true
tick()
check(actions() == "J3:0" and state().flee ~= nil and state().flee.reason == "hull",
      "hull below the threshold with enemies about sends the ship to a known sector")
check(state().vitals and state().vitals.hull == 0.4, "and its hull is published with it")

jumpTo(3, 0)
check(state().flee == nil and state().lastFlee.outcome == "arrived"
      and state().lastFlee.reason == "hull" and state().lastFlee.from.x == 0,
      "arriving ends the flee, and says where it ran from")

newWorld()
loadOrderChain()
world.known[1] = {{x = 3, y = 0}}
standing({flee = {enabled = true, hull = 0, shield = 0.5, requireEnemies = false}})
world.shield = 0.4
tick()
check(state().flee ~= nil and state().flee.reason == "shield",
      "the shield threshold fires on its own, and without enemies when told to")

print("\nfleeing: what it interrupts")

newWorld()
loadOrderChain()
world.known[1] = {{x = 3, y = 0}}
standing({flee = {enabled = true, hull = 0.5}, enemies = {enabled = true, mode = "interrupt"}})
plan({id = "r1", hops = {{x = 5, y = 0, kind = "jump"}}})
world.enemies = true
world.hull = 0.4
tick()
check(state().plan == nil and state().last.outcome == "fled" and state().flee ~= nil
      and actions() == "J3:0",
      "a flee breaks off a plan rather than waiting for it")
check(state().reaction == nil, "and the enemies order does not get the ship instead")

newWorld()
loadOrderChain()
world.known[1] = {{x = 3, y = 0}}
standing({enemies = {enabled = true, mode = "interrupt"}, flee = {enabled = true, hull = 0.5}})
world.enemies = true
tick()
check(state().reaction and state().reaction.kind == "enemies",
      "an undamaged ship fights as before")
world.hull = 0.4
tick()
check(state().flee ~= nil and state().lastReaction.outcome == "fled",
      "and breaks off that fight once it is losing it")

print("\nfleeing: where to")

newWorld()
loadOrderChain()
world.range = 6
world.known[1] = {{x = 3, y = 0}, {x = 5, y = 0}}
world.controlled["5:0"] = 7
world.relations[7] = 25000
standing({flee = {enabled = true, hull = 0.5, to = {kind = "safe"}}})
world.enemies = true
world.hull = 0.4
tick()
check(actions() == "J5:0", "'safe' runs for space held by a faction that is not hostile")

newWorld()
loadOrderChain()
world.range = 6
world.known[1] = {{x = 3, y = 0}, {x = 5, y = 0}}
world.controlled["5:0"] = 7
world.relations[7] = -50000
world.randoms = {1}   -- so "one of the known sectors" is the first of them
standing({flee = {enabled = true, hull = 0.5, to = {kind = "safe"}}})
world.enemies = true
world.hull = 0.4
tick()
check(actions() == "J3:0", "and passes over space held by somebody at war with the owner")

newWorld()
loadOrderChain()
world.values["automationapi_locations_1"] =
    Json.encode({version = 1, locations = {Home = {x = 2, y = 0}}})
standing({flee = {enabled = true, hull = 0.5, to = {kind = "location", name = "Home"}}})
world.enemies = true
world.hull = 0.4
tick()
check(actions() == "J2:0", "'location' reads the owner's library out of its Server value")
jumpTo(2, 0)
check(state().lastFlee.outcome == "arrived", "and reaching it ends the flee")

newWorld()
loadOrderChain()
standing({flee = {enabled = true, hull = 0.5, to = {kind = "sector", x = 4, y = 3}}})
world.enemies = true
world.hull = 0.4
tick()
check(actions() == "J4:3", "'sector' jumps to the coordinates it was given")

newWorld()
loadOrderChain()
world.x, world.y = 4, 3
world.known[1] = {{x = 4, y = 3}, {x = 6, y = 3}}
standing({flee = {enabled = true, hull = 0.5, to = {kind = "sector", x = 4, y = 3}}})
world.enemies = true
world.hull = 0.4
tick()
check(actions() == "J6:3",
      "a craft attacked in the sector it was told to run to still leaves")

print("\nfleeing: walking to somewhere out of reach")

newWorld()
loadOrderChain()
world.fleet[1] = {Yard = {x = 20, y = 0, station = true}, Tug = {x = 1, y = 1}}
world.known[1] = {{x = 5, y = 0}, {x = 10, y = 0}, {x = -5, y = 0}}
standing({flee = {enabled = true, hull = 0.5, hops = 2, to = {kind = "station"}}})
world.enemies = true
world.hull = 0.4
tick()
check(actions() == "J5:0", "a station out of jump range is walked towards, not routed")
jumpTo(5, 0)
check(actions() == "J10:0" and state().flee ~= nil, "one hop at a time, while hops are left")
jumpTo(10, 0)
check(state().flee == nil and state().lastFlee.outcome == "escaped"
      and state().lastFlee.hops == 2,
      "and running out of hops ends it as escaped rather than arrived")

newWorld()
loadOrderChain()
world.fleet[1] = {Tug = {x = 3, y = 0}}
standing({flee = {enabled = true, hull = 0.5, to = {kind = "station", name = "any"}}})
world.enemies = true
world.hull = 0.4
tick()
check(actions() == "J3:0", "'any' takes the nearest craft of the fleet when there is no station")

print("\nfleeing: when it cannot")

newWorld()
loadOrderChain()
world.range = 0
standing({flee = {enabled = true, hull = 0.5}})
world.enemies = true
world.hull = 0.4
tick()
check(state().flee and state().flee.phase == "stuck" and #OrderChain.chain == 0,
      "a ship that cannot jump clears its chain and keeps trying")
world.range = 5
world.known[1] = {{x = 3, y = 0}}
tick(6)   -- past AUTOMATION_API_FLEE_RETRY
check(actions() == "J3:0", "and goes as soon as it can")

newWorld()
loadOrderChain()
world.range = 0
standing({flee = {enabled = true, hull = 0.5}})
world.enemies = true
world.hull = 0.4
tick()
tick(1000)
check(state().flee == nil and state().lastFlee.outcome == "failed",
      "a flee that never gets anywhere gives up rather than holding the ship for ever")

print("\nfleeing: stopping and reloading")

newWorld()
loadOrderChain()
world.known[1] = {{x = 3, y = 0}}
standing({flee = {enabled = true, hull = 0.5}})
world.enemies = true
world.hull = 0.4
tick()
OrderChain.automationApiStop()
check(state().flee == nil and state().lastFlee.outcome == "stopped" and #OrderChain.chain == 0,
      "stop ends a flee in flight")

newWorld()
loadOrderChain()
world.known[1] = {{x = 3, y = 0}}
standing({flee = {enabled = true, hull = 0.5}})
world.enemies = true
world.hull = 0.4
tick()
standing({flee = {enabled = false}})
tick()
check(state().flee == nil and state().lastFlee.outcome == "switched_off",
      "switching the order off calls the ship back")

newWorld()
loadOrderChain()
world.known[1] = {{x = 3, y = 0}}
standing({flee = {enabled = true, hull = 0.75, hops = 3, to = {kind = "sector", x = 9, y = 9}}})
world.enemies = true
world.hull = 0.4
tick()
local fleeing = OrderChain.secure()
loadOrderChain()
OrderChain.restore(fleeing)
OrderChain.updateShipOrderInfo()
check(state().flee ~= nil and state().standing.flee.hull == 0.75
      and state().standing.flee.hops == 3 and state().standing.flee.to.x == 9,
      "a flee and its settings survive a reload")

newWorld()
loadOrderChain()
standing({flee = {enabled = true, hull = 2, hops = 99, to = {kind = "nonsense"}}})
check(state().standing.flee.hull == 1 and state().standing.flee.hops == 10
      and state().standing.flee.to.kind == "known",
      "the ship clamps what it is sent and ignores a destination it does not know")

print("")
if failures > 0 then print(failures .. " check(s) failed"); os.exit(1) end
print("all checks passed")
