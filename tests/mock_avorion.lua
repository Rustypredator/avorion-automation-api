-- Minimal stand-in for the Avorion scripting environment, enough to drive the bridge
-- outside the game. Only what the mod actually touches is implemented.

local M = {}

local root = os.getenv("MOCK_ROOT") or "/tmp/avorion-mock"

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
        function e:getReconstructionValue() return ship.reconstructionValue or 0 end
        function e:getStatusMessage() return ship.status end
        function e:getTitle() return ship.title end
        function e:getIcon() return ship.icon end
        function e:getOrderInfo() return ship.orderInfo end
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
            sectorInRift = function() return false end,
            sectorLoaded = function() return true end,
        }
    end

    -- asyncf runs on a worker thread in the game; here it queues so tests decide when
    -- (and whether) the result comes back.
    _G.asyncf = function(callbackName, script, ...)
        M.asyncQueue[#M.asyncQueue + 1] = {callback = callbackName, args = {...}}
    end

    M.stubs =
    {
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

-- Overridable by tests to drive the validation paths.
M.commandError = nil
M.commandErrorArgs = nil
M.predictionError = nil
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

        AutomationApiBridge[job.callback](shipName, missionType, area, analysis, callingPlayer)
    end

    return #queued
end

local ships = {}

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
    function faction:getShipStatus(name)
        local s = M.getShip(self.index, name); return s and s.statusText
    end
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
    function p:invokeFunction(script, functionName, ...)
        local args = {...}
        M.simulationCalls[#M.simulationCalls + 1] = {fn = functionName, args = args}

        -- startCommand reports failure only by chat message; a ship marked refuseStart
        -- stands in for that, staying Available instead of going InBackground
        if functionName == "startCommand" then
            local ship = M.getShip(self.index, args[1])
            if ship and not ship.refuseStart then
                ship.availability = ShipAvailability.InBackground
            end
        end

        return M.invokeResult or 0, M.invokeReturns and M.invokeReturns[functionName] or nil
    end
    addCraftApi(p)

    players[index] = p

    return p
end

function M.addAlliance(index, name, memberIndex, privileges)
    local a = {index = index, name = name, isAlliance = true}
    function a:hasPrivilege(playerIndex, privilege)
        if playerIndex ~= memberIndex then return false end
        return privileges == nil or privileges[privilege] == true
    end
    addCraftApi(a)
    M.alliances[index] = a

    if players[memberIndex] then
        players[memberIndex].alliance = a
        players[memberIndex].allianceIndex = index
    end

    return a
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
    M.commandError = nil
    M.predictionError = nil
    M.invokeResult = nil
    M.invokeReturns = nil
    clock = 1000.0
    M.errors = {}
end

return M
