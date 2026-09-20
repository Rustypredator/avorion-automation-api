-- /keys: a player managing their own API keys over the API, which is what the console's
-- Keys tab drives. Making a key is not here on purpose - that stays /apikey new in game
-- chat - so what this pins is the rest of a key's life, and that one player's keys are
-- invisible and untouchable to another.

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
    if cond then print("  ok   " .. msg)
    else failures = failures + 1; print("  FAIL " .. msg) end
end

-- #### WORLD #### --

Mock.addPlayer(1, "Rustypredator")
Mock.addPlayer(2, "Wingmate")

Bridge.initialize()

local mine = Auth.createKey(1, "console")
local spare = Auth.createKey(1, "")
local theirs = Auth.createKey(2, "wingmate's")

local seq = 0

local function callWith(key, method, path, body)
    seq = seq + 1
    local id = "k" .. seq

    local f = assert(io.open(Config.getRequestsDir() .. "/" .. id .. ".json", "wb"))
    f:write(Json.encode{id = id, key = key, method = method, path = path,
                        body = body or {}, query = {}})
    f:close()

    Bridge.update(Config.pollInterval)

    local rf = io.open(Config.getResponsesDir() .. "/" .. id .. ".json", "rb")
    if not rf then return nil end
    local res = Json.decode(rf:read("*all")); rf:close()
    return res.status, res.body
end

local function call(method, path, body) return callWith(mine, method, path, body) end

local function byFingerprint(keys, fingerprint)
    for _, entry in ipairs(keys or {}) do
        if entry.fingerprint == fingerprint then return entry end
    end
    return nil
end

-- #### LISTING #### --

print("\nlisting")

local status, body = call("GET", "/keys")
check(status == 200 and #body.keys == 2, "a player reads their own keys, and only those")

local encoded = Json.encode(body)
check(not string.find(encoded, mine, 1, true) and not string.find(encoded, spare, 1, true),
      "and the listing never carries a key itself")

check(byFingerprint(body.keys, Auth.fingerprint(mine)).current == true
      and byFingerprint(body.keys, Auth.fingerprint(spare)).current == false,
      "the key the request arrived with is marked, so a console can warn before revoking it")

check(byFingerprint(body.keys, Auth.fingerprint(mine)).label == "console",
      "labels come back as given")
check(type(body.now) == "number",
      "with the server's uptime to read the creation stamps against")

status, body = callWith(theirs, "GET", "/keys")
check(status == 200 and #body.keys == 1
      and body.keys[1].fingerprint == Auth.fingerprint(theirs),
      "another player sees theirs and nothing of the first player's")

-- #### RENAMING #### --

print("\nrenaming")

status, body = call("POST", "/keys/" .. Auth.fingerprint(spare), {label = "  the poller  "})
check(status == 200 and byFingerprint(body.keys, Auth.fingerprint(spare)).label == "the poller",
      "a key is renamed, trimmed")
check(#Auth.listKeys(1) == 2, "without making or losing one")

status, body = call("POST", "/keys/" .. Auth.fingerprint(spare), {label = ""})
check(status == 200 and byFingerprint(body.keys, Auth.fingerprint(spare)).label == "",
      "and the name can be taken off again")

status, body = call("POST", "/keys/" .. Auth.fingerprint(spare), {})
check(status == 400 and body.error.code == "bad_label", "renaming to nothing at all is refused")

status, body = call("POST", "/keys/" .. Auth.fingerprint(spare), {label = "a\nb"})
check(status == 400 and body.error.code == "bad_label",
      "so is a label that would forge a line in the key file")

status, body = call("POST", "/keys/" .. Auth.fingerprint(spare), {label = string.rep("x", 49)})
check(status == 400 and body.error.code == "bad_label", "and one nobody could read")

status, body = call("POST", "/keys/notahex!", {label = "no"})
check(status == 400 and body.error.code == "bad_fingerprint",
      "something that is not a fingerprint is turned away before the store sees it")

status, body = call("POST", "/keys/0123abcd", {label = "no"})
check(status == 404 and body.error.code == "unknown_key", "as is a fingerprint nobody owns")

-- Another player's key is nobody else's to rename, and must not even be admitted to
-- exist: the answer is the same 404 as for a fingerprint that was never issued.
status, body = call("POST", "/keys/" .. Auth.fingerprint(theirs), {label = "mine now"})
check(status == 404 and body.error.code == "unknown_key",
      "and so is a key belonging to somebody else")
check(Auth.listKeys(2)[1].label == "wingmate's", "which really did leave it alone")

-- #### REVOKING #### --

print("\nrevoking")

status, body = call("POST", "/keys/" .. Auth.fingerprint(theirs) .. "/delete")
check(status == 404 and body.error.code == "unknown_key", "one player cannot revoke another's")
check(#Auth.listKeys(2) == 1, "which really did leave it alone too")
check(Auth.resolve(theirs) == 2, "and it still opens the API")

status, body = call("POST", "/keys/" .. Auth.fingerprint(spare) .. "/delete")
check(status == 200 and body.revoked == Auth.fingerprint(spare), "a key of their own goes")
check(body.wasCurrent == false, "and this was not the one they are holding")
check(#body.keys == 1, "the listing that comes back is already without it")
check(Auth.resolve(spare) == nil, "and it opens nothing any more")

status, body = call("POST", "/keys/" .. Auth.fingerprint(spare) .. "/delete")
check(status == 404 and body.error.code == "unknown_key", "revoking it twice is a 404, not a crash")

-- The interesting one: revoking the key the request itself arrived with. It has to work
-- (that is how a console retires the key it is holding) and the answer has to say so,
-- because every later call with that key is a 401.
local fingerprint = Auth.fingerprint(mine)
status, body = call("POST", "/keys/" .. fingerprint .. "/delete")
check(status == 200 and body.wasCurrent == true,
      "a console can revoke the very key it is calling with, and is told it just did")
check(#body.keys == 0, "leaving the player with none")

status = call("GET", "/keys")
check(status == 401, "and the next call with it is unauthorized")

print("")
print(failures == 0 and "all checks passed" or (failures .. " check(s) failed"))
os.exit(failures == 0 and 0 or 1)
