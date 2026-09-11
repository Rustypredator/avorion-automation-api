-- Automation API transport bridge.
--
-- Attached to the Galaxy, so it runs whenever the server runs. That matters: read
-- endpoints stay available with nobody logged in, which a player script could not do.
--
-- Avorion's Lua sandbox has no sockets (os.execute, io.popen and package.loadlib are
-- all nil'd out, and it isn't LuaJIT, so there is no ffi either), so this mod cannot
-- host HTTP itself. Instead it speaks JSON over files in the galaxy's moddata folder
-- and a small HTTP process on the same machine translates. See docs/protocol.md.

package.path = package.path .. ";data/scripts/lib/?.lua"

local Json = include("automationapi/json")
local Config = include("automationapi/config")
local Auth = include("automationapi/auth")
local Router = include("automationapi/router")
local Serialize = include("automationapi/serialize")

local MetaHandler = include("automationapi/handlers/meta")
local ShipsHandler = include("automationapi/handlers/ships")
local MissionsHandler = include("automationapi/handlers/missions")
local MovementHandler = include("automationapi/handlers/movement")
local ShipEvents = include("automationapi/shipevents")
local MapHandler = include("automationapi/handlers/map")

local Analysis = include("automationapi/analysis")

-- Don't remove or alter the following comment, it tells the game the namespace this script lives in. If you remove it, the script will break.
-- namespace AutomationApiBridge
AutomationApiBridge = {}

local router
local ready = false

local dirs = {}

-- requestId -> {deadline, method, path, startedAt}
local pending = {}

-- absolute path -> time at which the bridge should delete it
local expiring = {}

local sinceLastPoll = 0
local sinceLastEnsure = 0

-- #### HELPERS #### --

local function log(format, ...)
    printlog("AutomationAPI: " .. format, ...)
end

local function logError(format, ...)
    eprint("AutomationAPI: " .. format, ...)
end

-- printlog lands in the log file, which a dedicated server's console does not show. The
-- one line saying whether the API came up, and which directory it settled on, is the line
-- an operator needs to see, so it goes to the console instead.
local function console(format, ...)
    print("AutomationAPI: " .. string.format(format, ...))
end

-- Whether a directory is actually there and actually usable.
--
-- There is no stat() in the sandbox, and listFilesOfDirectory() answers the same empty
-- list for a directory that is missing as for one that is merely empty. So ask the only
-- question that matters to this protocol - can a file be written here and read back - by
-- doing it. io.open cannot create a directory, so a probe that opens proves one exists.
--
-- The name fails the mod's own ^[A-Za-z0-9_-]+%.json$ request filter, so a probe left
-- behind by a crash is never mistaken for a request.
local function directoryUsable(path)
    local probe = path .. "/probe.tmp"

    local ok = pcall(function()
        local out = assert(io.open(probe, "wb"))
        out:write("probe")
        out:close()

        local back = assert(io.open(probe, "rb"))
        local content = back:read("*a")
        back:close()

        assert(content == "probe")
    end)

    pcall(deleteFile, probe)

    return ok
end

-- createDirectory is not documented as recursive, and the API's folder can sit several
-- levels below anything that exists - or be deleted underneath a running server, which is
-- how this came up. Walk the chain and create each level in turn.
--
-- Returns true, or false and a reason to put in front of an operator. Everything here is
-- pcall'd and verified rather than trusted: createDirectory is an engine call that reports
-- nothing useful, and on at least one server it is the io.open sandbox rather than the
-- directory that is the real obstacle, which looks identical from the outside.
local function ensureDirectory(path)
    if directoryUsable(path) then return true end

    if type(createDirectory) ~= "function" then
        return false, "createDirectory is not available to this script"
    end

    local built = string.sub(path, 1, 1) == "/" and "" or nil
    local lastError

    for segment in string.gmatch(path, "[^/]+") do
        built = built and (built .. "/" .. segment) or segment

        local ok, err = pcall(createDirectory, built)
        if not ok then lastError = tostring(err) end
    end

    if directoryUsable(path) then return true end

    if lastError then
        return false, "createDirectory failed: " .. lastError
    end

    return false, "createDirectory reported success but nothing can be written there"
end

-- listFilesOfDirectory() isn't documented as returning names or full paths, so accept
-- either and normalise.
local function basename(path)
    return string.match(path, "([^/\\]+)$") or path
end

local function readFile(path)
    local file = io.open(path, "rb")
    if not file then return nil, "could not open file" end

    -- read one byte past the limit so an oversized file is detected rather than
    -- silently truncated into a parse error
    local content = file:read(Config.maxRequestSize + 1)
    file:close()

    if content == nil then return nil, "empty file" end
    if #content > Config.maxRequestSize then return nil, "request exceeds size limit" end

    return content
end

-- Responses are written straight to their final name.
--
-- The obvious write-to-temp-then-rename trick is NOT usable here: inside Avorion's
-- sandbox os.rename() returns true and then loses the file - the source disappears and
-- the destination is never created. Verified against 2.5.13; plain writes to the same
-- directory persist normally.
--
-- So a reader can in principle catch a response mid-write. The protocol handles that by
-- making JSON its own integrity check: a truncated file fails to parse, and the client
-- simply retries. See docs/protocol.md. Requests travel the other way and are written by
-- an ordinary unsandboxed process, which can and should rename atomically.
local function writeFile(path, content)
    local file, err = io.open(path, "wb")
    if not file then return false, tostring(err or ("could not open " .. path)) end

    local ok, writeErr = pcall(function()
        file:write(content)
        file:close()
    end)

    if not ok then return false, tostring(writeErr) end

    return true
end

-- #### RESPONSES #### --

local function writeResponse(requestId, status, body, errorText)
    local envelope =
    {
        id = requestId,
        status = status,
        body = body,
        error = errorText,
    }

    local encoded, err = Json.encode(envelope)
    if not encoded then
        -- the body held something the encoder choked on; still answer, so the caller
        -- gets a failure instead of a timeout
        logError("failed to encode response for %s: %s", tostring(requestId), tostring(err))

        encoded = Json.encode(
        {
            id = requestId,
            status = 500,
            body = {error = {code = "encoding_failed", message = tostring(err)}},
        })
    end

    local path = dirs.responses .. "/" .. requestId .. ".json"

    local ok, writeErr = writeFile(path, encoded)
    if not ok then
        logError("failed to write response %s: %s", path, tostring(writeErr))
        return
    end

    expiring[path] = Server().unpausedRuntime + Config.responseTtl
end

-- #### REQUEST HANDLING #### --

local function badRequest(requestId, status, code, message)
    writeResponse(requestId, status, {error = {code = code, message = message}})
end

local function handleRequest(requestId, request)
    if type(request) ~= "table" then
        return badRequest(requestId, 400, "malformed_request", "Request must be a JSON object.")
    end

    local method = request.method
    local path = request.path

    if type(path) ~= "string" or string.sub(path, 1, 1) ~= "/" then
        return badRequest(requestId, 400, "malformed_request", "Missing or invalid 'path'.")
    end

    if method ~= nil and type(method) ~= "string" then
        return badRequest(requestId, 400, "malformed_request", "Invalid 'method'.")
    end

    local playerIndex = Auth.resolve(request.key)
    if not playerIndex then
        return badRequest(requestId, 401, "unauthorized",
                          "Unknown or missing API key. Run /apikey new in game.")
    end

    local player = Player(playerIndex)
    if not player then
        return badRequest(requestId, 401, "unauthorized",
                          "The player this key belongs to no longer exists.")
    end

    local query = request.query
    if type(query) ~= "table" then query = {} end

    local body = request.body
    if type(body) ~= "table" then body = {} end

    local completed = false

    local ctx =
    {
        requestId = requestId,
        method = string.upper(method or "GET"),
        path = path,
        query = query,
        body = body,
        playerIndex = playerIndex,
        player = player,
        now = Server().unpausedRuntime,
    }

    -- Handlers that start background work return Router.DEFERRED and call this when
    -- the work lands. Guarded against double completion so a callback that fires twice
    -- can't produce two responses for one request.
    ctx.complete = function(status, responseBody)
        if completed then return end
        completed = true

        pending[requestId] = nil
        writeResponse(requestId, status or 200, responseBody)
    end

    local status, responseBody, traceback = router:dispatch(ctx.method, path, ctx)

    if status == Router.DEFERRED then
        -- a handler may have completed synchronously anyway; don't re-arm in that case
        if not completed then
            pending[requestId] =
            {
                deadline = Server().unpausedRuntime + Config.requestTimeout,
                method = ctx.method,
                path = path,
                complete = ctx.complete,
            }
        end
        return
    end

    if traceback then
        logError("handler error on %s %s: %s", ctx.method, path, traceback)
    end

    completed = true
    writeResponse(requestId, status, responseBody)
end

local function processRequestFile(name)
    -- keeps ".tmp" files (mid-write by the client) and anything unexpected out
    if not string.match(name, "^[%w%-_]+%.json$") then return false end

    local requestId = string.gsub(name, "%.json$", "")
    local path = dirs.requests .. "/" .. name

    local content, readErr = readFile(path)

    -- Delete first, always. A request that somehow kills the handler must not be
    -- retried forever on every poll.
    deleteFile(path)

    if not content then
        logError("could not read request %s: %s", name, tostring(readErr))
        badRequest(requestId, 400, "unreadable_request", tostring(readErr))
        return true
    end

    local request, decodeErr = Json.decode(content)
    if not request then
        badRequest(requestId, 400, "malformed_json", tostring(decodeErr))
        return true
    end

    handleRequest(requestId, request)

    return true
end

-- #### MAINTENANCE #### --

local function expirePending(now)
    for requestId, job in pairs(pending) do
        if now >= job.deadline then
            pending[requestId] = nil
            log("request %s (%s %s) timed out", requestId, job.method, job.path)
            writeResponse(requestId, 504,
                {error = {code = "timeout", message = "The request timed out server-side."}})
        end
    end
end

-- Responses the client never picked up. listFilesOfDirectory gives names but no
-- timestamps, so the bridge remembers what it wrote instead of stat-ing the directory.
local function expireResponses(now)
    for path, deleteAt in pairs(expiring) do
        if now >= deleteAt then
            expiring[path] = nil
            deleteFile(path)
        end
    end
end

local function poll()
    local files = {listFilesOfDirectory(dirs.requests)}
    if #files == 0 then return end

    local handled = 0

    for _, file in ipairs(files) do
        if handled >= Config.maxRequestsPerPoll then break end

        if processRequestFile(basename(file)) then
            handled = handled + 1
        end
    end
end

-- #### SCRIPT ENTRY POINTS #### --

-- Every directory the API owns. Called on startup and again periodically, because these
-- can be removed while the server runs - by a cleanup, or by hand - and the mod should
-- come back on its own rather than failing every request until the next restart.
--
-- Returns a list of "<path>: <reason>" for the ones that could not be made.
local function ensureDirs()
    local failed = {}

    -- Root first: the rest sit inside it, and a failure there explains every other one.
    local order =
    {
        dirs.root,
        dirs.requests,
        dirs.responses,
        dirs.events,
        dirs.keys,
    }

    for _, path in ipairs(order) do
        local ok, reason = ensureDirectory(path)
        if not ok then
            failed[#failed + 1] = path .. ": " .. tostring(reason)
        end
    end

    return failed
end

-- What the sandbox actually handed this script. A mod that cannot create directories and
-- a mod that cannot open files fail in exactly the same way from the outside - nothing
-- appears - so say which one it is rather than leaving it to be guessed.
local function filesystemApi()
    return string.format("createDirectory=%s io.open=%s listFilesOfDirectory=%s deleteFile=%s",
                         type(createDirectory), type(io.open), type(listFilesOfDirectory),
                         type(deleteFile))
end

-- nil until the first run, then "ok" or "broken". Directory state is checked every 30
-- seconds and the console is not a log file, so only speak when the answer changes.
local dirState

local function ensureDirsAndReport()
    local failed = ensureDirs()

    if #failed == 0 then
        if dirState ~= "ok" then
            console("transport directories ready: requests, responses, events, keys")
        end

        dirState = "ok"
        return true
    end

    if dirState ~= "broken" then
        for _, reason in ipairs(failed) do
            console("could not create %s", reason)
        end

        console("the API cannot run without those directories - every request will fail. "
                .. "Create them by hand, or check that the server account may write to %s.",
                dirs.root)
        console("filesystem API: %s", filesystemApi())
    end

    dirState = "broken"
    return false
end

function AutomationApiBridge.initialize()
    if onClient() then return end

    dirs =
    {
        root = Config.getRoot(),
        requests = Config.getRequestsDir(),
        responses = Config.getResponsesDir(),
        events = Config.getEventsDir(),
        keys = Config.getKeysDir(),
    }

    router = Router.new()
    MetaHandler.register(router)
    ShipsHandler.register(router)
    MissionsHandler.register(router)
    MovementHandler.register(router)
    MapHandler.register(router)

    ready = true

    -- Both halves of the transport have to agree on this path, so print it whether or not
    -- anything went wrong: it is what the HTTP bridge's galaxy directory has to point at.
    console("v%s ready, API v%d, transport directory: %s", Config.version, Config.apiVersion,
            dirs.root)

    -- The sandbox can refuse io.open under every candidate root, and when it does the only
    -- other sign is a pair of errors per request, forever. Say it once, here, and name
    -- every path that was tried - the one that ought to have worked is the useful clue.
    if not Config.rootIsUsable() then
        for _, attempt in ipairs(Config.getRootAttempts()) do
            console("  tried %s: refused", attempt.path)
        end

        console("no usable transport directory. Every candidate above refused a "
                .. "write-read round trip, which is the sandbox rejecting the path rather "
                .. "than a permissions problem - the same error the log reports as "
                .. "'filename is not secure'.")
        console("filesystem API: %s", filesystemApi())
    end

    -- Last, so that anything it has to say sits under the path it is talking about.
    ensureDirsAndReport()

    log("v%s ready, API v%d, watching %s", Config.version, Config.apiVersion, dirs.requests)
end

-- Advisory: this is documented for Entity/Player/Sector/Server scripts but not for
-- Galaxy ones, so update() throttles itself as well rather than trusting it.
function AutomationApiBridge.getUpdateInterval()
    return Config.pollInterval
end

-- asyncf() resolves its callback name against this script's namespace, so the area
-- analysis worker lands here and is routed to whichever request is waiting on it.
function AutomationApiBridge.onAreaAnalysisFinished(shipName, missionType, area, results)
    local ok, err = pcall(Analysis.deliver, shipName, missionType, area, results)

    if not ok then
        logError("area analysis callback failed for %s: %s", tostring(shipName), tostring(err))
    end
end

-- Called by player/automationapi/agent.lua, which is the only context allowed to talk to
-- a player's Simulation. Payloads cross as JSON strings; see Missions.takeJobs.
function AutomationApiBridge.takeJobs(playerIndex)
    local ok, payload = pcall(MissionsHandler.takeJobs, playerIndex)

    if not ok then
        logError("takeJobs failed for %s: %s", tostring(playerIndex), tostring(payload))
        return ""
    end

    return payload
end

function AutomationApiBridge.reportJobs(payload)
    local ok, err = pcall(MissionsHandler.report, payload)

    if not ok then
        logError("reportJobs failed: %s", tostring(err))
        return false
    end

    return true
end

-- Called by the player agent whenever the game raises a ShipInfo callback. Fire and
-- forget from the agent's side, so failures are logged here or nowhere.
function AutomationApiBridge.pushShipEvent(ownerIndex, shipName, kind, payload)
    local ok, stored = pcall(ShipEvents.push, ownerIndex, shipName, kind, payload)

    if not ok then
        logError("pushShipEvent failed for %s: %s", tostring(shipName), tostring(stored))
        return false
    end

    -- false means the event was a duplicate or malformed, not that the call failed
    return stored == true
end

function AutomationApiBridge.update(timeStep)
    if not ready then return end

    sinceLastPoll = sinceLastPoll + timeStep
    if sinceLastPoll < Config.pollInterval then return end

    -- Capture before resetting: the accumulator is the elapsed time the pending-start
    -- queue needs, and zeroing it first would hand every tick a 0 and stall the queue.
    local elapsed = sinceLastPoll
    sinceLastPoll = 0

    -- This runs inside the server tick. An uncaught error here would take the whole
    -- API down until restart, so nothing is allowed to escape.
    local ok, err = pcall(function()
        local now = Server().unpausedRuntime

        sinceLastEnsure = sinceLastEnsure + elapsed
        if sinceLastEnsure >= Config.ensureDirsInterval then
            sinceLastEnsure = 0
            ensureDirsAndReport()
        end

        poll()
        Analysis.tick()
        MissionsHandler.tick(elapsed)
        MovementHandler.tick(elapsed)
        MapHandler.tick()
        expirePending(now)
        expireResponses(now)
    end)

    if not ok then
        logError("update failed: %s", tostring(err))
    end
end
