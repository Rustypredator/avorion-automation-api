-- The location library: named sectors a faction keeps, so a destination can be picked by
-- name instead of typed in as coordinates. "Home", "Iron field", "Trade hub".
--
-- Where things live, and why:
--
--   * Libraries are Server values, one JSON document per owning faction, for the reasons the
--     mission library and programs are: the galaxy bridge reads them with nobody logged in,
--     they survive restarts, and an alliance's library is one document every member shares.
--
--   * A player sees their own library and their alliance's. Any alliance member may add to
--     or change the alliance's: a location is a bookmark, and orders a member could not give
--     are refused where they are given, not here.
--
--   * Program steps name locations rather than copying coordinates, so moving a location
--     moves every program flying there from its next start. The library has to know who
--     uses what: deleting a location a program still names is refused, and renaming one
--     renames it in those programs. programs.lua answers both through the hooks below,
--     which keeps this module free of a dependency on it. Only the owning faction's own
--     programs are tracked - a player's program naming an alliance location is not, and
--     finds out at its next start that the location is gone.
--
-- The store lives here rather than in handlers/locations.lua because routes.lua resolves
-- destinations through it, and the handlers already include routes.lua.

local Json = include("automationapi/json")
local Router = include("automationapi/router")
local Config = include("automationapi/config")

local Locations = {}

-- The longest name a location may have. Names go into steps, logs and paths.
Locations.MAX_NAME = 48
Locations.MAX_NOTE = 200

-- Set by programs.lua. usersOf(index, name) lists the craft whose programs name the
-- location; renamed(index, old, new) points those programs at the new name.
Locations.usersOf = function() return {} end
Locations.renamed = function() end

-- A trimmed, non-empty name of sensible length, or nil.
function Locations.cleanName(value)
    if type(value) ~= "string" then return nil end
    local name = string.match(value, "^%s*(.-)%s*$")
    if name == "" or #name > Locations.MAX_NAME then return nil end
    return name
end

-- #### STORE #### --

local cache = {}

local function valueKey(index) return Config.locationValuePrefix .. tostring(index) end

function Locations.load(index)
    local raw = Server():getValue(valueKey(index))

    local cached = cache[index]
    if cached and cached.raw == raw then return cached.data end

    local data
    if type(raw) == "string" and raw ~= "" then
        local decoded = Json.decode(raw)
        if type(decoded) == "table" and type(decoded.locations) == "table" then data = decoded end
    end

    data = data or {locations = {}}
    cache[index] = {raw = raw, data = data}

    return data
end

function Locations.save(index, data)
    local raw
    if next(data.locations) ~= nil then
        local encoded, err = Json.encode({version = 1, locations = data.locations})
        if not encoded then
            Router.fail(500, "encoding_failed", "Could not store the locations: " .. tostring(err))
        end
        raw = encoded
    end

    Server():setValue(valueKey(index), raw)
    cache[index] = {raw = raw, data = data}
end

-- The stored entry {x, y, note, revision, updatedBy, updatedAt} for a name, or nil.
function Locations.get(index, name)
    return Locations.load(index).locations[name]
end

function Locations.count(index)
    local n = 0
    for _ in pairs(Locations.load(index).locations) do n = n + 1 end
    return n
end

-- For tests: forget in-memory state, as a server restart would.
function Locations.resetState()
    cache = {}
end

return Locations
