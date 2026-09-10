-- Sector knowledge: what the player has seen, and what the galaxy seed says is there.
--
-- Two sources, deliberately kept apart in the responses:
--
--   known      SectorView rows off the player or alliance record. Authoritative, but only
--              for sectors somebody has actually been to or scouted.
--   predicted  Recomputed from the galaxy seed with SectorSpecifics, exactly the way the
--              generator would when the sector is first loaded. Costs no sector load and
--              works for sectors nobody has visited - which is what makes a galaxy-wide
--              station search affordable at all.
--
-- Prediction is not a guess: it runs the generator's own decision layer. What it cannot
-- know is anything that happened after generation - stations built or destroyed by
-- players, ships that moved, resources already mined.

package.path = package.path .. ";data/scripts/?.lua"

local Json = include("automationapi/json")
local Serialize = include("automationapi/serialize")

local SectorSpecifics = include("sectorspecifics")
local GatesMap = include("gatesmap")

-- defines the Balancing_* globals used below
include("galaxy")

local Sectors = {}

-- A SectorView read can raise for a row the engine considers half-written; one bad field
-- should cost that field, not the request.
local function safe(fn, default)
    local ok, value = pcall(fn)
    if not ok then return default end
    if value == nil then return default end

    return value
end

-- #### SHARED GENERATOR STATE #### --

-- One instance, reused for every prediction. SectorSpecifics:determineContent lazily
-- builds a PassageMap (200 rifts into a quad tree) and a FactionsMap (1750 civilisation
-- dots) and caches them on the instance - so a fresh instance per sector would rebuild
-- both every time and make a scan hundreds of times more expensive than it needs to be.
-- The first call through here pays for both; every later one is cheap.
local specifics
local gatesMap

local function getSpecifics()
    if specifics then return specifics end

    local ok, made = pcall(function() return SectorSpecifics() end)
    if ok then specifics = made end

    return specifics
end

local function getGatesMap()
    if gatesMap then return gatesMap end

    local ok, made = pcall(function() return GatesMap(GameSeed()) end)
    if ok then gatesMap = made end

    return gatesMap
end

-- The cheap pre-filter: three hashes, no allocation, no maps. Only about 3% of sectors
-- hold regular content, and only regular sectors hold stations, so this is what keeps a
-- wide scan inside a server tick budget.
--
-- It has to be called off an instance. sectorspecifics.lua returns `{new = new}` with a
-- __call metamethod, NOT the class table, so the module has no determineFastContent on it
-- at all - the static function is only reachable through an instance's __index. Calling
-- it on the module silently yields nil, and since this is the filter that decides whether
-- a sector is worth looking at, every sector in the galaxy comes back empty. Vanilla only
-- ever calls it on an instance, which is why nothing in the game trips over this.
function Sectors.mayHaveContent(x, y)
    local specs = getSpecifics()
    if not specs then return false, false end

    -- called with '.', not ':' - it takes no self, exactly as vanilla calls it
    local ok, regular, offgrid = pcall(function()
        return specs.determineFastContent(x, y, GameSeed())
    end)

    if not ok then return false, false end

    return regular == true, offgrid == true
end

-- #### BALANCING #### --

local function materialNamesByIndex()
    local names = {}
    for i = 0, NumMaterials() - 1 do
        names[i] = safe(function() return Material(i).name end, tostring(i))
    end

    return names
end

-- Everything the balancing curves say about a position, without touching the sector.
-- This is the part a mining or trading planner actually wants: which materials can be
-- found here at all, and how dangerous the neighbourhood is.
function Sectors.balancing(x, y)
    local names = materialNamesByIndex()

    local materials = {}
    local probabilities = safe(function() return Balancing_GetMaterialProbability(x, y) end, {})

    for index, probability in pairs(probabilities) do
        local name = names[index]
        if name then materials[name] = Serialize.number(probability, 0) end
    end

    local highest = safe(function() return Balancing_GetHighestAvailableMaterial(x, y) end)

    return
    {
        distanceToCore = Serialize.number(math.sqrt(x * x + y * y), 0),
        techLevel = Serialize.number(safe(function() return Balancing_GetTechLevel(x, y) end), 0),
        richness = Serialize.number(safe(function() return Balancing_GetSectorRichnessFactor(x, y) end), 0),
        pirateLevel = Serialize.number(safe(function() return Balancing_GetPirateLevel(x, y) end), 0),
        highestMaterial = highest and names[highest] or nil,
        materials = materials,
        -- inside the barrier means Avorion territory and no ordinary hyperspace exit
        insideBarrier = safe(function() return Balancing_InsideRing(x, y) end, false) == true,
        inRift = safe(function() return Galaxy():sectorInRift(x, y) end, false) == true,
    }
end

-- #### KNOWN SECTORS #### --

local function coordinateList(view, getter)
    local result = Json.array({})

    local ok, values = pcall(function() return {view[getter](view)} end)
    if not ok then return result end

    for _, coords in ipairs(values) do
        result[#result + 1] = Serialize.vec2(coords.x, coords.y)
    end

    return result
end

-- Station titles are NamedFormats carrying their arguments ("${material} ${good} Factory").
-- Both forms are returned: `name` is what a search matches on, `title` keeps the template
-- and arguments for a caller that wants to pick them apart.
local function stationTitles(view)
    local result = Json.array({})

    local ok, titles = pcall(function() return {view:getStationTitles()} end)
    if not ok then return result end

    for _, title in ipairs(titles) do
        result[#result + 1] =
        {
            name = Serialize.formatText(title),
            title = Serialize.format(title),
        }
    end

    return result
end

Sectors.stationTitles = stationTitles

function Sectors.summary(view)
    local x, y = view:getCoordinates()

    return
    {
        coordinates = Serialize.vec2(x, y),
        name = Serialize.string(safe(function() return view.name end, "")),
        visited = safe(function() return view.visited end, false) == true,
        hasContent = safe(function() return view.hasContent end, false) == true,
        factionIndex = Serialize.number(safe(function() return view.factionIndex end), 0),
        numStations = Serialize.number(safe(function() return view.numStations end), 0),
        numShips = Serialize.number(safe(function() return view.numShips end), 0),
        numAsteroids = Serialize.number(safe(function() return view.numAsteroids end), 0),
        numWrecks = Serialize.number(safe(function() return view.numWrecks end), 0),
        influence = Serialize.number(safe(function() return view.influence end), 0),
        -- server runtime at which the knowledge was recorded, for `since` filtering
        timeStamp = Serialize.number(safe(function() return view.timeStamp end), 0),
        deathLocation = safe(function() return view.deathLocation end, false) == true,
        tagged = safe(function() return view.manuallyTagged end, false) == true,
    }
end

function Sectors.detail(view)
    local result = Sectors.summary(view)
    local x, y = view:getCoordinates()

    result.stations = stationTitles(view)
    result.gateDestinations = coordinateList(view, "getGateDestinations")
    result.wormHoleDestinations = coordinateList(view, "getWormHoleDestinations")

    result.note = Serialize.format(safe(function() return view.note end))
    result.customEntries = Serialize.value(safe(function() return view:getCustomEntries() end, {}))

    -- table<factionIndex, count>; JSON has no integer keys, so these come back as objects
    -- keyed by the faction index as a string
    result.stationsByFaction = Serialize.value(safe(function() return view:getStationsByFaction() end, {}))
    result.shipsByFaction = Serialize.value(safe(function() return view:getShipsByFaction() end, {}))

    result.balancing = Sectors.balancing(x, y)

    return result
end

-- #### PREDICTED SECTORS #### --

-- Recomputes a sector from the galaxy seed. Returns nil plus a reason if the generator
-- refused, which mostly means the coordinates are outside the galaxy.
function Sectors.predicted(x, y)
    local specs = getSpecifics()
    if not specs then return nil, "the sector generator is unavailable" end

    local ok, err = pcall(function() specs:initialize(x, y, GameSeed()) end)
    if not ok then return nil, tostring(err) end

    local hasContent = (specs.regular == true or specs.offgrid == true)

    local result =
    {
        coordinates = Serialize.vec2(x, y),
        name = Serialize.string(specs.name, x .. " : " .. y),
        -- regular sectors are the ones with stations; offgrid ones hold everything else
        regular = specs.regular == true,
        offgrid = specs.offgrid == true,
        -- blocked means a rift sits on the sector and nothing is generated there
        blocked = specs.blocked == true,
        hasContent = hasContent,
        gates = specs.gates == true,
        ancientGates = specs.ancientGates == true,
        dustyness = Serialize.number(specs.dustyness, 0),
        factionIndex = Serialize.number(specs.factionIndex, 0),
        centralArea = specs.centralArea == true,
        template = Serialize.string(safe(function() return specs:getScript() end, ""), ""),
        stations = Json.array({}),
        gateDestinations = Json.array({}),
        balancing = Sectors.balancing(x, y),
    }

    if not hasContent or not specs.generationTemplate then return result end

    local view = SectorView()

    local filled = pcall(function()
        specs:fillSectorView(view, getGatesMap(), true)
    end)

    if not filled then
        result.contentUnavailable = true
        return result
    end

    result.stations = stationTitles(view)
    result.gateDestinations = coordinateList(view, "getGateDestinations")
    result.numStations = Serialize.number(safe(function() return view.numStations end), 0)
    result.numShips = Serialize.number(safe(function() return view.numShips end), 0)
    result.numAsteroids = Serialize.number(safe(function() return view.numAsteroids end), 0)
    result.numWrecks = Serialize.number(safe(function() return view.numWrecks end), 0)
    result.influence = Serialize.number(safe(function() return view.influence end), 0)

    return result
end

-- Only what a search needs, so the scan does not build a full response per sector.
-- Returns the station list plus the couple of scalars a search result carries; the
-- generator instance itself is deliberately not returned, because it is shared and the
-- next call overwrites it.
function Sectors.predictedStations(x, y)
    local regular = Sectors.mayHaveContent(x, y)
    if not regular then return nil end

    local specs = getSpecifics()
    if not specs then return nil end

    local ok = pcall(function() specs:initialize(x, y, GameSeed()) end)
    if not ok then return nil end

    -- determineFastContent's answer is a tendency; determineContent, which initialize
    -- runs, is the real one and can flip it either way
    if specs.regular ~= true or not specs.generationTemplate then return nil end

    local view = SectorView()
    local filled = pcall(function()
        specs:fillSectorView(view, getGatesMap(), true)
    end)

    if not filled then return nil end

    return stationTitles(view),
    {
        name = Serialize.string(specs.name, x .. " : " .. y),
        factionIndex = Serialize.number(specs.factionIndex, 0),
        centralArea = specs.centralArea == true,
        template = Serialize.string(specs:getScript(), ""),
    }
end

-- #### GALAXY SHAPE #### --

function Sectors.galaxy()
    local names = materialNamesByIndex()
    local dimensions = safe(function() return Balancing_GetDimensions() end, 1000)

    local belts = {}
    for i = 0, NumMaterials() - 1 do
        local radius = safe(function() return Balancing_GetMaterialBeltRadius(i) end)
        if radius then
            -- the curves work in a 0..1 fraction of the galaxy radius; sectors are more
            -- useful to a caller that thinks in coordinates
            belts[names[i]] = Serialize.number(radius * (dimensions / 2), 0)
        end
    end

    return
    {
        dimensions = Serialize.number(dimensions, 0),
        bounds =
        {
            min = Serialize.number(safe(function() return Balancing_GetMinCoordinates() end), 0),
            max = Serialize.number(safe(function() return Balancing_GetMaxCoordinates() end), 0),
        },
        barrier =
        {
            min = Serialize.number(safe(function() return Balancing_GetBlockRingMin() end), 0),
            max = Serialize.number(safe(function() return Balancing_GetBlockRingMax() end), 0),
        },
        materialBelts = belts,
        materials = Json.array((function()
            local list = {}
            for i = 0, NumMaterials() - 1 do list[#list + 1] = names[i] end
            return list
        end)()),
    }
end

return Sectors
