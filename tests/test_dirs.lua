-- The mod's directory creation, and what it says about it.
--
-- Creating nothing and saying nothing is the worst failure this mod has: the bridge
-- reports an empty transport directory, the server console is silent, and there is no way
-- to tell a sandbox that refuses the path from an engine call that is not there at all.
-- These checks are about the console output, not the directories.

package.path = "data/scripts/lib/?.lua;tests/?.lua;" .. package.path

local Mock = require("mock_avorion")
Mock.install()
Mock.reset()

local failures = 0
local function check(cond, msg)
    if cond then
        print("  ok   " .. msg)
    else
        failures = failures + 1
        print("  FAIL " .. msg)
    end
end

-- #### HARNESS #### --

local realPrint = print
local captured = {}

local function capture()
    captured = {}
    _G.print = function(line) captured[#captured + 1] = tostring(line) end
end

local function release()
    _G.print = realPrint
end

local function said(pattern)
    for _, line in ipairs(captured) do
        if string.find(line, pattern) then return true end
    end

    return false
end

local function dump()
    for _, line in ipairs(captured) do realPrint("       > " .. line) end
end

-- The bridge resolves its root once and caches it, so a scenario that changes what the
-- filesystem can do has to start from a clean module table.
local function reload()
    for name in pairs(package.loaded) do
        if string.find(name, "^automationapi") then package.loaded[name] = nil end
    end

    _G.AutomationApiBridge = nil
    Mock.install()
    Mock.reset()
    Mock.addPlayer(1, "Rustypredator")

    dofile("data/scripts/galaxy/automationapi/bridge.lua")

    return AutomationApiBridge, require("automationapi.config")
end

local function wipe(path)
    os.execute("rm -rf '" .. path .. "'")
end

-- #### THE ORDINARY CASE #### --

realPrint("\ncreation succeeds")

local Bridge, Config = reload()
wipe(Config.getRoot())

capture()
Bridge.initialize()
release()

check(said("transport directory:"), "startup names the directory it settled on")
check(said("transport directories ready"), "and confirms the directories are there")
if not said("transport directories ready") then dump() end

check(io.open(Config.getKeysDir() .. "/probe.tmp", "wb") ~= nil,
      "the keys directory really exists")
deleteFile(Config.getKeysDir() .. "/probe.tmp")

-- Every 30 seconds is too often to repeat good news to a console.
capture()
Mock.advanceClock(Config.ensureDirsInterval + 1)
Bridge.update(Config.ensureDirsInterval + 1)
release()

check(not said("transport directories ready"), "and does not repeat itself every 30s")

-- #### createDirectory DOES NOTHING #### --
--
-- The engine call reports success and creates nothing. Before this test the mod believed
-- it, and the only symptom anywhere was an empty directory.

realPrint("\ncreateDirectory silently does nothing")

local Bridge, Config = reload()
_G.createDirectory = function() return 0 end
wipe(Config.getRoot())

capture()
Bridge.initialize()
release()

check(said("could not create"), "a directory that was not created is reported")
check(said("io.open refused the write"), "and the reason names the call that failed")
check(said("No such file or directory"),
      "passing the engine's own words through rather than paraphrasing them")
if not said("could not create") then dump() end

-- #### createDirectory IS NOT THERE #### --

realPrint("\ncreateDirectory is missing entirely")

local Bridge, Config = reload()
_G.createDirectory = nil
wipe(Config.getRoot())

capture()
Bridge.initialize()
release()

check(said("createDirectory is not available to this script"),
      "a missing engine call is named as such, not guessed at")
check(said("filesystem API: createDirectory=nil"),
      "and the console reports what the sandbox did hand over")
if not said("createDirectory is not available") then dump() end

-- #### createDirectory THROWS #### --

realPrint("\ncreateDirectory raises an error")

local Bridge, Config = reload()
_G.createDirectory = function() error("filename is not secure") end
wipe(Config.getRoot())

capture()
Bridge.initialize()
release()

check(said("filename is not secure"), "the engine's own error text reaches the console")
check(said("every request will fail"), "and the consequence is spelled out")
if not said("filename is not secure") then dump() end

-- #### THE DIRECTORY LISTS AS EMPTY #### --
--
-- Every write works and every read works, so the mod happily settles there - and then the
-- poll loop, which finds its work by listing rather than opening, never sees a thing. No
-- error is raised at either end: requests are delivered and silently ignored forever.

realPrint("\nfiles are written but the directory lists as empty")

local Bridge, Config = reload()
_G.listFilesOfDirectory = function() return end
wipe(Config.getRoot())

capture()
Bridge.initialize()
release()

check(said("listFilesOfDirectory returns nothing there"),
      "a directory that cannot be listed is reported, not trusted")
check(said("would never see a request delivered to it"),
      "and the message says what that costs, not just what it is")
check(said("no usable transport directory"),
      "root resolution refuses to settle on one")
check(said("Config.rootOverride"),
      "and points at the escape hatch, since the mod cannot find the path itself")
if not said("listFilesOfDirectory returns nothing there") then dump() end

-- #### RECOVERY #### --
--
-- Once it starts working, say so. A console that only ever reports failure leaves an
-- operator who fixed the problem with nothing to confirm it against.

realPrint("\nrecovery is announced")

local Bridge, Config = reload()
local broken = true
local realCreate = _G.createDirectory
_G.createDirectory = function(dir)
    if broken then return 0 end
    return realCreate(dir)
end
wipe(Config.getRoot())

capture()
Bridge.initialize()
release()
check(said("could not create"), "starts out broken")

broken = false

capture()
Mock.advanceClock(Config.ensureDirsInterval + 1)
Bridge.update(Config.ensureDirsInterval + 1)
release()

check(said("transport directories ready"), "and says so the moment it recovers")
if not said("transport directories ready") then dump() end

realPrint("")
if failures > 0 then
    realPrint(failures .. " check(s) failed")
    os.exit(1)
end
realPrint("all checks passed")
