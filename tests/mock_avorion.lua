-- Minimal stand-in for the Avorion scripting environment, enough to drive the bridge
-- outside the game. Only what the mod actually touches is implemented.

local M = {}

local root = os.getenv("MOCK_ROOT") or "/tmp/avorion-mock"

local function keyOf(x, y) return x .. ":" .. y end

local serverValues = {}
local playerValues = {}
local players = {}

local clock = 1000.0

-- #### FILESYSTEM #### --

local function shellQuote(s) return "'" .. string.gsub(s, "'", "'\\''") .. "'" end

function M.install()
    -- Our own modules load for real. Vanilla modules are stubbed: pulling in the real
    -- simulationutility would drag half the game's script tree along with it.
    _G.include = function(path)
        if M.stubs[path] then return M.stubs[path] end
        return require((string.gsub(path, "/", ".")))
    end

    -- lib/ordertypes.lua defines this global as a side effect of being included. Values
    -- are the game's own; the order confirmation matches published chains against them.
    _G.OrderType =
    {
        Jump = 1, Mine = 2, Salvage = 3, Loop = 4, Aggressive = 5, Patrol = 6,
        Escort = 9, AttackCraft = 10, FlyThroughWormhole = 11, FlyToPosition = 12,
        GuardPosition = 13, RefineOres = 14, Board = 15, RepairTarget = 16, Repair = 17,
        DockToStation = 19,
    }

    _G.onClient = function() return false end
    _G.onServer = function() return true end

    _G.printlog = function(fmt, ...)
        if M.verbose then print("[log] " .. string.format(fmt, ...)) end
    end
    _G.eprint = function(fmt, ...)
        M.errors[#M.errors + 1] = string.format(fmt, ...)
        if M.verbose then print("[err] " .. string.format(fmt, ...)) end
    end
    _G.print = _G.print

    _G.createDirectory = function(dir)
        os.execute("mkdir -p " .. shellQuote(dir))
        return 0
    end

    _G.deleteFile = function(file)
        os.remove(file)
        return 0
    end

    _G.listFilesOfDirectory = function(dir)
        local pipe = io.popen("ls -1 " .. shellQuote(dir) .. " 2>/dev/null")
        if not pipe then return end

        local names = {}
        for line in pipe:lines() do names[#names + 1] = line end
        pipe:close()

        return table.unpack(names)
    end

    -- #### GAME OBJECTS #### --

    local server =
    {
        folder = root,
        name = "MockGalaxy",
        seed = "ABCDEFG",
        players = 1,
        maxPlayers = 10,
    }

    setmetatable(server, {__index = function(t, k)
        if k == "unpausedRuntime" or k == "runtime" then return clock end
        return nil
    end})

    function server:setValue(key, value) serverValues[key] = value end
    function server:getValue(key) return serverValues[key] end
    function server:isOnline(index) return players[index] ~= nil and players[index].online end

    _G.Server = function() return server end

    _G.Player = function(index)
        -- In a player script Player() means "the player this script is attached to".
        if index == nil then index = M.currentPlayer end
        if index == nil then return nil end
        local p = players[index]
        if not p then return nil end

        return p
    end

    _G.GameVersion = function() return "2.5.13" end

    local uuidCounter = 0
    _G.Uuid = function()
        local u = {string = "00000000-0000-0000-0000-000000000000"}
        function u:toRandom()
            uuidCounter = uuidCounter + 1
            -- deterministic but distinct, so tests can assert on key uniqueness
            self.string = string.format("%08x-%04x-%04x-%04x-%012x",
                uuidCounter * 2654435761 % 0xffffffff, uuidCounter % 0xffff,
                (uuidCounter * 7) % 0xffff, (uuidCounter * 13) % 0xffff, uuidCounter)
        end
        return u
    end

    -- Avorion's sandbox breaks os.rename: it returns true, deletes the source and never
    -- creates the destination (verified against 2.5.13). Reproduced here so that any
    -- future attempt to rename inside the mod fails loudly in tests instead of silently
    -- losing data in the game.
    _G.os.rename = function(oldname, newname)
        os.remove(oldname)
        return true
    end

    -- #### ENUMS #### --
    -- The engine's enums are userdata: indexing works, pairs() yields nothing. Modelled
    -- here as proxy tables with no own keys so that code which tries to iterate an engine
    -- enum fails in tests the same way it fails in the game.
    local function engineEnum(members)
        return setmetatable({}, {__index = members})
    end
    _G.EntityType = engineEnum({None = 0, Ship = 1, Drone = 2, Station = 3, Turret = 4, Asteroid = 5,
                     Wreckage = 6, Anomaly = 7, Loot = 8, WormHole = 9, Torpedo = 10,
                     Fighter = 11, Container = 12, Unknown = 13, Other = 14})
    _G.ShipAvailability = engineEnum({Available = 0, Destroyed = 1, InBackground = 2})
    _G.CrewProfessionType = engineEnum({None = 0, Engine = 1, Gunner = 2, Miner = 3, Repair = 4,
                             Pilot = 5, Security = 6, Attacker = 7, Number = 8})
    _G.MalusReason = engineEnum({None = 0, Reconstruction = 1, Boarding = 2, RiftTeleport = 3})
    _G.WeaponCategory = engineEnum({Armed = 0, Mining = 1, Salvaging = 2, Heal = 3})
    _G.AlliancePrivilege = engineEnum({ManageShips = 15, ManageStations = 14, SpendResources = 13})

    _G.valid = function(o) return o ~= nil end

    -- #### SHIP DATABASE #### --

    _G.ShipDatabaseEntry = function(factionIndex, name)
        local ship = M.getShip(factionIndex, name)
        if not ship then return nil end

        local e = {faction = factionIndex, name = name, numBlocks = ship.blocks or 100}
        function e:exists() return true end
        function e:getCoordinates() return ship.x, ship.y end
        function e:getAvailability() return ship.availability end
        function e:getEntityType() return ship.type end
        function e:getCaptain() return ship.captain end
        function e:getCrew() return ship.crew end
        function e:buildIdealCrew() return ship.idealCrew or ship.crew end
        function e:getCrewRequirementsFulfilled() return ship.crewOk ~= false end
        function e:getCargo() return ship.cargo or {}, ship.cargoCapacity or 0 end
        function e:getFreeCargoSpace() return ship.cargoFree or 0 end
        function e:getHyperspaceProperties()
            return ship.range or 0, ship.canPassRifts == true, ship.cooldown or 0, ship.impaired == true
        end
        function e:getShields() return ship.shields or 0, ship.shieldPct or 1 end
        function e:getDurabilityProperties()
            return ship.hp or 0, ship.hpPct or 1, ship.malusFactor or 1, ship.malusReason or 0, ship.damaged == true
        end
        function e:getEnergyProperties() return ship.energyRequired or 0, ship.energyProduced or 0 end
        function e:getDPSValues() return ship.turretDps or 0, ship.fighterDps or 0 end
        function e:getTurrets() return ship.turrets or {} end
        function e:getSystems() return ship.systems or {} end
        function e:getLightweightHangar() return ship.hangar or {} end
        function e:getPlanValue() return ship.planValue or 0 end
        -- Only the statistics are modelled, and each read is counted, so a test can pin
        -- that a plan is not reloaded on every listing.
        function e:getPlan()
            ship.planReads = (ship.planReads or 0) + 1
            if ship.productionCapacity == nil then error("no plan") end
            return {getStats = function() return {productionCapacity = ship.productionCapacity} end}
        end
        function e:getReconstructionValue() return ship.reconstructionValue or 0 end
        function e:getStatusMessage() return ship.status end
        function e:getTitle() return ship.title end
        function e:getIcon() return ship.icon end
        function e:getOrderInfo() return ship.orderInfo end
        function e:getDocksEnabled() return ship.docksEnabled ~= false end

        -- scriptIndex -> path, and scriptIndex -> the table that script's secure()
        -- returned. Both are keyed by the same index and neither is a sequence, which is
        -- how the game hands them over and what the station reader has to cope with.
        function e:getScripts() return ship.scripts or {} end
        function e:getSecuredScriptValues() return ship.secured or {} end

        function e:getTurretSlotRequirementsFulfilled() return ship.turretSlotsOk ~= false end
        function e:getFighterStartRequirementsFulfilled() return ship.fighterStartsOk ~= false end
        function e:getFighterSquadRequirementsFulfilled() return ship.fighterSquadsOk ~= false end

        return e
    end

    _G.NumMaterials = function() return 7 end
    local materialNames = {[0]="Iron", [1]="Titanium", [2]="Naonite", [3]="Trinium",
                           [4]="Xanion", [5]="Ogonite", [6]="Avorion"}
    _G.Material = function(value) return {value = value, name = materialNames[value]} end

    _G.Galaxy = function()
        return
        {
            findFaction = function(_, index) return players[index] or M.alliances[index] end,
            sectorInRift = function(_, x, y) return M.riftSectors[keyOf(x, y)] == true end,
            sectorLoaded = function(_, x, y)
                if M.loadedSectors == nil then return true end
                return M.loadedSectors[keyOf(x, y)] == true
            end,
            sectorExists = function() return true end,
            jumpRouteUnobstructed = function() return M.jumpUnobstructed ~= false end,
            keepSector = function() return true end,
            -- The agent -> bridge direction, proven safe in game.
            invokeFunction = function(_, script, functionName, ...)
                local fn = AutomationApiBridge and AutomationApiBridge[functionName]
                if not fn then return 4 end
                return 0, fn(...)
            end,
        }
    end

    _G.vec2 = function(x, y) return {x = x or 0, y = y or 0} end
    _G.ivec2 = function(x, y) return {x = x or 0, y = y or 0} end

    _G.GameSeed = function() return {int32 = 4242, string = "MOCKSEED"} end
    _G.GameSettings = function() return {rifts = 200, mapFactions = 20} end

    -- A SectorView is engine userdata with properties and a handful of vararg getters.
    -- Modelled as a plain table, which is close enough: nothing in the mod does anything
    -- to one but read it.
    _G.SectorView = function(spec)
        local v = spec or {}

        v.x = v.x or 0
        v.y = v.y or 0
        v.name = v.name or (v.x .. " : " .. v.y)
        v.visited = v.visited ~= false
        v.factionIndex = v.factionIndex or 0
        v.numStations = v.numStations or 0
        v.numShips = v.numShips or 0
        v.numAsteroids = v.numAsteroids or 0
        v.numWrecks = v.numWrecks or 0
        v.influence = v.influence or 0
        v.timeStamp = v.timeStamp or 0
        v.hasContent = v.hasContent or (v.numStations > 0)
        v.deathLocation = v.deathLocation == true
        v.manuallyTagged = v.manuallyTagged == true
        v.note = v.note or "note"
        v.stations = v.stations or {}
        v.gates = v.gates or {}
        v.wormholes = v.wormholes or {}

        function v:getCoordinates() return self.x, self.y end
        function v:setCoordinates(x, y) self.x, self.y = x, y end
        function v:getStationTitles() return table.unpack(self.stations) end
        function v:setStationTitles(...) self.stations = {...} end
        function v:getGateDestinations() return table.unpack(self.gates) end
        function v:setGateDestinations(...) self.gates = {...} end
        function v:getWormHoleDestinations() return table.unpack(self.wormholes) end
        function v:setWormHoleDestinations(...) self.wormholes = {...} end
        function v:getCustomEntries() return self.customEntries or {} end
        function v:getStationsByFaction() return self.stationsByFaction or {} end
        function v:getShipsByFaction() return self.shipsByFaction or {} end
        function v:getCraftsByFaction() return self.craftsByFaction or {} end
        function v:calculateInfluence(stations) return (stations or 0) * 0.1 end

        return v
    end

    -- calculateJumpPath is the engine's pathfinder. The mock walks a straight line in
    -- jump-range steps, which is enough to exercise hop counting and the "route too
    -- short" gate without pretending to be a pathfinder.
    _G.calculateJumpPath = function(player, alliance, origin, destination, jumpRange, rifts)
        if M.routeResult ~= nil then return M.routeResult end

        local route = {{x = origin.x, y = origin.y}}
        local x, y = origin.x, origin.y
        local step = math.max(1, math.floor(jumpRange or 1))

        for _ = 1, 200 do
            if x == destination.x and y == destination.y then break end

            local dx = math.max(-step, math.min(step, destination.x - x))
            local dy = math.max(-step, math.min(step, destination.y - y))
            x, y = x + dx, y + dy

            route[#route + 1] = {x = x, y = y}
        end

        return route
    end

    -- Fire-and-forget by design; the mock records that it was asked, and then models the
    -- one observable consequence: orderchain.lua publishes the resulting chain back to the
    -- owning faction (setShipOrderInfo), which is how a dispatch can be confirmed at all.
    local chainEffects =
    {
        clearAllOrders       = function(c) return {} end,
        addJumpOrder         = function(c) c[#c + 1] = {name = "Jump", action = 1} return c end,
        addAggressiveOrder   = function(c) c[#c + 1] = {name = "Aggressive", action = 5} return c end,
        addPatrolOrder       = function(c) c[#c + 1] = {name = "Patrol", action = 6} return c end,
        addRepairOrder       = function(c) c[#c + 1] = {name = "Repair", action = 17} return c end,
        -- the one-shot wrappers replace the chain wholesale, as the engine's do
        onUserMineOrder      = function() return {{name = "Mine", action = 2}} end,
        onUserSalvageOrder   = function() return {{name = "Salvage", action = 3}} end,
        onUserRefineOresOrder = function() return {{name = "Refine Ores", action = 14}} end,
    }

    _G.invokeEntityFunction = function(x, y, printErrors, target, script, functionName, ...)
        M.entityCalls[#M.entityCalls + 1] =
        {
            x = x, y = y, target = target, script = script,
            fn = functionName, args = {...},
        }

        local ship = target and M.getShip(target.faction, target.name)
        -- orderChainFrozen models the engine refusing an order without saying so, which is
        -- the case the confirmation step exists to catch
        if ship and not M.orderChainFrozen then
            ship.chain = ship.chain or {}
            local effect = chainEffects[functionName]
            if effect then
                ship.chain = effect(ship.chain)
                ship.chainIndex = 0
            elseif functionName == "runOrders" then
                ship.chainIndex = math.min(1, #ship.chain)
            end

            -- The engine raises onShipOrderInfoUpdated on the owning faction whenever the
            -- chain changes; the player agent forwards it to the bridge. Tests install the
            -- forwarding end as `shipEventSink`, standing in for the agent.
            if M.shipEventSink and (effect or functionName == "runOrders") then
                local chain = {}
                for index, order in ipairs(ship.chain) do
                    chain[index] = {name = order.name, action = order.action}
                end

                M.shipEventSink(target.faction, target.name, "order",
                                {chain = chain, activeIndex = ship.chainIndex or 0,
                                 finished = false, x = x, y = y})
            end
        end

        return 0
    end

    -- asyncf runs on a worker thread in the game; here it queues so tests decide when
    -- (and whether) the result comes back.
    _G.asyncf = function(callbackName, script, ...)
        M.asyncQueue[#M.asyncQueue + 1] = {callback = callbackName, args = {...}}
    end

    M.stubs =
    {
        -- lib/ordertypes.lua defines OrderType as a global and returns the display table.
        -- Values mirror the game's exactly; the confirmation matches on them.
        ordertypes = setmetatable({}, {__call = function() return {} end}),
        captainclass = {None = 0, Commodore = 1, Smuggler = 2, Merchant = 3, Miner = 4,
                        Scavenger = 5, Explorer = 6, Daredevil = 7, Scientist = 8, Hunter = 9},
        simulationutility =
        {
            UsableError = {Unavailable = 1, NotAShip = 2, NoCaptain = 3, BadCrew = 4,
                           BadEnergy = 5, Damaged = 6, UnderAttack = 7},
            isShipUsable = function(ownerIndex, name)
                local ship = M.getShip(ownerIndex, name)
                if not ship then return 1 end
                return ship.usableError
            end,
            getAreaStats = function(area)
                return
                {
                    numSectors = area.analysis and area.analysis.sectors or 0,
                    area = {lower = area.lower, upper = area.upper, origin = area.origin},
                    unreachableSectors = area.analysis and area.analysis.unreachable or 0,
                    noMansSectors = 50, outerSectors = 30, centralSectors = 20,
                }
            end,
        },
        -- lib/galaxy.lua only exists for its Balancing_* globals, which are installed
        -- below; the module itself is never indexed by this mod.
        galaxy = {},

        -- lib/goods.lua is pure data that defines the `goods` global as a side effect.
        -- economy.lua prices a production chain off it, so the mock installs a handful of
        -- real entries rather than an empty table - a chain priced at zero would let a
        -- broken lookup pass the tests.
        goods = (function()
            _G.goods =
            {
                ["Ore"] = {name = "Ore", plural = "Ore", price = 30, size = 1, level = 0},
                ["Energy Cell"] = {name = "Energy Cell", plural = "Energy Cells",
                                   price = 61, size = 1, level = 0},
                ["Raw Oil"] = {name = "Raw Oil", plural = "Raw Oil", price = 66,
                               size = 2, level = 0},
                ["Oil"] = {name = "Oil", plural = "Oil", price = 320, size = 2, level = 1},
            }
            return {}
        end)(),

        -- The seed-derived generator. The real one reproduces the galaxy generator's
        -- decision layer; the mock reads a table the test set up, so the endpoints can
        -- be exercised without shipping a galaxy.
        -- Note the shape: the real module returns {new = new} with a __call metamethod
        -- and NOT the class table, so determineFastContent is reachable only through an
        -- instance. That is reproduced here, because getting it wrong silently rules out
        -- every sector in the galaxy.
        sectorspecifics = setmetatable({},
        {
            __call = function()
                local instance =
                {
                    determineFastContent = function(x, y, seed)
                        local spec = M.predicted[keyOf(x, y)]
                        if not spec then return false, false, 0 end
                        return spec.regular == true, spec.offgrid == true, spec.dustyness or 0
                    end,
                }

                function instance:initialize(x, y, seed)
                    local spec = M.predicted[keyOf(x, y)] or {}

                    M.predictions = M.predictions + 1

                    self.coordinates = {x = x, y = y}
                    self.name = spec.name or (x .. " : " .. y)
                    self.regular = spec.regular == true
                    self.offgrid = spec.offgrid == true
                    self.blocked = spec.blocked == true
                    self.gates = spec.gates == true
                    self.ancientGates = false
                    self.dustyness = spec.dustyness or 0
                    self.factionIndex = spec.factionIndex or 0
                    self.centralArea = spec.centralArea == true
                    self.stations = spec.stations or {}
                    self.generationTemplate =
                        (self.regular or self.offgrid) and {path = spec.template or "sectors/mock"}
                        or nil
                end

                function instance:getScript()
                    return self.generationTemplate and self.generationTemplate.path or ""
                end

                function instance:fillSectorView(view, gatesMap, withContent)
                    view:setCoordinates(self.coordinates.x, self.coordinates.y)
                    view.factionIndex = self.factionIndex
                    view.name = self.name

                    if withContent then
                        view.numStations = #self.stations
                        view:setStationTitles(table.unpack(self.stations))
                    end
                end

                return instance
            end,
        }),

        gatesmap = setmetatable({}, {__call = function()
            return {getConnectedSectors = function() return {} end,
                    hasGates = function() return false end}
        end}),

        commandtype = M.commandTypes,
        commandfactory =
        {
            makeCommand = function(missionType, shipName, area, config)
                return M.makeCommand(missionType, shipName, area, config)
            end,
            getRegistry = function() return {} end,
        },
    }

    -- Avorion's sandbox breaks os.rename: it returns true, deletes the source and never
    -- creates the destination (verified against 2.5.13). Reproduced here so that any
    -- future attempt to rename inside the mod fails loudly in tests instead of silently
    -- losing data in the game.
    _G.os.rename = function(oldname, newname)
        os.remove(oldname)
        return true
    end

    -- lib/galaxy.lua's balancing curves. Straight-line stand-ins: the mod only passes
    -- them through, so what matters is that they are called and produce finite numbers.
    _G.Balancing_GetDimensions = function() return 1000 end
    _G.Balancing_GetMaxCoordinates = function() return 500 end
    _G.Balancing_GetMinCoordinates = function() return -499 end
    _G.Balancing_GetBlockRingMin = function() return 147 end
    _G.Balancing_GetBlockRingMax = function() return 150 end
    _G.Balancing_InsideRing = function(x, y) return x * x + y * y < 147 * 147 end
    _G.Balancing_GetTechLevel = function(x, y)
        return math.max(1, 52 - math.floor(math.sqrt(x * x + y * y) / 10))
    end
    _G.Balancing_GetSectorRichnessFactor = function() return 3.5 end
    _G.Balancing_GetPirateLevel = function() return 12 end
    _G.Balancing_GetMaterialBeltRadius = function(material)
        return (7 - material) / 7 - 0.1
    end
    _G.Balancing_GetMaterialProbability = function()
        return {[0] = 0.5, [1] = 0.3, [2] = 0.2, [3] = 0, [4] = 0, [5] = 0, [6] = 0}
    end
    _G.Balancing_GetHighestAvailableMaterial = function() return 2 end

    M.errors = {}
end

-- #### TEST CONTROLS #### --

-- The real CommandType UUIDs, so the mapping the mod ships is exercised rather than
-- a parallel set of fake ids.
M.commandTypes =
{
    Prototype   = "75381938-0832-4be6-8d36-c3f1e9fce679",
    Travel      = "bbcf8ba1-a1e0-4a34-8174-15caebd11fed",
    Scout       = "7619ca9c-3f26-4b89-a4a4-10fd9aca5c60",
    Mine        = "c367bdbc-15c1-4aac-b691-cf92b6c541a0",
    Salvage     = "1cbc94e6-aea3-4d1f-8159-d9e27d6b5d92",
    Refine      = "77110b44-b327-4747-b618-69a82a5789cf",
    Trade       = "0c21be5b-d6a9-47ca-a1b3-200b11d2af4b",
    Procure     = "c2f0d06e-1a0b-490e-b2f1-e72f2c75a9db",
    Sell        = "6bf2d9af-255b-4108-a1e1-dc83ace49819",
    Supply      = "94f687f6-70b7-4491-afa5-99932a626be3",
    Expedition  = "3b881819-3eb6-4af0-b4d3-a24558162432",
    Maintenance = "d1a1b62f-6f58-43fa-93c0-3a0926a666af",
    Escort      = "4c9331c4-1634-4aaf-b1c6-1b9d38ddefde",
}

M.asyncQueue = {}
M.alliances = {}
M.simulationCalls = {}

-- Map-layer state. `predicted` stands in for what the galaxy seed would generate;
-- `entityCalls` records order-chain dispatch, which the engine gives no way to observe.
M.predicted = {}
M.predictions = 0
M.entityCalls = {}
M.orderChainFrozen = false
-- set by tests to the bridge's pushShipEvent, standing in for the player agent
M.shipEventSink = nil
M.riftSectors = {}
M.loadedSectors = nil
M.jumpUnobstructed = true
M.routeResult = nil

-- How long the game takes to run its own area analysis, in seconds.
M.analysisDelay = 1.2

-- True while an area analysis callback is running, i.e. while on a background thread.
M.inAsyncCallback = false

-- True while the player agent is running, i.e. while Simulation calls are legal.
M.inPlayerAgent = false

-- Overridable by tests to drive the validation paths.
M.commandError = nil
M.commandErrorArgs = nil
M.predictionError = nil
M.predictionRaises = nil
M.areaSize = {x = 15, y = 15}
M.areaFixed = false

function M.makeCommand(missionType, shipName, area, config)
    local c = {type = missionType, shipName = shipName, area = area, config = config or {}}

    function c:getAreaSize() return M.areaSize end
    function c:isAreaFixed() return M.areaFixed end
    function c:isShipRequiredInArea() return true end
    function c:getConfigurableValues()
        return {duration = {from = 0.5, to = 2, default = 1, displayName = "Duration"}}
    end
    function c:getPredictableValues() return {yields = {}, attackChance = {value = 0}} end
    function c:getErrors() return M.commandError, M.commandErrorArgs end
    function c:calculatePrediction()
        -- Vanilla prediction code indexes things it assumes are there - the captain,
        -- most often - and raises outright when they are not. That is a different
        -- failure from returning an error, and the mod has to survive both.
        if M.predictionRaises then error(M.predictionRaises, 0) end

        return {attackChance = {value = 0.12}, yields = {{from = 100, to = 200}},
                error = M.predictionError}
    end
    function c:generateAssessmentFromPrediction() return {"The area looks rich."} end

    return c
end

-- Delivers queued asyncf results, standing in for the worker thread finishing.
function M.flushAsync(results)
    local queued = M.asyncQueue
    M.asyncQueue = {}

    for _, job in ipairs(queued) do
        local ownerIndex, shipName, missionType, area, callingPlayer = table.unpack(job.args)

        area.origin = {x = 0, y = 0}
        local analysis = results or
        {
            sectors = 225, reachable = 200, unreachable = 25,
            sectorsByFaction = {[0] = 120}, reachableCoordinates = {},
            biggestFactionInArea = 0,
        }

        -- The real callback resumes on the background thread that ran the analysis.
        -- Engine reads survive that; invokeFunction takes the whole server down with a
        -- SIGSEGV. Standing in an error for the segfault keeps that discipline testable.
        M.inAsyncCallback = true
        local ok, err = pcall(AutomationApiBridge[job.callback],
                              shipName, missionType, area, analysis, callingPlayer)
        M.inAsyncCallback = false

        if not ok then error(err, 0) end
    end

    return #queued
end

local ships = {}

-- Reaching a player object back out of the mock, so a test can move them between sectors.
function M.player(index) return players[index] end

function M.getShip(factionIndex, name)
    return ships[factionIndex] and ships[factionIndex][name] or nil
end

-- spec fields mirror the ShipDatabaseEntry getters; everything has a default
function M.addShip(factionIndex, name, spec)
    spec = spec or {}
    spec.x = spec.x or 0
    spec.y = spec.y or 0
    spec.type = spec.type or EntityType.Ship
    spec.availability = spec.availability or ShipAvailability.Available

    ships[factionIndex] = ships[factionIndex] or {}
    ships[factionIndex][name] = spec

    return spec
end

-- The faction ledger, shared by Player and Alliance. Resources come back as one value
-- per material rather than a table, exactly as the engine returns them.
local function addLedgerApi(faction)
    faction.money = faction.money or 0
    faction.resources = faction.resources or {}

    function faction:getResources()
        local out = {}
        for value = 0, NumMaterials() - 1 do
            out[value + 1] = self.resources[value] or 0
        end
        return table.unpack(out)
    end
end

-- The craft API shared by Player and Alliance.
local function addCraftApi(faction)
    function faction:getShipNames()
        local owned = ships[self.index] or {}
        local names = {}
        for name, _ in pairs(owned) do names[#names + 1] = name end
        table.sort(names)
        return table.unpack(names)
    end
    function faction:ownsShip(name) return M.getShip(self.index, name) ~= nil end
    function faction:getShipType(name)
        local s = M.getShip(self.index, name); return s and s.type
    end
    function faction:getShipPosition(name)
        local s = M.getShip(self.index, name)
        if not s then return end
        return s.x, s.y
    end
    function faction:getShipAvailability(name)
        local s = M.getShip(self.index, name); return s and s.availability
    end
    -- The engine hands this back as a JSON string, so the mock must too - the handler
    -- decodes it rather than trusting a table.
    function faction:getShipOrderInfo(name)
        local s = M.getShip(self.index, name)
        if not s then return nil end

        local parts = {}
        for _, order in ipairs(s.chain or {}) do
            parts[#parts + 1] = string.format('{"action":%d,"name":"%s"}',
                                              order.action or 0, order.name or "")
        end

        local ship = M.getShip(self.index, name)
        return string.format('{"chain":[%s],"currentIndex":%d,"finished":%s}',
                             table.concat(parts, ","), ship.chainIndex or 0,
                             tostring(ship.chainFinished == true))
    end

    function faction:getShipStatus(name)
        local s = M.getShip(self.index, name); return s and s.statusText
    end

    function faction:getKnownSectorCoordinates()
        local owned = M.known[self.index] or {}

        local coords = {}
        for _, view in pairs(owned) do
            coords[#coords + 1] = {x = view.x, y = view.y}
        end

        table.sort(coords, function(a, b)
            if a.y ~= b.y then return a.y < b.y end
            return a.x < b.x
        end)

        return table.unpack(coords)
    end

    function faction:getKnownSector(x, y)
        return (M.known[self.index] or {})[x .. ":" .. y]
    end

    function faction:getKnownSectors()
        local owned = M.known[self.index] or {}
        local views = {}
        for _, view in pairs(owned) do views[#views + 1] = view end
        return table.unpack(views)
    end

    function faction:getHomeSectorCoordinates()
        local home = M.homeSectors[self.index]
        if not home then return 0, 0 end
        return home.x, home.y
    end
end

M.known = {}
M.homeSectors = {}

-- spec fields mirror the SectorView properties; `stations` is a list of plain names
function M.addKnownSector(factionIndex, x, y, spec)
    spec = spec or {}
    spec.x, spec.y = x, y

    M.known[factionIndex] = M.known[factionIndex] or {}
    M.known[factionIndex][x .. ":" .. y] = SectorView(spec)

    return M.known[factionIndex][x .. ":" .. y]
end

-- What the seed would generate for a sector nobody has visited.
function M.addPredictedSector(x, y, spec)
    M.predicted[x .. ":" .. y] = spec or {}
end

function M.addPlayer(index, name)
    local values = {}
    playerValues[index] = values

    local p =
    {
        index = index,
        name = name,
        online = true,
    }
    function p:setValue(key, value) values[key] = value end
    function p:getValue(key) return values[key] end
    function p:getValues() return values end
    -- A galaxy script calling this segfaults the real server, so the mock refuses it
    -- outright: only the player agent may reach Simulation. M.asPlayerAgent(fn) marks
    -- the window in which that is legal.
    function p:invokeFunction(script, functionName, ...)
        if not M.inPlayerAgent then
            error("SIGSEGV: Player:invokeFunction is only legal from a player script, "
                  .. "not from the galaxy bridge (" .. functionName .. ")", 0)
        end

        local args = {...}
        M.simulationCalls[#M.simulationCalls + 1] = {fn = functionName, args = args}

        -- The game insists on a two-step handshake: startCommand refuses unless the
        -- simulation is already holding an analysis it ran itself for that exact
        -- mission type, and it announces the refusal only by chat message. The delay
        -- is what forces the agent to retry rather than start in one pass.
        if functionName == "startAreaAnalysis" then
            local ship = M.getShip(self.index, args[1])
            if ship then
                ship.analyzedType = nil
                ship.analysisReadyAt = clock + M.analysisDelay
                ship.analysisPendingType = args[2]
            end

        elseif functionName == "startCommand" then
            local ship = M.getShip(self.index, args[1])

            if ship and ship.analysisReadyAt and clock >= ship.analysisReadyAt then
                ship.analyzedType = ship.analysisPendingType
                ship.analysisReadyAt = nil
            end

            if ship and not ship.refuseStart and ship.analyzedType == args[2] then
                ship.availability = ShipAvailability.InBackground
            end

        elseif functionName == "recall" or functionName == "forceRecall" then
            local ship = M.getShip(self.index, args[1])
            if ship and (functionName == "forceRecall" or not ship.refuseRecall) then
                ship.availability = ShipAvailability.Available
            end

        elseif functionName == "takeYield" then
            local ship = M.getShip(self.index, args[1])
            if ship then ship.yields = 0 end
        end

        if functionName == "getNumYields" then
            local ship = M.getShip(self.index, args[1])
            return 0, (ship and ship.yields) or 0
        end

        return M.invokeResult or 0, M.invokeReturns and M.invokeReturns[functionName] or nil
    end

    -- Where the player is standing. canReceivePlayerOrder() lets a captainless craft take
    -- orders only while its owner shares its sector, so the order tests need to move this.
    p.sectorX, p.sectorY = 0, 0
    function p:getSectorCoordinates() return self.sectorX, self.sectorY end

    addCraftApi(p)
    addLedgerApi(p)

    players[index] = p

    return p
end

-- `members` is every player index in the alliance; `memberIndex` is the one whose
-- privileges are modelled and whose Player object gets an .alliance back-reference.
-- They differ whenever a test needs a second member who is not the API caller, which is
-- the case the recording check exists for.
function M.addAlliance(index, name, memberIndex, privileges, members)
    local a = {index = index, name = name, isAlliance = true}
    local roster = members or {memberIndex}

    function a:hasPrivilege(playerIndex, privilege)
        if playerIndex ~= memberIndex then return false end
        return privileges == nil or privileges[privilege] == true
    end

    function a:getMembers()
        return table.unpack(roster)
    end

    addCraftApi(a)
    addLedgerApi(a)
    M.alliances[index] = a

    for _, who in ipairs(roster) do
        if players[who] then
            players[who].alliance = a
            players[who].allianceIndex = index
        end
    end

    return a
end

-- Runs fn in the context the player agent runs in: Simulation calls are legal and
-- Player() resolves to the player the agent is attached to.
function M.asPlayerAgent(index, fn)
    if fn == nil then index, fn = 1, index end

    M.inPlayerAgent = true
    M.currentPlayer = index
    local ok, err = pcall(fn)
    M.inPlayerAgent = false
    M.currentPlayer = nil
    if not ok then error(err, 0) end
end

function M.setOffline(index) if players[index] then players[index].online = false end end
function M.setOnline(index) if players[index] then players[index].online = true end end

function M.setClock(t) clock = t end
function M.advanceClock(dt) clock = clock + dt end
function M.getClock() return clock end
function M.root() return root end

function M.reset()
    os.execute("rm -rf " .. shellQuote(root))
    os.execute("mkdir -p " .. shellQuote(root))
    serverValues = {}
    playerValues = {}
    players = {}
    ships = {}
    M.alliances = {}
    M.asyncQueue = {}
    M.simulationCalls = {}
    M.known = {}
    M.homeSectors = {}
    M.predicted = {}
    M.predictions = 0
    M.entityCalls = {}
    M.riftSectors = {}
    M.loadedSectors = nil
    M.jumpUnobstructed = true
    M.routeResult = nil
    M.commandError = nil
    M.predictionError = nil
    M.predictionRaises = nil
    M.invokeResult = nil
    M.invokeReturns = nil
    clock = 1000.0
    M.errors = {}
end

return M
