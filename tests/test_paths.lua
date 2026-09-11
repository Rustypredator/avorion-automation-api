-- Root resolution against a sandbox that refuses insecure filenames.
--
-- Reproduces the hosted-server layout that broke the transport: Server().folder comes
-- back relative ("galaxy/Avorion"), the engine's directory calls keep working, and every
-- io.open under that path is refused with "filename is not secure" - so the mod saw
-- request files it could not read and wrote responses that never appeared. The galaxy
-- folder is an allowed location; the relative spelling of it is what the check rejects.
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

-- The sandbox trusts absolute paths under the working directory and nothing else, which
-- is the shape of the real one: a galaxy reached by a relative path is refused even
-- though the same directory reached absolutely is fine.
local pipe = assert(io.popen("pwd"))
local cwd = pipe:read("*l")
pipe:close()

local galaxy = "tests/.sandbox-galaxy"
local realOpen = io.open

io.open = function(path, mode)
    if string.sub(path, 1, 1) ~= "/" or string.sub(path, 1, #cwd) ~= cwd then
        return nil, "filename is not secure"
    end
    return realOpen(path, mode)
end

-- Engine calls do not go through that check. That asymmetry is the whole trap.
_G.createDirectory = function(dir) os.execute("mkdir -p '" .. dir .. "'") return 0 end
_G.deleteFile = function(file) os.remove(file) return 0 end

local serverFolder
_G.Server = function() return {folder = serverFolder} end

-- config.lua caches its answer, so each case needs a fresh copy of the module.
local function freshConfig()
    package.loaded["automationapi.config"] = nil
    return require("automationapi.config")
end

local function cleanup()
    io.open = realOpen
    os.execute("rm -rf '" .. cwd .. "/" .. galaxy .. "'")
end

-- #### THE HOSTED SERVER #### --

serverFolder = galaxy

local Config = freshConfig()
local root = Config.getRoot()

check(Config.rootIsUsable(), "a refused galaxy path does not leave the mod without a root")
check(root == cwd .. "/" .. galaxy .. "/moddata/AutomationAPI",
      "the galaxy folder is kept, spelled absolutely, rather than moved elsewhere")
check(Config.getRootAttempts()[1].ok == false,
      "the relative spelling is recorded as the candidate that failed")

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

-- #### NOTHING WORKS AT ALL #### --

-- The fallback has to stay the galaxy folder: unchanged behaviour, so a false negative
-- here cannot break an install, and initialize() reports it instead.
io.open = function() return nil, "filename is not secure" end
serverFolder = "galaxy/Avorion"

local Config3 = freshConfig()

check(Config3.getRoot() == "galaxy/Avorion/moddata/AutomationAPI",
      "with every candidate refused it falls back to the galaxy folder")
check(Config3.rootIsUsable() == false, "and reports the root as unusable")

cleanup()

print(failures == 0 and "PASS" or (failures .. " FAILED"))
os.exit(failures == 0 and 0 or 1)
