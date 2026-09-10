-- Jump routes, and the reachability gates the game applies to travel.
--
-- calculateJumpPath is the same function the background simulation's travel analysis
-- uses, so a route reported here is the route a travel mission would actually fly. It is
-- documented as slow, and it runs on the server tick, so it is throttled per caller.
--
-- The gates below are a deliberate re-implementation of TravelCommand:isValidAreaSelection,
-- which vanilla only ever runs on the client. Without it the API happily accepts a
-- destination one jump away, spends an area analysis on it, and is then refused by
-- TravelCommand:initialize with "This route is too short." - a failure the caller can do
-- nothing useful with. See docs/api.md.

local Json = include("automationapi/json")
local Router = include("automationapi/router")
local Config = include("automationapi/config")

local Routes = {}

-- #### COORDINATES #### --

-- Sector coordinates are always integers. Anything else is a caller bug worth reporting
-- rather than quietly flooring, since a fractional coordinate usually means the caller
-- did arithmetic on a position it should have passed through untouched.
local function integer(value)
    if type(value) == "string" then value = tonumber(value) end
    if type(value) ~= "number" then return nil end
    if value ~= value or value == math.huge or value == -math.huge then return nil end
    if value ~= math.floor(value) then return nil end

    return value
end

Routes.integer = integer

-- Accepts {x, y} in a body or a pair of query parameters.
function Routes.coordinates(value, label)
    if type(value) ~= "table" then
        Router.fail(400, "bad_coordinates", "'" .. label .. "' must be {x, y}.")
    end

    local x, y = integer(value.x), integer(value.y)
    if x == nil or y == nil then
        Router.fail(400, "bad_coordinates",
                    "'" .. label .. "' needs whole-number x and y sector coordinates.")
    end

    return x, y
end

-- The destination of a movement request, written whichever way reads naturally.
function Routes.destination(body)
    local value = body.to or body.destination

    if value == nil and (body.x ~= nil or body.y ~= nil) then value = body end

    if value == nil then
        Router.fail(400, "no_destination", "Provide a destination as 'to': {x, y}.")
    end

    return Routes.coordinates(value, "to")
end

-- #### JUMP PATHS #### --

-- calculateJumpPath reads gate knowledge off a player and an alliance, and vanilla passes
-- both when the owner is a player: a player's ships may use gates the alliance found.
local function knowledgeOf(owner)
    local faction = owner.faction

    if faction.isPlayer then return faction, faction.alliance end
    if faction.isAlliance then return nil, faction end

    return nil, nil
end

-- Route calculation is documented as expensive and it runs on the server tick, so each
-- caller gets one every Config.routeCooldown seconds. Keyed by player rather than by
-- API key so extra keys buy no extra budget.
local lastRouteAt = {}

function Routes.throttle(playerIndex)
    local now = Server().unpausedRuntime
    local last = lastRouteAt[playerIndex]

    if last and now - last < Config.routeCooldown then
        Router.fail(429, "route_busy",
                    string.format("Route calculation is limited to one every %g seconds.",
                                  Config.routeCooldown))
    end

    lastRouteAt[playerIndex] = now
end

-- Returns the route as a plain array of {x, y}, or nil when there is no way through.
function Routes.calculate(owner, fromX, fromY, toX, toY, jumpRange, canPassRifts)
    local player, alliance = knowledgeOf(owner)

    local ok, raw = pcall(function()
        return calculateJumpPath(player, alliance, vec2(fromX, fromY), vec2(toX, toY),
                                 jumpRange, canPassRifts == true)
    end)

    if not ok or type(raw) ~= "table" then return nil end

    local route = {}
    for _, sector in ipairs(raw) do
        route[#route + 1] = {x = sector.x, y = sector.y}
    end

    if #route == 0 then return nil end

    return route
end

-- Hop count, straight-line distance flown and the sector list, in the shape the rest of
-- the API reports positions in.
function Routes.describe(route)
    local sectors = Json.array({})
    local distance = 0

    for index, sector in ipairs(route) do
        sectors[index] = {x = sector.x, y = sector.y}

        if index > 1 then
            local dx = sector.x - route[index - 1].x
            local dy = sector.y - route[index - 1].y
            distance = distance + math.sqrt(dx * dx + dy * dy)
        end
    end

    return
    {
        sectors = sectors,
        -- a route of n sectors is n-1 jumps; the origin is included in the list
        jumps = math.max(0, #route - 1),
        distance = distance,
    }
end

-- #### TRAVEL GATES #### --

-- Reproduces TravelCommand:isValidAreaSelection, which vanilla runs on the client only.
-- Every rejection here is a destination the game itself would refuse, so failing early
-- costs the caller nothing but saves an area analysis and returns a reason it can act on.
function Routes.checkTravelDestination(owner, shipName, toX, toY)
    local entry = ShipDatabaseEntry(owner.index, shipName)
    if not entry then
        Router.fail(404, "no_ship_data", "No database entry for '" .. shipName .. "'.")
    end

    local x, y = entry:getCoordinates()

    if x == toX and y == toY then
        Router.fail(422, "already_there",
                    string.format("'%s' is already in (%d:%d).", shipName, toX, toY))
    end

    local reach = entry:getHyperspaceProperties()
    local dx, dy = toX - x, toY - y
    local straightLine = math.sqrt(dx * dx + dy * dy)

    local unobstructed = false
    local ok, result = pcall(function()
        return Galaxy():jumpRouteUnobstructed(x, y, toX, toY)
    end)
    if ok then unobstructed = result == true end

    if straightLine <= (reach or 0) and unobstructed then
        Router.fail(422, "destination_too_close",
                    string.format("(%d:%d) is within '%s' jump range of %.4g, so the game "
                                  .. "refuses a travel mission there. Send an in-sector "
                                  .. "jump order instead, or pick a further destination.",
                                  toX, toY, shipName, reach or 0))
    end

    -- A gate or wormhole out of the ship's current sector makes the destination one hop
    -- away, which the game refuses for the same reason.
    local view = owner.faction:getKnownSector(x, y)
    if not view and owner.faction.isPlayer and owner.faction.alliance then
        view = owner.faction.alliance:getKnownSector(x, y)
    end

    if view then
        for _, group in ipairs({"getGateDestinations", "getWormHoleDestinations"}) do
            local found, destinations = pcall(function() return {view[group](view)} end)

            if found then
                for _, coords in ipairs(destinations) do
                    if coords.x == toX and coords.y == toY then
                        Router.fail(422, "destination_too_close",
                                    string.format("(%d:%d) is directly connected to "
                                                  .. "(%d:%d) by a gate or wormhole, so "
                                                  .. "the game refuses a travel mission "
                                                  .. "there.", toX, toY, x, y))
                    end
                end
            end
        end
    end

    return {x = x, y = y, range = reach or 0, distance = straightLine}
end

return Routes
