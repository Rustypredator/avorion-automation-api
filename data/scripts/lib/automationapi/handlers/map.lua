-- Map knowledge: what the player has seen, and what the seed says is out there.
--
-- All of this is read-only and works with nobody logged in, because known sectors live on
-- the player record and predictions come from the galaxy seed. Nothing here loads a
-- sector - the point of the prediction path is that it never has to.
--
-- The search endpoint is the one that can hurt. It is sliced across server ticks rather
-- than run in one, and it is capped; see Config.maxSectorsPerScan.

local Json = include("automationapi/json")
local Router = include("automationapi/router")
local Config = include("automationapi/config")
local Serialize = include("automationapi/serialize")
local Owner = include("automationapi/owner")
local Routes = include("automationapi/routes")
local Sectors = include("automationapi/sectors")

local Map = {}

-- #### QUERY PARSING #### --

local function coordinateParam(query, name, required)
    local value = Routes.integer(query[name])

    if value == nil and required then
        Router.fail(400, "bad_coordinates",
                    "'" .. name .. "' must be a whole-number sector coordinate.")
    end

    return value
end

-- "minX,minY,maxX,maxY", inclusive at both ends, in any corner order.
local function parseBox(query)
    local raw = query.bbox
    if raw == nil then return nil end

    if type(raw) ~= "string" then
        Router.fail(400, "bad_bbox", "'bbox' must be 'minX,minY,maxX,maxY'.")
    end

    local parts = {}
    for part in string.gmatch(raw, "[^,]+") do
        parts[#parts + 1] = Routes.integer((string.gsub(part, "%s", "")))
    end

    if #parts ~= 4 or parts[1] == nil or parts[2] == nil
       or parts[3] == nil or parts[4] == nil then
        Router.fail(400, "bad_bbox",
                    "'bbox' must be four whole numbers: 'minX,minY,maxX,maxY'.")
    end

    local box =
    {
        minX = math.min(parts[1], parts[3]),
        minY = math.min(parts[2], parts[4]),
        maxX = math.max(parts[1], parts[3]),
        maxY = math.max(parts[2], parts[4]),
    }

    box.count = (box.maxX - box.minX + 1) * (box.maxY - box.minY + 1)

    return box
end

local function inBox(box, x, y)
    if not box then return true end

    return x >= box.minX and x <= box.maxX and y >= box.minY and y <= box.maxY
end

local function pageSize(query)
    local limit = tonumber(query.limit) or Config.defaultPageSize

    if limit < 1 then limit = 1 end
    if limit > Config.maxPageSize then limit = Config.maxPageSize end

    return math.floor(limit)
end

-- Known sectors come from a faction record, so listing across both owners is meaningful
-- in the same way it is for ships.
local function ownersFor(ctx)
    if ctx.query.owner == "all" then return Owner.all(ctx) end

    return {Owner.resolve(ctx)}
end

local function keyOf(x, y) return x .. ":" .. y end

-- #### KNOWN SECTOR ACCESS #### --

-- Coordinates first, views second: getKnownSectorCoordinates is one cheap engine call,
-- while materialising every SectorView in a well-explored galaxy is not. Only sectors
-- that survive the box filter get a view built.
local function knownCoordinates(owner, box)
    local ok, raw = pcall(function() return {owner.faction:getKnownSectorCoordinates()} end)
    if not ok then return {} end

    local coords = {}
    for _, c in ipairs(raw) do
        if inBox(box, c.x, c.y) then
            coords[#coords + 1] = {x = c.x, y = c.y}
        end
    end

    -- stable order, so offset/limit paging means something between calls
    table.sort(coords, function(a, b)
        if a.y ~= b.y then return a.y < b.y end
        return a.x < b.x
    end)

    return coords
end

local function knownView(owner, x, y)
    local ok, view = pcall(function() return owner.faction:getKnownSector(x, y) end)
    if not ok then return nil end

    return view
end

-- #### SEARCH #### --

-- Case-insensitive substring match against a station's rendered name, so "turret" finds
-- "Turret Factory" and "factory" finds both that and "Iron Mine"'s neighbours. Several
-- needles may be given comma-separated; any one matching is a hit.
local function parseNeedles(query)
    local raw = query.station or query.q

    if type(raw) ~= "string" or raw == "" then
        Router.fail(400, "no_search_term",
                    "Provide 'station', the station name or part of it to look for.")
    end

    local needles = {}
    for part in string.gmatch(raw, "[^,]+") do
        local trimmed = string.lower((string.gsub(part, "^%s*(.-)%s*$", "%1")))
        if trimmed ~= "" then needles[#needles + 1] = trimmed end
    end

    if #needles == 0 then
        Router.fail(400, "no_search_term", "'station' held nothing to search for.")
    end

    return needles
end

local function matchStations(stations, needles)
    local matches = Json.array({})

    for _, station in ipairs(stations or {}) do
        local name = station.name
        if type(name) == "string" then
            local lowered = string.lower(name)

            for _, needle in ipairs(needles) do
                if string.find(lowered, needle, 1, true) then
                    matches[#matches + 1] = name
                    break
                end
            end
        end
    end

    if #matches == 0 then return nil end

    return matches
end

-- The scans currently being stepped through. A scan owns its request: it completes it
-- when it finishes, runs out of budget, or runs out of time.
local scans = {}

local function describeQuery(needles, box, predict)
    return
    {
        station = Json.array(needles),
        bbox = box and {lower = Serialize.vec2(box.minX, box.minY),
                        upper = Serialize.vec2(box.maxX, box.maxY)} or nil,
        predict = predict == true,
    }
end

local function finishScan(scan)
    scan.complete(200,
    {
        query = describeQuery(scan.needles, scan.box, scan.predict),
        count = #scan.results,
        results = scan.results,
        -- both passes, so the number means "sectors considered" rather than "sectors
        -- charged against the prediction budget"
        scanned = scan.scanned + (scan.knownScanned or 0),
        -- 'limit', 'budget' or 'timeout' when the answer is partial; narrow the box or
        -- raise the limit and ask again
        truncated = scan.truncated or false,
    })
end

local function recordPrediction(scan, x, y)
    local stations, about = Sectors.predictedStations(x, y)
    if not stations then return end

    local matches = matchStations(stations, scan.needles)
    if not matches then return end

    about = about or {}

    scan.results[#scan.results + 1] =
    {
        coordinates = Serialize.vec2(x, y),
        source = "predicted",
        matches = matches,
        stations = stations,
        factionIndex = about.factionIndex or 0,
        name = about.name or (x .. " : " .. y),
        template = about.template,
        visited = false,
    }
end

-- One tick's worth. Returns true when the scan is done and has answered its request.
local function stepScan(scan)
    if Server().unpausedRuntime >= scan.deadline then
        scan.truncated = "timeout"
        finishScan(scan)
        return true
    end

    local sectorBudget = Config.scanSectorsPerTick
    local detailBudget = Config.scanDetailsPerTick

    while sectorBudget > 0 do
        if scan.y > scan.box.maxY then
            finishScan(scan)
            return true
        end

        local x, y = scan.x, scan.y

        -- Only regular sectors hold stations, and only about three in a hundred are
        -- regular, so the hash filter decides almost every sector without doing any real
        -- work. The rest cost a full generator run and come out of a separate budget.
        local regular = false
        if not scan.seen[keyOf(x, y)] then
            regular = Sectors.mayHaveContent(x, y)
        end

        if regular and detailBudget <= 0 then
            -- out of detail budget: leave the cursor here and pick this sector up next
            -- tick rather than skipping it
            return false
        end

        scan.x = scan.x + 1
        if scan.x > scan.box.maxX then
            scan.x = scan.box.minX
            scan.y = scan.y + 1
        end

        scan.scanned = scan.scanned + 1
        sectorBudget = sectorBudget - 1

        if regular then
            detailBudget = detailBudget - 1
            recordPrediction(scan, x, y)
        end

        if #scan.results >= scan.limit then
            scan.truncated = "limit"
            finishScan(scan)
            return true
        end

        if scan.scanned >= Config.maxSectorsPerScan then
            -- a box exactly the size of the cap is covered, not cut short; only say
            -- truncated when there is genuinely box left over
            if scan.y <= scan.box.maxY then scan.truncated = "budget" end

            finishScan(scan)
            return true
        end
    end

    return false
end

-- Called from the bridge's update tick.
function Map.tick()
    if #scans == 0 then return end

    local remaining = {}

    for _, scan in ipairs(scans) do
        local ok, done = pcall(stepScan, scan)

        if not ok then
            scan.complete(500, {error = {code = "scan_failed", message = tostring(done)}})
        elseif not done then
            remaining[#remaining + 1] = scan
        end
    end

    scans = remaining
end

-- #### ENDPOINTS #### --

function Map.register(router)

    -- The galaxy's shape, none of which depends on what the player has seen. Everything
    -- here is derived from the seed and the balancing curves, so it is cheap and stable.
    router:get("/galaxy/info", function(ctx)
        local server = Server()

        local known = 0
        for _, owner in ipairs(Owner.all(ctx)) do
            local ok, coords = pcall(function()
                return {owner.faction:getKnownSectorCoordinates()}
            end)
            if ok then known = known + #coords end
        end

        local info = Sectors.galaxy()
        info.name = Serialize.string(server.name)
        info.seed = Serialize.string(server.seed)
        info.knownSectors = known

        local ok, homeX, homeY = pcall(function()
            return ctx.player:getHomeSectorCoordinates()
        end)
        if ok and type(homeX) == "number" then
            info.homeSector = Serialize.vec2(homeX, homeY)
        end

        return info
    end)

    -- Known sectors, filtered. Works offline: this reads the player record, not the world.
    router:get("/map/sectors", function(ctx)
        local query = ctx.query
        local box = parseBox(query)
        local limit = pageSize(query)
        local offset = math.max(0, math.floor(tonumber(query.offset) or 0))

        local since = tonumber(query.since)
        local wantVisited
        if query.visited == "true" then wantVisited = true end
        if query.visited == "false" then wantVisited = false end
        local wantFaction = Routes.integer(query.faction)
        local minStations = tonumber(query.stations)

        -- Only these need the view itself. Without them the coordinate list can be paged
        -- directly and only `limit` views are ever built, which is the difference between
        -- a cheap call and materialising a well-explored galaxy.
        local needsView = since ~= nil or wantVisited ~= nil
                          or wantFaction ~= nil or minStations ~= nil

        -- one merged, stably ordered list across the owners in scope, so paging is
        -- consistent from call to call
        local candidates = {}
        for _, owner in ipairs(ownersFor(ctx)) do
            for _, c in ipairs(knownCoordinates(owner, box)) do
                candidates[#candidates + 1] = {owner = owner, x = c.x, y = c.y}
            end
        end

        table.sort(candidates, function(a, b)
            if a.y ~= b.y then return a.y < b.y end
            if a.x ~= b.x then return a.x < b.x end
            return a.owner.kind < b.owner.kind
        end)

        local sectors = Json.array({})
        local total = 0
        local truncated = false

        if not needsView then
            total = #candidates

            for index = offset + 1, math.min(#candidates, offset + limit) do
                local candidate = candidates[index]
                local view = knownView(candidate.owner, candidate.x, candidate.y)

                if view then
                    local summary = Sectors.summary(view)
                    summary.owner = Owner.describe(candidate.owner)
                    sectors[#sectors + 1] = summary
                end
            end
        else
            for index, candidate in ipairs(candidates) do
                if index > Config.maxSectorsPerScan then
                    truncated = true
                    break
                end

                local view = knownView(candidate.owner, candidate.x, candidate.y)

                if view then
                    local summary = Sectors.summary(view)

                    local keep = true
                    if since ~= nil and summary.timeStamp < since then keep = false end
                    if wantVisited ~= nil and summary.visited ~= wantVisited then keep = false end
                    if wantFaction ~= nil and summary.factionIndex ~= wantFaction then keep = false end
                    if minStations ~= nil and summary.numStations < minStations then keep = false end

                    if keep then
                        total = total + 1

                        if total > offset and #sectors < limit then
                            summary.owner = Owner.describe(candidate.owner)
                            sectors[#sectors + 1] = summary
                        end
                    end
                end
            end
        end

        return
        {
            count = #sectors,
            total = total,
            offset = offset,
            limit = limit,
            truncated = truncated,
            sectors = sectors,
        }
    end)

    -- One known sector, in full. 404 when the caller has never seen it - which is what
    -- /map/predict is for.
    router:get("/map/sectors/{x}/{y}", function(ctx, params)
        local x = coordinateParam(params, "x", true)
        local y = coordinateParam(params, "y", true)

        for _, owner in ipairs(ownersFor(ctx)) do
            local view = knownView(owner, x, y)

            if view then
                local detail = Sectors.detail(view)
                detail.owner = Owner.describe(owner)
                detail.source = "known"

                return detail
            end
        end

        Router.fail(404, "sector_unknown",
                    string.format("(%d:%d) is not in your map knowledge. Try "
                                  .. "GET /map/predict/%d/%d.", x, y, x, y))
    end)

    -- Seed-derived contents, for any sector, visited or not, with no sector load. What it
    -- cannot know is anything players changed after generation.
    router:get("/map/predict/{x}/{y}", function(ctx, params)
        local x = coordinateParam(params, "x", true)
        local y = coordinateParam(params, "y", true)

        local predicted, err = Sectors.predicted(x, y)
        if not predicted then
            Router.fail(422, "prediction_failed",
                        "The generator would not describe that sector: " .. tostring(err))
        end

        predicted.source = "predicted"

        -- what the player actually knows about it, when they know anything, so a caller
        -- can tell prediction from observation in one request
        for _, owner in ipairs(Owner.all(ctx)) do
            local view = knownView(owner, x, y)
            if view then
                predicted.known = Sectors.summary(view)
                predicted.known.owner = Owner.describe(owner)
                break
            end
        end

        return predicted
    end)

    -- The live station search. Known sectors are answered immediately; predict=true then
    -- extends the search into sectors nobody has visited, which is sliced across ticks
    -- and answered when it finishes.
    router:get("/map/search", function(ctx)
        local query = ctx.query
        local needles = parseNeedles(query)
        local box = parseBox(query)
        local limit = pageSize(query)
        local predict = query.predict == "true" or query.predict == true

        local results = Json.array({})
        local seen = {}
        local scanned = 0
        local truncated = false

        local candidates = {}
        for _, owner in ipairs(ownersFor(ctx)) do
            for _, c in ipairs(knownCoordinates(owner, box)) do
                candidates[#candidates + 1] = {owner = owner, x = c.x, y = c.y}
            end
        end

        for _, candidate in ipairs(candidates) do
            if scanned >= Config.maxSectorsPerScan then
                truncated = "budget"
                break
            end

            if #results >= limit then
                truncated = "limit"
                break
            end

            scanned = scanned + 1

            local key = keyOf(candidate.x, candidate.y)

            if not seen[key] then
                local view = knownView(candidate.owner, candidate.x, candidate.y)

                if view then
                    -- marked seen whether or not it matched, so the predicted pass does
                    -- not re-derive a sector the player has already been to
                    seen[key] = true

                    local stations = Sectors.stationTitles(view)
                    local matches = matchStations(stations, needles)

                    if matches then
                        local summary = Sectors.summary(view)

                        results[#results + 1] =
                        {
                            coordinates = summary.coordinates,
                            source = "known",
                            matches = matches,
                            stations = stations,
                            factionIndex = summary.factionIndex,
                            name = summary.name,
                            visited = summary.visited,
                            owner = Owner.describe(candidate.owner),
                        }
                    end
                end
            end
        end

        if not predict or truncated then
            return
            {
                query = describeQuery(needles, box, predict),
                count = #results,
                results = results,
                scanned = scanned,
                truncated = truncated or false,
            }
        end

        if not box then
            Router.fail(400, "bbox_required",
                        "'predict=true' searches sectors nobody has visited, so it needs "
                        .. "a 'bbox' to bound the work. The cap is "
                        .. Config.maxSectorsPerScan .. " sectors per request.")
        end

        scans[#scans + 1] =
        {
            needles = needles,
            box = box,
            predict = true,
            limit = limit,
            x = box.minX,
            y = box.minY,
            seen = seen,
            results = results,
            -- the predicted pass gets the whole budget; the known pass is engine reads
            -- and was already capped separately above
            scanned = 0,
            knownScanned = scanned,
            -- answer with partial results rather than let the bridge time the request out
            deadline = Server().unpausedRuntime + Config.requestTimeout - 2,
            complete = ctx.complete,
        }

        return Router.DEFERRED
    end)

end

return Map
