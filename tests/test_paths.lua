-- Root resolution against a sandbox that refuses insecure filenames.
--
-- Reproduces the hosted-server layout that broke the transport: Server().folder comes
-- back relative ("galaxy/Avorion"), the engine's directory calls keep working, and every
-- io.open under that path is refused with "filename is not secure" - so the mod saw
-- request files it could not read and wrote responses that never appeared. The galaxy
-- folder is an allowed location; the relative spelling of it is what the check rejects.
--
-- There are two places the transport directory can be and the mod tries both, in order,
-- and nothing else. The last section here is what holds it to that.
--
-- See the PATHS section of data/scripts/lib/automationapi/config.lua.

package.path = "data/scripts/lib/?.lua;tests/?.lua;" .. package.path

local failures = 0
local function check(cond, msg)
    if cond then
        print("  ok   " .. msg)
    else
        failures = failures + 1
        print("  FAIL " .. msg)
    end
end

-- The sandbox's filename check, in the shape the real one has: a relative path is resolved
-- against the Avorion data directory and only "moddata/" under it is trusted, while an
-- absolute path is trusted if it sits under the same tree. So the same galaxy directory is
-- refused spelled relatively and accepted spelled absolutely, and relative "moddata/" works
-- wherever the galaxy is. Here the working directory stands in for the data directory.
local pipe = assert(io.popen("pwd"))
local cwd = pipe:read("*l")
pipe:close()

local galaxy = "tests/.sandbox-galaxy"
local realOpen = io.open

local function secure(path)
    if string.sub(path, 1, 1) == "/" then return string.sub(path, 1, #cwd) == cwd end
    return string.sub(path, 1, 8) == "moddata/"
end

io.open = function(path, mode)
    if not secure(path) then return nil, "filename is not secure" end
    return realOpen(path, mode)
end

-- Engine calls do not go through that check. That asymmetry is the whole trap.
_G.createDirectory = function(dir) os.execute("mkdir -p '" .. dir .. "' 2>/dev/null") return 0 end
_G.deleteFile = function(file) os.remove(file) return 0 end

-- The bridge finds its work by listing, not by opening, so root resolution probes this
-- too. Set listBlind to a substring and listing reports every matching directory as empty
-- while io.open there keeps working - which is the silent shape of the failure: requests
-- arrive, the mod never sees them, and nothing anywhere reports an error.
local listBlind

_G.listFilesOfDirectory = function(dir)
    if listBlind and string.find(dir, listBlind, 1, true) then return end

    local ls = io.popen("ls -1 '" .. dir .. "' 2>/dev/null")
    if not ls then return end

    local names = {}
    for line in ls:lines() do names[#names + 1] = dir .. "/" .. line end
    ls:close()

    return table.unpack(names)
end

local serverFolder
_G.Server = function() return {folder = serverFolder} end

-- config.lua caches its answer, so each case needs a fresh copy of the module.
local function freshConfig()
    package.loaded["automationapi.config"] = nil
    return require("automationapi.config")
end

-- Probing creates directories, and two of the candidates land beside the working
-- directory. Never remove one that was already there.
local hadModdata = os.execute("test -d '" .. cwd .. "/moddata'")
local hadGalaxy = os.execute("test -d '" .. cwd .. "/galaxy'")

local function cleanup()
    io.open = realOpen
    os.execute("rm -rf '" .. cwd .. "/" .. galaxy .. "'")

    if not hadModdata then os.execute("rm -rf '" .. cwd .. "/moddata'") end
    if not hadGalaxy then os.execute("rm -rf '" .. cwd .. "/galaxy'") end
end

-- #### THE HOSTED SERVER #### --

serverFolder = galaxy

local Config = freshConfig()
local root = Config.getRoot()

check(Config.rootIsUsable(), "a refused galaxy path does not leave the mod without a root")
check(root == "moddata/AutomationAPI",
      "it falls back to moddata under the Avorion data directory")
check(Config.getRootAttempts()[1].ok == false,
      "the galaxy path is recorded as the candidate that failed")
check(#Config.getRootAttempts() == 2,
      "and there are only ever two places to try - no invented spellings in between")

-- Readable as well as writable: a root the mod can only write to is no use to a protocol
-- that has to read requests back out of it.
local probe = root .. "/roundtrip.tmp"
local out = io.open(probe, "wb")
check(out ~= nil, "the resolved root accepts a write")
if out then
    out:write("x")
    out:close()
    local back = io.open(probe, "rb")
    check(back ~= nil and back:read("*a") == "x", "and reads the same bytes back")
    if back then back:close() end
    os.remove(probe)
end

-- #### THE ORDINARY INSTALL #### --

-- An absolute galaxy folder has to keep winning outright, or this would quietly relocate
-- the transport directory on every install that already works.
serverFolder = cwd .. "/" .. galaxy

local Config2 = freshConfig()

check(Config2.getRoot() == serverFolder .. "/moddata/AutomationAPI",
      "an allowed galaxy folder is still preferred over every fallback")
check(Config2.getRootAttempts()[1].ok == true, "and is taken on the first attempt")
check(#Config2.getRootAttempts() == 1, "with no further candidates touched")

-- #### A ROOT THAT WRITES BUT DOES NOT LIST #### --

-- The failure this probe was added for. Every io.open under the galaxy succeeds, so a
-- write-and-read-back probe passes and the mod settles there - and then listFilesOfDirectory
-- reports the request directory empty forever. Requests are delivered, nothing reads them,
-- and no error is raised at either end. Resolution has to reject such a root outright.

serverFolder = cwd .. "/" .. galaxy
listBlind = galaxy

local Config4 = freshConfig()
local root4 = Config4.getRoot()

check(root4 ~= serverFolder .. "/moddata/AutomationAPI",
      "a root that cannot be listed is not settled on, however well it writes")
check(Config4.getRootAttempts()[1].ok == false,
      "it is recorded as a failed candidate like any other")
check(Config4.rootIsUsable(), "and resolution carries on to one that does list")

-- Proof the rejected root was not rejected for being unwritable, which would make this
-- test pass for the wrong reason.
local writable = io.open(serverFolder .. "/moddata/AutomationAPI/proof.tmp", "wb")
check(writable ~= nil, "while the rejected root does still accept writes")
if writable then
    writable:close()
    os.remove(serverFolder .. "/moddata/AutomationAPI/proof.tmp")
end

listBlind = nil

-- #### NOTHING IS INVENTED #### --

-- The mod used to try harder than this: a "./" spelling of moddata, the working directory
-- from os.getenv, the galaxy path absolutised from whatever listFilesOfDirectory returned.
-- All three were tried against a real hosted server and all three were dead - os.getenv is
-- nil in the sandbox, and the engine returns listings under the relative prefix it was
-- given, so there is no absolute path in them to recover. What they produced was a failure
-- report full of near-identical paths that obscured the two that matter.

io.open = function() return nil, "filename is not secure" end
serverFolder = "galaxy/Avorion"

local ConfigN = freshConfig()
ConfigN.getRoot()

local tried = {}
for _, attempt in ipairs(ConfigN.getRootAttempts()) do tried[#tried + 1] = attempt.path end

check(#tried == 2, "a total failure reports exactly two attempts")
check(tried[1] == "galaxy/Avorion/moddata/AutomationAPI" and tried[2] == "moddata/AutomationAPI",
      "the galaxy folder and moddata, in that order, and nothing else")
check(ConfigN.getRoot() == "galaxy/Avorion/moddata/AutomationAPI",
      "the galaxy folder is still what the paths are built from, so nothing malforms")
check(ConfigN.rootIsUsable() == false, "and the root is reported as unusable")

-- #### THE OPERATOR SAYS WHERE #### --

-- Last resort on a server where every spelling the mod can construct is refused. It has
-- no way to discover the working directory - os.getenv is nil inside the sandbox - so the
-- only thing left is to be told.

io.open = function(path, mode)
    if not secure(path) then return nil, "filename is not secure" end
    return realOpen(path, mode)
end

serverFolder = galaxy

local Config5 = freshConfig()
Config5.rootOverride = cwd .. "/" .. galaxy .. "/elsewhere"

check(Config5.getRoot() == Config5.rootOverride, "an override is used ahead of every guess")
check(#Config5.getRootAttempts() == 1, "and nothing else is even tried")

-- An override still has to earn it. Taking one on trust would turn a typo into the same
-- silent transport failure this whole search exists to avoid.
local Config6 = freshConfig()
Config6.rootOverride = "/refused/by/the/sandbox"

check(Config6.getRoot() ~= Config6.rootOverride, "a bad override is not taken on trust")
check(Config6.getRootAttempts()[1].ok == false, "it is probed and rejected like any other")
check(Config6.rootIsUsable(), "and the ordinary search still runs behind it")

cleanup()

print(failures == 0 and "PASS" or (failures .. " FAILED"))
os.exit(failures == 0 and 0 or 1)
