-- Mission catalog, preview and start orchestration, against the mocked simulation.
--
-- The vanilla prediction maths is not reproduced here - that is verified in game. What
-- these cover is the part this mod owns: config translation, area maths, the deferred
-- response, validation gating and the start handshake.

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

Mock.addPlayer(1, "Rustypredator")
Mock.addShip(1, "Prospector",
{
    x = -316, y = 319, range = 4.1, cargoFree = 768,
    -- generateAssessmentFromPrediction needs a captain, so a captainless ship has no
    -- assessment at all
    captain = {name = "Pritteggi", level = 3, tier = 3, primaryClass = 4},
})
Bridge.initialize()
local key = Auth.createKey(1, "tests")

local seq = 0

-- Sends a request and ticks. Deferred endpoints need the async worker flushed, so this
-- returns a resume() the caller invokes when it wants the analysis to land.
local function send(method, path, body, query)
    seq = seq + 1
    local id = "m" .. seq

    local f = assert(io.open(Config.getRequestsDir() .. "/" .. id .. ".json", "wb"))
    f:write(Json.encode{id = id, key = key, method = method, path = path,
                        body = body or {}, query = query or {}})
    f:close()

    Bridge.update(Config.pollInterval)

    local function read()
        local rf = io.open(Config.getResponsesDir() .. "/" .. id .. ".json", "rb")
        if not rf then return nil end
        local res = Json.decode(rf:read("*all")); rf:close()
        return res.status, res.body
    end

    return read, id
end

local function call(method, path, body, query)
    local read = send(method, path, body, query)
    local status, resBody = read()

    if status == nil then
        -- deferred: let the worker finish, then tick again
        Mock.flushAsync()
        Bridge.update(Config.pollInterval)
        status, resBody = read()
    end

    return status, resBody
end

-- #### CATALOG #### --

print("\ncatalog")

local status, body = call("GET", "/missions")
check(status == 200, "GET /missions returns 200")
check(#body.missions == 12, "all twelve mission types listed (got " .. #body.missions .. ")")
check(body.materials[1] == "Iron", "materials are ordered from Iron, not hash order")
check(body.materials[7] == "Avorion", "materials run through to Avorion")

local escort
for _, m in ipairs(body.missions) do if m.mission == "escort" then escort = m end end
check(escort and escort.startable == false, "escort is listed but not startable")

local status = call("POST", "/ships/Prospector/missions/escort/preview")
check(status == 422, "starting an escort directly is refused")

local status = call("POST", "/ships/Prospector/missions/nonsense/preview")
check(status == 404, "an unknown mission type is a 404")

local status, body = call("GET", "/ships/Prospector/missions")
check(status == 200 and #body.missions == 11, "per-ship catalog omits escort")

-- #### PREVIEW #### --

print("\npreview")

local status, body = call("POST", "/ships/Prospector/missions/mine/preview",
                          {config = {duration = 2}, materials = {"Iron", "Titanium"}})
check(status == 200, "preview returns 200")
check(body.canStart == true, "a healthy ship with no errors can start")
check(body.mission == "mine" and body.ship == "Prospector", "echoes what was asked for")

-- the area maths: 15x15 centred on the ship, upper bound inclusive
check(body.area.lower.x == -323 and body.area.lower.y == 312, "area is centred on the ship")
check(body.area.upper.x == -309 and body.area.upper.y == 326, "upper bound is inclusive")

check(body.config.materials[1] == "Iron" and #body.config.materials == 2,
      "material selection round-trips as names")
check(Json.isArray(body.config.escorts) and #body.config.escorts == 0,
      "an empty escort list is an array, not an object")
check(body.config.duration == 2, "config value passed through")
check(#body.assessment > 0, "the captain's assessment is included")
check(body.prediction ~= nil, "a prediction is included")

-- materials are index-keyed with different bases per mission; callers must never see that
local _, refine = call("POST", "/ships/Prospector/missions/refine/preview",
                       {materials = {"Naonite"}})
check(refine.config.materials[1] == "Naonite" and #refine.config.materials == 1,
      "refine uses a different index base but still round-trips by name")

local _, defaulted = call("POST", "/ships/Prospector/missions/mine/preview", {config = {duration = 2}})
check(#defaulted.config.materials == 7, "omitting materials selects them all")

local status = call("POST", "/ships/Prospector/missions/mine/preview",
                    {materials = {"Unobtainium"}})
check(status == 400, "an unknown material is a 400")

-- clamping must match the game's own clamp
local _, clamped = call("POST", "/ships/Prospector/missions/mine/preview", {config = {duration = 99}})
check(clamped.config.duration == 2, "duration is clamped to the command's maximum")

-- explicit rectangles are honoured verbatim
local _, explicit = call("POST", "/ships/Prospector/missions/mine/preview",
                         {area = {lower = {x = 0, y = 0}, upper = {x = 14, y = 14}}})
check(explicit.area.lower.x == 0 and explicit.area.upper.x == 14, "an explicit area is used as given")

-- #### VALIDATION #### --

print("\nvalidation gating")

Mock.commandError = "Not enough turret slots for all turrets!"
local _, blocked = call("POST", "/ships/Prospector/missions/mine/preview", {})
check(blocked.canStart == false, "a command error blocks starting")
check(blocked.errors.command.text == "Not enough turret slots for all turrets!",
      "the game's own wording is preserved")

local status, blockedStart = call("POST", "/ships/Prospector/missions/mine/start", {})
check(status == 422, "start refuses when preview would refuse")
check(blockedStart.started == false, "and says so explicitly")
check(#Mock.simulationCalls == 0, "nothing was dispatched to the simulation")
Mock.commandError = nil

Mock.predictionError = "This mining operation won't yield any resources!"
local _, noYield = call("POST", "/ships/Prospector/missions/mine/preview", {})
check(noYield.canStart == false, "a prediction error blocks starting")
Mock.predictionError = nil

Mock.addShip(1, "Hulk", {x = 0, y = 0, usableError = 3})
local _, unusable = call("POST", "/ships/Hulk/missions/mine/preview", {})
check(unusable.canStart == false, "an unusable ship cannot start")
check(unusable.errors.usable.code == "NoCaptain", "and reports why")

-- #### START #### --

print("\nstart")

Mock.simulationCalls = {}
local status, started = call("POST", "/ships/Prospector/missions/mine/start",
                             {config = {duration = 1}, materials = {"Iron"}})
check(status == 200, "start returns 200")
check(started.started == true, "reports the mission as started")

local calls = Mock.simulationCalls
check(#calls == 2, "two simulation calls were made (got " .. #calls .. ")")
check(calls[1].fn == "areaAnalysisFinished", "the analysis is handed over first")
check(calls[2].fn == "startCommand", "then the command is started")
check(calls[1].args[2] == Mock.commandTypes.Mine, "the real CommandType uuid is used")
check(calls[2].args[1] == "Prospector", "for the right ship")

-- startCommand reports failure only by chat message, so the mod must verify afterwards
Mock.addShip(1, "Stubborn", {x = 0, y = 0, refuseStart = true})
local status, refused = call("POST", "/ships/Stubborn/missions/mine/start", {})
check(status == 422 and refused.started == false,
      "a silently refused start is detected and reported")
check(refused.error.code == "start_rejected", "with a specific code")

-- #### OFFLINE #### --

print("\noffline owner")

Mock.setOffline(1)
local status, offline = call("POST", "/ships/Prospector/missions/mine/start", {})
check(status == 409 and offline.error.code == "owner_offline", "start refuses while offline")

local status = call("POST", "/ships/Prospector/missions/mine/preview", {})
check(status == 200, "preview still works while offline")

local status = call("GET", "/ships/Prospector")
check(status == 200, "ship reads still work while offline")
Mock.setOnline(1)

-- #### TIMEOUT #### --

print("\ntimeouts")

local read = send("POST", "/ships/Prospector/missions/mine/preview", {})
check(read() == nil, "a deferred request writes no response yet")
Mock.asyncQueue = {}    -- the worker never comes back
Mock.advanceClock(Config.requestTimeout + 1)
Bridge.update(Config.pollInterval)
local status = read()
check(status == 504, "a request whose analysis never lands times out with 504")

check(#Mock.errors == 0, "no errors logged")
for _, e in ipairs(Mock.errors) do print("       > " .. e) end

print("")
if failures > 0 then print(failures .. " check(s) failed"); os.exit(1) end
print("all checks passed")
