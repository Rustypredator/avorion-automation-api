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
-- every config worth trying against one area analysis, then the ordinary start job. So an
-- automated start can never be one the preview endpoint would have refused.

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

-- The rectangle a rule flies this time. A "ship" area follows the craft, so a trade ship
-- that ended its last contract somewhere else looks for routes around where it is now.
local function areaFor(command, owner, shipName, spec)
    spec = spec or {mode = "ship"}

    if spec.mode == "fixed" then
        return
        {
            lower = {x = spec.lower.x, y = spec.lower.y},
            upper = {x = spec.upper.x, y = spec.upper.y},
        }
    end

    local size
    for _, candidate in ipairs({command:getAreaSize(owner.index, shipName)}) do
        if type(candidate) == "table" then
            if not size then size = candidate end
            if spec.size and candidate.x == spec.size.x and candidate.y == spec.size.y then
                size = candidate
                break
            end
        end
    end

    if not size then
        Router.fail(500, "no_area_size", "The game did not report an area size for this mission.")
    end

    local x, y = owner.faction:getShipPosition(shipName)
    if type(x) ~= "number" or type(y) ~= "number" then
        Router.fail(409, "no_position", "The ship's position is unknown.")
    end

    local placement = spec.placement or {fx = 0.5, fy = 0.5}
    local lowerX = math.floor(x) - placementOffset(placement.fx, size.x)
    local lowerY = math.floor(y) - placementOffset(placement.fy, size.y)

    return
    {
        lower = {x = lowerX, y = lowerY},
        upper = {x = lowerX + size.x - 1, y = lowerY + size.y - 1},
    }
end

-- #### EVALUATION #### --

local function firstError(errors)
    if type(errors) ~= "table" then return nil end

    if type(errors.usable) == "table" then
        return errors.usable.message or errors.usable.code
    end

    for _, name in ipairs({"command", "prediction", "start"}) do
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

-- Every candidate against one analysed area, ranked. Runs on the bridge's tick inside
-- the analysis callback.
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
        }
    end

    MissionRules.rank(evaluated, rule.objective)

    local best = evaluated[1]

    return
    {
        area = area,
        results = results,
        candidates = evaluated,
        chosen = best and #best.violations == 0 and best or nil,
        money = money,
        at = now(),
    }
end

-- Runs one area analysis and judges every candidate against it. Raises an API error when
-- the analysis cannot even be started - a slot busy, a bad material name - so callers
-- decide whether that is a response or a retry.
local function evaluate(owner, shipName, rule, authIndex, onDone, onFail)
    local missionType = MissionTypes.typeOf(rule.mission)
    local command = MissionTypes.make(missionType, shipName, nil, {})

    local base = baseConfigOf(rule)
    local area = areaFor(command, owner, shipName, rule.area)

    Analysis.start(owner.index, authIndex or owner.index, shipName, missionType, area,
        function(analyzed, results)
            local ok, report = pcall(judge, owner, shipName, rule, authIndex, analyzed, results, base)

            if not ok then
                if Router.isApiError(report) then
                    onFail(report.code, report.message)
                else
                    onFail("evaluation_failed", tostring(report))
                end
                return
            end

            onDone(report)
        end,
        function(reason) onFail("analysis_failed", reason) end)
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

local function routeOf(report, goodName)
    if not goodName or type(report.results) ~= "table" then return nil end

    for _, route in ipairs(report.results.routes or {}) do
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

local function describeCandidate(report, rule, candidate)
    local violations = Json.array({})
    for _, v in ipairs(candidate.violations) do
        violations[#violations + 1] = {limit = v.limit, message = v.message}
    end

    return
    {
        passes = #candidate.violations == 0,
        config = MissionTypes.describeConfig(rule.mission, candidate.config),
        route = routeOf(report, candidate.config.goodName),
        metrics = describeMetrics(candidate.metrics),
        violations = violations,
    }
end

local function violationText(candidate)
    local parts = {}
    for _, v in ipairs(candidate.violations) do parts[#parts + 1] = v.message end
    return table.concat(parts, "; ")
end

local function describeReport(report, rule)
    local candidates = Json.array({})
    local passing = 0

    for index, candidate in ipairs(report.candidates) do
        if #candidate.violations == 0 then passing = passing + 1 end
        if index <= Config.missionAutomationReportedCandidates then
            candidates[#candidates + 1] = describeCandidate(report, rule, candidate)
        end
    end

    return
    {
        at = report.at,
        objective = rule.objective,
        area =
        {
            lower = Serialize.vec2(report.area.lower.x, report.area.lower.y),
            upper = Serialize.vec2(report.area.upper.x, report.area.upper.y),
        },
        tried = #report.candidates,
        passing = passing,
        money = report.money,
        chosen = report.chosen and describeCandidate(report, rule, report.chosen) or nil,
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
    return described
end

local function describeEntry(owner, shipName, rule)
    local state = states[stateKey(owner.index, shipName)]

    return
    {
        ship = shipName,
        owner = Owner.describe(owner),
        rule = rule and describeRule(rule) or nil,
        state = describeState(state),
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
        area = Missions.plainArea(report.area),
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
                candidate = describeCandidate(report, rule, chosen),
            }
            state.dispatchedRevision = rule.revision
            state.nextCheckAt = now() + Config.missionAutomationRecheck
            note(state, "running", "Out on a mission it was sent on.", state.lastDispatch.summary)
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

    -- One evaluation per pass, and never the last analysis slot: a person previewing a
    -- mission in the console should not be told the server is busy because of a timer.
    local ceiling = math.max(1, Config.maxConcurrentAnalyses - 1)
    if not mayEvaluate or Analysis.activeCount() >= ceiling then
        note(state, "waiting", "Waiting for a free area analysis.")
        state.nextCheckAt = 0
        return false
    end

    if rule.collectYields then
        pcall(collectYields, owner, shipName, authIndex, state)
    end

    state.busy = true
    note(state, "evaluating", "Analysing the area and checking the limits.")

    local okEvaluate, err = pcall(evaluate, owner, shipName, rule, authIndex,
        function(report)
            state.busy = false
            state.lastEvaluation = describeReport(report, rule)

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

            dispatch(owner, index, shipName, current, authIndex, report, state)
        end,
        function(code, message)
            state.busy = false
            later(state, "error", string.format("The check failed (%s): %s", tostring(code),
                                                tostring(message)), retry)
        end)

    if not okEvaluate then
        state.busy = false

        if Router.isApiError(err) and (err.code == "analysis_busy"
                                       or err.code == "analysis_in_progress") then
            note(state, "waiting", "Waiting for a free area analysis.")
            state.nextCheckAt = now() + Config.missionAutomationInterval
            return false
        end

        later(state, "error", Router.isApiError(err) and err.message or tostring(err), retry)
        return false
    end

    return true
end

local function pass()
    local t = now()
    local evaluated = false

    for _, index in ipairs(factionIndices()) do
        local data = loadFaction(index)
        local owner

        for _, shipName in ipairs(sortedKeys(data.ships)) do
            local rule = data.ships[shipName]
            local state = stateOf(index, shipName)

            if not rule.enabled then
                if state.phase ~= "disabled" and not state.busy then
                    note(state, "disabled", "Automation is switched off for this craft.")
                end
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

        for _, owner in ipairs(owners) do
            local data = loadFaction(owner.index)
            for _, shipName in ipairs(sortedKeys(data.ships)) do
                automations[#automations + 1] = describeEntry(owner, shipName, data.ships[shipName])
            end
        end

        return
        {
            serverTime = now(),
            automations = automations,
            supported = Json.array(MissionRules.supportedList()),
            limits = Json.array(MissionRules.copy(MissionRules.limitNames)),
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

        -- Checked now rather than at the first dispatch: a misspelt material is the
        -- caller's mistake, and the loop would otherwise report it every five minutes.
        baseConfigOf(rule)

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
        local state = states[stateKey(owner.index, params.name)]
        if state and not state.busy then states[stateKey(owner.index, params.name)] = nil end

        return {ship = params.name, owner = Owner.describe(owner), deleted = existed}
    end)

    -- A dry run: the analysis and every candidate, ranked, with the reason each one would
    -- or would not go - and no start. The body is merged over the stored rule without
    -- saving it, so limits can be tried out before anything is committed.
    router:post("/ships/{name}/mission/automation/evaluate", function(ctx, params)
        local owner = Owner.findShip(ctx, params.name)
        local previous = loadFaction(owner.index).ships[params.name]

        local rule = MissionRules.normalize(ctx.body, previous)
        rule.revision = previous and previous.revision or 0

        local authIndex = owner.kind == "alliance" and ctx.playerIndex or owner.index

        evaluate(owner, params.name, rule, authIndex,
            function(report)
                local body =
                {
                    ship = params.name,
                    owner = Owner.describe(owner),
                    rule = describeRule(rule),
                    evaluation = describeReport(report, rule),
                    wouldStart = report.chosen ~= nil,
                    serverTime = now(),
                }

                -- The captain's read on whichever candidate heads the list, as the order
                -- window would show it for that config.
                local head = report.chosen or report.candidates[1]
                if head then
                    local ok, assessed = pcall(Missions.assess, owner, params.name, rule.mission,
                                               MissionTypes.typeOf(rule.mission), report.area,
                                               report.results, MissionRules.copy(head.config))
                    if ok then body.assessment = assessed.body.assessment end
                end

                ctx.complete(200, body)
            end,
            function(code, message)
                ctx.complete(code == "analysis_failed" and 504 or 500,
                             {error = {code = code, message = message}})
            end)

        return Router.DEFERRED
    end)

end

-- For tests: forget in-memory state, as a server restart would.
function MissionAutomation.resetState()
    states = {}
    cache = {}
    sinceLastPass = 0
end

return MissionAutomation
