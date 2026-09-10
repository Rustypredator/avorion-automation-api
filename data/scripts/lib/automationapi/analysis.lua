-- Runs the background simulation's area analysis and hands the result back.
--
-- The analysis is what turns a rectangle of the galaxy into the reachability, faction and
-- resource data every mission prediction is computed from. It runs on a worker thread, so
-- endpoints that need it defer their response until it lands.
--
-- We run our own analysis rather than asking Simulation to do it, for two reasons: the
-- results table is needed here to validate and predict, and Simulation offers no way to
-- learn that its own analysis has finished.

local Router = include("automationapi/router")
local Config = include("automationapi/config")

local Analysis = {}

local ANALYSIS_SCRIPT = "data/scripts/player/background/simulation/areaanalysis.lua"

-- The worker returns (shipName, type, area, results, callingPlayer) and nothing else, so
-- ship name plus mission type is the only identity available to match a result to its
-- request. callingPlayer cannot be borrowed as a token: MaintenanceCommand reads it as a
-- real player index to find their reconstruction site.
local jobs = {}
local active = 0

local function keyOf(shipName, type)
    return shipName .. "\0" .. type
end

-- onDone(area, results) is called on the main thread once the worker finishes.
-- onFail(reason) is called if it never does.
function Analysis.start(ownerIndex, playerIndex, shipName, type, area, onDone, onFail)
    local key = keyOf(shipName, type)

    if jobs[key] then
        Router.fail(409, "analysis_in_progress",
                    "An area analysis for '" .. shipName .. "' is already running.")
    end

    if active >= Config.maxConcurrentAnalyses then
        Router.fail(429, "analysis_busy",
                    "Too many area analyses in flight. Retry shortly.")
    end

    jobs[key] =
    {
        ownerIndex = ownerIndex,
        shipName = shipName,
        type = type,
        onDone = onDone,
        onFail = onFail,
        deadline = os.time() + Config.requestTimeout,
    }
    active = active + 1

    asyncf("onAreaAnalysisFinished", ANALYSIS_SCRIPT, ownerIndex, shipName, type, area, playerIndex)
end

-- Called from the bridge's asyncf callback.
function Analysis.deliver(shipName, type, area, results)
    local key = keyOf(shipName, type)

    local job = jobs[key]
    if not job then return false end

    jobs[key] = nil
    active = active - 1

    job.onDone(area, results)

    return true
end

-- Reaps jobs whose worker never reported back, so a lost callback cannot permanently
-- consume one of the few analysis slots.
function Analysis.tick()
    local now = os.time()

    for key, job in pairs(jobs) do
        if now >= job.deadline then
            jobs[key] = nil
            active = active - 1

            if job.onFail then pcall(job.onFail, "the area analysis did not return") end
        end
    end
end

function Analysis.activeCount()
    return active
end

return Analysis
