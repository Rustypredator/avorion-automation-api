-- The once-a-minute throughput line.
--
-- It exists so an operator can tell "nothing is arriving" from "everything is arriving and
-- failing" without turning on per-request logging, so what matters is that the three
-- numbers mean what the line says they mean.

package.path = "data/scripts/lib/?.lua;tests/?.lua;" .. package.path

local Mock = require("mock_avorion")
Mock.install()
Mock.reset()

local Json = require("automationapi.json")
local Config = require("automationapi.config")
local Auth = require("automationapi.auth")

dofile("data/scripts/galaxy/automationapi/bridge.lua")
local Bridge = AutomationApiBridge

local failures = 0
local realPrint = print

local function check(cond, msg)
    if cond then
        realPrint("  ok   " .. msg)
    else
        failures = failures + 1
        realPrint("  FAIL " .. msg)
    end
end

-- #### HARNESS #### --

local captured = {}

local function capture()
    captured = {}
    _G.print = function(line) captured[#captured + 1] = tostring(line) end
end

local function release()
    _G.print = realPrint
end

-- The stats line, or nil. Directory messages share the console, so match on the shape.
local function statsLine()
    for _, line in ipairs(captured) do
        if string.find(line, "requests, ") then return line end
    end
end

Mock.addPlayer(1, "Rustypredator")
Bridge.initialize()

local key = Auth.createKey(1, "stats harness")

local seq = 0
local function send(tbl)
    seq = seq + 1
    tbl.id = "stat" .. seq

    local f = assert(io.open(Config.getRequestsDir() .. "/" .. tbl.id .. ".json", "wb"))
    f:write(Json.encode(tbl))
    f:close()

    Bridge.update(Config.pollInterval)
end

-- Push the clock past the reporting interval and take whatever the tick prints.
local function tickAndReport()
    capture()
    Mock.advanceClock(Config.statsInterval + 1)
    Bridge.update(Config.statsInterval + 1)
    release()

    return statsLine()
end

-- #### TESTS #### --

realPrint("\ncounting")

send{key = key, method = "GET", path = "/ping"}
send{key = key, method = "GET", path = "/ping"}
send{key = key, method = "GET", path = "/ping"}

local line = tickAndReport()
check(line ~= nil, "a line is printed once the interval elapses")
check(line and string.find(line, "3 requests", 1, true), "every request file is counted")
check(line and string.find(line, "3 responses", 1, true), "so is every response written")
check(line and string.find(line, "0 failures", 1, true), "and none of them was a failure")
if line then realPrint("       > " .. line) end

realPrint("\nthe counters reset")

check(tickAndReport() == nil, "an interval in which nothing happened prints nothing")

realPrint("\nwhat counts as a failure")

-- A 401 is the mod answering correctly. Counting it would make every mistyped key look
-- like a broken deployment.
send{key = "avo_bogus", method = "GET", path = "/ping"}
send{key = key, method = "GET", path = "/nowhere"}

local line = tickAndReport()
check(line and string.find(line, "2 requests", 1, true), "a rejected request is still a request")
check(line and string.find(line, "2 responses", 1, true), "and still gets a response")
check(line and string.find(line, "0 failures", 1, true), "a 401 and a 404 are not failures")
if line then realPrint("       > " .. line) end

-- A request the mod cannot read is this end failing, and is the exact symptom the
-- sandbox produced on a live server.
local oversized = Config.getRequestsDir() .. "/statbig.json"
local f = assert(io.open(oversized, "wb"))
f:write(string.rep("x", Config.maxRequestSize + 64))
f:close()
Bridge.update(Config.pollInterval)

local line = tickAndReport()
check(line and string.find(line, "1 failures", 1, true), "a request that cannot be read is a failure")
if line then realPrint("       > " .. line) end

realPrint("\nthe idle heartbeat")

Config.statsWhenIdle = true
local line = tickAndReport()
check(line and string.find(line, "0 requests", 1, true), "statsWhenIdle turns the line into a heartbeat")
Config.statsWhenIdle = false

realPrint("\nturning it off")

Config.statsInterval = 0
send{key = key, method = "GET", path = "/ping"}
capture()
Mock.advanceClock(120)
Bridge.update(120)
release()
check(statsLine() == nil, "statsInterval = 0 prints nothing at all")
Config.statsInterval = 60

realPrint("")
if failures > 0 then
    realPrint(failures .. " check(s) failed")
    os.exit(1)
end
realPrint("all checks passed")
