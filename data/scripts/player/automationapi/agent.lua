-- The write side of the API, running as a player script.
--
-- Everything the galaxy bridge does - transport, auth, routing, reads, previews - works
-- from a galaxy script. Talking to Simulation does not: it lives on the Player, and a
-- galaxy script calling Player:invokeFunction segfaults the server outright - no error,
-- no return code, the process dies. Verified against 2.5.13 with the exact call shape
-- vanilla uses. No vanilla galaxy script makes that call either; every vanilla caller of
-- simulation.lua is a player script, which is what this is.
--
-- So the bridge parks jobs and this agent, running in the right context, executes them
-- and reports back. Both directions of that handshake are proven in game.

package.path = package.path .. ";data/scripts/lib/?.lua"

local Json = include("automationapi/json")
local Serialize = include("automationapi/serialize")

-- namespace AutomationApiAgent
AutomationApiAgent = {}

local BRIDGE_SCRIPT = "data/scripts/galaxy/automationapi/bridge.lua"
local SIMULATION_SCRIPT = "simulation.lua"
local ORDERCHAIN_SCRIPT = "data/scripts/entity/orderchain.lua"

local POLL_INTERVAL = 0.25
local sinceLastPoll = 0

-- startCommand refuses until Simulation holds an analysis it ran itself, and offers no
-- way to learn when one lands, so it is retried until it takes.
local START_FIRST_DELAY = 1.0
local START_RETRY_DELAY = 1.5
local START_MAX_ATTEMPTS = 5

local running = {}

local function logError(format, ...)
    printlog("AutomationAPI agent: " .. format, ...)
end

-- Vanilla addresses the script by bare basename from player scripts; do the same.
local function callSimulation(owner, functionName, ...)
    local ok, status, a, b = pcall(function(...)
        return owner:invokeFunction(SIMULATION_SCRIPT, functionName, ...)
    end, ...)

    if not ok then return nil, tostring(status) end
    if status ~= 0 then
        return nil, "simulation call " .. functionName .. " returned " .. tostring(status)
    end

    return {a, b}
end

local function ownerOf(job)
    if job.ownerKind == "alliance" then
        local alliance = Player().alliance
        if not alliance then return nil end
        return alliance
    end

    return Player()
end

-- #### JOB KINDS #### --

local function runStatus(owner, job)
    local description, err = callSimulation(owner, "getDescription", job.shipName)
    if err then return {ok = false, code = "simulation_call_failed", message = err} end

    -- Only ask for UI data once the ship is known to be running a command.
    -- Simulation.getCommandUIData indexes self.uiData and self.commandDescriptions[ship]
    -- without checking either (simulation.lua:286), so calling it for an idle ship raises
    -- inside vanilla - and the engine logs a full traceback and fires a crash report on the
    -- way out even though the pcall catches it. The fix is not to make the call.
    local uiData
    if description and type(description[1]) == "table" then
        uiData = callSimulation(owner, "getCommandUIData", job.shipName)
    end

    local yields = callSimulation(owner, "getNumYields", job.shipName)

    local data = {}

    if description and type(description[1]) == "table" then
        local d = description[1]
        data.description =
        {
            command = Serialize.string(d.command),
            progress = Serialize.message(d.text, d.arguments),
            area = Serialize.value(d.area),
            escortee = Serialize.string(d.escortee),
        }
    end

    if uiData and type(uiData[1]) == "table" then
        local u = uiData[1]
        data.uiData =
        {
            config = Serialize.value(u.config),
            prediction = Serialize.value(u.prediction),
            area = Serialize.value(u.area),
        }
    end

    data.yields = yields and Serialize.number(yields[1], 0) or 0

    return {ok = true, data = data}
end

local function runRecall(owner, job)
    local _, err = callSimulation(owner, job.force and "forceRecall" or "recall",
                                  job.shipName)
    if err then return {ok = false, code = "simulation_call_failed", message = err} end

    local availability = owner:getShipAvailability(job.shipName)

    return {ok = true, data = {active = availability == ShipAvailability.InBackground}}
end

local function runCollect(owner, job)
    local before = callSimulation(owner, "getNumYields", job.shipName)

    local _, err = callSimulation(owner, "takeYield", job.shipName)
    if err then return {ok = false, code = "simulation_call_failed", message = err} end

    local after = callSimulation(owner, "getNumYields", job.shipName)

    return {ok = true, data =
    {
        before = before and Serialize.number(before[1], 0) or 0,
        after = after and Serialize.number(after[1], 0) or 0,
    }}
end

-- In-sector orders, replayed onto the ship's own order chain.
--
-- invokeEntityFunction is a free function rather than a Player method, so it is not
-- obviously subject to the segfault that rules Player:invokeFunction out of the galaxy
-- bridge - but nothing proves it is safe there either, and the cost of being wrong is the
-- whole server. Vanilla's only equivalent, MapCommands, is a player script and does
-- exactly this, so the agent does it too.
--
-- Nothing can be read back: the call runs on the target's next tick and returns nothing,
-- and a sector that is not resident swallows it silently. The endpoint answers 202 for
-- that reason.
local function runOrders(owner, job)
    local target = {faction = owner.index, name = job.shipName}
    local x, y = job.sector.x, job.sector.y

    local function invoke(functionName, ...)
        return invokeEntityFunction(x, y, false, target, ORDERCHAIN_SCRIPT,
                                    functionName, ...)
    end

    local ok, err = pcall(function()
        if job.clear then invoke("clearAllOrders") end

        for _, call in ipairs(job.calls or {}) do
            invoke(call.fn, table.unpack(call.args or {}))
        end

        -- enchain() only queues; the chain will not advance past what runOrders() has
        -- marked executable, so without this the ship sits there holding its new orders.
        invoke("runOrders")
    end)

    if not ok then
        return {ok = false, code = "orders_dispatch_failed", message = tostring(err)}
    end

    return {ok = true, data = {accepted = #(job.calls or {})}}
end

-- Start is the only job that cannot finish in one visit: the game's analysis runs on a
-- worker and startCommand silently no-ops until it lands. So it keeps state and is
-- retried from update() until it takes or runs out of attempts.
local function stepStart(owner, job, state)
    if not state.analysisRequested then
        state.analysisRequested = true
        state.nextAt = state.uptime + START_FIRST_DELAY

        local _, err = callSimulation(owner, "startAreaAnalysis", job.shipName,
                                      job.missionType, job.area)

        if err then
            return {ok = false, code = "analysis_dispatch_failed", message = err}
        end

        return nil
    end

    if state.uptime < state.nextAt then return nil end

    state.attempts = state.attempts + 1
    state.nextAt = state.uptime + START_RETRY_DELAY

    -- startCommand reports failure only as an in-game chat message and returns nothing,
    -- so the only way to know is to read the ship's availability back afterwards.
    callSimulation(owner, "startCommand", job.shipName, job.missionType, job.config)

    if owner:getShipAvailability(job.shipName) == ShipAvailability.InBackground then
        return {ok = true, started = true}
    end

    if state.attempts >= START_MAX_ATTEMPTS then
        return {ok = false, started = false, code = "start_rejected"}
    end

    return nil
end

-- #### LOOP #### --

local function claimJobs()
    local ok, status, payload = pcall(function()
        return Galaxy():invokeFunction(BRIDGE_SCRIPT, "takeJobs", Player().index)
    end)

    if not ok or status ~= 0 then return nil end
    if type(payload) ~= "string" or payload == "" then return nil end

    local decoded, jobs = pcall(Json.decode, payload)
    if not decoded or type(jobs) ~= "table" then return nil end

    return jobs
end

local function reportResults(results)
    if #results == 0 then return end

    local ok, payload = pcall(Json.encode, Json.array(results))
    if not ok then
        logError("could not encode %s results", tostring(#results))
        return
    end

    local sent = pcall(function()
        return Galaxy():invokeFunction(BRIDGE_SCRIPT, "reportJobs", payload)
    end)

    if not sent then logError("could not report results back to the bridge") end
end

function AutomationApiAgent.getUpdateInterval()
    return POLL_INTERVAL
end

-- #### SHIP EVENT FEED #### --
--
-- The order chain reports what it is doing by chat message to whoever gave the order -
-- unreachable for an API caller, since sendChatMessage has no server-side hook and
-- onChatMessage only fires for messages a player sends. But the same information is
-- published as ShipInfo updates, and those do have callbacks. Registering them here turns
-- "the ship stopped and I have no idea why" into a readable per-ship log.
--
-- These are Player/Alliance callbacks, so they only exist while the owner is online. That
-- matches the rest of the write path and is documented rather than worked around.
local function forward(ownerIndex, shipName, kind, payload)
    local ok, err = pcall(function()
        Galaxy():invokeFunction(BRIDGE_SCRIPT, "pushShipEvent",
                                ownerIndex, shipName, kind, payload)
    end)

    if not ok then logError("event forward failed: %s", tostring(err)) end
end

-- The chain arrives as a table here, unlike getShipOrderInfo's JSON string. Flattened to
-- plain fields because it has to cross a script boundary to reach the bridge.
local function orderPayload(info)
    local payload = {chain = {}, activeIndex = 0, finished = false}
    if type(info) ~= "table" then return payload end

    payload.activeIndex = tonumber(info.currentIndex) or 0
    payload.finished = info.finished == true

    if type(info.coordinates) == "table" then
        payload.x = tonumber(info.coordinates.x)
        payload.y = tonumber(info.coordinates.y)
    end

    for index, entry in ipairs(info.chain or {}) do
        payload.chain[index] =
        {
            name = tostring(entry.name or ""),
            action = tonumber(entry.action) or 0,
        }
    end

    return payload
end

function AutomationApiAgent.onPlayerShipOrderInfoUpdated(name, info)
    forward(Player().index, name, "order", orderPayload(info))
end

function AutomationApiAgent.onPlayerShipStatusMessageUpdated(name, status, args)
    forward(Player().index, name, "status", Serialize.message(status, args) or {})
end

function AutomationApiAgent.onAllianceShipOrderInfoUpdated(name, info)
    local alliance = Player().alliance
    if not alliance then return end

    forward(alliance.index, name, "order", orderPayload(info))
end

function AutomationApiAgent.onAllianceShipStatusMessageUpdated(name, status, args)
    local alliance = Player().alliance
    if not alliance then return end

    forward(alliance.index, name, "status", Serialize.message(status, args) or {})
end

local function registerEventCallbacks()
    local player = Player()

    player:registerCallback("onShipOrderInfoUpdated", "onPlayerShipOrderInfoUpdated")
    player:registerCallback("onShipStatusMessageUpdated", "onPlayerShipStatusMessageUpdated")

    -- Alliance craft publish on the alliance object, not on any member's.
    local alliance = player.alliance
    if alliance then
        alliance:registerCallback("onShipOrderInfoUpdated", "onAllianceShipOrderInfoUpdated")
        alliance:registerCallback("onShipStatusMessageUpdated",
                                  "onAllianceShipStatusMessageUpdated")
    end
end

function AutomationApiAgent.initialize()
    printlog("AutomationAPI agent: attached to player %s", tostring(Player().index))

    local ok, err = pcall(registerEventCallbacks)
    if not ok then logError("event callbacks not registered: %s", tostring(err)) end
end

function AutomationApiAgent.update(timeStep)
    sinceLastPoll = sinceLastPoll + timeStep
    if sinceLastPoll < POLL_INTERVAL then return end
    local elapsed = sinceLastPoll
    sinceLastPoll = 0

    local ok, err = pcall(function()
        local results = {}

        for _, job in ipairs(claimJobs() or {}) do
            local owner = ownerOf(job)

            if not owner then
                results[#results + 1] = {id = job.id, ok = false, started = false,
                                         code = "no_alliance",
                                         message = "You are not in an alliance."}
            elseif job.kind == "start" then
                running[#running + 1] =
                {
                    job = job,
                    owner = owner,
                    state = {uptime = 0, attempts = 0, analysisRequested = false},
                }
            elseif job.kind == "status" then
                local result = runStatus(owner, job)
                result.id = job.id
                results[#results + 1] = result
            elseif job.kind == "recall" then
                local result = runRecall(owner, job)
                result.id = job.id
                results[#results + 1] = result
            elseif job.kind == "collect" then
                local result = runCollect(owner, job)
                result.id = job.id
                results[#results + 1] = result
            elseif job.kind == "orders" then
                local result = runOrders(owner, job)
                result.id = job.id
                results[#results + 1] = result
            else
                results[#results + 1] = {id = job.id, ok = false,
                                         code = "unknown_job_kind",
                                         message = tostring(job.kind)}
            end
        end

        local stillRunning = {}

        for _, entry in ipairs(running) do
            entry.state.uptime = entry.state.uptime + elapsed

            local result = stepStart(entry.owner, entry.job, entry.state)

            if result then
                result.id = entry.job.id
                results[#results + 1] = result
            else
                stillRunning[#stillRunning + 1] = entry
            end
        end

        running = stillRunning

        reportResults(results)
    end)

    if not ok then logError("update failed: %s", tostring(err)) end
end
