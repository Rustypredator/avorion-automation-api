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
    -- Values follow the documented member order. The mod never hardcodes these; it
    -- reverse-looks-up names from the tables, which is exactly what these exercise.
    _G.EntityType = {None = 0, Ship = 1, Drone = 2, Station = 3, Turret = 4, Asteroid = 5,
                     Wreckage = 6, Anomaly = 7, Loot = 8, WormHole = 9, Torpedo = 10,
                     Fighter = 11, Container = 12, Unknown = 13, Other = 14}
    _G.ShipAvailability = {Available = 0, Destroyed = 1, InBackground = 2}
    _G.CrewProfessionType = {None = 0, Engine = 1, Gunner = 2, Miner = 3, Repair = 4,
                             Pilot = 5, Security = 6, Attacker = 7, Number = 8}
    _G.MalusReason = {None = 0, Reconstruction = 1, Boarding = 2, RiftTeleport = 3}
    _G.WeaponCategory = {Armed = 0, Mining = 1, Salvaging = 2, Heal = 3}
    _G.AlliancePrivilege = {ManageShips = 15, ManageStations = 14, SpendResources = 13}

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

    if players[memberIndex] then
        players[memberIndex].alliance = a
        players[memberIndex].allianceIndex = index
    end

    return a
end

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
    clock = 1000.0
    M.errors = {}
end

return M
