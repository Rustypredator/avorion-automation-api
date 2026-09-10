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

local SIMULATION_SCRIPT = "data/scripts/player/background/simulation/simulation.lua"

local Missions = {}

-- #### HELPERS #### --

-- Player:invokeFunction returns a status int first: 0 on success, 3 script not found,
-- 4 function not found, 5 invalid script state.
local function invokeSimulation(owner, functionName, ...)
    local ok, status, a, b = pcall(function(...)
        return owner.faction:invokeFunction(SIMULATION_SCRIPT, functionName, ...)
    end, ...)

    if not ok then
        Router.fail(500, "simulation_call_failed",
                    "Could not call " .. functionName .. ": " .. tostring(status))
    end

    if status ~= 0 then
        Router.fail(409, "simulation_unavailable",
                    "The background simulation is not running for this owner (code "
                    .. tostring(status) .. "). The owning player has to be logged in.",
                    {functionName = functionName})
    end

    return a, b
end

-- Mission state lives in a script attached to the Player or Alliance, and those scripts
-- only exist while that player is in game. Reads work regardless; writes do not.
local function requireOnline(owner)
    local ok, online = pcall(function() return Server():isOnline(owner.index) end)

    if not ok or not online then
        Router.fail(409, "owner_offline",
                    "Captain missions only run while the owning player is logged in. "
                    .. "This is a vanilla limitation, not one this API adds.")
    end
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

    local commandError, commandArgs = FactionScope.with(owner.faction, function()
        return command:getErrors(owner.index, shipName, area, command.config)
    end)

    local prediction = FactionScope.with(owner.faction, function()
        return command:calculatePrediction(owner.index, shipName, area, command.config)
    end)

    prediction = prediction or {}

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
                       and errors.prediction == nil,
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

    router:post("/ships/{name}/missions/{key}/start", function(ctx, params)
        return withAssessment(ctx, params,
            function(assessed, area, results, owner, shipName, key, missionType)
                local body = assessed.body

                if not body.canStart then
                    body.started = false
                    ctx.complete(422, body)
                    return
                end

                requireOnline(owner)

                -- startCommand refuses to run without a matching analysis already stored
                -- in Simulation, and reports failures by chat message with no return
                -- value. So: hand it our analysis, start, then verify by reading the
                -- ship's availability back.
                invokeSimulation(owner, "areaAnalysisFinished", shipName, missionType,
                                 area, results, ctx.playerIndex)
                invokeSimulation(owner, "startCommand", shipName, missionType,
                                 assessed.command.config)

                local availability = owner.faction:getShipAvailability(shipName)
                body.started = availability == ShipAvailability.InBackground

                if not body.started then
                    body.error =
                    {
                        code = "start_rejected",
                        message = "The game rejected the command. Its reason was sent to "
                                  .. "the owner as an in-game chat message.",
                    }
                    ctx.complete(422, body)
                    return
                end

                ctx.complete(200, body)
            end)
    end)

    router:get("/ships/{name}/mission", function(ctx, params)
        local owner = Owner.findShip(ctx, params.name)

        local availability = owner.faction:getShipAvailability(params.name)
        if availability ~= ShipAvailability.InBackground then
            return {ship = params.name, active = false,
                    availability = "Available", status = nil}
        end

        requireOnline(owner)

        local description = invokeSimulation(owner, "getDescription", params.name)
        local uiData, descriptionArgs = invokeSimulation(owner, "getCommandUIData", params.name)

        local result =
        {
            ship = params.name,
            owner = Owner.describe(owner),
            active = true,
            availability = "InBackground",
        }

        if type(description) == "table" then
            result.mission = MissionTypes.keyOf(description.command)
            result.progress = Serialize.message(description.text, description.arguments)
            result.area = Serialize.value(description.area)
            result.escorting = Serialize.string(description.escortee)
        end

        if type(uiData) == "table" then
            result.config = Serialize.value(uiData.config)
            result.prediction = Serialize.value(uiData.prediction)
            result.areaStats = Serialize.value(uiData.area)
        end

        result.yields = Serialize.number(invokeSimulation(owner, "getNumYields", params.name), 0)

        return result
    end)

    router:post("/ships/{name}/mission/recall", function(ctx, params)
        local owner = Owner.findShip(ctx, params.name)
        requireOnline(owner)

        local force = ctx.query.force == "true" or ctx.body.force == true

        invokeSimulation(owner, force and "forceRecall" or "recall", params.name)

        local availability = owner.faction:getShipAvailability(params.name)

        return
        {
            ship = params.name,
            recalled = availability ~= ShipAvailability.InBackground,
            forced = force,
            -- a command may refuse recall, e.g. a ship mid-repair
            note = availability == ShipAvailability.InBackground
                   and "Still on mission; the command refused the recall. Retry with force=true."
                   or nil,
        }
    end)

    router:post("/ships/{name}/mission/collect", function(ctx, params)
        local owner = Owner.findShip(ctx, params.name)
        requireOnline(owner)

        local before = Serialize.number(invokeSimulation(owner, "getNumYields", params.name), 0)
        invokeSimulation(owner, "takeYield", params.name)
        local after = Serialize.number(invokeSimulation(owner, "getNumYields", params.name), 0)

        return {ship = params.name, collected = before - after, remaining = after}
    end)

end

return Missions
