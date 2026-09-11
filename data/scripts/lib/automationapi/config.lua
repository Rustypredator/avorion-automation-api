-- Tunables and filesystem layout for the Automation API.
--
-- Everything the bridge writes lives under the galaxy's moddata/ folder, which is the
-- only location the Avorion Lua sandbox permits writes to (createDirectory, deleteFile
-- and listFilesOfDirectory are all restricted to it).

local Config = {}

Config.version = "0.1.8"

-- API surface version. Bump the major when a response shape changes incompatibly;
-- external clients should check this on /ping and refuse to run against a surprise.
Config.apiVersion = 1

Config.folderName = "AutomationAPI"

-- Absolute path to use as the transport directory, bypassing the search below. Leave nil
-- unless the mod reports that it could not find a usable directory on its own; see the
-- PATHS section at the bottom of this file.
--
--   Config.rootOverride = "/home/avorion/.avorion/moddata/AutomationAPI"
Config.rootOverride = nil

-- #### TRANSPORT #### --

-- How often the bridge looks for new request files, in seconds. Galaxy scripts get
-- update() every tick, which is far more often than we want to touch the filesystem.
Config.pollInterval = 0.2

-- Requests handled per poll. Caps the damage a flood of request files can do to the
-- server tick.
Config.maxRequestsPerPoll = 4

-- How long a request may wait for async work (area analysis) before we answer 504.
Config.requestTimeout = 20

-- How long a written response file is kept before the bridge deletes it. Protects the
-- directory from growing without bound if the HTTP sidecar dies mid-flight.
Config.responseTtl = 60

-- How often the bridge re-creates its directories, in seconds. They can be removed while
-- the server runs, and every request fails until they are back.
Config.ensureDirsInterval = 30

-- How often the bridge reports throughput to the server console, in seconds. One line per
-- request would be unreadable on a busy server and useless on a quiet one; this is the
-- coarse "is anything getting through" view. 0 turns it off.
Config.statsInterval = 60

-- Whether to print that line during an interval in which nothing happened at all. Off by
-- default, so an idle server does not fill its console with zeroes. Turn it on to use the
-- line as a heartbeat instead.
Config.statsWhenIdle = false

-- Largest request file we will read, in bytes.
Config.maxRequestSize = 256 * 1024

-- #### LIMITS #### --

-- Concurrent background area analyses. The server defaults to scriptBackgroundThreads=2,
-- so going wider just queues work while holding server memory.
Config.maxConcurrentAnalyses = 2

-- Hard ceiling on sectors touched by a single map query. A 100x100 box, which at the
-- budgets below takes roughly six seconds of wall clock spread across server ticks.
Config.maxSectorsPerScan = 10000

-- A wide map search cannot run in one tick without stalling the server, so it is sliced.
-- Two budgets, because the two halves of the work differ by orders of magnitude: the
-- cheap seed hash that rules a sector out, and the full generator run for the ~3% it
-- does not.
Config.scanSectorsPerTick = 800
Config.scanDetailsPerTick = 40

-- Route calculation per player, in seconds. calculateJumpPath is documented as slow and
-- runs on the server tick.
Config.routeCooldown = 2

-- How long POST /ships/{name}/orders waits for the ship's order chain to change before
-- answering unconfirmed. Dispatch is one tick delayed and the chain publishes back on the
-- tick after that, so this only has to cover a couple of ticks plus slack.
Config.orderConfirmWindow = 3

-- Per-ship activity log. Events are pushed by the player agent as the game raises them, so
-- this bounds memory for a busy ship rather than throughput.
Config.shipEventsPerShip = 200
Config.maxShipEventsPerRead = 200

-- Default and maximum page sizes for list endpoints.
Config.defaultPageSize = 100
Config.maxPageSize = 1000

-- #### AUTH #### --

Config.keyPrefix = "avo_"

-- Server value keys. Namespaced so they can't collide with another mod's globals.
Config.keyValuePrefix = "automationapi_key_"
Config.playerKeysValue = "automationapi_keys"

-- #### PATHS #### --

-- Where the transport directory lives.
--
-- The galaxy's own moddata folder is the right answer, and on an ordinary install it is
-- the one this resolves to. It is not always reachable. io.open goes through a sandbox
-- that refuses any path it does not consider secure, and it only trusts what sits under
-- the Avorion data directory (~/.avorion, %AppData%/Avorion). A hosted server usually
-- keeps its galaxy somewhere else entirely - Server().folder then comes back as something
-- like "galaxy/Avorion", relative to a working directory of its own - and there every
-- open fails with "filename is not secure".
--
-- That failure is a bad one to diagnose, because createDirectory, listFilesOfDirectory
-- and deleteFile are engine calls that do not go through the same check and keep working.
-- The mod therefore sees request files it cannot read, writes responses that never
-- appear, and cannot delete either - so every request is retried on every poll, forever.
--
-- Guessing the layout is not worth it: try each candidate once and keep the first that
-- survives a real write-read-delete round trip through io.open.

local resolvedRoot
local rootAttempts

local function candidateRoots()
    local roots = {}

    -- Set Config.rootOverride to an absolute path to skip the search entirely. The mod
    -- cannot discover the server's working directory - os.getenv is nil inside the sandbox
    -- - so on a server where every relative spelling fails, stating the absolute path is
    -- the only thing left. It is still probed like any other candidate, so a wrong one
    -- reports itself rather than breaking the mod silently.
    if type(Config.rootOverride) == "string" and Config.rootOverride ~= "" then
        roots[#roots + 1] = Config.rootOverride
    end

    local ok, folder = pcall(function() return Server().folder end)
    if not ok or type(folder) ~= "string" then folder = "" end

    if folder ~= "" then
        roots[#roots + 1] = folder .. "/moddata/" .. Config.folderName
    end

    -- The working directory, if the sandbox left os.getenv alone. Worth having because
    -- the galaxy folder IS an allowed root - it is a relative spelling of it that the
    -- check refuses - so absolutising it keeps the documented layout rather than moving
    -- the transport directory somewhere else entirely.
    local cwdOk, cwd = pcall(function() return os.getenv("PWD") end)
    if not cwdOk or type(cwd) ~= "string" or cwd == "" then cwd = nil end

    if cwd and folder ~= "" and string.sub(folder, 1, 1) ~= "/" then
        roots[#roots + 1] = cwd .. "/" .. folder .. "/moddata/" .. Config.folderName
    end

    -- moddata under the Avorion data directory, which is the one location the sandbox
    -- documents as writable regardless of where the galaxy itself is kept.
    --
    -- Plain first, "./" second. They name the same directory and io.open accepts both, but
    -- the engine's directory calls are not the same code and need not normalise a leading
    -- "./" the way a libc path would. Prefer the spelling with nothing to normalise.
    roots[#roots + 1] = "moddata/" .. Config.folderName
    roots[#roots + 1] = "./moddata/" .. Config.folderName

    if cwd then
        roots[#roots + 1] = cwd .. "/moddata/" .. Config.folderName
    end

    return roots
end

-- Whether a directory is genuinely usable, and if not, exactly what about it is not.
--
-- Two calls have to work, and they are not the same code. io.open goes through the
-- sandbox's filename check; listFilesOfDirectory is an engine call that does not. Either
-- can work where the other does not, and the mod needs both: it reads and writes with the
-- first and finds its work with the second. A directory that passes one and fails the
-- other is the worst case to land on, because nothing errors - requests are delivered and
-- never seen.
--
-- Returns true, or false and a reason written for whoever has to read the console. The
-- reason matters as much as the verdict: "refused" is not a diagnosis, and the difference
-- between the sandbox rejecting a path and a listing coming back empty is the difference
-- between two completely unrelated fixes.
function Config.probeDirectory(path)
    local probe = path .. "/probe.tmp"
    local failure

    local wrote = pcall(function()
        local out, openErr = io.open(probe, "wb")
        if not out then
            failure = "io.open refused the write: " .. tostring(openErr or "no reason given")
            error(failure, 0)
        end

        out:write("probe")
        out:close()

        local back, readErr = io.open(probe, "rb")
        if not back then
            failure = "written, but io.open refused to read it back: "
                      .. tostring(readErr or "no reason given")
            error(failure, 0)
        end

        local content = back:read("*a")
        back:close()

        if content ~= "probe" then
            failure = "read back " .. #tostring(content) .. " bytes, not the 5 written"
            error(failure, 0)
        end
    end)

    if not wrote then
        pcall(deleteFile, probe)
        return false, failure or "io.open failed there"
    end

    -- Collect the raw listing rather than just asking whether the probe is in it. When
    -- this is the half that fails, what the call actually returned is the only clue to
    -- why, so it goes in the message.
    local entries = {}

    local listOk = pcall(function()
        for _, entry in ipairs({listFilesOfDirectory(path)}) do
            entries[#entries + 1] = entry
        end
    end)

    local listed = false
    for _, entry in ipairs(entries) do
        if string.match(tostring(entry), "([^/\\]+)$") == "probe.tmp" then listed = true end
    end

    pcall(deleteFile, probe)

    if listed then return true end

    if not listOk then
        return false, "written and read back, but listFilesOfDirectory raised an error there"
    end

    if #entries == 0 then
        return false, "written and read back, but listFilesOfDirectory returns nothing "
                      .. "there - the mod would never see a request delivered to it"
    end

    return false, string.format(
        "written and read back, but listFilesOfDirectory did not report it among %d "
        .. "entries (first is a %s: %s)",
        #entries, type(entries[1]), string.sub(tostring(entries[1]), 1, 60))
end

-- A candidate root: create it, then find out whether it is any use.
local function roundTrips(root)
    local created, createErr = pcall(createDirectory, root)

    local ok, reason = Config.probeDirectory(root)
    if ok then return true end

    if not created then
        return false, "createDirectory failed (" .. tostring(createErr) .. "); " .. reason
    end

    return false, reason
end

function Config.getRoot()
    if resolvedRoot then return resolvedRoot end

    local candidates = candidateRoots()
    rootAttempts = {}

    for _, root in ipairs(candidates) do
        local ok, reason = roundTrips(root)
        rootAttempts[#rootAttempts + 1] = {path = root, ok = ok, reason = reason}

        if ok then
            resolvedRoot = root
            return resolvedRoot
        end
    end

    -- Nothing round-tripped. Fall back to the galaxy folder, which is exactly what this
    -- did before there was a choice: the paths stay well formed, the mod behaves as it
    -- always has, and initialize() reports why every call is about to fail.
    resolvedRoot = candidates[1] or ("./moddata/" .. Config.folderName)

    return resolvedRoot
end

-- What getRoot() tried, in order, so the bridge can report it. Empty until something has
-- actually asked for the root.
function Config.getRootAttempts()
    return rootAttempts or {}
end

-- Whether the root in use is one that round-tripped, as opposed to the fallback.
function Config.rootIsUsable()
    for _, attempt in ipairs(rootAttempts or {}) do
        if attempt.ok then return true end
    end

    return false
end

function Config.getRequestsDir()  return Config.getRoot() .. "/requests" end
function Config.getResponsesDir() return Config.getRoot() .. "/responses" end
function Config.getEventsDir()    return Config.getRoot() .. "/events" end
function Config.getKeysDir()      return Config.getRoot() .. "/keys" end

return Config
