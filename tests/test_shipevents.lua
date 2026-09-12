-- The per-ship activity log.
--
-- The log exists because the order chain narrates itself by chat message to a calling
-- player, which an API caller never is. These checks pin the two things that makes
-- awkward: events arrive out of band from the player agent, and they have to survive a
-- round trip through the same plain-table boundary the rest of the write path uses.

package.path = package.path .. ";tests/?.lua;data/scripts/lib/?.lua"

local Mock = require("mock_avorion")
Mock.install()

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

-- #### WORLD #### --

Mock.addPlayer(1, "Rustypredator")
Mock.setOnline(1)
Mock.addShip(1, "Ore Hound", {x = 5, y = 5})
Mock.addShip(1, "Tug", {x = 5, y = 5})

Bridge.initialize()
local key = Auth.createKey(1, "tests")

local seq = 0
local function call(method, path, body, query)
    seq = seq + 1
    local id = "r" .. seq
    local f = assert(io.open(Config.getRequestsDir() .. "/" .. id .. ".json", "wb"))
    f:write(Json.encode{id = id, key = key, method = method, path = path,
                        query = query or {}, body = body or {}})
    f:close()

    Bridge.update(Config.pollInterval)

    local rf = assert(io.open(Config.getResponsesDir() .. "/" .. id .. ".json", "rb"),
                      "no response for " .. method .. " " .. path)
    local res = Json.decode(rf:read("*all")); rf:close()

    return res.status, res.body
end

-- The agent forwards these across a script boundary, so they are always plain tables.
local function pushOrder(ship, chain, activeIndex, finished)
    local entries = {}
    for index, action in ipairs(chain) do
        entries[index] = {name = "Order" .. action, action = action}
    end

    return Bridge.pushShipEvent(1, ship, "order",
                                {chain = entries, activeIndex = activeIndex or 0,
                                 finished = finished or false, x = 5, y = 5})
end

local function pushStatus(ship, text, args)
    return Bridge.pushShipEvent(1, ship, "status",
                                {text = text, template = text, args = args or {}})
end

print("\nGET /ships/{name}/events")

local status, body = call("GET", "/ships/Ore Hound/events")
check(status == 200, "an unknown ship's log is an empty feed, not a 404")
check(#body.events == 0, "with no events")
check(body.recording == true, "and says it is recording while the owner is online")

pushOrder("Ore Hound", {6}, 1, false)
pushStatus("Ore Hound", "Patrolling Sector")

local status, body = call("GET", "/ships/Ore Hound/events")
check(status == 200 and #body.events == 2, "both events are readable")
check(body.events[1].kind == "order" and body.events[2].kind == "status",
      "in the order they happened")
check(body.events[1].chain[1].action == 6, "the order event carries the chain")
check(body.events[2].text == "Patrolling Sector", "the status event carries the text")
check(body.events[1].seq < body.events[2].seq, "sequence numbers increase")

-- the whole point of the cursor: poll without replaying history
local cursor = body.cursor
local status, body = call("GET", "/ships/Ore Hound/events", nil, {since = tostring(cursor)})
check(status == 200 and #body.events == 0, "nothing new since the cursor")

pushStatus("Ore Hound", "Jump not possible. Terminating orders in (5:6)")
local status, body = call("GET", "/ships/Ore Hound/events", nil, {since = tostring(cursor)})
check(#body.events == 1, "only the new event comes back")
check(string.find(body.events[1].text, "Terminating orders") ~= nil,
      "including the reason the chain stopped, which chat would have swallowed")

print("\nnoise control")

-- The engine republishes an unchanged status whenever the AI re-evaluates; recording every
-- repeat would bury the transitions that matter.
local _, feed = call("GET", "/ships/Ore Hound/events")
local before = #feed.events
check(pushStatus("Ore Hound", "Jump not possible. Terminating orders in (5:6)") == false,
      "a repeated status is dropped")
local _, feed = call("GET", "/ships/Ore Hound/events")
check(#feed.events == before, "and does not reach the log")

check(pushStatus("Ore Hound", "Idle") == true, "a changed status is kept")

check(pushOrder("Ore Hound", {6}, 1, false) == true,
      "an order event after a status is kept even if the chain is unchanged")
check(pushOrder("Ore Hound", {6}, 1, false) == false,
      "but an identical consecutive order event is dropped")
check(pushOrder("Ore Hound", {6}, 2, false) == true,
      "advancing to the next order in the chain is a real event")
check(pushOrder("Ore Hound", {6}, 2, true) == true, "so is the chain finishing")

local status, body = call("GET", "/ships/Ore Hound/events")
local last = body.events[#body.events]
check(last.finished == true and last.idle == true,
      "a finished chain is flagged idle, which is what a planner watches for")

print("\nlogs are per ship")

pushStatus("Tug", "Idle")
local status, body = call("GET", "/ships/Tug/events")
check(#body.events == 1, "the Tug has only its own event")
check(body.ship == "Tug", "and the response names it")

print("\nbounds")

for i = 1, Config.shipEventsPerShip + 25 do pushStatus("Tug", "status " .. i) end
local status, body = call("GET", "/ships/Tug/events", nil, {limit = "1000"})
check(#body.events == Config.shipEventsPerShip,
      "the ring buffer caps a busy ship at " .. Config.shipEventsPerShip)
check(body.events[#body.events].text == "status " .. (Config.shipEventsPerShip + 25),
      "keeping the newest")

local status, body = call("GET", "/ships/Tug/events", nil, {limit = "5"})
check(#body.events == 5, "a limit is honoured")
check(body.dropped > 0, "and reports that older events were left out")
check(body.events[#body.events].text == "status " .. (Config.shipEventsPerShip + 25),
      "a limited read returns the newest, not the oldest")

print("\nvalidation and gating")

local status, body = call("GET", "/ships/Ore Hound/events", nil, {since = "-1"})
check(status == 400 and body.error.code == "bad_since", "a negative cursor is rejected")
local status, body = call("GET", "/ships/Ore Hound/events", nil, {limit = "0"})
check(status == 400 and body.error.code == "bad_limit", "so is a zero limit")

local status, body = call("GET", "/ships/Nonexistent/events")
check(status == 404, "a ship the player does not own is a 404")

check(Bridge.pushShipEvent(1, "Ore Hound", "nonsense", {}) == false,
      "an unknown event kind is refused rather than stored")
check(Bridge.pushShipEvent(1, "", "status", {text = "x"}) == false,
      "so is a nameless ship")

-- reads work offline; the log just stops growing
Mock.setOffline(1)
local status, body = call("GET", "/ships/Ore Hound/events")
check(status == 200, "the log is still readable with the owner offline")
check(body.recording == false,
      "but says so, since the callbacks live on the player's own scripts")
check(body.watchers == 0, "and counts nobody watching")

print("\nalliance craft are watched by whichever member is online")

-- The caller (1) is offline throughout this block. Alliance craft publish their
-- callbacks on the Alliance object, so a second member being logged in is enough to keep
-- the log running - and reporting otherwise sent people looking for a bug in a fleet that
-- was recording perfectly well.
Mock.addPlayer(2, "Crewmate")
local alliance = Mock.addAlliance(100, "Test Alliance", 1, nil, {1, 2})
Mock.addShip(100, "Alliance Hauler", {x = 8, y = 8})

Mock.setOffline(2)
local status, body = call("GET", "/ships/Alliance Hauler/events", nil, {owner = "alliance"})
check(status == 200, "an alliance craft's log reads back")
check(body.recording == false, "nobody online, so nothing is being recorded")

Mock.setOnline(2)
local status, body = call("GET", "/ships/Alliance Hauler/events", nil, {owner = "alliance"})
check(body.recording == true,
      "another member online is enough, even though the key's owner is not")
check(body.watchers == 1, "and exactly one agent is watching")

Mock.setOnline(1)
local status, body = call("GET", "/ships/Alliance Hauler/events", nil, {owner = "alliance"})
check(body.watchers == 2, "both members online means two agents watching")

-- The caller's own craft are a different question: those callbacks live on their Player.
Mock.setOffline(1)
local status, body = call("GET", "/ships/Ore Hound/events")
check(body.recording == false,
      "a member being online does not record the caller's personal craft")

-- What the alliance agent actually pushes, keyed by the alliance index rather than any
-- member's, which is what makes one log serve every member.
check(Bridge.pushShipEvent(100, "Alliance Hauler", "status", {text = "Patrolling"}) == true,
      "an alliance event is recorded against the alliance")
local status, body = call("GET", "/ships/Alliance Hauler/events", nil, {owner = "alliance"})
check(#body.events == 1 and body.events[1].text == "Patrolling",
      "and reads back off the alliance's log")

-- Two members online both register on the same Alliance object, so the same change is
-- forwarded twice. The duplicate has to die here or every alliance log doubles.
check(Bridge.pushShipEvent(100, "Alliance Hauler", "status", {text = "Patrolling"}) == false,
      "a second member forwarding the same change is collapsed, not recorded twice")

print("")
if failures == 0 then
    print("all checks passed")
else
    print(failures .. " check(s) failed")
    os.exit(1)
end
