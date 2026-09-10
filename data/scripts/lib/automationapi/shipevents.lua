-- A per-ship activity log, populated as things happen rather than polled.
--
-- Why this exists: the order chain narrates itself by chat message to whoever gave the
-- order - "Order completed. Awaiting new orders.", "Jump not possible. Terminating orders
-- in (x:y)" (orderchain.lua:1435, :1776). An API caller never sees those. There is no
-- server-side hook on outgoing chat, and onChatMessage fires only for messages a player
-- *sends*, so that channel is closed to us.
--
-- The same information is published a second way, though: every change to a ship's order
-- info or AI status message raises a callback on the owning Player or Alliance. The player
-- agent registers those and forwards them here, which is why this log records what a ship
-- did and why it stopped, instead of only what the API asked it to do.
--
-- Two consequences worth stating plainly:
--
--   * Player and Alliance scripts only run while the owner is online, so nothing is
--     recorded while they are logged out. That is the same constraint the whole write path
--     has, not a new one.
--   * The log lives in memory and starts empty after a server restart. It is a recent
--     activity feed, not an audit trail.

local Json = include("automationapi/json")
local Config = include("automationapi/config")
local Serialize = include("automationapi/serialize")

local ShipEvents = {}

-- keyed "<ownerIndex>/<shipName>" -> {events = {}, nextSeq = n}
local logs = {}

-- Sequence numbers are global rather than per ship, so a caller watching several ships can
-- hold one cursor across all of them and still see a consistent order.
local nextSeq = 0

local function keyOf(ownerIndex, shipName)
    return tostring(ownerIndex) .. "/" .. tostring(shipName)
end

local function logFor(ownerIndex, shipName)
    local key = keyOf(ownerIndex, shipName)
    local log = logs[key]

    if not log then
        log = {events = {}}
        logs[key] = log
    end

    return log
end

-- Status messages in particular repeat: the engine republishes the same text whenever the
-- AI re-evaluates. Recording every repeat would bury the transitions that matter.
local function sameAsLast(log, kind, event)
    local last = log.events[#log.events]
    if not last or last.kind ~= kind then return false end

    if kind == "status" then return last.text == event.text end

    if kind == "order" then
        if last.activeIndex ~= event.activeIndex then return false end
        if last.finished ~= event.finished then return false end
        if #last.chain ~= #event.chain then return false end

        for index, entry in ipairs(event.chain) do
            if last.chain[index].action ~= entry.action then return false end
        end

        return true
    end

    return false
end

local function chainOf(payload)
    local chain = Json.array({})

    for _, entry in ipairs((payload or {}).chain or {}) do
        chain[#chain + 1] =
        {
            name = Serialize.string(entry.name),
            action = Serialize.number(entry.action, 0),
        }
    end

    return chain
end

-- Called from the player agent, across a script boundary, so `payload` is a plain table.
function ShipEvents.push(ownerIndex, shipName, kind, payload)
    if type(shipName) ~= "string" or shipName == "" then return false end
    if kind ~= "order" and kind ~= "status" then return false end

    payload = payload or {}

    local event = {kind = kind}

    if kind == "order" then
        event.chain = chainOf(payload)
        event.activeIndex = Serialize.number(payload.activeIndex, 0)
        event.finished = payload.finished == true

        if payload.x and payload.y then
            event.sector = Serialize.vec2(payload.x, payload.y)
        end

        -- The most useful single field for a planner: the chain emptied on its own.
        event.idle = event.finished or #event.chain == 0
    else
        event.text = Serialize.string(payload.text)
        event.template = Serialize.string(payload.template)
        event.args = payload.args or {}
    end

    local log = logFor(ownerIndex, shipName)
    if sameAsLast(log, kind, event) then return false end

    nextSeq = nextSeq + 1
    event.seq = nextSeq

    local ok, now = pcall(function() return Server().unpausedRuntime end)
    event.at = Serialize.number(ok and now or 0, 0)

    log.events[#log.events + 1] = event

    -- Ring buffer: drop the oldest rather than letting a busy ship grow without bound.
    local overflow = #log.events - Config.shipEventsPerShip
    if overflow > 0 then
        local trimmed = {}
        for index = overflow + 1, #log.events do
            trimmed[#trimmed + 1] = log.events[index]
        end
        log.events = trimmed
    end

    return true
end

-- Returns events for one ship, oldest first, optionally only those after `since`.
function ShipEvents.read(ownerIndex, shipName, since, limit)
    local log = logs[keyOf(ownerIndex, shipName)]
    local out = Json.array({})

    if not log then return out, 0 end

    local dropped = 0

    for _, event in ipairs(log.events) do
        if since == nil or event.seq > since then
            out[#out + 1] = event
        end
    end

    -- Keep the newest when a limit cuts in: a caller catching up cares about where the ship
    -- is now, and can page backwards with `since` if it wants the rest.
    if limit and #out > limit then
        local trimmed = Json.array({})
        for index = #out - limit + 1, #out do
            trimmed[#trimmed + 1] = out[index]
        end
        dropped = #out - limit
        out = trimmed
    end

    return out, dropped
end

-- The most recent order event for a ship, or nil.
--
-- This is how a dispatch gets confirmed. The obvious alternative - reading getShipOrderInfo
-- back off the owner handle the request captured - does not work: that handle serves a
-- cached ShipInfo and keeps returning the state it held when the request arrived, so a
-- chain that has plainly moved reads as unchanged. The pushed events are the live view.
function ShipEvents.latestOrder(ownerIndex, shipName)
    local log = logs[keyOf(ownerIndex, shipName)]
    if not log then return nil end

    for index = #log.events, 1, -1 do
        if log.events[index].kind == "order" then return log.events[index] end
    end

    return nil
end

-- The highest sequence number issued so far, so a caller can start watching from "now"
-- without replaying history.
function ShipEvents.cursor()
    return nextSeq
end

function ShipEvents.forget(ownerIndex, shipName)
    logs[keyOf(ownerIndex, shipName)] = nil
end

return ShipEvents
