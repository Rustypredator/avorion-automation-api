-- Mission automation: ships that send themselves back out on a captain mission whenever
-- they are free, as long as the mission stays inside the limits their owner set.
--
-- A rule is per craft and says what to fly (the same mission, area, config, materials and
-- escorts a start takes), what to optimise for, and the limits a dispatch must keep inside:
-- an ambush chance ceiling, a duration window, the flights a trade customer will sit
-- through, the deposit, a credit reserve. missionrules.lua owns that arithmetic; this file
-- owns everything around it.
--
-- Where things live, and why:
--
--   * Rules are Server values, one JSON document per owning faction. The galaxy bridge
--     reads them without touching a Player or Alliance object, they survive restarts, and
--     an alliance's rules are one document every member reads and edits - so a rule set by
--     one member is the rule every other member sees, and a revision number keeps two
--     members from silently overwriting each other.
--
--   * The loop runs here, in the galaxy bridge, so it keeps going with no console open.
--     It needs the owner online for exactly the reason every start does: the start itself
--     is carried out by the owner's agent (player/automationapi/agent.lua). For alliance
--     craft that is the alliance's own agent, which runs while any member is logged in.
--
--   * What the loop is doing - evaluating, blocked and why, out on a mission - is kept in
--     memory and served with the rule, so every member watching an alliance craft sees the
--     same state. It starts empty after a restart; the rules do not.
--
-- A dispatch is the same assessment a manual start runs (Missions.assess), repeated for
-- every config worth trying against each area analysed - one, or a sweep of the area laid
-- around the ship every way it fits - then the ordinary start job. So an automated start
-- can never be one the preview endpoint would have refused.
--
-- A rule's escorts make a pair: the escorts go out with the craft, a required one holds it
-- back until it is ready, and while paired an escort's own rule does not send it anywhere.

local Json = include("automationapi/json")
local Router = include("automationapi/router")
local Serialize = include("automationapi/serialize")
local Config = include("automationapi/config")
local Owner = include("automationapi/owner")
local ShipData = include("automationapi/shipdata")
local MissionTypes = include("automationapi/missiontypes")
local MissionRules = include("automationapi/missionrules")
local Analysis = include("automationapi/analysis")
local FactionScope = include("automationapi/factionscope")
local Missions = include("automationapi/handlers/missions")

-- Pure data defining the `goods` global; trade candidates are priced off it.
include("goods")

local MissionAutomation = {}

-- #### HELPERS #### --

local function now()
    local ok, runtime = pcall(function() return Server().unpausedRuntime end)
    return ok and type(runtime) == "number" and runtime or 0
end

local function sortedKeys(t)
    local keys = {}
    for key, _ in pairs(t) do keys[#keys + 1] = key end
    table.sort(keys)
    return keys
end

-- #### STORE #### --

-- factionIndex -> {raw, data}. Keyed on the raw string, so a value changed underneath -
-- by hand, or by a future second writer - is noticed rather than served stale.
local cache = {}

local function valueKey(index)
    return Config.missionAutomationValuePrefix .. tostring(index)
end

local function factionIndices()
    local raw = Server():getValue(Config.missionAutomationIndexValue)
    local list = type(raw) == "string" and Json.decode(raw) or nil

    local result = {}
    for _, index in ipairs(type(list) == "table" and list or {}) do
        if type(index) == "number" then result[#result + 1] = index end
    end

    return result
end

local function loadFaction(index)
    local raw = Server():getValue(valueKey(index))

    local cached = cache[index]
    if cached and cached.raw == raw then return cached.data end

    local data
    if type(raw) == "string" and raw ~= "" then
        local decoded = Json.decode(raw)
        if type(decoded) == "table" and type(decoded.ships) == "table" then data = decoded end
    end

    data = data or {ships = {}}
    cache[index] = {raw = raw, data = data}

    return data
end

local function saveFaction(index, data)
    local empty = next(data.ships) == nil

    local raw
    if not empty then
        local encoded, err = Json.encode({version = 1, ships = data.ships})
        if not encoded then
            Router.fail(500, "encoding_failed", "Could not store the rule: " .. tostring(err))
        end
        raw = encoded
    end

    Server():setValue(valueKey(index), raw)
    cache[index] = {raw = raw, data = data}

    -- The index is what the loop walks, so a faction is only in it while it has rules.
    local indices = factionIndices()
    local present, kept = false, Json.array({})

    for _, existing in ipairs(indices) do
        if existing == index then
            present = true
            if not empty then kept[#kept + 1] = existing end
        else
            kept[#kept + 1] = existing
        end
    end

    if not present and not empty then kept[#kept + 1] = index end

    if #kept ~= #indices or not present then
        Server():setValue(Config.missionAutomationIndexValue,
                          #kept > 0 and Json.encode(kept) or nil)
    end
end

-- #### STATE #### --

-- "<factionIndex>/<shipName>" -> what the loop last did for that rule
local states = {}

local function stateKey(index, shipName) return tostring(index) .. "/" .. shipName end

local function stateOf(index, shipName)
    local key = stateKey(index, shipName)
    local state = states[key]

    if not state then
        state = {phase = "waiting", message = "Not checked yet.", since = now(),
                 nextCheckAt = 0, dispatches = 0, log = {}}
        states[key] = state
    end

    return state
end

-- Moves a rule to a phase, and logs it when that is news. A ship blocked by the same
-- limit on every retry is one log line, not one every five minutes.
local function note(state, phase, message, detail)
    local changed = state.phase ~= phase or state.message ~= message

    state.phase = phase
    state.message = message
    if changed then state.since = now() end

    if changed or detail then
        state.log[#state.log + 1] = {at = now(), phase = phase, message = message, detail = detail}

        local overflow = #state.log - Config.missionAutomationLogSize
        if overflow > 0 then
            local trimmed = {}
            for i = overflow + 1, #state.log do trimmed[#trimmed + 1] = state.log[i] end
            state.log = trimmed
        end
    end
end

-- #### OWNERS #### --

-- A request's owner comes from the caller's Player and its .alliance, both of which carry
-- the craft API. The loop has only an index. findFaction says which kind it is, but hands
-- back a plain Faction that is not documented to carry ship calls, so the Player or
-- Alliance by that index is used where the engine gives one.
local function ownerOf(index)
    local function attempt(fn)
        local ok, found = pcall(fn)
        return ok and found or nil
    end

    local found = attempt(function() return Galaxy():findFaction(index) end)
    if not found then return nil end

    local isAlliance = found.isAlliance == true
    local faction = isAlliance and attempt(function() return Alliance(index) end)
                    or not isAlliance and attempt(function() return Player(index) end)
                    or found

    return
    {
        faction = faction,
        index = index,
        kind = isAlliance and "alliance" or "player",
        name = Serialize.string(faction.name, ""),
    }
end

-- Whose authority a start runs under. A player's own craft: the player. An alliance's: the
-- member who last saved the rule, whose rank the alliance agent checks on every start -
-- so a member who is demoted or leaves stops dispatching the moment it happens.
local function authorityOf(owner, rule)
    if owner.kind ~= "alliance" then return owner.index end
    return type(rule.updatedBy) == "table" and rule.updatedBy.index or nil
end

local function hasPrivilege(owner, playerIndex, privilege)
    if owner.kind ~= "alliance" then return true end
    if not playerIndex then return false end

    local ok, allowed = pcall(function()
        return owner.faction:hasPrivilege(playerIndex, privilege)
    end)

    return ok and allowed == true
end

-- #### AREAS #### --

local function placementOffset(fraction, length)
    if fraction <= 0 then return 0 end
    if fraction >= 1 then return length - 1 end
    return math.floor((length - 1) / 2)
end

local function areaSizes(command, owner, shipName)
    local sizes = {}
    for _, candidate in ipairs({command:getAreaSize(owner.index, shipName)}) do
        if type(candidate) == "table" then sizes[#sizes + 1] = candidate end
    end

    if #sizes == 0 then
        Router.fail(500, "no_area_size", "The game did not report an area size for this mission.")
    end

    return sizes
end

local function placed(x, y, size, placement)
    local lowerX = x - placementOffset(placement.fx, size.x)
    local lowerY = y - placementOffset(placement.fy, size.y)

    return
    {
        lower = {x = lowerX, y = lowerY},
        upper = {x = lowerX + size.x - 1, y = lowerY + size.y - 1},
    }
end

-- Every rectangle one check analyses, in the order it analyses them. A "ship" area follows
-- the craft, so a trade ship that ended its last contract somewhere else looks for routes
-- around where it is now; a "sweep" lays that area around the craft at every placement and
-- shape, since which stations fall inside decides which routes the game offers at all.
local function areasFor(command, owner, shipName, spec)
    spec = spec or {mode = "ship"}

    if spec.mode == "fixed" then
        return
        {{
            lower = {x = spec.lower.x, y = spec.lower.y},
            upper = {x = spec.upper.x, y = spec.upper.y},
        }}
    end

    local sizes = areaSizes(command, owner, shipName)

    local x, y = owner.faction:getShipPosition(shipName)
    if type(x) ~= "number" or type(y) ~= "number" then
        Router.fail(409, "no_position", "The ship's position is unknown.")
    end
    x, y = math.floor(x), math.floor(y)

    if spec.mode == "sweep" then
        local wanted = sizes
        if spec.sizes then
            wanted = {}
            for _, size in ipairs(sizes) do
                for _, asked in ipairs(spec.sizes) do
                    if size.x == asked.x and size.y == asked.y then wanted[#wanted + 1] = size end
                end
            end
            -- a captain whose shapes changed under the rule still gets searched
            if #wanted == 0 then wanted = sizes end
        end

        -- A command whose area the game recentres on the ship anyway has one placement.
        local placements = MissionRules.placements
        local okFixed, fixed = pcall(function() return command:isAreaFixed(owner.index, shipName) end)
        if okFixed and fixed then placements = {{fx = 0.5, fy = 0.5}} end

        local areas, seen = {}, {}
        for _, size in ipairs(wanted) do
            for _, placement in ipairs(placements) do
                local area = placed(x, y, size, placement)
                local key = string.format("%d:%d:%d:%d", area.lower.x, area.lower.y,
                                          area.upper.x, area.upper.y)
                if not seen[key] then
                    seen[key] = true
                    areas[#areas + 1] = area
                end
            end
        end

        return areas
    end

    local size = sizes[1]
    for _, candidate in ipairs(sizes) do
        if spec.size and candidate.x == spec.size.x and candidate.y == spec.size.y then
            size = candidate
            break
        end
    end

    return {placed(x, y, size, spec.placement or {fx = 0.5, fy = 0.5})}
end

-- #### EVALUATION #### --

local function firstError(errors)
    if type(errors) ~= "table" then return nil end

    if type(errors.usable) == "table" then
        return errors.usable.message or errors.usable.code
    end

    for _, name in ipairs({"config", "command", "prediction", "start"}) do
        local e = errors[name]
        if type(e) == "table" and e.text then return Serialize.displayName(e.text) end
    end

    return nil
end

local function baseConfigOf(rule)
    return MissionTypes.buildConfig(rule.mission,
    {
        config = MissionRules.copy(rule.config or {}),
        materials = rule.materials and MissionRules.copy(rule.materials) or nil,
        escorts = MissionRules.copy(rule.escorts or {}),
    })
end

local function routeOf(results, goodName)
    if not goodName or type(results) ~= "table" then return nil end

    for _, route in ipairs(results.routes or {}) do
        if route.name == goodName then
            return
            {
                good = Serialize.string(route.name),
                from = route.from and Serialize.vec2(route.from.x, route.from.y) or nil,
                to = route.to and Serialize.vec2(route.to.x, route.to.y) or nil,
            }
        end
    end

    return nil
end

-- Every candidate against one analysed area, unranked, each carrying the area and analysis
-- it was predicted on - in a sweep they differ from one candidate to the next, and a start
-- has to name the area its config was judged against. Runs on the bridge's tick inside the
-- analysis callback.
local function judge(owner, shipName, rule, authIndex, area, results, base)
    local key = rule.mission
    local missionType = MissionTypes.typeOf(key)

    area.analysis = results
    local command = MissionTypes.make(missionType, shipName, area, {})

    local configurable = {}
    local okValues, values = pcall(function()
        return command:getConfigurableValues(owner.index, shipName)
    end)
    if okValues and type(values) == "table" then configurable = values end

    local freeCargo = 0
    local entry = ShipDatabaseEntry(owner.index, shipName)
    if entry then
        local okFree, free = pcall(function() return entry:getFreeCargoSpace() end)
        if okFree and type(free) == "number" then freeCargo = free end
    end

    local env =
    {
        configurable = configurable,
        routes = type(results) == "table" and results.routes or nil,
        goods = goods,
        freeCargo = freeCargo,
        probe = function(config)
            local ok, predicted = pcall(function()
                return FactionScope.with(owner.faction, function()
                    return command:calculatePrediction(owner.index, shipName, area, config)
                end)
            end)
            return ok and type(predicted) == "table" and predicted or nil
        end,
    }

    local money
    local okMoney, value = pcall(function() return owner.faction.money end)
    if okMoney and type(value) == "number" then money = value end

    -- Simulation only checks SpendResources against callingPlayer, which a start on the
    -- alliance's own thread has none of - so a deposit is checked here instead.
    local maySpend = hasPrivilege(owner, authIndex, AlliancePrivilege.SpendResources)

    local evaluated = {}

    for _, config in ipairs(MissionRules.candidates(key, rule, base, env)) do
        local assessed = Missions.assess(owner, shipName, key, missionType, area, results,
                                         config, {brief = true})

        local metrics = MissionRules.metrics(key, assessed.command.config, assessed.prediction)
        local violations = MissionRules.check(rule.limits, metrics,
        {
            money = money,
            canStart = assessed.body.canStart,
            gameError = firstError(assessed.body.errors),
        })

        if (metrics.cost or 0) > 0 and not maySpend then
            violations[#violations + 1] =
            {
                limit = "privilege",
                message = "the member who set this rule may not spend alliance funds",
            }
        end

        evaluated[#evaluated + 1] =
        {
            config = assessed.command.config,
            metrics = metrics,
            violations = violations,
            prediction = assessed.body.prediction,
            area = area,
            results = results,
            route = routeOf(results, assessed.command.config.goodName),
        }
    end

    return evaluated, money
end

-- #### SWEEPS #### --

-- A check analyses its areas one after another: Analysis keys a job on ship and mission
-- type, so a ship never has two in flight. Each next analysis is started from the tick, not
-- from inside the last one's callback, and only while an analysis slot is free below the
-- one kept for people previewing in the console.
local sweeps = {}

local function slotCeiling()
    return math.max(1, Config.maxConcurrentAnalyses - 1)
end

local function isBusy(err)
    return Router.isApiError(err) and (err.code == "analysis_busy" or err.code == "analysis_in_progress")
end

local function removeSweep(sweep)
    for i, s in ipairs(sweeps) do
        if s == sweep then table.remove(sweeps, i) return end
    end
end

-- Ranks everything every area offered and hands the report on.
local function conclude(sweep)
    if sweep.finished then return end
    sweep.finished = true
    removeSweep(sweep)

    local failure = sweep.failure
    if #sweep.evaluated == 0 and failure and sweep.analysed == 0 then
        sweep.handlers.failed(failure.code, failure.message)
        return
    end

    local rule = sweep.rule
    MissionRules.rank(sweep.evaluated, MissionRules.priorityList(rule),
                      {prefer = rule.goods and rule.goods.prefer})

    local best = sweep.evaluated[1]

    sweep.handlers.done(
    {
        area = best and best.area or sweep.areas[1],
        results = best and best.results or nil,
        areas = #sweep.areas,
        analysed = sweep.analysed,
        candidates = sweep.evaluated,
        chosen = best and #best.violations == 0 and best or nil,
        money = sweep.money,
        at = now(),
    })
end

local function launch(sweep)
    local area = sweep.areas[sweep.next]

    Analysis.start(sweep.owner.index, sweep.authIndex or sweep.owner.index, sweep.shipName,
                   sweep.missionType, area,
        function(analyzed, results)
            sweep.inFlight = false
            if sweep.finished then return end

            local ok, evaluated, money = pcall(judge, sweep.owner, sweep.shipName, sweep.rule,
                                               sweep.authIndex, analyzed, results, sweep.base)
            if ok then
                sweep.analysed = sweep.analysed + 1
                sweep.money = money or sweep.money
                for _, candidate in ipairs(evaluated) do
                    sweep.evaluated[#sweep.evaluated + 1] = candidate
                end
            elseif Router.isApiError(evaluated) then
                sweep.failure = {code = evaluated.code, message = evaluated.message}
            else
                sweep.failure = {code = "evaluation_failed", message = tostring(evaluated)}
            end

            if sweep.handlers.progress then
                pcall(sweep.handlers.progress, sweep.next - 1, #sweep.areas)
            end

            if sweep.next > #sweep.areas then conclude(sweep) end
        end,
        function(reason)
            sweep.inFlight = false
            if sweep.finished then return end

            sweep.failure = {code = "analysis_failed", message = reason}
            if sweep.next > #sweep.areas then conclude(sweep) end
        end)

    -- only once the start went through: a busy slot is retried with the same area
    sweep.next = sweep.next + 1
    sweep.inFlight = true
end

local function advanceSweeps()
    local t = now()

    for i = #sweeps, 1, -1 do
        local sweep = sweeps[i]

        if t > sweep.deadline then
            sweep.failure = {code = "sweep_timeout", message = string.format(
                "Analysed %d of %d areas before giving up.", sweep.analysed, #sweep.areas)}
            conclude(sweep)
        elseif not sweep.inFlight and sweep.next <= #sweep.areas
               and Analysis.activeCount() < slotCeiling() then
            local ok, err = pcall(launch, sweep)
            if not ok and not isBusy(err) then
                sweep.failure = Router.isApiError(err) and {code = err.code, message = err.message}
                                or {code = "analysis_failed", message = tostring(err)}
                sweep.next = #sweep.areas + 1
                conclude(sweep)
            end
        end
    end
end

-- Runs one check: an analysis per area and every candidate judged against each. handlers:
--
--   done(report)            every area analysed (or given up on) and something to rank
--   failed(code, message)   nothing could be analysed at all
--   progress(done, total)   optional, after each area
--
-- The first analysis starts before this returns, so an error starting it - a slot busy, a
-- bad material - is raised to the caller, which decides whether that is a response or a
-- retry. Returns the number of areas the check covers.
local function evaluate(owner, shipName, rule, authIndex, handlers)
    local missionType = MissionTypes.typeOf(rule.mission)
    local command = MissionTypes.make(missionType, shipName, nil, {})

    local sweep =
    {
        owner = owner,
        shipName = shipName,
        rule = rule,
        authIndex = authIndex,
        missionType = missionType,
        base = baseConfigOf(rule),
        areas = areasFor(command, owner, shipName, rule.area),
        handlers = handlers,
        next = 1,
        analysed = 0,
        evaluated = {},
        deadline = now() + Config.missionAutomationSweepTimeout,
    }

    launch(sweep)
    sweeps[#sweeps + 1] = sweep

    return #sweep.areas
end

-- #### PAIRS #### --

-- ship name -> {primary, required}: every escort an enabled rule of the faction names. A
-- ship escorts one primary at a time; saving a rule keeps it that way.
local function escortIndex(data)
    local result = {}

    for _, primary in ipairs(sortedKeys(data.ships)) do
        local rule = data.ships[primary]
        if rule.enabled then
            for _, escort in ipairs(MissionRules.escortList(rule)) do
                result[escort.name] = result[escort.name]
                                      or {primary = primary, required = escort.required}
            end
        end
    end

    return result
end

-- Why an escort cannot join its primary right now, or nil when it can. The start runs the
-- same checks (SimulationUtility.isShipUsableAsEscort) but answers a failure only in chat,
-- which leaves an automated start with nothing to report but "the game refused".
local function escortProblem(owner, index, primary, name)
    if name == primary then return "a craft cannot escort itself" end

    local okOwns, owns = pcall(function() return owner.faction:ownsShip(name) end)
    if not okOwns or not owns then return "no craft by that name belongs to " .. owner.name end

    local availability = owner.faction:getShipAvailability(name)
    if availability == ShipAvailability.Destroyed then return "destroyed" end
    if availability == ShipAvailability.InBackground then return "out on a mission" end
    if availability ~= ShipAvailability.Available then return "not available" end

    local program = MissionAutomation.controlledBy(index, name)
    if program then return "the program '" .. tostring(program) .. "' drives it" end

    -- One jump from the primary, measured with the escort's own drive, and on the same
    -- side of the barrier unless it can cross rifts.
    local px, py = owner.faction:getShipPosition(primary)
    local entry = ShipDatabaseEntry(owner.index, name)
    if entry and type(px) == "number" and type(py) == "number" then
        local okDrive, reach, canPassRifts = pcall(function() return entry:getHyperspaceProperties() end)
        local okAt, ex, ey = pcall(function() return entry:getCoordinates() end)

        if okDrive and okAt and type(reach) == "number" and type(ex) == "number" then
            local dx, dy = ex - px, ey - py
            if dx * dx + dy * dy > reach * reach then
                return string.format("%.1f sectors away at (%d:%d), beyond its %.1f-sector jump",
                                     math.sqrt(dx * dx + dy * dy), ex, ey, reach)
            end

            if not canPassRifts then
                local okRing, inside, primaryInside = pcall(function()
                    return Balancing_InsideRing(ex, ey), Balancing_InsideRing(px, py)
                end)
                if okRing and inside ~= primaryInside then
                    return "on the other side of the barrier, which it cannot cross"
                end
            end
        end
    end

    local usable = ShipData.usable(owner.index, name)
    if not usable.ok then return tostring(usable.message) end

    return nil
end

-- Sorts a rule's escorts into those ready to go and those that are not. Returns going (the
-- names), the first required escort not ready ({name, problem}) or nil, and the optional
-- ones left behind.
local function muster(owner, index, shipName, rule)
    local going, left = Json.array({}), {}

    for _, escort in ipairs(MissionRules.escortList(rule)) do
        local problem = escortProblem(owner, index, shipName, escort.name)

        if not problem then
            going[#going + 1] = escort.name
        elseif escort.required then
            return going, {name = escort.name, problem = problem}, left
        else
            left[#left + 1] = {name = escort.name, problem = problem}
        end
    end

    return going, nil, left
end

-- The rule a check flies: the stored one, with only the escorts that are going.
local function flownWith(rule, going)
    local flying = MissionRules.copy(rule)
    flying.escorts = going
    return flying
end

local function leftText(left)
    local parts = {}
    for _, escort in ipairs(left) do
        parts[#parts + 1] = escort.name .. " (" .. escort.problem .. ")"
    end
    return "left behind: " .. table.concat(parts, ", ")
end

-- Refuses a rule that would put a ship in two pairs at once, or make an escort lead a pair
-- of its own. Only enabled rules pair ships up; a switched-off rule frees its escorts.
local function checkPairing(owner, data, shipName, rule)
    if not rule.enabled then return end

    local others = {}
    for name, other in pairs(data.ships) do
        if name ~= shipName then others[name] = other end
    end
    local paired = escortIndex({ships = others})

    local escorts = MissionRules.escortList(rule)

    if #escorts > 0 and paired[shipName] then
        Router.fail(409, "escort_paired", "'" .. shipName .. "' escorts '" .. paired[shipName].primary
                    .. "', so it cannot lead a pair of its own.",
                    {escort = shipName, primary = paired[shipName].primary})
    end

    for _, escort in ipairs(escorts) do
        local name = escort.name

        if name == shipName then
            Router.fail(400, "bad_rule", "A craft cannot escort itself.")
        end

        local okOwns, owns = pcall(function() return owner.faction:ownsShip(name) end)
        if not okOwns or not owns then
            Router.fail(400, "bad_rule", "No craft called '" .. name .. "' belongs to "
                        .. owner.name .. ".")
        end

        if paired[name] then
            Router.fail(409, "escort_paired", "'" .. name .. "' already escorts '"
                        .. paired[name].primary .. "'.",
                        {escort = name, primary = paired[name].primary})
        end

        local own = others[name]
        if own and own.enabled and #(own.escorts or {}) > 0 then
            Router.fail(409, "escort_paired", "'" .. name .. "' leads a pair of its own.",
                        {escort = name, primary = name})
        end
    end
end

local function describePairing(owner, index, shipName, rule, data)
    if rule and #(rule.escorts or {}) > 0 then
        local escorts = Json.array({})
        for _, escort in ipairs(MissionRules.escortList(rule)) do
            local problem = escortProblem(owner, index, shipName, escort.name)
            escorts[#escorts + 1] =
            {
                name = escort.name,
                required = escort.required,
                ready = problem == nil,
                problem = problem,
            }
        end
        return {role = "primary", active = rule.enabled == true, escorts = escorts}
    end

    local paired = escortIndex(data)[shipName]
    if paired then
        return {role = "escort", active = true, primary = paired.primary, required = paired.required}
    end

    return nil
end

-- #### DESCRIPTIONS #### --

local function roundTo(value, digits)
    if type(value) ~= "number" or value ~= value then return nil end
    local scale = 10 ^ (digits or 0)
    return math.floor(value * scale + 0.5) / scale
end

local function describeMetrics(m)
    return
    {
        attackChance = roundTo(m.attackChance, 4),
        duration = roundTo(m.duration),
        expectedDuration = roundTo(m.expectedDuration),
        flights = m.flights,
        expectedFlights = roundTo(m.expectedFlights, 2),
        completionChance = roundTo(m.completionChance, 4),
        patience = m.patience,
        cost = roundTo(m.cost),
        value = roundTo(m.value),
        contractValue = roundTo(m.contractValue),
        valueUnit = m.valueUnit,
        hourly = roundTo(m.hourly),
    }
end

local function describeArea(area)
    return
    {
        lower = Serialize.vec2(area.lower.x, area.lower.y),
        upper = Serialize.vec2(area.upper.x, area.upper.y),
    }
end

local function describeCandidate(rule, candidate)
    local violations = Json.array({})
    for _, v in ipairs(candidate.violations) do
        violations[#violations + 1] = {limit = v.limit, message = v.message}
    end

    return
    {
        passes = #candidate.violations == 0,
        preferred = candidate.preferred == true or nil,
        config = MissionTypes.describeConfig(rule.mission, candidate.config),
        route = candidate.route,
        area = describeArea(candidate.area),
        metrics = describeMetrics(candidate.metrics),
        violations = violations,
    }
end

local function violationText(candidate)
    local parts = {}
    for _, v in ipairs(candidate.violations) do parts[#parts + 1] = v.message end
    return table.concat(parts, "; ")
end

-- A sweep sees the same route from several areas; the list shows each route and flight
-- count once, at its best-ranked area.
local function sameOption(candidate)
    local route = candidate.route
    if not route then return nil end
    return string.format("%s@%s:%s>%s:%s/%s", tostring(route.good),
                         tostring(route.from and route.from.x), tostring(route.from and route.from.y),
                         tostring(route.to and route.to.x), tostring(route.to and route.to.y),
                         tostring(candidate.metrics.flights))
end

local function describeReport(report, rule)
    local candidates = Json.array({})
    local passing = 0
    local shown = {}

    for _, candidate in ipairs(report.candidates) do
        if #candidate.violations == 0 then passing = passing + 1 end

        local key = sameOption(candidate)
        if #candidates < Config.missionAutomationReportedCandidates and not (key and shown[key]) then
            if key then shown[key] = true end
            candidates[#candidates + 1] = describeCandidate(rule, candidate)
        end
    end

    local escorts
    if report.escorts then
        local left = Json.array({})
        for _, escort in ipairs(report.escorts.left or {}) do
            left[#left + 1] = {name = escort.name, problem = escort.problem}
        end
        escorts = {going = Json.array(MissionRules.copy(report.escorts.going or {})), left = left}
    end

    return
    {
        at = report.at,
        objective = rule.objective,
        priorities = Json.array(MissionRules.copy(MissionRules.priorityList(rule))),
        area = describeArea(report.area),
        areas = report.areas,
        analysed = report.analysed,
        tried = #report.candidates,
        passing = passing,
        money = report.money,
        escorts = escorts,
        chosen = report.chosen and describeCandidate(rule, report.chosen) or nil,
        candidates = candidates,
    }
end

-- One line saying what was sent out, for the log.
local function dispatchSummary(rule, candidate)
    local m = candidate.metrics
    local parts = {rule.mission}

    if candidate.config.goodName then parts[#parts + 1] = tostring(candidate.config.goodName) end
    if m.flights then parts[#parts + 1] = string.format("%d flights", m.flights) end
    if m.duration then
        parts[#parts + 1] = string.format("%.1fh", m.duration / 3600)
    end
    parts[#parts + 1] = string.format("ambush %d%%", math.floor(m.attackChance * 100 + 0.5))
    if m.hourly then
        parts[#parts + 1] = string.format("~%d %s/h", math.floor(m.hourly + 0.5),
                                          m.valueUnit == "credits" and "¢" or "units")
    end

    local escorts = candidate.config.escorts
    if type(escorts) == "table" and #escorts > 0 then
        parts[#parts + 1] = "with " .. table.concat(escorts, ", ")
    end

    return table.concat(parts, ", ")
end

local function describeState(state)
    if not state then return nil end

    local log = Json.array({})
    for _, entry in ipairs(state.log or {}) do log[#log + 1] = entry end

    return
    {
        phase = state.phase,
        message = state.message,
        since = state.since,
        nextCheckAt = state.nextCheckAt,
        busy = state.busy == true,
        progress = state.progress,
        dispatches = state.dispatches or 0,
        lastDispatch = state.lastDispatch,
        lastEvaluation = state.lastEvaluation,
        lastCollect = state.lastCollect,
        log = log,
    }
end

local function describeRule(rule)
    local described = MissionRules.copy(rule)
    described.escorts = Json.array(described.escorts or {})
    if described.materials then described.materials = Json.array(described.materials) end
    if described.optionalEscorts then described.optionalEscorts = Json.array(described.optionalEscorts) end
    if described.priorities then described.priorities = Json.array(described.priorities) end
    if described.goods then
        described.goods.prefer = Json.array(described.goods.prefer or {})
        described.goods.avoid = Json.array(described.goods.avoid or {})
    end
    if described.area and described.area.sizes then
        described.area.sizes = Json.array(described.area.sizes)
    end
    return described
end

-- dry runs a sweep is too slow to answer in one request: "<factionIndex>/<shipName>" ->
-- {running, done, total, startedAt, by, result, error}
local dryRuns = {}

local function describeEntry(owner, shipName, rule)
    local key = stateKey(owner.index, shipName)
    local data = loadFaction(owner.index)

    local pairing
    local okPairing, found = pcall(describePairing, owner, owner.index, shipName, rule, data)
    if okPairing then pairing = found end

    return
    {
        ship = shipName,
        owner = Owner.describe(owner),
        rule = rule and describeRule(rule) or nil,
        state = describeState(states[key]),
        pairing = pairing,
        dryRun = dryRuns[key],
    }
end

-- #### THE LOOP #### --

local function later(state, phase, message, delay)
    note(state, phase, message)
    state.nextCheckAt = now() + delay
end

local function collectYields(owner, shipName, authIndex, state)
    Missions.enqueue
    {
        kind = "collect",
        owner = owner,
        playerIndex = authIndex,
        shipName = shipName,
        complete = function() end,
        onResult = function(result)
            local data = result.data or {}
            local collected = Serialize.number(data.before, 0) - Serialize.number(data.after, 0)
            if collected > 0 then
                state.lastCollect = {at = now(), collected = collected}
                note(state, state.phase, state.message,
                     string.format("collected %d yield%s", collected, collected == 1 and "" or "s"))
            end
        end,
    }
end

local function dispatch(owner, index, shipName, rule, authIndex, report, state)
    local chosen = report.chosen

    state.busy = true
    note(state, "starting", "Starting: " .. dispatchSummary(rule, chosen))

    local function failed(code, message)
        state.busy = false
        later(state, "error", string.format("The start failed (%s): %s", tostring(code),
                                            tostring(message or "no reason given")),
              Config.missionAutomationRetry)
    end

    Missions.enqueue
    {
        kind = "start",
        owner = owner,
        playerIndex = authIndex,
        shipName = shipName,
        missionType = MissionTypes.typeOf(rule.mission),
        area = Missions.plainArea(chosen.area),
        config = Missions.plainConfig(chosen.config),
        -- the queue answers here when the start never reached an agent, or the agent
        -- refused it for the authorising member's rank
        complete = function(status, body)
            local err = type(body) == "table" and body.error or {}
            failed(err.code or ("http_" .. tostring(status)), err.message)
        end,
        onResult = function(result)
            if not result.started then
                failed(result.code or "start_rejected", result.message
                       or "the game refused the start; its reason went to the owner as chat")
                return
            end

            state.busy = false
            state.dispatches = (state.dispatches or 0) + 1
            state.lastDispatch =
            {
                at = now(),
                mission = rule.mission,
                summary = dispatchSummary(rule, chosen),
                candidate = describeCandidate(rule, chosen),
            }
            state.dispatchedRevision = rule.revision
            state.nextCheckAt = now() + Config.missionAutomationRecheck

            local detail = state.lastDispatch.summary
            local left = report.escorts and report.escorts.left or {}
            if #left > 0 then detail = detail .. "; " .. leftText(left) end
            note(state, "running", "Out on a mission it was sent on.", detail)
        end,
    }
end

local function considerRule(owner, index, shipName, rule, state, mayEvaluate)
    local recheck = Config.missionAutomationRecheck
    local retry = Config.missionAutomationRetry

    if not owner then
        later(state, "error", "The owning faction no longer exists.", retry)
        return false
    end

    local okOwns, owns = pcall(function() return owner.faction:ownsShip(shipName) end)
    if not okOwns or not owns then
        later(state, "missing", "No craft by this name belongs to " .. owner.name .. " any more.",
              retry)
        return false
    end

    local availability = owner.faction:getShipAvailability(shipName)

    if availability == ShipAvailability.InBackground then
        if state.phase == "running" then
            state.nextCheckAt = now() + recheck
        else
            later(state, "busy", "Out on a mission started elsewhere; waiting for it to return.",
                  recheck)
        end
        return false
    end

    if availability == ShipAvailability.Destroyed then
        later(state, "blocked", "The ship is destroyed.", retry)
        return false
    end

    local okOnline, online = pcall(function() return Server():isOnline(owner.index) end)
    if not okOnline or not online then
        later(state, "offline", owner.kind == "alliance"
              and "Waiting for an alliance member to log in: the alliance's agent starts its missions."
              or "Waiting for the owner to log in: only their agent can start a mission.",
              recheck)
        return false
    end

    local authIndex = authorityOf(owner, rule)
    if not hasPrivilege(owner, authIndex, AlliancePrivilege.ManageShips) then
        later(state, "blocked", "The member who last saved this rule may no longer manage "
              .. "alliance ships. Saving it again puts it under your own rank.", retry)
        return false
    end

    local command = MissionTypes.make(MissionTypes.typeOf(rule.mission), shipName, nil, {})
    local ignored
    if command.getIgnoredErrors then
        local okIgnored, value = pcall(function() return command:getIgnoredErrors() end)
        if okIgnored then ignored = value end
    end

    local usable = ShipData.usable(owner.index, shipName, ignored)
    if not usable.ok then
        later(state, "blocked", "The ship cannot go out: " .. tostring(usable.message), recheck)
        return false
    end

    -- A pair goes out together. A required escort that is not ready holds the primary back;
    -- an optional one is left behind, and the limits then judge the mission without it.
    local going, missing, left = muster(owner, index, shipName, rule)
    if missing then
        later(state, "escort", "Waiting for escort " .. missing.name .. ": " .. missing.problem .. ".",
              recheck)
        return false
    end

    -- One evaluation per pass, and never the last analysis slot: a person previewing a
    -- mission in the console should not be told the server is busy because of a timer.
    if not mayEvaluate or Analysis.activeCount() >= slotCeiling() then
        note(state, "waiting", "Waiting for a free area analysis.")
        state.nextCheckAt = 0
        return false
    end

    if rule.collectYields then
        pcall(collectYields, owner, shipName, authIndex, state)
    end

    state.busy = true
    state.progress = nil
    note(state, "evaluating", "Analysing the area and checking the limits.")

    local flying = flownWith(rule, going)

    local okEvaluate, err = pcall(evaluate, owner, shipName, flying, authIndex,
    {
        progress = function(done, total)
            -- progress is not news: it moves the message without adding to the log
            state.progress = {done = done, total = total}
            state.message = string.format("Analysing area %d of %d and checking the limits.",
                                          math.min(done + 1, total), total)
        end,
        done = function(report)
            state.busy = false
            state.progress = nil
            report.escorts = {going = going, left = left}
            state.lastEvaluation = describeReport(report, flying)

            -- The rule may have been edited, disabled or removed while the analysis ran; a
            -- dispatch under settings nobody holds any more is the one thing not to do.
            local current = loadFaction(index).ships[shipName]
            if not current or not current.enabled or current.revision ~= rule.revision then
                note(state, "waiting", "The rule changed while it was being checked.")
                state.nextCheckAt = 0
                return
            end

            -- or the ship was sent out by hand in the meantime
            if owner.faction:getShipAvailability(shipName) ~= ShipAvailability.Available then
                later(state, "busy", "Sent out by someone else while it was being checked.",
                      recheck)
                return
            end

            if not report.chosen then
                local nearest = report.candidates[1]
                local why = nearest and violationText(nearest)
                            or "no way to fly this mission was found in the area"
                later(state, "blocked", "Nothing within the limits: " .. why, retry)
                return
            end

            -- an escort sent elsewhere while a sweep ran would only have the game refuse
            for _, name in ipairs(going) do
                local problem = escortProblem(owner, index, shipName, name)
                if problem then
                    later(state, "escort", "Waiting for escort " .. name .. ": " .. problem .. ".",
                          recheck)
                    return
                end
            end

            dispatch(owner, index, shipName, current, authIndex, report, state)
        end,
        failed = function(code, message)
            state.busy = false
            state.progress = nil
            later(state, "error", string.format("The check failed (%s): %s", tostring(code),
                                                tostring(message)), retry)
        end,
    })

    if not okEvaluate then
        state.busy = false

        if isBusy(err) then
            note(state, "waiting", "Waiting for a free area analysis.")
            state.nextCheckAt = now() + Config.missionAutomationInterval
            return false
        end

        later(state, "error", Router.isApiError(err) and err.message or tostring(err), retry)
        return false
    end

    return true
end

-- Set by handlers/programs.lua: returns the program's name when an enabled program drives
-- the craft. A program sends the craft out on missions itself, and two loops dispatching
-- one ship would each find it busy with the other's mission.
MissionAutomation.controlledBy = function() return nil end

local function pass()
    local t = now()
    local evaluated = false

    for _, index in ipairs(factionIndices()) do
        local data = loadFaction(index)
        local paired = escortIndex(data)
        local owner

        for _, shipName in ipairs(sortedKeys(data.ships)) do
            local rule = data.ships[shipName]
            local state = stateOf(index, shipName)
            local program = rule.enabled and not state.busy
                            and MissionAutomation.controlledBy(index, shipName)
            local escorting = paired[shipName]

            if not rule.enabled then
                if state.phase ~= "disabled" and not state.busy then
                    note(state, "disabled", "Automation is switched off for this craft.")
                end
            elseif escorting and not state.busy then
                -- its own rule would send it off just as its primary needs it
                note(state, "paired", "Escorts " .. escorting.primary .. "; its own rule waits "
                     .. "while it is paired.")
            elseif program then
                note(state, "program", "The program '" .. tostring(program) .. "' drives this "
                     .. "craft; its mission steps use this rule.")
            elseif not state.busy and t >= (state.nextCheckAt or 0) then
                owner = owner or ownerOf(index)

                local ok, started = pcall(considerRule, owner, index, shipName, rule, state,
                                          not evaluated)
                if not ok then
                    state.busy = false
                    later(state, "error", tostring(started), Config.missionAutomationRetry)
                elseif started then
                    evaluated = true
                end
            end
        end
    end
end

local sinceLastPass = 0

function MissionAutomation.tick(elapsed)
    -- sweeps move on every tick: each waits on nothing but a free analysis slot
    advanceSweeps()

    sinceLastPass = sinceLastPass + (elapsed or 0)
    if sinceLastPass < Config.missionAutomationInterval then return end
    sinceLastPass = 0

    pass()
end

-- #### ENDPOINTS #### --

local function requireManage(ctx, owner)
    if owner.kind == "alliance"
       and not owner.faction:hasPrivilege(ctx.playerIndex, AlliancePrivilege.ManageShips) then
        Router.fail(403, "missing_privilege",
                    "Your alliance rank does not allow managing alliance ships.")
    end
end

-- Goods named in a rule, spelt the way the goods table spells them. Matching at run time is
-- case-blind anyway; this catches a good that does not exist at all while someone is
-- still looking at the form.
local function canonicalGoods(rule)
    if not rule.goods then return end

    local byLower = {}
    for name, _ in pairs(goods) do byLower[string.lower(name)] = name end

    for _, side in ipairs({"prefer", "avoid"}) do
        local list = rule.goods[side] or {}
        for i, name in ipairs(list) do
            local known = byLower[string.lower(name)]
            if not known then
                Router.fail(400, "bad_rule", "Unknown good '" .. tostring(name) .. "' in 'goods."
                            .. side .. "'.")
            end
            list[i] = known
        end
    end
end

-- Every pair the owner has set up: an enabled rule with escorts, and who escorts it.
local function describePairs(owner, data)
    local result = Json.array({})

    for _, primary in ipairs(sortedKeys(data.ships)) do
        local rule = data.ships[primary]
        if rule.enabled and #(rule.escorts or {}) > 0 then
            local escorts = Json.array({})
            for _, escort in ipairs(MissionRules.escortList(rule)) do
                escorts[#escorts + 1] = {name = escort.name, required = escort.required}
            end
            result[#result + 1] = {owner = Owner.describe(owner), primary = primary, escorts = escorts}
        end
    end

    return result
end

-- The dry run's answer, in the same shape whether it came back at once or through a sweep.
local function dryRunBody(owner, shipName, rule, report, readiness)
    local body =
    {
        ship = shipName,
        owner = Owner.describe(owner),
        rule = describeRule(rule),
        evaluation = describeReport(report, rule),
        wouldStart = report.chosen ~= nil and readiness.waitingFor == nil,
        waitingFor = readiness.waitingFor,
        serverTime = now(),
    }

    -- The captain's read on whichever candidate heads the list, as the order window would
    -- show it for that config, in the area it was judged in.
    local head = report.chosen or report.candidates[1]
    if head then
        local ok, assessed = pcall(Missions.assess, owner, shipName, rule.mission,
                                   MissionTypes.typeOf(rule.mission), head.area,
                                   head.results, MissionRules.copy(head.config))
        if ok then body.assessment = assessed.body.assessment end
    end

    return body
end

function MissionAutomation.register(router)

    -- Every rule the caller can see, with what the loop is doing about each. Alliance
    -- rules come back to every member alike; that is what keeps two consoles in step.
    router:get("/automation/missions", function(ctx)
        local owners
        if ctx.query.owner == nil or ctx.query.owner == "all" then
            owners = Owner.all(ctx)
        else
            owners = {Owner.resolve(ctx)}
        end

        local automations = Json.array({})
        local pairList = Json.array({})

        for _, owner in ipairs(owners) do
            local data = loadFaction(owner.index)
            for _, shipName in ipairs(sortedKeys(data.ships)) do
                automations[#automations + 1] = describeEntry(owner, shipName, data.ships[shipName])
            end
            for _, pair in ipairs(describePairs(owner, data)) do pairList[#pairList + 1] = pair end
        end

        return
        {
            serverTime = now(),
            automations = automations,
            pairs = pairList,
            supported = Json.array(MissionRules.supportedList()),
            limits = Json.array(MissionRules.copy(MissionRules.limitNames)),
            criteria = Json.array(MissionRules.copy(MissionRules.criteriaList)),
        }
    end)

    router:get("/ships/{name}/mission/automation", function(ctx, params)
        local owner = Owner.findShip(ctx, params.name)
        local rule = loadFaction(owner.index).ships[params.name]

        local body = describeEntry(owner, params.name, rule)
        body.serverTime = now()

        return body
    end)

    -- Creates or updates the rule. Fields left out keep their stored values, so
    -- {"enabled": false} switches a craft off without touching anything else.
    router:post("/ships/{name}/mission/automation", function(ctx, params)
        local owner = Owner.findShip(ctx, params.name)
        requireManage(ctx, owner)

        local data = loadFaction(owner.index)
        local previous = data.ships[params.name]

        if ctx.body.ifRevision ~= nil then
            local current = previous and previous.revision or 0
            if ctx.body.ifRevision ~= current then
                Router.fail(409, "rule_changed",
                            "Someone changed this rule since you loaded it. Reload and apply "
                            .. "your change again.",
                            {revision = current,
                             rule = previous and describeRule(previous) or Json.null})
            end
        end

        local rule = MissionRules.normalize(ctx.body, previous)

        -- Checked now rather than at the first dispatch: a misspelt material or good is the
        -- caller's mistake, and the loop would otherwise report it every five minutes.
        MissionAutomation.checkRule(rule)
        checkPairing(owner, data, params.name, rule)

        rule.revision = (previous and previous.revision or 0) + 1
        rule.updatedBy = {index = ctx.playerIndex, name = Serialize.string(ctx.player.name, "")}
        rule.updatedAt = os.time()

        data.ships[params.name] = rule
        saveFaction(owner.index, data)

        local state = stateOf(owner.index, params.name)
        if not state.busy then
            state.nextCheckAt = 0
            if rule.enabled then
                note(state, "waiting", "Saved; checking on the next pass.",
                     "rule saved by " .. rule.updatedBy.name)
            else
                note(state, "disabled", "Automation is switched off for this craft.",
                     "switched off by " .. rule.updatedBy.name)
            end
        end

        local body = describeEntry(owner, params.name, rule)
        body.serverTime = now()

        return body
    end)

    router:post("/ships/{name}/mission/automation/delete", function(ctx, params)
        local owner = Owner.findShip(ctx, params.name)
        requireManage(ctx, owner)

        local data = loadFaction(owner.index)
        local existed = data.ships[params.name] ~= nil

        data.ships[params.name] = nil
        if existed then saveFaction(owner.index, data) end

        -- An evaluation in flight finds no rule when it lands and stands down by itself.
        local key = stateKey(owner.index, params.name)
        local state = states[key]
        if state and not state.busy then states[key] = nil end
        if dryRuns[key] and not dryRuns[key].running then dryRuns[key] = nil end

        return {ship = params.name, owner = Owner.describe(owner), deleted = existed}
    end)

    -- A dry run: the analysis and every candidate, ranked, with the reason each one would
    -- or would not go - and no start. The body is merged over the stored rule without
    -- saving it, so limits can be tried out before anything is committed.
    --
    -- A check over one area answers in the response. A sweep takes one analysis per area,
    -- far longer than a request may wait, so it answers 202 at once and its result lands in
    -- the craft's `dryRun`, which GET /ships/{name}/mission/automation serves.
    router:post("/ships/{name}/mission/automation/evaluate", function(ctx, params)
        local owner = Owner.findShip(ctx, params.name)
        local previous = loadFaction(owner.index).ships[params.name]
        local key = stateKey(owner.index, params.name)

        if dryRuns[key] and dryRuns[key].running then
            Router.fail(409, "evaluation_running", "A check of this craft is still running.",
                        {done = dryRuns[key].done, total = dryRuns[key].total})
        end

        local rule = MissionRules.normalize(ctx.body, previous)
        MissionAutomation.checkRule(rule)
        rule.revision = previous and previous.revision or 0

        local authIndex = owner.kind == "alliance" and ctx.playerIndex or owner.index

        -- Optional escorts not ready are left out, as the loop would. A required one is
        -- kept - the loop would wait for it, and the figures are those of the pair - and
        -- named in `waitingFor`.
        local going, missing, left = muster(owner, owner.index, params.name, rule)
        local readiness = {}
        if missing then
            going[#going + 1] = missing.name
            readiness.waitingFor = {escort = missing.name, problem = missing.problem}
        end
        local flying = flownWith(rule, going)

        local async, dry
        local total = evaluate(owner, params.name, flying, authIndex,
        {
            progress = function(done, count)
                if dry then dry.done = done; dry.total = count end
            end,
            done = function(report)
                report.escorts = {going = going, left = left}
                local ok, body = pcall(dryRunBody, owner, params.name, flying, report, readiness)
                if not ok then
                    local failure = {code = "evaluation_failed", message = tostring(body)}
                    if async then
                        dry.running = false
                        dry.error = failure
                    else
                        ctx.complete(500, {error = failure})
                    end
                    return
                end

                if async then
                    dry.running = false
                    dry.finishedAt = now()
                    dry.result = body
                else
                    ctx.complete(200, body)
                end
            end,
            failed = function(code, message)
                if async then
                    dry.running = false
                    dry.finishedAt = now()
                    dry.error = {code = code, message = message}
                else
                    ctx.complete(code == "analysis_failed" and 504 or 500,
                                 {error = {code = code, message = message}})
                end
            end,
        })

        if total <= 1 then return Router.DEFERRED end

        -- never answered through ctx.complete: the request is answered here and now
        async = true
        dry =
        {
            running = true,
            done = 0,
            total = total,
            startedAt = now(),
            by = Serialize.string(ctx.player.name, ""),
        }
        dryRuns[key] = dry

        return 202,
        {
            ship = params.name,
            owner = Owner.describe(owner),
            evaluating = true,
            dryRun = dry,
            serverTime = now(),
        }
    end)

end

-- #### FOR PROGRAMS #### --

-- A program's owner and authority are found exactly as a rule's are.
MissionAutomation.ownerOf = ownerOf
MissionAutomation.hasPrivilege = hasPrivilege

-- Raises the error a save would for a rule whose config cannot be built (an unknown material,
-- say) or that names a good that does not exist, for callers storing rules of their own: the
-- mission library. Goods are rewritten to the goods table's spelling.
function MissionAutomation.checkRule(rule)
    baseConfigOf(rule)
    canonicalGoods(rule)
end

-- The craft's stored rule, or nil.
function MissionAutomation.ruleFor(index, shipName)
    return loadFaction(index).ships[shipName]
end

-- One dispatch under `rule`, for a program's mission step: the same escorts, analysis,
-- limits and start the loop runs, but once, and answering through callbacks rather than
-- into a rule's state. onStarted(summary) once the ship is out; onFailed(code, message)
-- otherwise, including when nothing passes the limits or a required escort is not ready.
-- onProgress(done, total), if given, after each area a sweep analyses - a sweep can take
-- longer than a program waits for an answer without one.
function MissionAutomation.startOnce(owner, shipName, rule, authIndex, onStarted, onFailed, onProgress)
    local availability = owner.faction:getShipAvailability(shipName)
    if availability ~= ShipAvailability.Available then
        onFailed("ship_unavailable", "The craft is not available to send out.")
        return
    end

    local going, missing, left = muster(owner, owner.index, shipName, rule)
    if missing then
        onFailed("escort_unavailable", "Escort " .. missing.name .. " is not ready: "
                 .. missing.problem .. ".")
        return
    end

    local flying = flownWith(rule, going)

    local okEvaluate, err = pcall(evaluate, owner, shipName, flying, authIndex,
    {
        progress = onProgress,
        done = function(report)
            if not report.chosen then
                local nearest = report.candidates[1]
                onFailed("nothing_within_limits", "Nothing within the limits: "
                         .. (nearest and violationText(nearest)
                             or "no way to fly this mission was found in the area"))
                return
            end

            local chosen = report.chosen

            Missions.enqueue
            {
                kind = "start",
                owner = owner,
                playerIndex = authIndex,
                shipName = shipName,
                missionType = MissionTypes.typeOf(rule.mission),
                area = Missions.plainArea(chosen.area),
                config = Missions.plainConfig(chosen.config),
                complete = function(status, body)
                    local e = type(body) == "table" and body.error or {}
                    onFailed(e.code or ("http_" .. tostring(status)), e.message)
                end,
                onResult = function(result)
                    if not result.started then
                        onFailed(result.code or "start_rejected", result.message
                                 or "the game refused the start; its reason went to the owner as chat")
                        return
                    end

                    local summary = dispatchSummary(rule, chosen)
                    if #left > 0 then summary = summary .. "; " .. leftText(left) end
                    onStarted(summary)
                end,
            }
        end,
        failed = function(code, message) onFailed(code, message) end,
    })

    if not okEvaluate then
        if Router.isApiError(err) then onFailed(err.code, err.message)
        else onFailed("evaluation_failed", tostring(err)) end
    end
end

-- For tests: forget in-memory state, as a server restart would.
function MissionAutomation.resetState()
    states = {}
    cache = {}
    dryRuns = {}
    sweeps = {}
    sinceLastPass = 0
end

return MissionAutomation
