-- Tunables and filesystem layout for the Automation API.
--
-- Everything the bridge writes lives under the galaxy's moddata/ folder, which is the
-- only location the Avorion Lua sandbox permits writes to (createDirectory, deleteFile
-- and listFilesOfDirectory are all restricted to it).

local Config = {}

Config.version = "0.1.4"

-- API surface version. Bump the major when a response shape changes incompatibly;
-- external clients should check this on /ping and refuse to run against a surprise.
Config.apiVersion = 1

Config.folderName = "AutomationAPI"

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
    roots[#roots + 1] = "./moddata/" .. Config.folderName
    roots[#roots + 1] = "moddata/" .. Config.folderName

    if cwd then
        roots[#roots + 1] = cwd .. "/moddata/" .. Config.folderName
    end

    return roots
end

-- A round trip rather than a bare open: the sandbox judges reads and writes separately,
-- and a directory the mod can write but not read back is no use to this protocol.
local function roundTrips(root)
    pcall(createDirectory, root)

    local probe = root .. "/probe.tmp"

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

function Config.getRoot()
    if resolvedRoot then return resolvedRoot end

    local candidates = candidateRoots()
    rootAttempts = {}

    for _, root in ipairs(candidates) do
        local ok = roundTrips(root)
        rootAttempts[#rootAttempts + 1] = {path = root, ok = ok}

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
