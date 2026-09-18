-- The location library: named sectors kept per faction, the player's own and the alliance's
-- shared by every member, and destinations resolved through it. Programs naming locations
-- are tests/test_programs.lua's business.

package.path = "data/scripts/lib/?.lua;tests/?.lua;" .. package.path

local Mock = require("mock_avorion")
Mock.install()
Mock.reset()

local Json = require("automationapi.json")
local Config = require("automationapi.config")
local Auth = require("automationapi.auth")
local Locations = require("automationapi.locations")

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
Mock.addAlliance(9, "Rusty Co", 1, nil, {1, 2})

Mock.addShip(1, "Hauler", {x = 0, y = 0, range = 5, captain = {name = "Vel", level = 2, primaryClass = 3}})
Mock.addShip(9, "Freighter", {x = 0, y = 0, range = 5, captain = {name = "Ori", level = 2, primaryClass = 3}})

Bridge.initialize()

local keys = {[1] = Auth.createKey(1, "tests"), [2] = Auth.createKey(2, "tests")}
local seq = 0

local function call(method, path, body, query, as)
    seq = seq + 1
    local id = "l" .. seq

    local f = assert(io.open(Config.getRequestsDir() .. "/" .. id .. ".json", "wb"))
    f:write(Json.encode{id = id, key = keys[as or 1], method = method, path = path,
                        body = body or {}, query = query or {}})
    f:close()

    Bridge.update(Config.pollInterval)

    local rf = io.open(Config.getResponsesDir() .. "/" .. id .. ".json", "rb")
    if not rf then return nil end
    local res = Json.decode(rf:read("*all")); rf:close()
    return res.status, res.body
end

-- #### THE LIBRARY #### --

print("\nsaving locations")

local status, body = call("POST", "/locations/Home", {x = 10, y = -4, note = "the shipyard"})
check(status == 200 and body.x == 10 and body.y == -4 and body.note == "the shipyard"
      and body.revision == 1 and body.owner.kind == "player" and body.updatedBy.name == "Rustypredator",
      "a location is saved with its revision and author")

status, body = call("POST", "/locations/Nowhere", {note = "no coordinates"})
check(status == 400 and body.error.code == "bad_coordinates", "a new location needs coordinates")

status, body = call("POST", "/locations/Home", {x = 1.5, y = 2})
check(status == 400 and body.error.code == "bad_coordinates", "whole ones")

status, body = call("POST", "/locations/" .. string.rep("x", 60), {x = 1, y = 2})
check(status == 400 and body.error.code == "bad_name", "names have a length limit")

status, body = call("POST", "/locations/Home", {note = "the old shipyard"})
check(status == 200 and body.x == 10 and body.note == "the old shipyard" and body.revision == 2,
      "a change keeps what it leaves out")

status, body = call("POST", "/locations/Home", {x = 11, y = -4, ifRevision = 1})
check(status == 409 and body.error.code == "location_changed", "a stale revision is refused")

status, body = call("POST", "/locations/Home", {note = Json.null})
check(status == 200 and body.note == nil, "a null note clears it")

print("\nthe alliance's library")

status, body = call("POST", "/locations/Home", {x = 50, y = 50}, {owner = "alliance"}, 2)
check(status == 200 and body.owner.kind == "alliance", "any member adds to the alliance's library")

status, body = call("GET", "/locations", nil, nil, 1)
local seen = {}
for _, location in ipairs(body.locations) do seen[location.owner.kind .. "/" .. location.name] = location end
check(seen["player/Home"] and seen["alliance/Home"] and seen["alliance/Home"].updatedBy.name == "Wingmate",
      "and every member sees it next to their own")

status, body = call("GET", "/locations", nil, nil, 2)
check(#body.locations == 1 and body.locations[1].owner.kind == "alliance",
      "a member sees only the alliance's and their own")

print("\ndestinations by location")

local Routes = require("automationapi.routes")
local Owner = require("automationapi.owner")
local ctx = {player = Mock.player(1), playerIndex = 1, query = {}}
local owner, entry = Routes.findLocation(ctx, "Home", Owner.all(ctx)[1])
check(owner.kind == "player" and entry.x == 10 and entry.y == -4,
      "a player's craft finds the player's own location first")
owner, entry = Routes.findLocation(ctx, "Home", Owner.all(ctx)[2])
check(owner.kind == "alliance" and entry.x == 50, "an alliance craft the alliance's")

local ok, err = pcall(Routes.findLocation, ctx, "Atlantis", Owner.all(ctx)[1])
check(not ok and err.code == "no_such_location", "an unknown location is a 404")

print("\ndeleting")

status, body = call("POST", "/locations/Home/delete")
check(status == 200 and body.deleted == true, "a location nobody uses is deleted")
status, body = call("POST", "/locations/Home/delete")
check(status == 200 and body.deleted == false, "and deleting it twice is harmless")

print("\nlimits")

Config.maxLocations = 2
call("POST", "/locations/One", {x = 1, y = 1})
call("POST", "/locations/Two", {x = 2, y = 2})
status, body = call("POST", "/locations/Three", {x = 3, y = 3})
check(status == 409 and body.error.code == "too_many_locations", "a library holds a limited number")
status, body = call("POST", "/locations/Two", {x = 4, y = 4})
check(status == 200, "but a full one can still be edited")

print("\nsurviving a restart")

Locations.resetState()
status, body = call("GET", "/locations", {}, {owner = "player"})
check(#body.locations == 2 and body.locations[2].x == 4, "the library is read back from the server")

print("")
if failures > 0 then print(failures .. " check(s) failed"); os.exit(1) end
print("all checks passed")
