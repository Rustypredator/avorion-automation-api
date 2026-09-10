-- End-to-end test of the file transport: drop a request, tick the bridge, read the
-- response. Runs against tests/mock_avorion.lua, no game required.

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
local function check(cond, msg)
    if cond then
        print("  ok   " .. msg)
    else
        failures = failures + 1
        print("  FAIL " .. msg)
    end
end

-- #### SETUP #### --

Mock.addPlayer(1, "Rustypredator")
Bridge.initialize()

local key = Auth.createKey(1, "test harness")
check(type(key) == "string" and #key > 20, "createKey returns a long token")
check(Auth.resolve(key) == 1, "resolve maps the key back to its player")
check(Auth.resolve("avo_nonsense") == nil, "resolve rejects an unknown key")
check(Auth.resolve(nil) == nil, "resolve rejects a nil key")

-- #### HELPERS #### --

local seq = 0
local function request(tbl)
    seq = seq + 1
    local id = "req" .. seq

    tbl.id = id
    local path = Config.getRequestsDir() .. "/" .. id .. ".json"
    local f = assert(io.open(path, "wb"))
    f:write(Json.encode(tbl))
    f:close()

    -- one tick, long enough to clear the poll interval
    Bridge.update(Config.pollInterval)

    local rf = io.open(Config.getResponsesDir() .. "/" .. id .. ".json", "rb")
    if not rf then return nil, id end

    local content = rf:read("*all")
    rf:close()

    return Json.decode(content), id
end

-- #### TESTS #### --

print("\ntransport")

local res = request{key = key, method = "GET", path = "/ping"}
check(res ~= nil, "a request file produces a response file")
check(res and res.status == 200, "GET /ping returns 200")
check(res and res.body.player.index == 1, "ping identifies the calling player")
check(res and res.body.api == Config.apiVersion, "ping reports the API version")
check(res and res.body.game == "2.5.13", "ping reports the game version")

local files = {listFilesOfDirectory(Config.getRequestsDir())}
check(#files == 0, "the request file is consumed")

print("\nauth")

local res = request{key = "avo_bogus", method = "GET", path = "/ping"}
check(res and res.status == 401, "an unknown key is rejected with 401")
check(res and res.body.error.code == "unauthorized", "401 carries a machine-readable code")

local res = request{method = "GET", path = "/ping"}
check(res and res.status == 401, "a missing key is rejected")

-- a revoked key must stop working immediately
local throwaway = Auth.createKey(1, "throwaway")
local fingerprint = Auth.fingerprint(throwaway)
check(Auth.revokeKey(1, fingerprint), "revokeKey reports success")
local res = request{key = throwaway, method = "GET", path = "/ping"}
check(res and res.status == 401, "a revoked key no longer authenticates")
check(Auth.resolve(key) == 1, "revoking one key leaves the others working")

local listed = Auth.listKeys(1)
check(#listed == 1, "listKeys reflects the revocation")
check(listed[1].fingerprint and #listed[1].fingerprint == 8, "keys list by 8-char fingerprint")
check(not string.find(Json.encode(listed), key, 1, true), "listKeys never leaks the full key")

print("\nrouting and errors")

local res = request{key = key, method = "GET", path = "/does-not-exist"}
check(res and res.status == 404, "an unknown path is a 404")

local res = request{key = key, method = "POST", path = "/ping"}
check(res and res.status == 405, "a wrong method is a 405")

local res = request{key = key, method = "GET"}
check(res and res.status == 400, "a missing path is a 400")

local res = request{key = key, method = "GET", path = "relative"}
check(res and res.status == 400, "a non-absolute path is a 400")

-- malformed JSON must still produce an answer rather than a silent drop
local badId = "reqbad"
local f = assert(io.open(Config.getRequestsDir() .. "/" .. badId .. ".json", "wb"))
f:write("{not json")
f:close()
Bridge.update(Config.pollInterval)
local rf = io.open(Config.getResponsesDir() .. "/" .. badId .. ".json", "rb")
check(rf ~= nil, "malformed JSON still gets a response")
if rf then
    local res = Json.decode(rf:read("*all")); rf:close()
    check(res.status == 400 and res.body.error.code == "malformed_json", "malformed JSON is a 400")
end

-- files the client is still writing must be ignored
local tmp = Config.getRequestsDir() .. "/reqpartial.json.tmp"
local f = assert(io.open(tmp, "wb")); f:write("{}"); f:close()
Bridge.update(Config.pollInterval)
local still = io.open(tmp, "rb")
check(still ~= nil, "a .tmp file is left alone")
if still then still:close() end
os.remove(tmp)

print("\nthrottling and cleanup")

-- below the poll interval nothing should be picked up
seq = seq + 1
local id = "reqslow"
local f = assert(io.open(Config.getRequestsDir() .. "/" .. id .. ".json", "wb"))
f:write(Json.encode{id = id, key = key, method = "GET", path = "/ping"})
f:close()
Bridge.update(Config.pollInterval / 4)
check(io.open(Config.getResponsesDir() .. "/" .. id .. ".json", "rb") == nil,
      "the bridge does not poll faster than its interval")
Bridge.update(Config.pollInterval)
check(io.open(Config.getResponsesDir() .. "/" .. id .. ".json", "rb") ~= nil,
      "the request is picked up on the next due tick")

-- responses the client never collected are eventually swept
local before = #{listFilesOfDirectory(Config.getResponsesDir())}
check(before > 0, "responses are sitting in the directory")
Mock.advanceClock(Config.responseTtl + 1)
Bridge.update(Config.pollInterval)
local after = #{listFilesOfDirectory(Config.getResponsesDir())}
check(after == 0, "stale responses are deleted after the TTL")

check(#Mock.errors == 0, "no errors were logged during the run")
if #Mock.errors > 0 then
    for _, e in ipairs(Mock.errors) do print("       > " .. e) end
end

print("")
if failures > 0 then
    print(failures .. " check(s) failed")
    os.exit(1)
end
print("all checks passed")
