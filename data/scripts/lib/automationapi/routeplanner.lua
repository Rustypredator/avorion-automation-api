-- A route planner with preferences, and the boss-farming loop picker.
--
-- calculateJumpPath is the game's pathfinder and the right answer when all a caller wants
-- is the shortest way there. It takes no preferences, though: it cannot be told to favour
-- gates, to keep a rift-capable ship out of rifts, or to stay out of faction territory. So
-- this is a search of its own, over the same facts the engine uses - jump range, rift
-- geometry, known gates and wormholes - weighted by what the caller asked for.
--
-- It is a weighted A*. Neighbours are not every sector within jump range, which at a late
-- game range of twenty is well over a thousand per step, but a fixed set of directions at
-- full and two-thirds range plus every known gate and wormhole out of the sector. That
-- keeps each expansion's cost independent of range, and costs little in route quality: a
-- jump rarely wants to be shorter than it has to be.
--
-- Everything here is plain data in and out; the engine calls are all behind pcall, since
-- a sector the engine refuses to describe should cost that sector, not the request.

local Config = include("automationapi/config")
local Sectors = include("automationapi/sectors")

local Planner = {}

local HEURISTIC_WEIGHT = 1.25

-- A jump costs 1. A gate costs more than that by default, because flying to it takes
-- longer than a jump, so it is only taken when it saves jumps; asking for gates makes it
-- cheap instead.
local GATE_COST = 1.5
local GATE_COST_PREFERRED = 0.35

-- Added to any hop that lands in faction territory when the caller prefers otherwise. One
-- extra jump's worth: a detour of one jump that avoids one controlled sector breaks even.
local CONTROLLED_PENALTY = 1.0

-- The two rings vanilla spawns a boss in after enough jumps into empty space. Bounds are
-- exclusive, exactly as player/story/spawnrandombosses.lua compares them.
Planner.bossRings =
{
    ai = {min = 240, max = 340},
    swoks = {min = 350, max = 430},
}

-- #### ENGINE FACTS #### --

local function keyOf(x, y) return x .. ":" .. y end

local function distance(ax, ay, bx, by)
    local dx, dy = bx - ax, by - ay
    return math.sqrt(dx * dx + dy * dy)
end

local function bounds()
    local okMin, min = pcall(function() return Balancing_GetMinCoordinates() end)
    local okMax, max = pcall(function() return Balancing_GetMaxCoordinates() end)

    return okMin and min or -499, okMax and max or 500
end

local function insideBarrier(x, y)
    local ok, inside = pcall(function() return Balancing_InsideRing(x, y) end)
    return ok and inside == true
end

local function inRift(x, y)
    local ok, result = pcall(function() return Galaxy():sectorInRift(x, y) end)
    return ok and result == true
end

local function unobstructed(ax, ay, bx, by)
    local ok, result = pcall(function() return Galaxy():jumpRouteUnobstructed(ax, ay, bx, by) end)
    return ok and result == true
end

local function controlled(x, y)
    local ok, faction = pcall(function() return Galaxy():getControllingFaction(x, y) end)
    return ok and faction ~= nil
end

-- A player's ships may use what their alliance found, as calculateJumpPath allows.
local function knownViews(owner, x, y)
    local views = {}
    local faction = owner.faction

    local ok, view = pcall(function() return faction:getKnownSector(x, y) end)
    if ok and view then views[#views + 1] = view end

    if faction.isPlayer and faction.alliance then
        local okAlliance, allianceView = pcall(function()
            return faction.alliance:getKnownSector(x, y)
        end)
        if okAlliance and allianceView then views[#views + 1] = allianceView end
    end

    return views
end

local function connections(owner, x, y)
    local result = {}

    for _, view in ipairs(knownViews(owner, x, y)) do
        for kind, getter in pairs({gate = "getGateDestinations",
                                   wormhole = "getWormHoleDestinations"}) do
            local ok, destinations = pcall(function() return {view[getter](view)} end)
            if ok then
                for _, coords in ipairs(destinations) do
                    result[#result + 1] = {x = coords.x, y = coords.y, kind = kind}
                end
            end
        end
    end

    return result
end

-- #### NEIGHBOURS #### --

local offsetCache = {}

-- Directions at full and two-thirds range, pulled in until each lies inside the range and
-- deduplicated - at short range several directions round onto the same sector.
local function offsetsFor(range)
    local directions = Config.routePlanDirections
    local key = string.format("%.3f/%d", range, directions)
    if offsetCache[key] then return offsetCache[key] end

    local offsets, seen = {}, {}

    for _, fraction in ipairs({1, 0.66}) do
        local radius = math.max(1, range * fraction)

        for step = 0, directions - 1 do
            local angle = (step / directions) * 2 * math.pi
            local dx = math.floor(math.cos(angle) * radius + 0.5)
            local dy = math.floor(math.sin(angle) * radius + 0.5)

            while dx * dx + dy * dy > range * range do
                if math.abs(dx) >= math.abs(dy) then
                    dx = dx - (dx > 0 and 1 or -1)
                else
                    dy = dy - (dy > 0 and 1 or -1)
                end
            end

            local id = keyOf(dx, dy)
            if (dx ~= 0 or dy ~= 0) and not seen[id] then
                seen[id] = true
                offsets[#offsets + 1] = {dx, dy}
            end
        end
    end

    offsetCache[key] = offsets
    return offsets
end

-- #### PRIORITY QUEUE #### --

local function push(heap, node)
    heap[#heap + 1] = node
    local i = #heap

    while i > 1 do
        local parent = math.floor(i / 2)
        if heap[parent].f <= heap[i].f then break end
        heap[parent], heap[i] = heap[i], heap[parent]
        i = parent
    end
end

local function pop(heap)
    local top = heap[1]
    local last = table.remove(heap)

    if #heap > 0 then
        heap[1] = last
        local i = 1

        while true do
            local left, right = i * 2, i * 2 + 1
            local smallest = i

            if left <= #heap and heap[left].f < heap[smallest].f then smallest = left end
            if right <= #heap and heap[right].f < heap[smallest].f then smallest = right end
            if smallest == i then break end

            heap[smallest], heap[i] = heap[i], heap[smallest]
            i = smallest
        end
    end

    return top
end

-- #### SEARCH #### --

-- Whether a hyperspace jump from a to b is one the planner may take. The ship re-checks
-- every jump against the engine when the route is dispatched, so a disagreement here
-- costs a refused dispatch rather than a stranded ship.
local function jumpAllowed(search, ax, ay, bx, by)
    if bx < search.minCoord or bx > search.maxCoord
       or by < search.minCoord or by > search.maxCoord then
        return false
    end

    local respectRifts = not search.canPassRifts or search.avoidRifts
    if not respectRifts then return true end

    if inRift(bx, by) then return false end
    if insideBarrier(ax, ay) ~= insideBarrier(bx, by) then return false end

    return unobstructed(ax, ay, bx, by)
end

local function landingCost(search, x, y)
    if not search.preferUncontrolled then return 0 end

    local key = keyOf(x, y)
    local cached = search.controlled[key]
    if cached == nil then
        cached = controlled(x, y)
        search.controlled[key] = cached
    end

    return cached and CONTROLLED_PENALTY or 0
end

local function heuristic(search, x, y)
    return distance(x, y, search.to.x, search.to.y) / search.range * HEURISTIC_WEIGHT
end

-- Starts a search. Nothing is expanded until the first step().
--
--   spec = {owner, from = {x, y}, to = {x, y}, range, canPassRifts,
--           preferGates, avoidRifts, preferUncontrolled}
function Planner.start(spec)
    local minCoord, maxCoord = bounds()

    local search =
    {
        owner = spec.owner,
        from = {x = spec.from.x, y = spec.from.y},
        to = {x = spec.to.x, y = spec.to.y},
        range = math.max(1, tonumber(spec.range) or 1),
        canPassRifts = spec.canPassRifts == true,
        preferGates = spec.preferGates == true,
        avoidRifts = spec.avoidRifts == true,
        preferUncontrolled = spec.preferUncontrolled == true,
        minCoord = minCoord,
        maxCoord = maxCoord,

        open = {},
        best = {},
        closed = {},
        controlled = {},
        expansions = 0,
        done = false,
    }

    local startKey = keyOf(search.from.x, search.from.y)
    search.best[startKey] = {g = 0, x = search.from.x, y = search.from.y}
    push(search.open, {key = startKey, x = search.from.x, y = search.from.y, g = 0,
                       f = heuristic(search, search.from.x, search.from.y)})

    -- Both of these can never be planned through, and finding that out by exhausting the
    -- search would spend the whole budget - most of a minute of ticks - to say so.
    if not search.canPassRifts or search.avoidRifts then
        if inRift(search.to.x, search.to.y) then
            search.done = true
            search.result = {reachable = false, reason = "destination_in_rift", expansions = 0}
        elseif insideBarrier(search.from.x, search.from.y)
               ~= insideBarrier(search.to.x, search.to.y) then
            search.done = true
            search.result = {reachable = false, reason = "barrier", expansions = 0}
        end
    end

    return search
end

local function finish(search, goalKey)
    local hops = {}
    local key = goalKey

    while key do
        local node = search.best[key]
        if not node.parent then break end

        table.insert(hops, 1, {x = node.x, y = node.y, kind = node.kind})
        key = node.parent
    end

    search.done = true
    search.result =
    {
        reachable = true,
        hops = hops,
        cost = search.best[goalKey].g,
        expansions = search.expansions,
    }
end

local function consider(search, current, x, y, kind, cost)
    local key = keyOf(x, y)
    if search.closed[key] then return end

    local g = current.g + cost + landingCost(search, x, y)
    local known = search.best[key]
    if known and known.g <= g then return end

    search.best[key] = {g = g, x = x, y = y, parent = current.key, kind = kind}
    push(search.open, {key = key, x = x, y = y, g = g, f = g + heuristic(search, x, y)})
end

-- Spends up to `budget` steps. Returns true once search.result is set.
function Planner.step(search, budget)
    if search.done then return true end

    local offsets = offsetsFor(search.range)
    local goalKey = keyOf(search.to.x, search.to.y)

    while budget > 0 do
        local current = pop(search.open)

        if not current then
            search.done = true
            search.result = {reachable = false, reason = "no_route",
                             expansions = search.expansions}
            return true
        end

        -- stale queue entries: a cheaper way to this sector was found after it was queued
        if not search.closed[current.key] and search.best[current.key].g >= current.g then
            if current.key == goalKey then
                finish(search, goalKey)
                return true
            end

            search.closed[current.key] = true
            search.expansions = search.expansions + 1
            budget = budget - 1

            if search.expansions > Config.routePlanMaxExpansions then
                search.done = true
                search.result = {reachable = false, reason = "search_limit",
                                 expansions = search.expansions}
                return true
            end

            local x, y = current.x, current.y

            -- the destination itself, whenever it is in range: the sampled directions
            -- almost never land on it exactly
            if distance(x, y, search.to.x, search.to.y) <= search.range then
                budget = budget - 1
                if jumpAllowed(search, x, y, search.to.x, search.to.y) then
                    consider(search, current, search.to.x, search.to.y, "jump", 1)
                end
            end

            for _, offset in ipairs(offsets) do
                budget = budget - 1
                local nx, ny = x + offset[1], y + offset[2]

                if not search.closed[keyOf(nx, ny)] and jumpAllowed(search, x, y, nx, ny) then
                    consider(search, current, nx, ny, "jump", 1)
                end
            end

            for _, link in ipairs(connections(search.owner, x, y)) do
                budget = budget - 1
                consider(search, current, link.x, link.y, link.kind,
                         search.preferGates and GATE_COST_PREFERRED or GATE_COST)
            end
        end
    end

    return false
end

-- Fills in what a caller wants to know about each hop. Only run over the finished route,
-- so a search that never needed faction lookups does not pay for them here either.
function Planner.describeHops(hops, from)
    local described = {}
    local px, py = from.x, from.y

    for index, hop in ipairs(hops) do
        described[index] =
        {
            x = hop.x, y = hop.y, kind = hop.kind,
            distance = distance(px, py, hop.x, hop.y),
            controlled = controlled(hop.x, hop.y),
            rift = inRift(hop.x, hop.y),
        }
        px, py = hop.x, hop.y
    end

    return described
end

-- #### RUNNING ACROSS TICKS #### --

-- Searches waiting for their next slice. Each request gets its own, and the per-tick
-- budget is shared between them so two at once cannot take twice the tick.
local jobs = {}

local function now()
    local ok, runtime = pcall(function() return Server().unpausedRuntime end)
    return ok and runtime or 0
end

-- Plans in the background. onDone(result) is called on the bridge's tick once the search
-- ends; an error inside it answers the request with a 500 through `complete`.
function Planner.run(spec, onDone, complete)
    jobs[#jobs + 1] =
    {
        search = Planner.start(spec),
        onDone = onDone,
        complete = complete,
        -- a little inside the request timeout, so a slow search answers with a reason
        -- instead of the transport's bare 504
        deadline = now() + math.max(1, Config.requestTimeout - 2),
    }
end

function Planner.tick()
    if #jobs == 0 then return end

    local budget = math.max(200, math.floor(Config.routePlanStepsPerTick / #jobs))
    local remaining = {}

    for _, job in ipairs(jobs) do
        local ok, done = pcall(Planner.step, job.search, budget)

        if ok and not done and now() >= job.deadline then
            job.search.result = {reachable = false, reason = "timeout",
                                 expansions = job.search.expansions}
            done = true
        end

        if not ok then
            job.complete(500, {error = {code = "route_planning_failed", message = tostring(done)}})
        elseif done then
            local handled, err = pcall(job.onDone, job.search.result)

            if not handled then
                if type(err) == "table" and err.status then
                    job.complete(err.status, {error = {code = err.code, message = err.message,
                                                       details = err.details}})
                else
                    job.complete(500, {error = {code = "internal_error", message = tostring(err)}})
                end
            end
        else
            remaining[#remaining + 1] = job
        end
    end

    jobs = remaining
end

-- #### BOSS FARMING #### --

local function ringOf(x, y)
    local d = distance(0, 0, x, y)

    for name, ring in pairs(Planner.bossRings) do
        if d > ring.min and d < ring.max then return name end
    end

    return nil
end

Planner.ringOf = ringOf

-- The ring a farm should use: the one asked for, or with "auto" the one the ship is in,
-- or failing that the nearer of the two.
function Planner.pickRing(boss, x, y)
    if Planner.bossRings[boss] then return boss end

    local inside = ringOf(x, y)
    if inside then return inside end

    local d = distance(0, 0, x, y)
    local best, bestGap

    for name, ring in pairs(Planner.bossRings) do
        local gap = math.min(math.abs(d - ring.min), math.abs(d - ring.max))
        if not bestGap or gap < bestGap then best, bestGap = name, gap end
    end

    return best
end

-- The sectors around (cx, cy) nearest first, out to `radius`.
local function spiral(cx, cy, radius, visit)
    if visit(cx, cy) then return true end

    for r = 1, radius do
        for dx = -r, r do
            if visit(cx + dx, cy - r) or visit(cx + dx, cy + r) then return true end
        end
        for dy = -r + 1, r - 1 do
            if visit(cx - r, cy + dy) or visit(cx + r, cy + dy) then return true end
        end
    end

    return false
end

-- A pair of empty sectors in a boss ring that a ship can jump between for ever. Two is
-- enough: vanilla counts consecutive jumps into empty space, not distinct sectors, so
-- flying back and forth counts every jump.
--
-- Returns {ring, a = {x, y}, b = {x, y}}, or nil and a reason.
function Planner.farmLoop(x, y, range, canPassRifts, boss)
    local ringName = Planner.pickRing(boss, x, y)
    local ring = Planner.bossRings[ringName]

    -- Start from the ship when it is already in the ring, else from the point on the ring
    -- straight out from (or in towards) it, which is the nearest way there.
    local ax, ay = x, y
    if ringOf(x, y) ~= ringName then
        local d = distance(0, 0, x, y)
        local middle = (ring.min + ring.max) / 2
        if d < 1 then
            ax, ay = math.floor(middle), 0
        else
            ax = math.floor(x / d * middle + 0.5)
            ay = math.floor(y / d * middle + 0.5)
        end
    end

    local function usable(sx, sy)
        if ringOf(sx, sy) ~= ringName then return false end
        return Sectors.emptySpace(sx, sy)
    end

    local searchRadius = math.max(12, math.ceil(range * 2))
    local a

    spiral(ax, ay, searchRadius, function(sx, sy)
        if usable(sx, sy) then a = {x = sx, y = sy} return true end
        return false
    end)

    if not a then
        return nil, string.format("no empty sector in the %s ring within %d sectors of (%d:%d)",
                                  ringName, searchRadius, ax, ay)
    end

    local b
    local reach = math.floor(range)

    spiral(a.x, a.y, reach, function(sx, sy)
        if sx == a.x and sy == a.y then return false end
        if distance(a.x, a.y, sx, sy) > range then return false end
        if not canPassRifts and not unobstructed(a.x, a.y, sx, sy) then return false end
        if usable(sx, sy) then b = {x = sx, y = sy} return true end
        return false
    end)

    if not b then
        return nil, string.format("no second empty sector within jump range of (%d:%d)",
                                  a.x, a.y)
    end

    return {ring = ringName, a = a, b = b}
end

return Planner
