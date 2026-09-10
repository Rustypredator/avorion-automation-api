-- Tunables and filesystem layout for the Automation API.
--
-- Everything the bridge writes lives under the galaxy's moddata/ folder, which is the
-- only location the Avorion Lua sandbox permits writes to (createDirectory, deleteFile
-- and listFilesOfDirectory are all restricted to it).

local Config = {}

Config.version = "0.1.0"

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

-- Largest request file we will read, in bytes.
Config.maxRequestSize = 256 * 1024

-- #### LIMITS #### --

-- Concurrent background area analyses. The server defaults to scriptBackgroundThreads=2,
-- so going wider just queues work while holding server memory.
Config.maxConcurrentAnalyses = 2

-- Hard ceiling on sectors touched by a single map query.
Config.maxSectorsPerScan = 2000

-- Default and maximum page sizes for list endpoints.
Config.defaultPageSize = 100
Config.maxPageSize = 1000

-- #### AUTH #### --

Config.keyPrefix = "avo_"

-- Server value keys. Namespaced so they can't collide with another mod's globals.
Config.keyValuePrefix = "automationapi_key_"
Config.playerKeysValue = "automationapi_keys"

-- #### PATHS #### --

-- The galaxy folder is only known at runtime on the server.
function Config.getRoot()
    return Server().folder .. "/moddata/" .. Config.folderName
end

function Config.getRequestsDir()  return Config.getRoot() .. "/requests" end
function Config.getResponsesDir() return Config.getRoot() .. "/responses" end
function Config.getEventsDir()    return Config.getRoot() .. "/events" end

return Config
