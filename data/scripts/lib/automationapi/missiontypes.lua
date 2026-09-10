-- The boundary between the API's vocabulary and the background simulation's.
--
-- Every awkward detail of the vanilla command interface is meant to be contained here:
-- mission types are UUIDs, areas are inclusive rectangles the game may silently recentre,
-- material selections are index-keyed with two different base offsets, and clampConfig is
-- not actually a method on the command classes.

package.path = package.path .. ";data/scripts/player/background/simulation/?.lua"

local Json = include("automationapi/json")
local Router = include("automationapi/router")
local Serialize = include("automationapi/serialize")

local CommandType = include("commandtype")
local CommandFactory = include("commandfactory")

local MissionTypes = {}

-- #### TYPE NAMES #### --

-- Short, stable keys for the API. The UUIDs are the game's own and are documented as
-- never changing, but they make for miserable URLs.
local keyToType =
{
    travel      = CommandType.Travel,
    scout       = CommandType.Scout,
    mine        = CommandType.Mine,
    salvage     = CommandType.Salvage,
    refine      = CommandType.Refine,
    trade       = CommandType.Trade,
    procure     = CommandType.Procure,
    sell        = CommandType.Sell,
    supply      = CommandType.Supply,
    expedition  = CommandType.Expedition,
    maintenance = CommandType.Maintenance,
    escort      = CommandType.Escort,
}

local typeToKey = {}
for key, missionType in pairs(keyToType) do typeToKey[missionType] = key end

-- Escort is attached automatically to escorting ships by the simulation; it is not
-- something a caller starts directly.
local notStartable = {escort = true}

function MissionTypes.typeOf(key)
    return keyToType[string.lower(key or "")]
end

function MissionTypes.keyOf(missionType)
    return typeToKey[missionType]
end

function MissionTypes.isStartable(key)
    return keyToType[key] ~= nil and not notStartable[key]
end

function MissionTypes.keys()
    local result = {}
    for key, _ in pairs(keyToType) do result[#result + 1] = key end
    table.sort(result)

    return result
end

-- Resolves a URL segment to a command type, or fails the request.
function MissionTypes.require(key)
    local missionType = MissionTypes.typeOf(key)
    if not missionType then
        Router.fail(404, "no_such_mission",
                    "Unknown mission type '" .. tostring(key) .. "'. See GET /missions.")
    end

    if notStartable[string.lower(key)] then
        Router.fail(422, "not_startable",
                    "'" .. key .. "' is attached automatically by the game and cannot be started directly.")
    end

    return missionType
end

-- #### COMMAND CONSTRUCTION #### --

-- Simulation.makeCommand() decorates commands with a clampConfig method the classes do
-- not define themselves (simulation.lua:52). We only need that one, reproduced here so
-- config values are clamped exactly the way the game would clamp them.
local function clampConfig(command, ownerIndex, shipName)
    local ok, configurable = pcall(function()
        return command:getConfigurableValues(ownerIndex, shipName)
    end)

    if not ok or type(configurable) ~= "table" then return end

    for name, properties in pairs(configurable) do
        local value = command.config[name]

        if properties.default ~= nil and value == nil then value = properties.default end

        if type(value) == "number" then
            if properties.from and value < properties.from then value = properties.from end
            if properties.to and value > properties.to then value = properties.to end
        end

        command.config[name] = value
    end
end

MissionTypes.clampConfig = clampConfig

function MissionTypes.make(missionType, shipName, area, config)
    local command = CommandFactory.makeCommand(missionType, shipName, area, config)
    if not command then
        Router.fail(500, "no_command", "The game did not produce a command for that type.")
    end

    command.config = config or {}

    return command
end

-- #### MATERIALS #### --

-- Mine and Salvage key their material selection from 0, Refine keys it from 1. Callers
-- of this API name materials instead, and the offset is applied here.
local function materialNames()
    local names = {}
    for i = 0, NumMaterials() - 1 do
        names[i] = Material(i).name
    end

    return names
end

MissionTypes.materialNames = materialNames

local function materialIndex(name)
    local wanted = string.lower(tostring(name))

    for index, materialName in pairs(materialNames()) do
        if string.lower(materialName) == wanted then return index end
    end

    return nil
end

-- Which config field holds a material selection, and what its first index is.
local materialFields =
{
    mine    = {field = "collected", base = 0},
    salvage = {field = "collected", base = 0},
    refine  = {field = "refined",   base = 1},
}

-- Turns {"materials": ["Iron", "Titanium"]} into the index-keyed table the command wants.
-- Omitting it selects everything, which is what the game's UI defaults to.
local function applyMaterials(key, config)
    local spec = materialFields[key]
    if not spec then return end

    local names = config.materials
    config.materials = nil

    local selection = {}

    if names == nil then
        for index, _ in pairs(materialNames()) do
            selection[index + spec.base] = true
        end
    else
        if type(names) ~= "table" then
            Router.fail(400, "bad_materials", "'materials' must be an array of material names.")
        end

        for _, name in ipairs(names) do
            local index = materialIndex(name)
            if index == nil then
                Router.fail(400, "bad_materials",
                            "Unknown material '" .. tostring(name) .. "'.",
                            {known = Json.array(MissionTypes.materialList())})
            end

            selection[index + spec.base] = true
        end
    end

    config[spec.field] = selection
end

-- Ordered by material index (Iron first), which is the order players think in.
function MissionTypes.materialList()
    local names = materialNames()

    local result = {}
    for i = 0, NumMaterials() - 1 do result[#result + 1] = names[i] end

    return result
end

-- Reverses applyMaterials so a response echoes names rather than raw indices.
function MissionTypes.describeMaterials(key, config)
    local spec = materialFields[key]
    if not spec or type(config[spec.field]) ~= "table" then return nil end

    local names = materialNames()
    local result = Json.array({})

    for index = 0, NumMaterials() - 1 do
        if config[spec.field][index + spec.base] then
            result[#result + 1] = names[index]
        end
    end

    return result
end

function MissionTypes.usesMaterials(key)
    return materialFields[key] ~= nil
end

-- #### CONFIG #### --

-- JSON nulls arrive as a sentinel table; the game expects them simply to be absent.
local function stripNulls(value)
    if type(value) ~= "table" then return value end
    if value == Json.null then return nil end

    local result = {}
    for k, v in pairs(value) do
        if v ~= Json.null then result[k] = stripNulls(v) end
    end

    return result
end

-- Builds the config table a command expects from the request body.
function MissionTypes.buildConfig(key, body)
    local config = stripNulls(body.config) or {}

    -- both of these read naturally at the top level of a request, so accept them there
    if body.escorts ~= nil then config.escorts = body.escorts end
    if body.materials ~= nil then config.materials = body.materials end
    if config.escorts == nil then config.escorts = {} end
    config.escorts = Json.array(config.escorts)

    if type(config.escorts) ~= "table" then
        Router.fail(400, "bad_escorts", "'escorts' must be an array of ship names.")
    end

    applyMaterials(key, config)

    return config
end

-- Echoes a config back the way the caller expressed it: material selections as names
-- rather than the index-keyed tables the game works in.
function MissionTypes.describeConfig(key, config)
    local spec = materialFields[key]

    local result = {}
    for name, value in pairs(config or {}) do
        if not (spec and name == spec.field) then
            result[name] = Serialize.value(value)
        end
    end

    -- an empty escort list is an empty array, not an empty object
    result.escorts = Json.array(result.escorts or {})

    local materials = MissionTypes.describeMaterials(key, config or {})
    if materials then result.materials = materials end

    return result
end

-- #### START-TIME CHECKS #### --

-- Vanilla runs a second round of validation inside command:initialize(), which only
-- startCommand reaches. Preview never gets there, so without this a preview reports
-- canStart on a mission the game will refuse - the "route too short" case is real and
-- was hit in testing. Only checks that can be answered from the area analysis belong
-- here; anything else would need the command to actually be started.
local startChecks = {}

function startChecks.travel(owner, shipName, area)
    local analysis = area.analysis
    if type(analysis) ~= "table" then return nil end

    local entry = ShipDatabaseEntry(owner.index, shipName)
    if not entry then return nil end

    local x, y = entry:getCoordinates()
    if area.lower.x == x and area.lower.y == y then
        return "The ship is already in this sector."
    end

    -- TravelCommand:initialize refuses a route of two sectors or fewer, i.e. anything
    -- the ship could reach in a single jump.
    if type(analysis.route) == "table" and #analysis.route <= 2 then
        return "This route is too short."
    end

    local values = analysis.values
    if type(values) == "table" then
        local jumpRange, canPassRifts = entry:getHyperspaceProperties()
        if jumpRange ~= values.jumpRange or canPassRifts ~= values.canPassRifts then
            return "Hyperspace properties changed since planning the route."
        end
    end

    return nil
end

-- Returns a plain error string, or nil when the game would let the mission start.
function MissionTypes.startErrors(key, owner, shipName, area)
    local check = startChecks[string.lower(key or "")]
    if not check then return nil end

    local ok, message = pcall(check, owner, shipName, area)
    if not ok then return nil end

    return message
end

-- #### AREAS #### --

local function rectangle(lowerX, lowerY, sizeX, sizeY)
    return
    {
        -- upper is inclusive, hence the minus one
        lower = {x = lowerX, y = lowerY},
        upper = {x = lowerX + sizeX - 1, y = lowerY + sizeY - 1},
    }
end

-- Accepts either an explicit rectangle or a centre, and produces the inclusive rectangle
-- the game wants at one of the sizes this command allows.
--
-- Commands whose area is fixed recentre it on the ship server-side no matter what we
-- pass, so for those the request's area is only a hint.
function MissionTypes.buildArea(command, ownerIndex, shipName, body)
    local sizes = {command:getAreaSize(ownerIndex, shipName)}
    local size = sizes[1]

    if type(size) ~= "table" then
        Router.fail(500, "no_area_size", "The game did not report an area size for this mission.")
    end

    local area = body.area

    if type(area) == "table" and area.lower and area.upper then
        return
        {
            lower = {x = math.floor(area.lower.x), y = math.floor(area.lower.y)},
            upper = {x = math.floor(area.upper.x), y = math.floor(area.upper.y)},
        }
    end

    -- a centre, or the ship's own position
    local centreX, centreY

    if type(area) == "table" and area.center then
        centreX, centreY = area.center.x, area.center.y
    elseif type(body.to) == "table" then
        centreX, centreY = body.to.x, body.to.y
    else
        local faction = Galaxy():findFaction(ownerIndex)
        centreX, centreY = faction:getShipPosition(shipName)
    end

    if type(centreX) ~= "number" or type(centreY) ~= "number" then
        Router.fail(400, "bad_area",
                    "Provide 'area' as {lower:{x,y}, upper:{x,y}} or {center:{x,y}}, or 'to' as {x,y}.")
    end

    return rectangle(math.floor(centreX) - math.floor((size.x - 1) / 2),
                     math.floor(centreY) - math.floor((size.y - 1) / 2),
                     size.x, size.y)
end

-- Every area shape this command accepts, for the catalog.
function MissionTypes.describeAreaSizes(command, ownerIndex, shipName)
    local result = Json.array({})

    for _, size in ipairs({command:getAreaSize(ownerIndex, shipName)}) do
        if type(size) == "table" then
            result[#result + 1] = {x = size.x, y = size.y}
        end
    end

    return result
end

return MissionTypes
