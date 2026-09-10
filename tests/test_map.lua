-- Map knowledge: known sectors, seed prediction and the station search.
--
-- The prediction maths itself is vanilla and is verified in game; what these cover is
-- the part this mod owns - filtering, paging, the known/predicted split, and the fact
-- that a wide search is sliced across ticks instead of stalling one.

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
Mock.addAlliance(77, "Rusty Industries", 1, {[AlliancePrivilege.ManageShips] = true})
Mock.homeSectors[1] = {x = -120, y = 90}

Mock.addKnownSector(1, 0, 0, {name = "Origin", visited = true, factionIndex = 5,
                              numStations = 2, numShips = 4, timeStamp = 100,
                              stations = {"Turret Factory", "Repair Dock"},
                              gates = {{x = 40, y = 40}},
                              stationsByFaction = {[5] = 2}})
Mock.addKnownSector(1, 1, 0, {name = "Next Door", visited = true, factionIndex = 5,
                              numStations = 1, timeStamp = 300,
                              stations = {"Iron Mine"}})
Mock.addKnownSector(1, 0, 1, {name = "Scouted", visited = false, factionIndex = 0,
                              numStations = 0, timeStamp = 500})
Mock.addKnownSector(1, 60, 60, {name = "Far Off", visited = true, factionIndex = 9,
                                numStations = 1, timeStamp = 700,
                                stations = {"Turret Factory Supplier"}})
Mock.addKnownSector(77, 5, 5, {name = "Alliance Yard", visited = true,
                               numStations = 1, stations = {"Shipyard"}})

-- what the seed says about sectors nobody has been to
Mock.addPredictedSector(10, 10, {regular = true, name = "Predicted Alpha", factionIndex = 3,
                                 stations = {"Turret Factory", "Casino"}})
Mock.addPredictedSector(12, 11, {regular = true, name = "Predicted Beta", factionIndex = 3,
                                 stations = {"Iron Mine"}})
Mock.addPredictedSector(14, 12, {offgrid = true, name = "Predicted Offgrid"})

Bridge.initialize()
local key = Auth.createKey(1, "tests")

local seq = 0

local function send(method, path, query)
    seq = seq + 1
    local id = "p" .. seq

    local f = assert(io.open(Config.getRequestsDir() .. "/" .. id .. ".json", "wb"))
    f:write(Json.encode{id = id, key = key, method = method, path = path,
                        query = query or {}, body = {}})
    f:close()

    Bridge.update(Config.pollInterval)

    return function()
        local rf = io.open(Config.getResponsesDir() .. "/" .. id .. ".json", "rb")
        if not rf then return nil end
        local res = Json.decode(rf:read("*all")); rf:close()
        return res.status, res.body
    end
end

local function call(method, path, query)
    return send(method, path, query)()
end

-- #### GALAXY INFO #### --

print("\nGET /galaxy/info")

local status, info = call("GET", "/galaxy/info")
check(status == 200, "returns 200")
check(info.bounds.min == -499 and info.bounds.max == 500, "reports the galaxy bounds")
check(info.barrier.min == 147, "reports the barrier ring")
check(info.homeSector.x == -120 and info.homeSector.y == 90, "reports the home sector")
check(info.knownSectors == 5, "counts known sectors across player and alliance")
check(info.materialBelts.Avorion ~= nil and info.materialBelts.Iron > info.materialBelts.Avorion,
      "material belts are in sector coordinates, Iron furthest out")

-- #### KNOWN SECTORS #### --

print("\nGET /map/sectors")

local status, body = call("GET", "/map/sectors")
check(status == 200, "returns 200")
check(body.total == 4, "lists the player's known sectors")
check(body.sectors[1].coordinates.x == 0 and body.sectors[1].coordinates.y == 0,
      "ordered by y then x")
check(body.sectors[1].name == "Origin", "carries the sector name")
check(body.sectors[1].numStations == 2, "and its station count")

local _, body = call("GET", "/map/sectors", {owner = "all"})
check(body.total == 5, "owner=all merges the alliance's knowledge")

local _, body = call("GET", "/map/sectors", {bbox = "-1,-1,1,1"})
check(body.total == 3, "bbox filters, inclusive at both ends")

local _, body = call("GET", "/map/sectors", {bbox = "1,1,-1,-1"})
check(body.total == 3, "bbox corners may be given in any order")

local status, body = call("GET", "/map/sectors", {bbox = "1,2,3"})
check(status == 400 and body.error.code == "bad_bbox", "a malformed bbox is a 400")

local _, body = call("GET", "/map/sectors", {visited = "false"})
check(body.total == 1 and body.sectors[1].name == "Scouted", "visited=false filters")

local _, body = call("GET", "/map/sectors", {faction = "5"})
check(body.total == 2, "faction filters")

local _, body = call("GET", "/map/sectors", {since = "400"})
check(body.total == 2, "since filters on the knowledge timestamp")

local _, body = call("GET", "/map/sectors", {stations = "2"})
check(body.total == 1 and body.sectors[1].name == "Origin", "stations sets a minimum")

local _, body = call("GET", "/map/sectors", {limit = "2"})
check(body.count == 2 and body.total == 4, "limit pages while total stays honest")

local _, body = call("GET", "/map/sectors", {limit = "2", offset = "2"})
check(body.count == 2 and body.sectors[1].coordinates.y == 1, "offset continues the page")

print("\nGET /map/sectors/{x}/{y}")

local status, sector = call("GET", "/map/sectors/0/0")
check(status == 200, "returns 200")
check(sector.source == "known", "labelled as observed rather than predicted")
check(#sector.stations == 2, "lists station titles")
check(sector.stations[1].name == "Turret Factory", "titles are flattened to plain names")
check(#sector.gateDestinations == 1 and sector.gateDestinations[1].x == 40, "gate destinations")
check(sector.balancing.techLevel > 0, "carries the balancing curves for the position")
check(sector.balancing.materials.Iron == 0.5, "including material probabilities by name")

local status, body = call("GET", "/map/sectors/99/99")
check(status == 404 and body.error.code == "sector_unknown",
      "an unknown sector is a 404 pointing at the prediction endpoint")

local status, body = call("GET", "/map/sectors/foo/0")
check(status == 400 and body.error.code == "bad_coordinates", "a non-numeric coordinate is a 400")

-- #### PREDICTION #### --

print("\nGET /map/predict/{x}/{y}")

local status, predicted = call("GET", "/map/predict/10/10")
check(status == 200, "returns 200")
check(predicted.source == "predicted", "labelled as predicted")
check(predicted.regular == true and predicted.hasContent == true, "reports sector content")
check(#predicted.stations == 2, "lists the stations the seed says are there")
check(predicted.stations[1].name == "Turret Factory", "by name")
check(predicted.known == nil, "with no observation attached for an unvisited sector")

local _, predicted = call("GET", "/map/predict/0/0")
check(predicted.known ~= nil and predicted.known.name == "Origin",
      "a sector the player has seen carries the observation alongside the prediction")

local _, empty = call("GET", "/map/predict/500/500")
check(empty.hasContent == false and #empty.stations == 0,
      "an empty sector predicts as empty rather than failing")

-- #### SEARCH #### --

print("\nGET /map/search")

local status, body = call("GET", "/map/search")
check(status == 400 and body.error.code == "no_search_term", "a missing search term is a 400")

local status, found = call("GET", "/map/search", {station = "turret factory"})
check(status == 200, "returns 200")
check(found.count == 2, "matches known sectors case-insensitively, including partial names")
check(found.results[1].source == "known", "labelled as observed")
check(found.results[1].matches[1] == "Turret Factory", "reports which station matched")

local _, found = call("GET", "/map/search", {station = "mine,shipyard", owner = "all"})
check(found.count == 2, "several comma-separated terms match as alternatives")

local status, body = call("GET", "/map/search", {station = "turret", predict = "true"})
check(status == 400 and body.error.code == "bbox_required",
      "a predicted search without a bbox is refused rather than scanning the galaxy")

print("\nGET /map/search?predict=true - sliced across ticks")

Mock.predictions = 0
local read = send("GET", "/map/search", {station = "turret,mine", predict = "true",
                                         bbox = "0,0,60,60"})
check(read() == nil, "a predicted search does not answer on the first tick")

local ticks = 0
while read() == nil and ticks < 200 do
    Bridge.update(Config.pollInterval)
    ticks = ticks + 1
end

local status, found = read()
check(status == 200, "it answers once the scan finishes")
check(ticks >= 3, "spread across several ticks rather than stalling one (" .. ticks .. ")")
check(found.scanned >= 3721, "scanned the whole box")
check(Mock.predictions <= 10,
      "the cheap seed filter kept full generator runs down to "
      .. Mock.predictions .. " for 3721 sectors")

local sources, names = {}, {}
for _, hit in ipairs(found.results) do
    sources[hit.source] = true
    names[#names + 1] = hit.name
end
table.sort(names)

check(sources.known == true and sources.predicted == true,
      "results mix observed and predicted sectors")
check(table.concat(names, ",") == "Far Off,Next Door,Origin,Predicted Alpha,Predicted Beta",
      "and cover both (got " .. table.concat(names, ",") .. ")")

local sectorsSeen = {}
for _, hit in ipairs(found.results) do
    local key = hit.coordinates.x .. ":" .. hit.coordinates.y
    check(sectorsSeen[key] == nil, "no sector is reported twice (" .. key .. ")")
    sectorsSeen[key] = true
end

check(#Mock.errors == 0, "no errors logged")
for _, e in ipairs(Mock.errors) do print("       > " .. e) end

print("")
if failures > 0 then print(failures .. " check(s) failed"); os.exit(1) end
print("all checks passed")
