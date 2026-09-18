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
local Owner = include("automationapi/owner")
local Locations = include("automationapi/locations")
local RoutePlanner = include("automationapi/routeplanner")

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

-- #### NAMED DESTINATIONS #### --
--
-- Anywhere a ship is sent, the destination can be given three ways, exactly one at a time:
--
--   to = {x, y}               a sector
--   target = "Hub"            wherever that craft of the caller's or their alliance's is now
--                             (targetOwner = player or alliance when both have one)
--   location = "Home"         a sector from the location library
--
-- A craft or location is looked up when the request is made, so a program step naming one
-- goes wherever it is at the time the step starts.

local function trimmed(value)
    if type(value) ~= "string" then return nil end
    local name = string.match(value, "^%s*(.-)%s*$")
    return name ~= "" and name or nil
end

local function givenValue(value)
    if value == Json.null then return nil end
    return value
end

-- Which of the three a body uses: "to", "target", "location", or nil for none. More than one
-- is a caller bug worth refusing rather than guessing at.
function Routes.destinationKind(body)
    local kinds = {}
    if givenValue(body.to) ~= nil or givenValue(body.destination) ~= nil
       or givenValue(body.x) ~= nil or givenValue(body.y) ~= nil then
        kinds[#kinds + 1] = "to"
    end
    if givenValue(body.target) ~= nil then kinds[#kinds + 1] = "target" end
    if givenValue(body.location) ~= nil then kinds[#kinds + 1] = "location" end

    if #kinds > 1 then
        Router.fail(400, "conflicting_destination",
                    "Give the destination one way: 'to', 'target' or 'location', not "
                    .. table.concat(kinds, " and ") .. ".")
    end

    return kinds[1]
end

-- The craft a destination names, among the caller's own and their alliance's. Returns the
-- owner and the craft's position.
function Routes.findCraft(ctx, name, ownerKind)
    if ownerKind ~= nil and ownerKind ~= "player" and ownerKind ~= "alliance" then
        Router.fail(400, "bad_target_owner", "'targetOwner' is player or alliance.")
    end

    for _, owner in ipairs(Owner.all(ctx)) do
        if ownerKind == nil or owner.kind == ownerKind then
            local ok, owns = pcall(function() return owner.faction:ownsShip(name) end)
            if ok and owns then
                if owner.faction:getShipAvailability(name) == ShipAvailability.InBackground then
                    Router.fail(409, "target_in_background",
                                "'" .. name .. "' is out on a captain mission, so it has no "
                                .. "sector to fly to.")
                end

                local okPosition, x, y = pcall(function() return owner.faction:getShipPosition(name) end)
                if not okPosition or type(x) ~= "number" or type(y) ~= "number" then
                    Router.fail(404, "no_ship_position",
                                "The game does not report a position for '" .. name .. "'.")
                end

                return owner, x, y
            end
        end
    end

    Router.fail(404, "no_such_target",
                "Neither you nor your alliance own a craft named '" .. name .. "'.")
end

-- A location by name. The library of the faction owning the ship being sent is asked
-- first, then the caller's other one: a player's craft finds the player's own "Home"
-- before the alliance's, an alliance craft the alliance's.
function Routes.findLocation(ctx, name, shipOwner)
    local owners = {}
    if shipOwner then owners[1] = shipOwner end
    for _, owner in ipairs(Owner.all(ctx)) do
        if not shipOwner or owner.index ~= shipOwner.index then owners[#owners + 1] = owner end
    end

    for _, owner in ipairs(owners) do
        local entry = Locations.get(owner.index, name)
        if entry then return owner, entry end
    end

    Router.fail(404, "no_such_location", "No location called '" .. name .. "' in your library"
                .. (ctx.player and ctx.player.alliance and " or your alliance's" or "") .. ".")
end

-- Resolves a destination given any of the three ways. Returns x, y and a description of
-- what was named - {kind = "sector"}, {kind = "craft", name, owner} or {kind = "location",
-- name, owner} - for the response to echo, so a caller sees where a name led.
function Routes.resolveDestination(ctx, body, shipOwner)
    local kind = Routes.destinationKind(body)

    if kind == "target" then
        local name = trimmed(body.target)
        if not name then
            Router.fail(400, "no_target", "'target' is the name of the craft to fly to.")
        end
        local owner, x, y = Routes.findCraft(ctx, name, givenValue(body.targetOwner))
        return x, y, {kind = "craft", name = name, owner = Owner.describe(owner), x = x, y = y}
    end

    if kind == "location" then
        local name = trimmed(body.location)
        if not name then
            Router.fail(400, "no_location", "'location' is the name of a location in your library.")
        end
        local owner, entry = Routes.findLocation(ctx, name, shipOwner)
        return entry.x, entry.y,
               {kind = "location", name = name, owner = Owner.describe(owner), x = entry.x, y = entry.y}
    end

    local x, y = Routes.destination(body)
    return x, y, {kind = "sector", x = x, y = y}
end

-- A request body with a named destination rewritten as plain coordinates, for code further
-- down that only knows `to`. Returns the rewritten copy and the description.
function Routes.withResolvedDestination(ctx, body, shipOwner)
    local x, y, via = Routes.resolveDestination(ctx, body, shipOwner)

    local copy = {}
    for k, v in pairs(body) do copy[k] = v end
    copy.target, copy.targetOwner, copy.location = nil, nil, nil
    copy.destination, copy.x, copy.y = nil, nil, nil
    copy.to = {x = x, y = y}

    return copy, via
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

-- #### PLANNED ROUTES #### --

local PREFERENCES = {"preferGates", "preferWormholes", "fewestJumps", "avoidRifts",
                     "preferUncontrolled"}

Routes.PREFERENCES = PREFERENCES

local function flag(value)
    return value == true or value == "true" or value == "1" or value == 1
end

-- The planner preferences in a body or a query, or nil when none was given at all - which
-- is what decides between calculateJumpPath and this mod's own planner.
function Routes.preferences(source)
    if type(source) ~= "table" then return nil end

    local given = false
    local result = {}

    for _, name in ipairs(PREFERENCES) do
        if source[name] ~= nil then given = true end
        result[name] = flag(source[name])
    end

    return given and result or nil
end

-- The preferences with every one set, for callers that always use the planner.
function Routes.preferencesOrDefault(source)
    local result = Routes.preferences(source)
    if result then return result end

    result = {}
    for _, name in ipairs(PREFERENCES) do result[name] = false end
    return result
end

-- The planner's spec for a ship's search: where from, where to, how far it jumps, and the
-- preferences.
function Routes.plannerSpec(owner, from, to, range, canPassRifts, preferences)
    local spec =
    {
        owner = owner,
        from = from,
        to = to,
        range = range,
        canPassRifts = canPassRifts,
    }
    for _, name in ipairs(PREFERENCES) do spec[name] = preferences and preferences[name] or false end
    return spec
end

-- A finished planner search in the shape GET /galaxy/route answers with, so a caller can
-- treat the two planners alike: `route` includes the origin, as the engine's does.
function Routes.describePlan(result, fromX, fromY, toX, toY, jumpRange, canPassRifts, preferences)
    local body =
    {
        from = {x = fromX, y = fromY},
        to = {x = toX, y = toY},
        reachable = result.reachable == true,
        jumpRange = jumpRange or 0,
        canPassRifts = canPassRifts == true,
        planner = "automation",
        preferences = preferences,
        expansions = result.expansions or 0,
    }

    if not result.reachable then
        body.reason = result.reason
        body.route = Json.array({})
        body.hops = Json.array({})
        body.jumps = 0
        body.gates = 0
        body.distance = 0
        return body
    end

    local hops = RoutePlanner.describeHops(result.hops, {x = fromX, y = fromY})

    local route = Json.array({{x = fromX, y = fromY}})
    local described = Json.array({})
    local distance, gates, wormholes, controlled = 0, 0, 0, 0

    for index, hop in ipairs(hops) do
        route[#route + 1] = {x = hop.x, y = hop.y}
        described[index] = hop
        distance = distance + hop.distance
        if hop.kind ~= "jump" then gates = gates + 1 end
        if hop.kind == "wormhole" then wormholes = wormholes + 1 end
        if hop.controlled then controlled = controlled + 1 end
    end

    body.route = route
    body.hops = described
    -- hops of any kind, as the engine planner's `jumps` counts them
    body.jumps = #hops
    -- gates and wormholes both, as before wormholes were counted apart; `wormholes` is the
    -- share of them that were wormholes
    body.gates = gates
    body.wormholes = wormholes
    body.controlledSectors = controlled
    body.distance = distance

    return body
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
