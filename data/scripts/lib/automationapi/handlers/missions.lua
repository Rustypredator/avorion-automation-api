-- Captain missions: catalog, preview, start, status, recall, collect.
--
-- Missions run in the background simulation, which addresses ships by (faction, name) and
-- never touches sectors - so these endpoints reach ships anywhere in the galaxy without
-- loading anything.
--
-- Preview is a genuine dry run rather than an approximation: it calls the same
-- calculatePrediction and getErrors the game's own order window calls, on the same area
-- analysis a start would use.

package.path = package.path .. ";data/scripts/player/background/simulation/?.lua"

local Json = include("automationapi/json")
local Router = include("automationapi/router")
local Serialize = include("automationapi/serialize")
local Owner = include("automationapi/owner")
local ShipData = include("automationapi/shipdata")
local MissionTypes = include("automationapi/missiontypes")
local Analysis = include("automationapi/analysis")
local FactionScope = include("automationapi/factionscope")

local SimulationUtility = include("simulationutility")

local Missions = {}

-- #### HELPERS #### --

-- Simulation is deliberately NOT called from here. It lives on the Player, and a galaxy
-- script calling Player:invokeFunction segfaults the server - no error, no return code,
-- the process dies. Verified against 2.5.13 using the exact call shape vanilla uses, and
-- corroborated by the vanilla tree: every caller of simulation.lua is a player script.
-- Everything that needs Simulation goes through the job queue below and is executed by
-- player/automationapi/agent.lua.

function Missions.requireOnline(owner)
    local ok, online = pcall(function() return Server():isOnline(owner.index) end)

    if not ok or not online then
        Router.fail(409, "owner_offline",
                    "Writes need the owning player online: the game only runs a player's "
                    .. "scripts while they are logged in, so nothing can be dispatched on "
                    .. "their behalf. This is a vanilla limitation, not one this API adds. "
                    .. "Reads work offline.")
    end
end

-- Only plain numbers cross the script boundary. The analysis results table is full of
-- engine userdata (materials, trading goods, faction handles) and passing it through
-- invokeFunction segfaults the server outright, so nothing but this ever gets handed over.
local function plainArea(area)
    return
    {
        lower = {x = math.floor(area.lower.x), y = math.floor(area.lower.y)},
        upper = {x = math.floor(area.upper.x), y = math.floor(area.upper.y)},
    }
end

-- Same reasoning as plainArea, for the config table. clampConfig runs vanilla code over
-- it and Json.array leaves a metatable behind; neither belongs on the other side of the
-- boundary, so the table is rebuilt from scratch out of numbers, strings and booleans.
local function plainConfig(config)
    local result = {}

    for key, value in pairs(config or {}) do
        local keyType = type(key)

        if keyType == "string" or keyType == "number" then
            local valueType = type(value)

            if valueType == "table" then
                result[key] = plainConfig(value)
            elseif valueType == "number" or valueType == "string"
                   or valueType == "boolean" then
                result[key] = value
            end
        end
    end

    return result
end

local function ignoredErrorsOf(command)
    if not command.getIgnoredErrors then return nil end

    local ok, ignored = pcall(function() return command:getIgnoredErrors() end)
    return ok and ignored or nil
end

-- #### CATALOG #### --

local function describeConfigurable(command, ownerIndex, shipName)
    local ok, values = pcall(function()
        return command:getConfigurableValues(ownerIndex, shipName)
    end)

    if not ok or type(values) ~= "table" then return {} end

    local result = {}
    for name, properties in pairs(values) do
        result[name] =
        {
            from = Serialize.number(properties.from),
            to = Serialize.number(properties.to),
            default = Serialize.value(properties.default),
            displayName = Serialize.string(properties.displayName),
        }
    end

    return result
end

local function boolCall(command, methodName, ownerIndex, shipName)
    if not command[methodName] then return false end

    local ok, value = pcall(function() return command[methodName](command, ownerIndex, shipName) end)

    return ok and value == true
end

local function describeMission(key, ownerIndex, shipName)
    local command = MissionTypes.make(MissionTypes.typeOf(key), shipName, nil, {})

    local predictable = {}
    if command.getPredictableValues then
        local ok, values = pcall(function() return command:getPredictableValues() end)
        if ok then predictable = values end
    end

    local described =
    {
        mission = key,
        areaSizes = MissionTypes.describeAreaSizes(command, ownerIndex, shipName),
        -- a fixed area is recentred on the ship server-side whatever the caller asks for
        areaFixed = boolCall(command, "isAreaFixed", ownerIndex, shipName),
        shipRequiredInArea = boolCall(command, "isShipRequiredInArea", ownerIndex, shipName),
        configurable = describeConfigurable(command, ownerIndex, shipName),
        predictable = Serialize.value(predictable),
    }

    if MissionTypes.usesMaterials(key) then
        described.materials = Json.array(MissionTypes.materialList())
    end

    return described
end

-- #### PREVIEW AND START #### --

-- Validates and predicts against a completed analysis. Shared by preview and start so the
-- two can never disagree about whether a mission is startable.
local function assess(owner, shipName, key, missionType, area, results, config)
    area.analysis = results

    local command = MissionTypes.make(missionType, shipName, area, config)
    MissionTypes.clampConfig(command, owner.index, shipName)

    local usable = ShipData.usable(owner.index, shipName, ignoredErrorsOf(command))

    -- Both of these are vanilla code running on data vanilla does not usually hand it.
    -- TravelCommand:calculatePrediction, for one, indexes the captain without checking,
    -- so previewing a travel mission for a captainless ship raises rather than returning
    -- an error - and a request about a perfectly ordinary ship would become a 500. The
    -- failure is caught and reported as what it is: something wrong with the ship, not
    -- with the request.
    local commandError, commandArgs
    local commandFailure

    local okErrors, errorText, errorArgs = pcall(function()
        return FactionScope.with(owner.faction, function()
            return command:getErrors(owner.index, shipName, area, command.config)
        end)
    end)

    if okErrors then
        commandError, commandArgs = errorText, errorArgs
    else
        commandFailure = tostring(errorText)
    end

    local predictionFailure

    local okPrediction, predicted = pcall(function()
        return FactionScope.with(owner.faction, function()
            return command:calculatePrediction(owner.index, shipName, area, command.config)
        end)
    end)

    local prediction = okPrediction and (predicted or {}) or {}
    if not okPrediction then predictionFailure = tostring(predicted) end

    -- The captain's own read on the job. Needs a captain, so a captainless ship simply
    -- has no assessment - the usable check already reports why.
    local assessment = Json.array({})

    local entry = ShipDatabaseEntry(owner.index, shipName)
    local captain
    if entry then
        local ok, found = pcall(function() return entry:getCaptain() end)
        if ok then captain = found end
    end

    if captain and command.generateAssessmentFromPrediction then
        local ok, lines = pcall(function()
            return FactionScope.with(owner.faction, function()
                return command:generateAssessmentFromPrediction(prediction, captain,
                                                                owner.index, shipName,
                                                                area, command.config)
            end)
        end)

        if ok and type(lines) == "table" then
            -- the vanilla generators build a fixed set of slots and leave some empty, so
            -- the table is sparse and ipairs would stop at the first gap
            local indices = {}
            for index, _ in pairs(lines) do
                if type(index) == "number" then indices[#indices + 1] = index end
            end
            table.sort(indices)

            for _, index in ipairs(indices) do
                local text = Serialize.displayName(lines[index])
                if text and text ~= "" then assessment[#assessment + 1] = text end
            end
        end
    end

    -- NB: `usable.ok and nil or usable` cannot be used here - in Lua that expression
    -- always evaluates to the right-hand side, which would make canStart permanently false
    local errors =
    {
        command = Serialize.message(commandError, commandArgs),
        prediction = Serialize.message(prediction.error, prediction.errorArgs),
    }

    if not usable.ok then errors.usable = usable end

    if commandFailure and not errors.command then
        errors.command = Serialize.message(
            "The game could not validate this mission for this ship: ${reason}",
            {reason = commandFailure})
    end

    if predictionFailure and not errors.prediction then
        errors.prediction = Serialize.message(
            "The game could not predict this mission for this ship: ${reason}",
            {reason = predictionFailure})
    end

    -- The game validates twice: once through getErrors, which preview reaches, and again
    -- inside command:initialize(), which only a start reaches. Whatever of the second
    -- round can be answered from the analysis is folded in here, so canStart means what
    -- it says instead of "canStart, probably".
    local startError = MissionTypes.startErrors(key, owner, shipName, area)
    if startError then errors.start = Serialize.message(startError) end

    local areaStats
    local okStats, stats = pcall(function() return SimulationUtility.getAreaStats(area) end)
    if okStats then areaStats = Serialize.value(stats) end

    return
    {
        command = command,
        body =
        {
            mission = key,
            ship = shipName,
            owner = Owner.describe(owner),
            area =
            {
                lower = Serialize.vec2(area.lower.x, area.lower.y),
                upper = Serialize.vec2(area.upper.x, area.upper.y),
                origin = area.origin and Serialize.vec2(area.origin.x, area.origin.y) or nil,
                stats = areaStats,
            },
            config = MissionTypes.describeConfig(key, command.config),
            prediction = Serialize.value(prediction),
            assessment = assessment,
            errors = errors,
            canStart = errors.usable == nil
                       and errors.command == nil
                       and errors.prediction == nil
                       and errors.start == nil,
        },
    }
end

-- Runs an analysis and calls back with the assessment. Returns Router.DEFERRED.
local function withAssessment(ctx, params, onAssessed)
    local key = string.lower(params.key or "")
    local missionType = MissionTypes.require(key)

    local owner = Owner.findShip(ctx, params.name)
    local shipName = params.name

    local command = MissionTypes.make(missionType, shipName, nil, {})
    local config = MissionTypes.buildConfig(key, ctx.body)
    local area = MissionTypes.buildArea(command, owner.index, shipName, ctx.body)

    Analysis.start(owner.index, ctx.playerIndex, shipName, missionType, area,
        function(analyzedArea, results)
            local ok, err = pcall(function()
                local assessed = assess(owner, shipName, key, missionType, analyzedArea, results, config)
                onAssessed(assessed, analyzedArea, results, owner, shipName, key, missionType)
            end)

            if not ok then
                if Router.isApiError(err) then
                    ctx.complete(err.status, {error = {code = err.code, message = err.message,
                                                       details = err.details}})
                else
                    ctx.complete(500, {error = {code = "internal_error", message = tostring(err)}})
                end
            end
        end,
        function(reason)
            ctx.complete(504, {error = {code = "analysis_failed", message = reason}})
        end)

    return Router.DEFERRED
end

-- The queue of missions waiting to be started.
--
-- Two constraints shape it. First, startCommand refuses unless Simulation already holds a
-- matching analysis it ran itself, and there is no way to be told when one finishes -
-- handing over the analysis this mod computed is not an option (see plainArea) - so the
-- game is asked to run its own and startCommand is retried until it takes.
--
-- Second, and the reason the work happens somewhere else entirely: Simulation lives on
-- the Player, and a galaxy script calling Player:invokeFunction segfaults the server -
-- no error, no return code, the process dies. Verified against 2.5.13 with the exact call
-- shape vanilla uses. No vanilla galaxy script makes that call either; every caller of
-- simulation.lua is a player script. So this queue only ever holds plain data, and
-- player/automationapi/agent.lua drains it and does the talking.
local pendingJobs = {}
local nextJobId = 0

-- How long a job may live before the request gives up. This has to sit between the
-- agent's worst case for a start (1.0s + 5 retries at 1.5s = 8.5s) and Config.requestTimeout,
-- or a slow-but-succeeding start would be reported as a failure.
local JOB_TIMEOUT = 12

Missions.uptime = 0

-- Called by the bridge on behalf of the player agent. Returns a JSON string rather than
-- a table: tables are known to cross Player->Simulation safely because vanilla does it,
-- but nothing proves it for the galaxy boundary, and after the segfault above this code
-- does not assume. Strings are proven.
function Missions.takeJobs(playerIndex)
    local claimed = {}

    for _, job in ipairs(pendingJobs) do
        if job.playerIndex == playerIndex and not job.claimed then
            job.claimed = true

            claimed[#claimed + 1] =
            {
                id = job.id,
                kind = job.kind,
                ownerKind = job.owner.kind,
                shipName = job.shipName,
                missionType = job.missionType,
                area = job.area,
                config = job.config,
                force = job.force,
                -- in-sector orders; see handlers/movement.lua
                sector = job.sector,
                clear = job.clear,
                calls = job.calls,
            }
        end
    end

    if #claimed == 0 then return "" end

    return Json.encode(Json.array(claimed))
end

-- Called by the bridge when the agent reports back. Each result resolves one request.
function Missions.report(payload)
    local ok, results = pcall(Json.decode, payload)
    if not ok or type(results) ~= "table" then return false end

    for _, result in ipairs(results) do
        for index, job in ipairs(pendingJobs) do
            if job.id == result.id then
                table.remove(pendingJobs, index)

                if result.ok == false and job.kind ~= "start" then
                    job.complete(502, {error =
                    {
                        code = result.code or "simulation_call_failed",
                        message = result.message
                                  or "The background simulation refused the call.",
                    }})
                    break
                end

                local handled, err = pcall(job.onResult, result)
                if not handled then
                    job.complete(500, {error = {code = "internal_error",
                                                message = tostring(err)}})
                end

                break
            end
        end
    end

    return true
end

-- Parks a unit of work for the agent. onResult(result) resolves the request; it is
-- called on the bridge's own tick, so it may complete the response directly.
function Missions.enqueue(job)
    nextJobId = nextJobId + 1

    job.id = nextJobId
    job.expiresAt = Missions.uptime + JOB_TIMEOUT
    pendingJobs[#pendingJobs + 1] = job

    return Router.DEFERRED
end

function Missions.tick(elapsed)
    Missions.uptime = Missions.uptime + (elapsed or 0)

    local remaining = {}

    for _, job in ipairs(pendingJobs) do
        if Missions.uptime < job.expiresAt then
            remaining[#remaining + 1] = job
        else
            job.complete(409, {error =
            {
                code = "agent_unavailable",
                message = "The owner's player agent did not pick the request up. The "
                          .. "owning player has to be logged in.",
            }})
        end
    end

    pendingJobs = remaining
end

-- Exposed rather than registered inline: POST /ships/{name}/travel is the same start,
-- with the mission type fixed and the destination validated first, and the two must not
-- be allowed to drift apart. See handlers/movement.lua.
function Missions.startHandler(ctx, params)
    return withAssessment(ctx, params,
        function(assessed, area, results, owner, shipName, key, missionType)
            local body = assessed.body

            if not body.canStart then
                body.started = false
                ctx.complete(422, body)
                return
            end

            Missions.requireOnline(owner)

            -- Nothing here talks to the simulation; see the note on pendingJobs.
            Missions.enqueue
            {
                kind = "start",
                owner = owner,
                playerIndex = ctx.playerIndex,
                shipName = shipName,
                missionType = missionType,
                area = plainArea(area),
                config = plainConfig(assessed.command.config),
                complete = ctx.complete,
                onResult = function(result)
                    body.started = result.started == true

                    if result.started then
                        ctx.complete(200, body)
                    else
                        body.error =
                        {
                            code = result.code or "start_rejected",
                            message = result.message
                                      or "The game did not start the mission. Its reason, "
                                         .. "if any, was sent to the owner as an in-game "
                                         .. "chat message.",
                        }
                        ctx.complete(422, body)
                    end
                end,
            }
        end)
end

-- #### ENDPOINTS #### --

function Missions.register(router)

    router:get("/missions", function(ctx)
        local result = Json.array({})
        for _, key in ipairs(MissionTypes.keys()) do
            result[#result + 1] = {mission = key, startable = MissionTypes.isStartable(key)}
        end

        return {missions = result, materials = Json.array(MissionTypes.materialList())}
    end)

    -- Area sizes and configurable ranges depend on the ship's captain, so the useful
    -- catalog is per ship rather than global.
    router:get("/ships/{name}/missions", function(ctx, params)
        local owner = Owner.findShip(ctx, params.name)

        local result = Json.array({})
        for _, key in ipairs(MissionTypes.keys()) do
            if MissionTypes.isStartable(key) then
                local ok, described = pcall(describeMission, key, owner.index, params.name)
                if ok then result[#result + 1] = described end
            end
        end

        return
        {
            ship = params.name,
            owner = Owner.describe(owner),
            usable = ShipData.usable(owner.index, params.name),
            missions = result,
        }
    end)

    -- Side-effect free. Runs the same analysis, validation and prediction a start would.
    router:post("/ships/{name}/missions/{key}/preview", function(ctx, params)
        return withAssessment(ctx, params, function(assessed)
            ctx.complete(200, assessed.body)
        end)
    end)

    router:post("/ships/{name}/missions/{key}/start", Missions.startHandler)


    router:get("/ships/{name}/mission", function(ctx, params)
        local owner = Owner.findShip(ctx, params.name)

        local availability = owner.faction:getShipAvailability(params.name)
        if availability ~= ShipAvailability.InBackground then
            return {ship = params.name, active = false,
                    availability = "Available", status = nil}
        end

        Missions.requireOnline(owner)

        return Missions.enqueue
        {
            kind = "status",
            owner = owner,
            playerIndex = ctx.playerIndex,
            shipName = params.name,
            complete = ctx.complete,
            onResult = function(result)
                local data = result.data or {}
                local description = data.description
                local uiData = data.uiData

                local body =
                {
                    ship = params.name,
                    owner = Owner.describe(owner),
                    active = true,
                    availability = "InBackground",
                    yields = Serialize.number(data.yields, 0),
                }

                if type(description) == "table" then
                    body.mission = MissionTypes.keyOf(description.command)
                    body.progress = description.progress
                    body.area = description.area
                    body.escorting = description.escortee
                end

                if type(uiData) == "table" then
                    body.config = uiData.config
                    body.prediction = uiData.prediction
                    body.areaStats = uiData.area
                end

                ctx.complete(200, body)
            end,
        }
    end)

    router:post("/ships/{name}/mission/recall", function(ctx, params)
        local owner = Owner.findShip(ctx, params.name)
        Missions.requireOnline(owner)

        local force = ctx.query.force == "true" or ctx.body.force == true

        return Missions.enqueue
        {
            kind = "recall",
            owner = owner,
            playerIndex = ctx.playerIndex,
            shipName = params.name,
            force = force,
            complete = ctx.complete,
            onResult = function(result)
                local stillOut = (result.data or {}).active == true

                ctx.complete(200,
                {
                    ship = params.name,
                    recalled = not stillOut,
                    forced = force,
                    -- a command may refuse recall, e.g. a ship mid-repair
                    note = stillOut
                           and "Still on mission; the command refused the recall. "
                               .. "Retry with force=true."
                           or nil,
                })
            end,
        }
    end)

    router:post("/ships/{name}/mission/collect", function(ctx, params)
        local owner = Owner.findShip(ctx, params.name)
        Missions.requireOnline(owner)

        return Missions.enqueue
        {
            kind = "collect",
            owner = owner,
            playerIndex = ctx.playerIndex,
            shipName = params.name,
            complete = ctx.complete,
            onResult = function(result)
                local data = result.data or {}
                local before = Serialize.number(data.before, 0)
                local after = Serialize.number(data.after, 0)

                ctx.complete(200, {ship = params.name,
                                   collected = before - after, remaining = after})
            end,
        }
    end)

end

return Missions
